pub const default_key = "unknown_key";
pub const API_URL = "https://api.deepseek.com/chat/completions";
pub const CHAT_MODEL = "deepseek-chat";
pub const REASONER_MODEL = "deepseek-reasoner";

pub const SYSTEM_PROMPT = "You are a helpful assistant.";

pub const InputModel = enum {
    deepseekChat,
    deepseekReasoner,
};
