const std = @import("std");
const Ast = std.zig.Ast;
const types = @import("types.zig");

pub const ParseError = error{
    OutOfMemory,
    ParseFailed,
};

/// Result of parsing a file for call sites
pub const ParseResult = struct {
    call_sites: std.ArrayList(types.CallSite),
    has_errors: bool,

    pub fn deinit(self: *ParseResult, allocator: std.mem.Allocator) void {
        for (self.call_sites.items) |*site| {
            site.deinit();
        }
        self.call_sites.deinit(allocator);
    }
};

/// Find all call sites of a function in the given source
pub fn findCallSites(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    file_path: []const u8,
    target_fn_name: []const u8,
) ParseError!ParseResult {
    var tree = Ast.parse(allocator, source, .zig) catch {
        return ParseError.ParseFailed;
    };
    defer tree.deinit(allocator);

    var result = ParseResult{
        .call_sites = .{},
        .has_errors = tree.errors.len > 0,
    };
    errdefer result.deinit(allocator);

    // Iterate all nodes looking for call expressions
    var buffer: [1]Ast.Node.Index = undefined;
    const node_count = tree.nodes.len;

    for (0..node_count) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);

        if (tree.fullCall(&buffer, node)) |call| {
            const fn_name = extractFunctionName(&tree, call.ast.fn_expr) orelse continue;

            if (std.mem.eql(u8, fn_name, target_fn_name)) {
                const site = buildCallSite(allocator, &tree, call, node, file_path, source) catch |err| {
                    switch (err) {
                        error.OutOfMemory => return ParseError.OutOfMemory,
                    }
                };
                result.call_sites.append(allocator, site) catch return ParseError.OutOfMemory;
            }
        }
    }

    return result;
}

/// Extract the function name from a call expression's fn_expr
fn extractFunctionName(tree: *const Ast, fn_expr: Ast.Node.Index) ?[]const u8 {
    const tag = tree.nodeTag(fn_expr);

    return switch (tag) {
        .identifier => tree.tokenSlice(tree.nodeMainToken(fn_expr)),
        .field_access => blk: {
            // Method call: self.foo() or obj.method()
            // The field name is the main token
            const main_token = tree.nodeMainToken(fn_expr);
            break :blk tree.tokenSlice(main_token);
        },
        else => null,
    };
}

/// Build a CallSite struct from AST information
fn buildCallSite(
    allocator: std.mem.Allocator,
    tree: *const Ast,
    call: Ast.full.Call,
    node: Ast.Node.Index,
    file_path: []const u8,
    source: [:0]const u8,
) !types.CallSite {
    // Get lparen position
    const lparen_token = call.ast.lparen;
    const lparen_start = tree.tokenStart(lparen_token);

    // Find rparen token
    const rparen_token = findRParen(tree, node);
    const rparen_start = tree.tokenStart(rparen_token);

    // Get line/column info from lparen
    const location = tree.tokenLocation(0, lparen_token);

    // Build argument spans
    const arg_spans = try allocator.alloc(types.ArgSpan, call.ast.params.len);
    errdefer allocator.free(arg_spans);

    for (call.ast.params, 0..) |param, idx| {
        const first_token = tree.firstToken(param);
        const last_token = tree.lastToken(param);
        const start = tree.tokenStart(first_token);
        const end = tree.tokenStart(last_token) + @as(u32, @intCast(tree.tokenSlice(last_token).len));
        arg_spans[idx] = .{ .start = start, .end = end };
    }

    // Detect trailing comma by checking the node tag
    const node_tag = tree.nodeTag(node);
    const has_trailing_comma = (node_tag == .call_comma or node_tag == .call_one_comma);

    // Get original call text
    const original_call = source[lparen_start .. rparen_start + 1];

    return types.CallSite{
        .file_path = file_path,
        .line = location.line + 1, // 1-indexed
        .column = location.column + 1,
        .lparen_offset = lparen_start,
        .rparen_offset = rparen_start,
        .arg_spans = arg_spans,
        .has_trailing_comma = has_trailing_comma,
        .original_call = original_call,
        .fn_name = extractFunctionName(tree, call.ast.fn_expr).?,
        .allocator = allocator,
    };
}

/// Find the closing parenthesis token for a call
fn findRParen(tree: *const Ast, node: Ast.Node.Index) Ast.TokenIndex {
    // The last token of a call node is the closing paren
    return tree.lastToken(node);
}

/// Read a file and return its contents with a null terminator
pub fn readFileNullTerminated(allocator: std.mem.Allocator, path: []const u8) ![:0]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    const size = stat.size;

    // Allocate with space for null terminator
    const buffer = try allocator.allocSentinel(u8, size, 0);
    errdefer allocator.free(buffer);

    const bytes_read = try file.readAll(buffer);
    if (bytes_read != size) {
        return error.UnexpectedEndOfFile;
    }

    return buffer;
}

test "extractFunctionName - identifier" {
    const source: [:0]const u8 = "fn main() void { foo(); }";
    var tree = try Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    // Find the call node
    var buffer: [1]Ast.Node.Index = undefined;
    for (0..tree.nodes.len) |i| {
        const node: Ast.Node.Index = @enumFromInt(i);
        if (tree.fullCall(&buffer, node)) |call| {
            const name = extractFunctionName(&tree, call.ast.fn_expr);
            try std.testing.expectEqualStrings("foo", name.?);
            return;
        }
    }
    try std.testing.expect(false); // Should have found a call
}
