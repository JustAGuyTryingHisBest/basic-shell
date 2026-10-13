//! Process-wide signal handling for the shell.
const builtin = @import("builtin");
const std = @import("std");

var should_exit = std.atomic.Value(bool).init(false);

fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    should_exit.store(true, .seq_cst);
}

pub fn installHandlers(stderr: *std.Io.Writer) !void {
    // posix only
    if (comptime builtin.os.tag == .windows) {
        try std.Io.Writer.print(stderr, "POSIX signals are not supported on Windows.\n", .{});
        return;
    }

    const sig_act: std.posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };

    std.posix.sigaction(std.posix.SIG.INT, &sig_act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sig_act, null);
}

/// Restores the default SIGPIPE disposition (spec §8.6), so that writing to a
/// closed pipe kills the process quietly as it does in `sh`. The standard
/// library's I/O runtime installs a no-op handler that turns it into EPIPE.
pub fn restoreDefaultPipeSignal() void {
    if (comptime builtin.os.tag == .windows) return;
    const default_action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &default_action, null);
}

/// Reports whether a termination signal has been received.
pub fn shouldExit() bool {
    return should_exit.load(.monotonic);
}
