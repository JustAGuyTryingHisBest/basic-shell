//! Running commands and turning their outcome into an exit status.
const std = @import("std");

const ShellCtx = @import("ShellCtx.zig");
const path_search = @import("path_search.zig");

/// Errors from running a command with inherited streams.
pub const RunError = std.Io.Writer.Error || std.process.Child.WaitError;
/// Errors from running a command and capturing its stdout.
pub const CaptureError = error{
    /// The command wrote more than the capture limit; it has been killed.
    CaptureTooLarge,
    ReadFailed,
} || RunError || std.mem.Allocator.Error;

/// Runs the command described by `argv` and records its exit status in
/// `shell_ctx.last_exit_status`. An empty `argv` (a blank line) does nothing.
pub fn runCommand(shell_ctx: *ShellCtx, argv: [][]const u8) !void {
    if (argv.len == 0) return;
    shell_ctx.last_exit_status = try runExternalCommand(shell_ctx, argv);
}

/// Spawns `argv` with inherited standard streams, waits for it, and returns
/// its exit status using the usual shell conventions: 127 when the command
/// cannot be found, 126 when it is found but cannot be executed, and
/// 128 + N when the child is killed by signal N. Overwrites `argv[0]` with
/// the resolved path, which is only valid until this function returns.
pub fn runExternalCommand(shell_ctx: *ShellCtx, argv: [][]const u8) RunError!u8 {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var child = switch (try spawnProgram(shell_ctx, argv, &path_buffer, .inherit)) {
        .started => |child| child,
        .not_started => |exit_status| return exit_status,
    };
    return waitForExitStatus(shell_ctx, &child);
}

/// The outcome of a captured command.
pub const Capture = struct {
    exit_status: u8,
    /// Everything the command wrote to stdout, unmodified.
    output: []u8,
};

/// Like `runExternalCommand`, but the child's stdout goes to a pipe whose
/// contents are returned, allocated with `allocator`. Output longer than
/// `output_limit` bytes kills the child and fails with `error.CaptureTooLarge`.
pub fn captureExternalCommand(
    shell_ctx: *ShellCtx,
    allocator: std.mem.Allocator,
    argv: [][]const u8,
    output_limit: usize,
) CaptureError!Capture {
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var child = switch (try spawnProgram(shell_ctx, argv, &path_buffer, .pipe)) {
        .started => |child| child,
        .not_started => |exit_status| return .{ .exit_status = exit_status, .output = &.{} },
    };
    var read_buffer: [4096]u8 = undefined;
    var stdout_reader = child.stdout.?.readerStreaming(shell_ctx.io, &read_buffer);
    const output = stdout_reader.interface.allocRemaining(allocator, .limited(output_limit)) catch |err| {
        child.kill(shell_ctx.io);
        return switch (err) {
            error.StreamTooLong => error.CaptureTooLarge,
            error.ReadFailed => error.ReadFailed,
            error.OutOfMemory => error.OutOfMemory,
        };
    };
    errdefer allocator.free(output);
    return .{ .exit_status = try waitForExitStatus(shell_ctx, &child), .output = output };
}

const Spawned = union(enum) {
    started: std.process.Child,
    /// The program could not be found or started; the message is printed.
    not_started: u8,
};

fn spawnProgram(
    shell_ctx: *ShellCtx,
    argv: [][]const u8,
    path_buffer: []u8,
    stdout_mode: std.process.SpawnOptions.StdIo,
) std.Io.Writer.Error!Spawned {
    const command_name = argv[0];
    const executable_path = path_search.findExecutable(
        shell_ctx.io,
        shell_ctx.env_vars.get("PATH"),
        command_name,
        path_buffer,
    ) orelse {
        try shell_ctx.reportError("{s}: command not found", .{command_name});
        return .{ .not_started = 127 };
    };

    // `spawn` would otherwise search the PATH this process started with,
    // not the shell's own (and possibly modified) PATH.
    argv[0] = executable_path;
    const child = std.process.spawn(shell_ctx.io, .{
        .argv = argv,
        .environ_map = shell_ctx.env_vars,
        .stdout = stdout_mode,
    }) catch |err| {
        try shell_ctx.reportError("{s}: {s}", .{ command_name, ShellCtx.describeFileError(err) });
        return .{ .not_started = switch (err) {
            error.FileNotFound => 127,
            else => 126,
        } };
    };
    return .{ .started = child };
}

fn waitForExitStatus(shell_ctx: *ShellCtx, child: *std.process.Child) std.process.Child.WaitError!u8 {
    return switch (try child.wait(shell_ctx.io)) {
        .exited => |exit_code| exit_code,
        .signal, .stopped => |signal| 128 +% @as(u8, @truncate(@backingInt(signal))),
        .unknown => 1,
    };
}

fn initTestShell(shell_ctx: *ShellCtx, environment: *std.process.Environ.Map) !void {
    try environment.put("PATH", "/usr/bin:/bin");
    shell_ctx.init(std.testing.io, environment);
}

test "capture returns raw output and the exit status" {
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    var shell_ctx: ShellCtx = undefined;
    try initTestShell(&shell_ctx, &environment);

    var printf_argv = [_][]const u8{ "printf", "abc" };
    const without_newline = try captureExternalCommand(&shell_ctx, std.testing.allocator, &printf_argv, 1024);
    defer std.testing.allocator.free(without_newline.output);
    try std.testing.expectEqual(@as(u8, 0), without_newline.exit_status);
    try std.testing.expectEqualStrings("abc", without_newline.output);

    var failing_argv = [_][]const u8{ "sh", "-c", "printf 'a\\n\\n'; exit 3" };
    const with_newlines = try captureExternalCommand(&shell_ctx, std.testing.allocator, &failing_argv, 1024);
    defer std.testing.allocator.free(with_newlines.output);
    try std.testing.expectEqual(@as(u8, 3), with_newlines.exit_status);
    try std.testing.expectEqualStrings("a\n\n", with_newlines.output);
}

test "capture over the limit fails without hanging" {
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    var shell_ctx: ShellCtx = undefined;
    try initTestShell(&shell_ctx, &environment);

    var flood_argv = [_][]const u8{ "head", "-c", "2000000", "/dev/zero" };
    try std.testing.expectError(error.CaptureTooLarge, captureExternalCommand(&shell_ctx, std.testing.allocator, &flood_argv, 1024 * 1024));
}

test "run returns exit statuses, 127 when not found" {
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    var shell_ctx: ShellCtx = undefined;
    try initTestShell(&shell_ctx, &environment);

    var exit_argv = [_][]const u8{ "sh", "-c", "exit 5" };
    try std.testing.expectEqual(@as(u8, 5), try runExternalCommand(&shell_ctx, &exit_argv));
    var missing_argv = [_][]const u8{"definitely-not-a-command-xyz"};
    try std.testing.expectEqual(@as(u8, 127), try runExternalCommand(&shell_ctx, &missing_argv));
}

test "capture accepts exactly the limit and rejects one byte more" {
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    var shell_ctx: ShellCtx = undefined;
    try initTestShell(&shell_ctx, &environment);

    var exact_argv = [_][]const u8{ "printf", "12345678" };
    const exact = try captureExternalCommand(&shell_ctx, std.testing.allocator, &exact_argv, 8);
    defer std.testing.allocator.free(exact.output);
    try std.testing.expectEqualStrings("12345678", exact.output);

    var over_argv = [_][]const u8{ "printf", "123456789" };
    try std.testing.expectError(error.CaptureTooLarge, captureExternalCommand(&shell_ctx, std.testing.allocator, &over_argv, 8));
}
