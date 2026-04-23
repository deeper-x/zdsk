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

// Interactive read-eval-print loop. Runs until the user quits, maintaining
// the full conversation history across turns so the model has context.
pub fn REPL(
    io: std.Io,
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    api_key: []const u8,
    model: []const u8,
) !void {
    // stdout and stdin both require an explicit backing buffer in Zig 0.15;
    // the buffer acts as a ring buffer that the writer flushes to the OS when full
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout: *std.Io.Writer = &stdout_writer.interface;

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    const stdin: *std.Io.Reader = &stdin_reader.interface;

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
        try stdout.writeAll("You: ");
        try stdout.flush(); // flush before blocking on stdin

        // read one line into a heap-growing buffer; we use Allocating here
        // because user input length is unbounded at compile time
        var line_buf: std.Io.Writer.Allocating = .init(allocator);
        defer line_buf.deinit();

        _ = stdin.streamDelimiter(&line_buf.writer, '\n') catch |err| {
            if (err == error.EndOfStream) break; // Ctrl-D
            return err;
        };
        stdin.toss(1); // discard the '\n' that streamDelimiter left in the buffer

        const input = std.mem.trim(u8, line_buf.written(), " \r\t");
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
