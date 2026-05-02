const std = @import("std");
const config_api = @import("./config/api.zig");
const cli_input = @import("./cli/input.zig");
const ai_server = @import("./ai/server.zig");
const ai_client = @import("./ai/client.zig");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const env_map = init.environ_map;

    // args[0] is the binary name, args[1] (if present) is the model override
    const args = try init.minimal.args.toSlice(allocator);

    // read DEEPSEEK_API_KEY from the environment; exits early if not set
    const api_key = config_api.getKey(env_map);
    defer allocator.free(api_key);

    // in case no arg is passed , set deepseek-chat as default
    const input_model: []const u8 = cli_input.get_model(args);

    var client: std.http.Client = ai_client.getInstance(io, allocator);
    defer client.deinit();

    try ai_server.REPL(io, allocator, &client, api_key, input_model);
}
