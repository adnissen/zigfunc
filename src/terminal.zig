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

    /// Read a line with manual echo (works in raw mode)
    /// Returns null if Escape is pressed (to cancel input)
    pub fn readLine(self: *RawTerminal, allocator: std.mem.Allocator) !?[]const u8 {
        var line: std.ArrayList(u8) = .{};
        errdefer line.deinit(allocator);

        const stdout_fd = posix.STDOUT_FILENO;

        // Read from stdin and manually echo each character
        var buf: [1]u8 = undefined;
        while (true) {
            const n = try posix.read(self.stdin_fd, &buf);
            if (n == 0) {
                if (line.items.len > 0) {
                    return try line.toOwnedSlice(allocator);
                }
                return error.EndOfFile;
            }
            if (buf[0] == 27) {
                // Escape key - cancel input
                line.deinit(allocator);
                return null;
            }
            if (buf[0] == '\n') {
                // Echo newline and break
                _ = posix.write(stdout_fd, "\n") catch {};
                break;
            }
            if (buf[0] == 127 or buf[0] == 8) {
                // Handle backspace
                if (line.items.len > 0) {
                    _ = line.pop();
                    _ = posix.write(stdout_fd, "\x08 \x08") catch {}; // backspace, space, backspace
                }
            } else if (buf[0] >= 32) {
                // Echo printable characters
                try line.append(allocator, buf[0]);
                _ = posix.write(stdout_fd, &buf) catch {};
            }
        }

        return try line.toOwnedSlice(allocator);
    }
};

/// Print colored text
pub fn printColored(writer: anytype, color: []const u8, text: []const u8) !void {
    try writer.print("{s}{s}{s}", .{ color, text, Color.reset });
}
