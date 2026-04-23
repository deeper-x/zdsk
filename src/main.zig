const std = @import("std");
const config_api = @import("./config/api.zig");
const config_system = @import("./config/system.zig");

const ai_server = @import("./ai/server.zig");
const ai_client = @import("./ai/client.zig");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const io = init.io;
    const env_map = init.environ_map;

    // read DEEPSEEK_API_KEY from the environment; exits early if not set
    const api_key = config_api.getKey(env_map);
    defer allocator.free(api_key);

    // args[0] is the binary name, args[1] (if present) is the model override
    const args = try init.minimal.args.toSlice(allocator);

    const model = if (args.len > 1) args[1] else config_system.DEFAULT_MODEL;

    var client = ai_client.getInstance(io, allocator);
    defer client.deinit();

    try ai_server.REPL(io, allocator, &client, api_key, model);
}
