//! `bs fmt [--check] [FILE...]` (formatter spec §2): formats files in
//! place, or stdin to stdout, and reports problems like the rest of bs.
const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const format = @import("format.zig");
const ShellCtx = @import("ShellCtx.zig");
const Source = @import("Source.zig");

const Allocator = std.mem.Allocator;

/// Runs `bs fmt` with `arguments` (everything after `fmt`) and returns the
/// exit status: the highest any input produced (spec §2.1).
pub fn run(gpa: Allocator, shell_ctx: *ShellCtx, arguments: []const []const u8) !u8 {
    var check_only = false;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    for (arguments) |argument| {
        if (std.mem.eql(u8, argument, "--check")) {
            check_only = true;
        } else if (std.mem.startsWith(u8, argument, "-")) {
            try shell_ctx.reportError("fmt: unknown option '{s}'", .{argument});
            return 2;
        } else {
            try paths.append(gpa, argument);
        }
    }
    if (paths.items.len == 0) return formatStandardInput(gpa, shell_ctx, check_only);
    var worst_status: u8 = 0;
    for (paths.items) |path| worst_status = @max(worst_status, try formatFile(gpa, shell_ctx, path, check_only));
    return worst_status;
}

/// Formatted text, or the exit status after reporting why there is none.
const Formatted = union(enum) {
    text: []const u8,
    failed: u8,
};

fn formatSource(allocator: Allocator, shell_ctx: *ShellCtx, source: Source) !Formatted {
    var problems: diagnostics.Diagnostics = .init(allocator);
    switch (try format.format(allocator, source.text, &problems)) {
        .formatted => |text| return .{ .text = text },
        .syntax_errors => {
            try diagnostics.renderAll(shell_ctx.stderr(), source, problems.items.items);
            return .{ .failed = 2 };
        },
        .verification_failed => {
            try shell_ctx.reportError("fmt: internal error: formatting would change the meaning of {s}; please report it", .{source.display_name});
            return .{ .failed = 3 };
        },
    }
}

fn formatFile(gpa: Allocator, shell_ctx: *ShellCtx, path: []const u8, check_only: bool) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = Source.load(shell_ctx.io, allocator, path) catch |err| {
        try shell_ctx.reportError("fmt: {s}: {s}", .{ path, ShellCtx.describeFileError(err) });
        return 1;
    };
    const text = switch (try formatSource(allocator, shell_ctx, source)) {
        .text => |text| text,
        .failed => |status| return status,
    };
    if (std.mem.eql(u8, text, source.text)) return 0;
    if (check_only) {
        const stdout = shell_ctx.stdout();
        try stdout.print("{s}\n", .{path});
        try stdout.flush();
        return 1;
    }
    writeInPlace(shell_ctx.io, allocator, path, text) catch |err| {
        try shell_ctx.reportError("fmt: {s}: {s}", .{ path, ShellCtx.describeFileError(err) });
        return 1;
    };
    return 0;
}

/// Replaces the file at `path` with `text` through `PATH.bs-fmt` in the
/// same directory, keeping the file's permission bits (spec §2.3).
fn writeInPlace(io: std.Io, allocator: Allocator, path: []const u8, text: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const original = try cwd.statFile(io, path, .{});
    const temporary_path = try std.fmt.allocPrint(allocator, "{s}.bs-fmt", .{path});
    errdefer cwd.deleteFile(io, temporary_path) catch {};
    try cwd.writeFile(io, .{ .sub_path = temporary_path, .data = text, .flags = .{ .permissions = original.permissions } });
    // Creating the file applied the umask; set the bits exactly.
    try cwd.setFilePermissions(io, temporary_path, original.permissions, .{});
    try cwd.rename(temporary_path, cwd, path, io);
}

fn formatStandardInput(gpa: Allocator, shell_ctx: *ShellCtx, check_only: bool) !u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const input_text = shell_ctx.stdin().allocRemaining(allocator, .limited(Source.max_script_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try shell_ctx.reportError("fmt: <stdin>: {s}", .{ShellCtx.describeFileError(err)});
            return 1;
        },
    };
    const source: Source = .{ .display_name = "<stdin>", .text = input_text };
    const text = switch (try formatSource(allocator, shell_ctx, source)) {
        .text => |text| text,
        .failed => |status| return status,
    };
    if (check_only) return @intFromBool(!std.mem.eql(u8, text, source.text));
    const stdout = shell_ctx.stdout();
    try stdout.writeAll(text);
    try stdout.flush();
    return 0;
}
