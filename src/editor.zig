const std = @import("std");
const types = @import("types.zig");

/// Generate an edit to add an argument at the specified position
pub fn generateAddEdit(
    allocator: std.mem.Allocator,
    site: types.CallSite,
    position: types.Position,
    value: []const u8,
) !types.Edit {
    const pos_index = position.resolve(site.arg_spans.len);

    if (site.arg_spans.len == 0) {
        // foo() -> foo(value)
        return types.Edit{
            .start = site.lparen_offset + 1,
            .end = site.lparen_offset + 1,
            .replacement = value,
            .allocator = null,
        };
    } else if (pos_index == 0) {
        // foo(a, b) -> foo(value, a, b)
        const insert_text = try std.fmt.allocPrint(allocator, "{s}, ", .{value});
        return types.Edit{
            .start = site.arg_spans[0].start,
            .end = site.arg_spans[0].start,
            .replacement = insert_text,
            .allocator = allocator,
        };
    } else if (pos_index >= site.arg_spans.len) {
        // foo(a, b) -> foo(a, b, value)
        const last_arg = site.arg_spans[site.arg_spans.len - 1];
        if (site.has_trailing_comma) {
            // foo(a, b,) -> foo(a, b, value,)
            const insert_text = try std.fmt.allocPrint(allocator, "{s}, ", .{value});
            return types.Edit{
                .start = last_arg.end,
                .end = last_arg.end,
                .replacement = insert_text,
                .allocator = allocator,
            };
        } else {
            const insert_text = try std.fmt.allocPrint(allocator, ", {s}", .{value});
            return types.Edit{
                .start = last_arg.end,
                .end = last_arg.end,
                .replacement = insert_text,
                .allocator = allocator,
            };
        }
    } else {
        // Insert in middle: foo(a, b, c) at pos 1 -> foo(a, value, b, c)
        const insert_text = try std.fmt.allocPrint(allocator, "{s}, ", .{value});
        return types.Edit{
            .start = site.arg_spans[pos_index].start,
            .end = site.arg_spans[pos_index].start,
            .replacement = insert_text,
            .allocator = allocator,
        };
    }
}

/// Generate an edit to remove an argument at the specified position
pub fn generateRemoveEdit(
    allocator: std.mem.Allocator,
    site: types.CallSite,
    source: []const u8,
    position: types.Position,
) !?types.Edit {
    _ = allocator;

    if (site.arg_spans.len == 0) {
        return null; // Cannot remove from empty args
    }

    const pos_index = switch (position) {
        .last => site.arg_spans.len - 1,
        .index => |i| if (i >= site.arg_spans.len) return null else i,
    };

    const target = site.arg_spans[pos_index];
    var remove_start = target.start;
    var remove_end = target.end;

    if (site.arg_spans.len == 1) {
        // foo(arg) -> foo()
        // Just remove the argument content
    } else if (pos_index == 0) {
        // foo(a, b) -> foo(b)
        // Remove arg and following comma+whitespace
        // Find the comma after this arg
        var i = target.end;
        while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\n' or source[i] == ',')) {
            if (source[i] == ',') {
                i += 1;
                // Skip whitespace after comma
                while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\n')) {
                    i += 1;
                }
                break;
            }
            i += 1;
        }
        remove_end = @intCast(i);
    } else {
        // foo(a, b) -> foo(a) or foo(a, b, c) remove middle
        // Remove preceding comma+whitespace and arg
        // Find the comma before this arg
        var i: usize = target.start;
        while (i > 0) {
            i -= 1;
            if (source[i] == ',') {
                remove_start = @intCast(i);
                break;
            }
        }
    }

    return types.Edit{
        .start = remove_start,
        .end = remove_end,
        .replacement = "",
        .allocator = null,
    };
}

/// Apply a list of edits to a file
pub fn applyEdits(allocator: std.mem.Allocator, file_path: []const u8, edits: []const types.Edit) !void {
    if (edits.len == 0) return;

    // Sort edits by position (descending) to apply from end to start
    const sorted = try allocator.alloc(types.Edit, edits.len);
    defer allocator.free(sorted);
    @memcpy(sorted, edits);

    std.mem.sort(types.Edit, sorted, {}, struct {
        fn cmp(_: void, a: types.Edit, b: types.Edit) bool {
            return a.start > b.start; // Descending
        }
    }.cmp);

    // Read file
    const file = try std.fs.cwd().openFile(file_path, .{ .mode = .read_write });
    defer file.close();

    const stat = try file.stat();
    const content = try allocator.alloc(u8, stat.size);
    defer allocator.free(content);

    const bytes_read = try file.readAll(content);
    if (bytes_read != stat.size) {
        return error.UnexpectedEndOfFile;
    }

    // Apply edits in reverse order (from end to start)
    var result: std.ArrayList(u8) = .{};
    defer result.deinit(allocator);

    try result.appendSlice(allocator, content);

    for (sorted) |edit| {
        // Replace the range [start, end) with replacement
        const before = result.items[0..edit.start];
        const after = result.items[edit.end..];

        var new_result: std.ArrayList(u8) = .{};
        try new_result.appendSlice(allocator, before);
        try new_result.appendSlice(allocator, edit.replacement);
        try new_result.appendSlice(allocator, after);

        result.deinit(allocator);
        result = new_result;
    }

    // Write back
    try file.seekTo(0);
    try file.setEndPos(result.items.len);
    _ = try file.writeAll(result.items);
}

/// Generate the proposed call text after applying an edit
/// If highlight_start/highlight_end are provided, the new/changed part will be wrapped with them
pub fn generateProposedCall(
    allocator: std.mem.Allocator,
    site: types.CallSite,
    source: []const u8,
    mode: types.Mode,
    position: types.Position,
    value: ?[]const u8,
    highlight_start: ?[]const u8,
    highlight_end: ?[]const u8,
) ![]const u8 {
    // Get the function name part (everything before lparen)
    const fn_start = blk: {
        var i: usize = site.lparen_offset;
        while (i > 0) {
            i -= 1;
            const c = source[i];
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') {
                break :blk i + 1;
            }
        }
        break :blk 0;
    };
    const fn_name_part = source[fn_start..site.lparen_offset];

    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    try result.appendSlice(allocator, fn_name_part);
    try result.append(allocator, '(');

    switch (mode) {
        .add => {
            const pos_index = position.resolve(site.arg_spans.len);
            var arg_idx: usize = 0;

            // Insert new arg at position
            while (arg_idx < site.arg_spans.len or arg_idx == pos_index) {
                if (arg_idx == pos_index) {
                    if (result.items.len > 0 and result.items[result.items.len - 1] != '(') {
                        try result.appendSlice(allocator, ", ");
                    }
                    if (highlight_start) |hs| try result.appendSlice(allocator, hs);
                    try result.appendSlice(allocator, value.?);
                    if (highlight_end) |he| try result.appendSlice(allocator, he);
                    if (arg_idx < site.arg_spans.len) {
                        try result.appendSlice(allocator, ", ");
                    }
                }

                if (arg_idx < site.arg_spans.len) {
                    const span = site.arg_spans[arg_idx];
                    if (arg_idx > 0 and arg_idx != pos_index) {
                        try result.appendSlice(allocator, ", ");
                    }
                    try result.appendSlice(allocator, source[span.start..span.end]);
                    arg_idx += 1;
                } else {
                    break;
                }
            }
        },
        .remove => {
            const pos_index = switch (position) {
                .last => if (site.arg_spans.len > 0) site.arg_spans.len - 1 else 0,
                .index => |i| i,
            };

            var first = true;
            for (site.arg_spans, 0..) |span, idx| {
                if (idx == pos_index) continue;
                if (!first) {
                    try result.appendSlice(allocator, ", ");
                }
                try result.appendSlice(allocator, source[span.start..span.end]);
                first = false;
            }
        },
    }

    if (site.has_trailing_comma and result.items.len > 0 and result.items[result.items.len - 1] != '(') {
        try result.append(allocator, ',');
    }
    try result.append(allocator, ')');

    return try result.toOwnedSlice(allocator);
}
