pub const Message = struct {
    role: []const u8,
    content: []const u8,
};

pub const ChatRequest = struct {
    model: []const u8,
    messages: []const Message,
    stream: bool = false,
    temperature: f32 = 1.0,
    max_tokens: ?u32 = null,
};

pub const ResponseMessage = struct {
    role: []const u8,
    content: []const u8,
};

pub const Choice = struct {
    index: u32,
    message: ResponseMessage,
    finish_reason: ?[]const u8 = null,
};

pub const ChatResponse = struct {
    id: []const u8,
    object: []const u8,
    model: []const u8,
    choices: []Choice,
};
