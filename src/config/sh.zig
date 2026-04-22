pub const std = @import("std");

pub const ANSI = struct {
    pub const code_bg = "\x1b[48;2;3;10;36m\x1b[97m";
    pub const code_fence = "\x1b[48;2;3;10;36m\x1b[38;5;214m";
    pub const reset = "\x1b[0m";
};

// Returns the current terminal column width by querying the OS directly.
// Falls back to 80 if stdout is not a TTY (e.g. when output is piped)
// or if the ioctl call fails for any other reason.
pub fn getTermWidth() usize {
    const default_size: usize = 80;

    // ws will be fully populated by ioctl on success; undefined is safe here
    // because we only read ws.col on the branch where ioctl returned 0
    var ws: std.posix.winsize = undefined;
    const fd = std.Io.File.stdout().handle;

    // TIOCGWINSZ asks the kernel to fill ws with the current terminal dimensions
    const rc = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc == 0 and ws.col > 0) return @intCast(ws.col);

    return default_size;
}
