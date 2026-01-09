const std = @import("std");
const posix = std.posix;
const types = @import("types.zig");
const parser = @import("parser.zig");
const editor = @import("editor.zig");
const terminal = @import("terminal.zig");

const stdout_file = std.fs.File{ .handle = posix.STDOUT_FILENO };
const stderr_file = std.fs.File{ .handle = posix.STDERR_FILENO };

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const output = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = stdout_file.write(output) catch {};
}

fn printErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const output = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = stderr_file.write(output) catch {};
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = parseArgs(allocator) catch |err| {
        printUsage(err);
        std.process.exit(1);
    } orelse {
        printHelp();
        return;
    };

    // Initialize terminal for raw mode
    var term = terminal.RawTerminal.init();
    defer term.deinit();

    if (!term.is_tty) {
        printErr("Error: stdin is not a terminal. This tool requires interactive input.\n", .{});
        std.process.exit(1);
    }

    // Run the main refactoring loop
    runRefactoring(allocator, config, &term) catch |err| {
        term.deinit(); // Restore terminal before printing error
        printErr("Error during refactoring: {}\n", .{err});
        std.process.exit(1);
    };
}

fn printUsage(err: anyerror) void {
    printErr("Error: {}\n\n", .{err});
    printHelp();
}

fn printHelp() void {
    print(
        \\Usage: zigfunc [OPTIONS]
        \\
        \\A tool to refactor function call sites in Zig code.
        \\
        \\OPTIONS:
        \\  --fn <name>       Name of the function to refactor (required)
        \\  --arg <value>     Default value for new argument (add mode)
        \\  --pos <N|last>    Argument position (0-indexed, or "last")
        \\  --remove <N>      Remove argument at position N (remove mode)
        \\  --dir <path>      Directory to scan (default: current directory)
        \\  --help, -h        Show this help message
        \\
        \\MODES:
        \\  Add mode:    --fn <name> --arg <value> --pos <position>
        \\  Remove mode: --fn <name> --remove <position>
        \\
        \\EXAMPLES:
        \\  zigfunc --fn allocPrint --arg allocator --pos 0 --dir ./src
        \\  zigfunc --fn foo --arg "null" --pos last
        \\  zigfunc --fn bar --remove 1 --dir ./lib
        \\
    , .{});
}

fn parseArgs(allocator: std.mem.Allocator) !?types.Config {
    _ = allocator;

    var args = std.process.args();
    _ = args.skip(); // skip program name

    var fn_name: ?[]const u8 = null;
    var arg_value: ?[]const u8 = null;
    var remove_pos: ?usize = null;
    var position: ?types.Position = null;
    var directory: []const u8 = ".";

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--fn")) {
            fn_name = args.next() orelse return types.ArgError.MissingFnName;
        } else if (std.mem.eql(u8, arg, "--arg")) {
            arg_value = args.next() orelse return types.ArgError.MissingArgValue;
        } else if (std.mem.eql(u8, arg, "--remove")) {
            const pos_str = args.next() orelse return types.ArgError.MissingRemovePos;
            remove_pos = std.fmt.parseInt(usize, pos_str, 10) catch return types.ArgError.InvalidPosition;
        } else if (std.mem.eql(u8, arg, "--pos")) {
            const pos_str = args.next() orelse return types.ArgError.MissingPos;
            if (std.mem.eql(u8, pos_str, "last")) {
                position = .last;
            } else {
                const idx = std.fmt.parseInt(usize, pos_str, 10) catch return types.ArgError.InvalidPosition;
                position = .{ .index = idx };
            }
        } else if (std.mem.eql(u8, arg, "--dir")) {
            directory = args.next() orelse return types.ArgError.MissingDir;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return null;
        }
    }

    // Validation
    if (fn_name == null) return types.ArgError.MissingFnName;
    if (arg_value != null and remove_pos != null) return types.ArgError.MutuallyExclusive;
    if (arg_value == null and remove_pos == null) return types.ArgError.NeedArgOrRemove;

    const mode: types.Mode = if (remove_pos != null) .remove else .add;

    const final_pos: types.Position = if (remove_pos) |p|
        .{ .index = p }
    else
        position orelse return types.ArgError.MissingPositionForAdd;

    return types.Config{
        .fn_name = fn_name.?,
        .mode = mode,
        .position = final_pos,
        .default_value = arg_value,
        .directory = directory,
    };
}

fn discoverZigFiles(allocator: std.mem.Allocator, root_path: []const u8) !std.ArrayList([]const u8) {
    var files: std.ArrayList([]const u8) = .{};
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    // Open the directory
    var dir = std.fs.cwd().openDir(root_path, .{ .iterate = true }) catch |err| {
        print("Cannot open directory '{s}': {}\n", .{ root_path, err });
        return files;
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        // Build full path
        const full_path = try std.fs.path.join(allocator, &.{ root_path, entry.path });
        try files.append(allocator, full_path);
    }

    return files;
}

fn runRefactoring(
    allocator: std.mem.Allocator,
    config: types.Config,
    term: *terminal.RawTerminal,
) !void {
    var stats = types.Stats{};
    var accept_all = false;

    print("\nScanning {s} ...\n", .{config.directory});

    // Discover files
    var files = try discoverZigFiles(allocator, config.directory);
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    if (files.items.len == 0) {
        print("No .zig files found in {s}\n", .{config.directory});
        return;
    }

    // First pass: count total call sites
    var total_sites: usize = 0;
    var files_with_matches: usize = 0;

    for (files.items) |file_path| {
        const source = parser.readFileNullTerminated(allocator, file_path) catch continue;
        defer allocator.free(source);

        var result = parser.findCallSites(allocator, source, file_path, config.fn_name) catch continue;
        defer result.deinit(allocator);

        if (result.call_sites.items.len > 0) {
            total_sites += result.call_sites.items.len;
            files_with_matches += 1;
        }
    }

    if (total_sites == 0) {
        print("No call sites for '{s}' found.\n", .{config.fn_name});
        return;
    }

    print("Found {d} call site(s) in {d} file(s).\n\n", .{ total_sites, files_with_matches });

    // Second pass: process each file
    for (files.items) |file_path| {
        stats.files_scanned += 1;

        // Read file with null terminator for AST parsing
        const source = parser.readFileNullTerminated(allocator, file_path) catch |err| {
            print("{s}Warning:{s} Could not read {s}: {}\n", .{
                terminal.Color.yellow, terminal.Color.reset, file_path, err,
            });
            stats.files_with_errors += 1;
            continue;
        };
        defer allocator.free(source);

        // Parse and find call sites
        var result = parser.findCallSites(allocator, source, file_path, config.fn_name) catch |err| {
            print("{s}Warning:{s} Parse error in {s}: {}\n", .{
                terminal.Color.yellow, terminal.Color.reset, file_path, err,
            });
            stats.files_with_errors += 1;
            continue;
        };
        defer result.deinit(allocator);

        if (result.call_sites.items.len == 0) continue;

        if (result.has_errors) {
            print("{s}Warning:{s} {s} has parse errors, results may be incomplete\n", .{
                terminal.Color.yellow, terminal.Color.reset, file_path,
            });
        }

        stats.files_with_matches += 1;
        stats.call_sites_found += result.call_sites.items.len;

        // Process each call site
        var file_edits: std.ArrayList(types.Edit) = .{};
        defer {
            for (file_edits.items) |*e| e.deinit();
            file_edits.deinit(allocator);
        }

        for (result.call_sites.items) |site| {
            // Inner loop allows re-prompting when edit is cancelled
            while (true) {
                const action: types.UserAction = if (accept_all)
                    .accept
                else
                    try promptForAction(allocator, term, site, source, config);

                switch (action) {
                    .quit => {
                        // Apply pending edits before quitting
                        if (file_edits.items.len > 0) {
                            try editor.applyEdits(allocator, file_path, file_edits.items);
                            stats.files_modified += 1;
                        }
                        printStats(stats);
                        return;
                    },
                    .skip => {
                        stats.call_sites_skipped += 1;
                        print("Skipped\n", .{});
                        break;
                    },
                    .accept_all => {
                        accept_all = true;
                        const edit_result = try generateEdit(allocator, site, source, config, config.default_value.?);
                        if (edit_result) |e| {
                            try file_edits.append(allocator, e);
                            stats.call_sites_modified += 1;
                            print("{s}Updated{s}\n", .{ terminal.Color.green, terminal.Color.reset });
                        }
                        break;
                    },
                    .accept => {
                        const edit_result = try generateEdit(allocator, site, source, config, config.default_value.?);
                        if (edit_result) |e| {
                            try file_edits.append(allocator, e);
                            stats.call_sites_modified += 1;
                            print("{s}Updated{s}\n", .{ terminal.Color.green, terminal.Color.reset });
                        }
                        break;
                    },
                    .edit => {
                        print("Enter value: ", .{});
                        const custom_value = try term.readLine(allocator) orelse {
                            // Escape pressed - return to prompt
                            print("\n", .{});
                            continue;
                        };
                        defer allocator.free(custom_value);

                        const edit_result = try generateEdit(allocator, site, source, config, custom_value);
                        if (edit_result) |e| {
                            try file_edits.append(allocator, e);
                            stats.call_sites_modified += 1;
                            print("{s}Updated{s}\n", .{ terminal.Color.green, terminal.Color.reset });
                        }
                        break;
                    },
                }
            }
        }

        // Apply all edits for this file
        if (file_edits.items.len > 0) {
            try editor.applyEdits(allocator, file_path, file_edits.items);
            stats.files_modified += 1;
        }
    }

    printStats(stats);
}

fn generateEdit(
    allocator: std.mem.Allocator,
    site: types.CallSite,
    source: [:0]const u8,
    config: types.Config,
    value: []const u8,
) !?types.Edit {
    return switch (config.mode) {
        .add => try editor.generateAddEdit(allocator, site, config.position, value),
        .remove => try editor.generateRemoveEdit(allocator, site, source, config.position),
    };
}

fn promptForAction(
    allocator: std.mem.Allocator,
    term: *terminal.RawTerminal,
    site: types.CallSite,
    source: [:0]const u8,
    config: types.Config,
) !types.UserAction {
    // Display file path in cyan
    print("\n{s}{s}{s}:{d}:{d}\n", .{
        terminal.Color.cyan, site.file_path, terminal.Color.reset,
        site.line,           site.column,
    });

    // Show current and proposed
    const proposed = try editor.generateProposedCall(allocator, site, source, config.mode, config.position, config.default_value, terminal.Color.green, terminal.Color.reset);
    defer allocator.free(proposed);

    print("\nCurrent:  {s}{s}{s}\n", .{ terminal.Color.dim, site.original_call, terminal.Color.reset });
    print("Proposed: {s}\n", .{proposed});

    // Prompt
    print("\n[{s}a{s}]ccept  [{s}e{s}]dit  [{s}s{s}]kip  [{s}A{s}]ll  [{s}q{s}]uit: ", .{
        terminal.Color.green,  terminal.Color.reset,
        terminal.Color.cyan,   terminal.Color.reset,
        terminal.Color.yellow, terminal.Color.reset,
        terminal.Color.green,  terminal.Color.reset,
        terminal.Color.red,    terminal.Color.reset,
    });

    while (true) {
        const key = try term.readKey();
        return switch (key) {
            'a' => .accept,
            'e' => .edit,
            's' => .skip,
            'A' => .accept_all,
            'q', 3 => .quit, // 3 = Ctrl-C
            else => continue,
        };
    }
}

fn printStats(stats: types.Stats) void {
    print("\n{s}Done.{s} Modified {d} file(s), updated {d} call site(s), skipped {d}.\n", .{
        terminal.Color.bold,
        terminal.Color.reset,
        stats.files_modified,
        stats.call_sites_modified,
        stats.call_sites_skipped,
    });

    if (stats.files_with_errors > 0) {
        print("{s}Warning:{s} {d} file(s) had errors and were skipped.\n", .{
            terminal.Color.yellow,
            terminal.Color.reset,
            stats.files_with_errors,
        });
    }
}
