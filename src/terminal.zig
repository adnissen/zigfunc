const std = @import("std");
const posix = std.posix;

/// ANSI color codes
pub const Color = struct {
    pub const reset = "\x1b[0m";
    pub const cyan = "\x1b[36m";
    pub const yellow = "\x1b[33m";
    pub const green = "\x1b[32m";
    pub const red = "\x1b[31m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
};

/// Terminal handler for raw mode input
pub const RawTerminal = struct {
    original_termios: ?posix.termios,
    stdin_fd: posix.fd_t,
    is_raw: bool,
    is_tty: bool,

    pub fn init() RawTerminal {
        const stdin_fd = posix.STDIN_FILENO;

        // Check if stdin is a terminal
        const original = posix.tcgetattr(stdin_fd) catch {
            // Not a terminal, return non-raw terminal
            return RawTerminal{
                .original_termios = null,
                .stdin_fd = stdin_fd,
                .is_raw = false,
                .is_tty = false,
            };
        };

        // Configure raw mode
        var raw = original;
        raw.lflag.ICANON = false; // Disable canonical mode (line buffering)
        raw.lflag.ECHO = false; // Disable echo
        raw.lflag.ISIG = false; // Disable Ctrl-C/Ctrl-Z signals

        // Set VMIN=1, VTIME=0 for blocking read of single character
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        posix.tcsetattr(stdin_fd, .FLUSH, raw) catch {
            return RawTerminal{
                .original_termios = original,
                .stdin_fd = stdin_fd,
                .is_raw = false,
                .is_tty = true,
            };
        };

        return RawTerminal{
            .original_termios = original,
            .stdin_fd = stdin_fd,
            .is_raw = true,
            .is_tty = true,
        };
    }

    pub fn deinit(self: *RawTerminal) void {
        if (self.is_raw) {
            if (self.original_termios) |orig| {
                posix.tcsetattr(self.stdin_fd, .FLUSH, orig) catch {};
            }
            self.is_raw = false;
        }
    }

    /// Read a single keypress without requiring Enter
    pub fn readKey(self: *RawTerminal) !u8 {
        var buf: [1]u8 = undefined;
        const n = try posix.read(self.stdin_fd, &buf);
        if (n == 0) return error.EndOfFile;
        return buf[0];
    }

    /// Temporarily restore canonical mode and read a line
    pub fn readLine(self: *RawTerminal, allocator: std.mem.Allocator) ![]const u8 {
        if (self.original_termios) |orig| {
            // Temporarily restore canonical mode for line input
            var temp = orig;
            temp.lflag.ECHO = true;
            temp.lflag.ICANON = true;
            posix.tcsetattr(self.stdin_fd, .FLUSH, temp) catch {};

            defer {
                // Restore raw mode
                var raw = orig;
                raw.lflag.ICANON = false;
                raw.lflag.ECHO = false;
                raw.lflag.ISIG = false;
                raw.cc[@intFromEnum(posix.V.MIN)] = 1;
                raw.cc[@intFromEnum(posix.V.TIME)] = 0;
                posix.tcsetattr(self.stdin_fd, .FLUSH, raw) catch {};
            }
        }

        var line: std.ArrayList(u8) = .{};
        errdefer line.deinit(allocator);

        // Read from stdin using posix.read
        var buf: [1]u8 = undefined;
        while (true) {
            const n = try posix.read(self.stdin_fd, &buf);
            if (n == 0) {
                if (line.items.len > 0) {
                    return try line.toOwnedSlice(allocator);
                }
                return error.EndOfFile;
            }
            if (buf[0] == '\n') break;
            try line.append(allocator, buf[0]);
        }

        return try line.toOwnedSlice(allocator);
    }
};

/// Print colored text
pub fn printColored(writer: anytype, color: []const u8, text: []const u8) !void {
    try writer.print("{s}{s}{s}", .{ color, text, Color.reset });
}
