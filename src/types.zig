const std = @import("std");

/// Byte span for an argument in the call
pub const ArgSpan = struct {
    start: u32,
    end: u32,
};

/// Represents a single call site found in the codebase
pub const CallSite = struct {
    /// Absolute path to the file containing the call
    file_path: []const u8,
    /// Line number (1-indexed for display)
    line: usize,
    /// Column number (1-indexed for display)
    column: usize,
    /// Byte offset of the opening parenthesis in the source
    lparen_offset: u32,
    /// Byte offset of the closing parenthesis in the source
    rparen_offset: u32,
    /// Byte offsets of each argument's start and end
    arg_spans: []const ArgSpan,
    /// Whether the call has a trailing comma
    has_trailing_comma: bool,
    /// The original source text of the call arguments (between parens)
    original_call: []const u8,
    /// Name of the function being called
    fn_name: []const u8,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *CallSite) void {
        self.allocator.free(self.arg_spans);
    }
};

/// Result of user interaction for a single call site
pub const UserAction = enum {
    accept,
    edit,
    skip,
    accept_all,
    quit,
};

/// Argument position specification
pub const Position = union(enum) {
    index: usize,
    last,

    pub fn resolve(self: Position, arg_count: usize) usize {
        return switch (self) {
            .index => |i| i,
            .last => arg_count,
        };
    }
};

/// Operation mode
pub const Mode = enum {
    add,
    remove,
};

/// Configuration parsed from CLI arguments
pub const Config = struct {
    fn_name: []const u8,
    mode: Mode,
    position: Position,
    default_value: ?[]const u8,
    directory: []const u8,
};

/// An edit to be applied to a file
pub const Edit = struct {
    /// Byte offset where edit starts
    start: u32,
    /// Byte offset where edit ends (exclusive)
    end: u32,
    /// New text to insert (empty for pure deletion)
    replacement: []const u8,

    allocator: ?std.mem.Allocator,

    pub fn deinit(self: *Edit) void {
        if (self.allocator) |alloc| {
            alloc.free(self.replacement);
        }
    }
};

/// Statistics for the refactoring session
pub const Stats = struct {
    files_scanned: usize = 0,
    files_with_matches: usize = 0,
    files_modified: usize = 0,
    call_sites_found: usize = 0,
    call_sites_modified: usize = 0,
    call_sites_skipped: usize = 0,
    files_with_errors: usize = 0,
};

/// Errors that can occur during argument parsing
pub const ArgError = error{
    MissingFnName,
    MissingArgValue,
    MissingRemovePos,
    MissingPos,
    MissingDir,
    InvalidPosition,
    MutuallyExclusive,
    NeedArgOrRemove,
    MissingPositionForAdd,
};
