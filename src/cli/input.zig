const config_system = @import("../config/system.zig");
const std = @import("std");

pub fn get_model(args: []const []const u8) []const u8 {
    const in_model: []const u8 = if (args.len > 1) args[1] else config_system.CHAT_MODEL;

    var output: []const u8 = config_system.CHAT_MODEL;

    if (std.mem.eql(u8, in_model, config_system.REASONER_MODEL)) {
        output = config_system.REASONER_MODEL;
    }

    return output;
}
