const builtin = @import("builtin");
const std = @import("std");
const ShellCtx = @import("shell").ShellCtx;

var should_exit = std.atomic.Value(bool).init(false);

fn handleSignal(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    should_exit.store(true, .seq_cst);
}

fn printPrompt(stdout: *std.Io.Writer) !void {
    try std.Io.Writer.print(stdout, "$ ", .{});
}

fn installSignalHandlers(stderr: *std.Io.Writer) !void {
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

pub fn main(init: std.process.Init) !void {
    var shell_ctx: ShellCtx = undefined;
    shell_ctx.init(init.io);

    try installSignalHandlers(shell_ctx.stderr());

    while (!should_exit.load(.monotonic)) {
        try printPrompt(shell_ctx.stdout());
        try shell_ctx.stdout().flush();
        const keep_reading = try readUserInput(&shell_ctx);
        if (!keep_reading) break;
    }
}

/// Returns false once stdin hits end-of-file (e.g. Ctrl-D).
fn readUserInput(shell_ctx: *ShellCtx) !bool {
    const line = try shell_ctx.stdin().takeDelimiter('\n') orelse return false;
    const stdout = shell_ctx.stdout();
    try stdout.print("{s}\n", .{line});
    try stdout.flush();
    return true;
}
