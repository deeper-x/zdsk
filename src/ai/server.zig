const std = @import("std");
const ztypes = @import("../data/ztypes.zig");
const config_sh = @import("../config/sh.zig");
const config_api = @import("../config/api.zig");
const config_system = @import("../config/system.zig");
const ai_client = @import("../ai/client.zig");
const ai_server = @import("../ai/server.zig");

// Writes a single line of a code block with a solid background colour that
// stretches to the full terminal width, producing a rectangular highlight.
fn printCodeLine(
    writer: *std.Io.Writer,
    bg: []const u8, // ANSI background escape sequence to apply
    line: []const u8, // actual text content of the line
    width: usize, // terminal column count from termWidth()
) !void {
    // switch on the background colour before writing any text
    try writer.writeAll(bg);
    try writer.writeAll(line);

    // fill the remaining columns with spaces so the background colour
    // extends to the right edge of the terminal, not just the last character
    if (width > line.len) {
        const pad = width - line.len;

        // write spaces in 64-byte chunks to avoid a per-byte vtable call loop;
        // the chunk size is comptime so `spaces` is a static array in the binary
        const spaces = " " ** 64;
        var remaining = pad;

        while (remaining > 0) {
            const n = @min(remaining, spaces.len);
            try writer.writeAll(spaces[0..n]);
            remaining -= n;
        }
    }

    // reset all attributes before the newline so the background colour does
    // not bleed into the next line
    try writer.writeAll(config_sh.ANSI.reset);
    try writer.writeByte('\n');
}

// Extracts the assistant reply text from a raw JSON response body.
// Returns an owned slice — the caller is responsible for freeing it.
pub fn parseResponse(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    // deserialise the full response; unknown fields (usage, system_fingerprint,
    // etc.) are silently ignored since we only need choices[0].message.content
    const parsed = try std.json.parseFromSlice(
        ztypes.ChatResponse,
        allocator,
        raw,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit(); // frees all arena memory owned by the parsed value

    if (parsed.value.choices.len == 0) return error.NoChoicesInResponse;

    // dupe the content string before parsed is freed by the deferred deinit above
    return try allocator.dupe(u8, parsed.value.choices[0].message.content);
}

const RawTerm = struct {
    orig: std.posix.termios,

    pub fn enable() !RawTerm {
        const orig = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = orig;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.iflag.IXON = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
        return .{ .orig = orig };
    }

    pub fn disable(self: *RawTerm) void {
        std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, self.orig) catch {};
    }
};

fn readLine(allocator: std.mem.Allocator, stdout: *std.Io.Writer, prompt: []const u8) !?[]u8 {
    var rt = try RawTerm.enable();
    defer rt.disable();

    try stdout.writeAll(prompt);
    try stdout.flush();

    var buf = std.ArrayList(u8).empty;

    var cursor: usize = 0;

    const fd = std.posix.STDIN_FILENO;

    while (true) {
        var seq: [4]u8 = undefined;
        const n = try std.posix.read(fd, seq[0..1]);
        if (n == 0) return null; // EOF / Ctrl-D

        switch (seq[0]) {
            '\r', '\n' => {
                try stdout.writeAll("\n");
                try stdout.flush();
                return try buf.toOwnedSlice(allocator);
            },
            4 => return null, // Ctrl-D mid-line
            127 => { // backspace
                if (cursor > 0) {
                    _ = buf.orderedRemove(cursor - 1);
                    cursor -= 1;
                }
            },
            '\x1b' => {
                var esc: [2]u8 = undefined;
                _ = std.posix.read(fd, esc[0..1]) catch continue;
                _ = std.posix.read(fd, esc[1..2]) catch continue;
                if (esc[0] == '[') switch (esc[1]) {
                    'D', 'A' => {
                        if (cursor > 0) cursor -= 1;
                    }, // left
                    'C', 'B' => {
                        if (cursor < buf.items.len) cursor += 1;
                    }, // right
                    else => {},
                };
            },
            else => |ch| {
                if (ch >= 32 and ch < 127) {
                    try buf.insert(allocator, cursor, ch);
                    cursor += 1;
                }
            },
        }

        // redraw line
        const move_back = buf.items.len - cursor;
        try stdout.print("\r\x1b[2K{s}{s}", .{ prompt, buf.items });
        if (move_back > 0) try stdout.print("\x1b[{d}D", .{move_back});
        try stdout.flush();
    }
}

// Interactive read-eval-print loop. Runs until the user quits, maintaining
// the full conversation history across turns so the model has context.
pub fn REPL(
    io: std.Io,
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    api_key: []const u8,
    model: []const u8,
) !void {
    // stdout and stdin both require an explicit backing buffer in Zig 0.16;
    // the buffer acts as a ring buffer that the writer flushes to the OS when full
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_writer.interface;

    // var stdin_buf: [4096]u8 = undefined;
    // var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    // const stdin: *std.Io.Reader = &stdin_reader.interface;

    // growing list of {role, content} pairs sent to the API on every request;
    // each content string is heap-allocated and freed in the deferred block below
    var messages = std.ArrayList(ztypes.Message).empty;
    defer {
        for (messages.items) |m| allocator.free(m.content);
        messages.deinit(allocator);
    }

    // seed the conversation with a system prompt so the model knows its role
    try messages.append(allocator, .{
        .role = "system",
        .content = try allocator.dupe(u8, config_system.SYSTEM_PROMPT),
    });

    try stdout.print(
        \\DeepSeek CLI  (model: {s})
        \\Type your message and press Enter. Ctrl-D or /exit to quit.
        \\
        \\
    , .{model});
    try stdout.flush();

    while (true) {
        // read one line into a heap-growing buffer; we use Allocating here
        // because user input length is unbounded at compile time
        var line_buf: std.Io.Writer.Allocating = .init(allocator);
        defer line_buf.deinit();

        const input_or_null = try readLine(allocator, stdout, "You: ");
        const owned_input = input_or_null orelse break; // Ctrl-D
        defer allocator.free(owned_input);
        const input = std.mem.trim(u8, owned_input, " \r\t");

        if (input.len == 0) continue;
        if (std.mem.eql(u8, input, "/exit") or std.mem.eql(u8, input, "/quit")) break;

        // append before sending so the user turn is part of the context;
        // if the request fails we pop it back off to keep history consistent
        try messages.append(allocator, .{
            .role = "user",
            .content = try allocator.dupe(u8, input),
        });

        try stdout.writeAll("DeepSeek: thinking...\r"); // \r overwrites the line on reply
        try stdout.flush();

        const body = try ai_client.buildRequestBody(allocator, model, messages.items);
        defer allocator.free(body);

        const raw_response = ai_client.sendRequest(allocator, client, api_key, body) catch |err| {
            try stdout.print("Error: {s}\n", .{@errorName(err)});
            try stdout.flush();
            // remove the user turn we just appended so history stays consistent
            const last = messages.pop().?;
            allocator.free(last.content);
            continue;
        };
        defer allocator.free(raw_response);

        const reply = ai_server.parseResponse(allocator, raw_response) catch |err| {
            try stdout.print("Parse error: {s}\n", .{@errorName(err)});
            try stdout.flush();
            continue;
        };

        // append the assistant reply so it becomes part of the next request's context;
        // reply is already an owned allocation from parseResponse, no dupe needed
        try messages.append(allocator, .{ .role = "assistant", .content = reply });

        try stdout.writeAll("\r"); // clear the "thinking..." line
        try stdout.writeAll("DeepSeek:\n");

        try ai_server.printReply(stdout, reply);

        try stdout.writeAll("\n");
        try stdout.flush();
    }

    try stdout.writeAll("\nGoodbye!\n");
    try stdout.flush();
}

// Prints the assistant reply to the terminal, rendering markdown fenced code
// blocks as full-width coloured rectangles. Prose lines are printed as-is.
pub fn printReply(writer: *std.Io.Writer, text: []const u8) !void {
    const width = config_sh.getTermWidth(); // sampled once per reply, not per line
    var in_code = false;

    // walk the reply line by line; splitScalar does not allocate
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "```")) {
            // opening or closing fence — toggle code mode and print the fence
            // line itself with the accent colour so the language tag is visible
            in_code = !in_code;
            try printCodeLine(writer, config_sh.ANSI.code_fence, line, width);
        } else if (in_code) {
            // code body line — dark background padded to full terminal width
            try printCodeLine(writer, config_sh.ANSI.code_bg, line, width);
        } else {
            // normal prose line — no colour applied
            try writer.print("{s}\n", .{line});
        }
    }
}
