//! Running commands and turning their outcome into an exit status.
const std = @import("std");

const ShellCtx = @import("ShellCtx.zig");
const path_search = @import("path_search.zig");

/// Runs the command described by `argv` and records its exit status in
/// `shell_ctx.last_exit_status`. An empty `argv` (a blank line) does nothing.
pub fn runCommand(shell_ctx: *ShellCtx, argv: [][]const u8) !void {
    if (argv.len == 0) return;
    shell_ctx.last_exit_status = try runExternalCommand(shell_ctx, argv);
}

/// Spawns `argv` as a child process, waits for it, and returns its exit
/// status using the usual shell conventions: 127 when the command cannot be
/// found, 126 when it is found but cannot be executed, and 128 + N when the
/// child is killed by signal N.
fn runExternalCommand(shell_ctx: *ShellCtx, argv: [][]const u8) !u8 {
    const command_name = argv[0];
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const executable_path = path_search.findExecutable(
        shell_ctx.io,
        shell_ctx.env_vars.get("PATH"),
        command_name,
        &path_buffer,
    ) orelse {
        try shell_ctx.reportError("{s}: command not found", .{command_name});
        return 127;
    };

    // `spawn` would otherwise search the PATH this process started with,
    // not the shell's own (and possibly modified) PATH.
    argv[0] = executable_path;
    var child = std.process.spawn(shell_ctx.io, .{
        .argv = argv,
        .environ_map = shell_ctx.env_vars,
    }) catch |err| {
        try shell_ctx.reportError("{s}: {s}", .{ command_name, @errorName(err) });
        return switch (err) {
            error.FileNotFound => 127,
            else => 126,
        };
    };

    return switch (try child.wait(shell_ctx.io)) {
        .exited => |exit_code| exit_code,
        .signal, .stopped => |signal| 128 +% @as(u8, @truncate(@intFromEnum(signal))),
        .unknown => 1,
    };
}
