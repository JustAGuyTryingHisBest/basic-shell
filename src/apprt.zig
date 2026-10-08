const builtin = @import("builtin");
const std = @import("std");

var should_exit = std.atomic.Value(bool).init(false);

fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    should_exit.store(true, .seq_cst);
}

pub fn installSignalHandlers(stderr: *std.Io.Writer) !void {
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

pub fn should_app_exit() bool {
    return should_exit.load(.monotonic);
}
