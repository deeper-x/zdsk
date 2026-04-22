const std = @import("std");
const config_api = @import("../config/api.zig");
const ztypes = @import("../data/ztypes.zig");

// Creates and returns a new HTTP client bound to the given allocator.
// write_buffer_size is set to 8192 bytes (above the 1024 default) to prevent
// the client from stalling on large HTTPS POST bodies — see ziglang/zig#25015.
pub fn getInstance(io: std.Io, allocator: std.mem.Allocator) std.http.Client {
    const client: std.http.Client = .{
        .io = io,
        .allocator = allocator,
        .write_buffer_size = 8192,
    };

    return client;
}

// Sends a POST request to the DeepSeek API and returns the raw response body.
// The returned slice is owned by the caller and must be freed with allocator.free().
pub fn sendRequest(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    api_key: []const u8,
    request_body: []const u8, // JSON-encoded ChatRequest
) ![]u8 {
    // response body streams into this growing buffer; freed on scope exit
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    // build the Authorization header value; freed after fetch completes
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_header);

    const result = try client.fetch(.{
        .location = .{ .url = config_api.API_URL },
        .method = .POST,
        .payload = request_body,
        .response_writer = &body.writer, // streams response bytes directly into body
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Authorization", .value = auth_header },
        },
    });

    if (result.status != .ok) {
        // log the status code and raw body to help diagnose API-level errors
        // (e.g. 400 malformed JSON, 401 bad key, 429 rate limit)
        std.log.err("API returned HTTP {d}", .{@intFromEnum(result.status)});
        std.log.err("Body: {s}", .{body.written()});
        return error.ApiError;
    }

    // dupe the response out of body's internal buffer before body.deinit() frees it
    return try allocator.dupe(u8, body.written());
}

// Serialises a ChatRequest to a JSON string ready to be used as an HTTP body.
// The returned slice is owned by the caller and must be freed with allocator.free().
pub fn buildRequestBody(
    allocator: std.mem.Allocator,
    model: []const u8,
    messages: []const ztypes.Message, // full conversation history including system prompt
) ![]u8 {
    const req = ztypes.ChatRequest{
        .model = model,
        .messages = messages,
        .stream = false, // streaming is not supported by this client
        .temperature = 1.0,
    };

    // write the JSON into a growing buffer; freed on scope exit
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    // {f} is the format specifier that triggers std.json.fmt's JSON serialisation;
    // plain {} would produce a Zig struct representation, not valid JSON
    try out.writer.print("{f}", .{std.json.fmt(req, .{})});

    // dupe out of out's internal buffer before out.deinit() frees it
    return try allocator.dupe(u8, out.written());
}
