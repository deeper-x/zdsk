const std = @import("std");
const settings = @import("system.zig");

// Reads the DeepSeek API key from the environment.
// Returns an owned slice — the caller must free it with allocator.free().
// Exits the process immediately with an error message if the variable is not set.
pub fn getKey(env_map: *std.process.Environ.Map) []const u8 {
    const default_key = settings.default_key;

    const api_key = env_map.get("DEEPSEEK_API_KEY") orelse default_key;

    return api_key;
}
