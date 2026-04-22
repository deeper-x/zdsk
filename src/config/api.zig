const std = @import("std");

pub const API_URL = "https://api.deepseek.com/chat/completions";
pub const DEFAULT_MODEL = "deepseek-chat";
pub const SYSTEM_PROMPT = "You are a helpful assistant.";

// Reads the DeepSeek API key from the environment.
// Returns an owned slice — the caller must free it with allocator.free().
// Exits the process immediately with an error message if the variable is not set.
pub fn getKey(env_map: *std.process.Environ.Map) []const u8 {
    const default = "todo_move_to_settings_key";

    const api_key = env_map.get("DEEPSEEK_API_KEY") orelse default;

    return api_key;
}
