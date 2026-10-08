//! Public interface of the `shell` module.
const std = @import("std");

pub const AppRt = @import("apprt.zig");
pub const ShellCtx = @import("ShellCtx.zig");

/// Runs the interactive read loop until end of input or a termination signal.
pub fn main(init: std.process.Init) !void {
    var shell_ctx: ShellCtx = undefined;
    shell_ctx.init(init.io, init.environ_map);

    try AppRt.installSignalHandlers(shell_ctx.stderr());

    while (!AppRt.should_app_exit()) {
        try printPrompt(shell_ctx.stdout());
        readUserInput(&shell_ctx) catch |err| switch (err) {
            error.EndOfInput => break,
            error.LineTooLong => {
                const stderr = shell_ctx.stderr();
                try stderr.print("shell: input line too long\n", .{});
                try stderr.flush();
                // Drop the rest of the oversized line so the next read starts fresh.
                _ = shell_ctx.stdin().discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                    error.EndOfStream => break,
                    error.ReadFailed => return error.ReadFailed,
                };
            },
            error.ReadFailed, error.WriteFailed => |fatal_err| return fatal_err,
        };
    }
}

fn printPrompt(stdout: *std.Io.Writer) !void {
    try stdout.print("$ ", .{});
    try stdout.flush();
}

const ReadUserInputError = error{
    /// Stdin reached end-of-file (e.g. Ctrl-D) with no pending input.
    EndOfInput,
    /// The line did not fit in the stdin buffer.
    LineTooLong,
    ReadFailed,
} || std.Io.Writer.Error;

fn readUserInput(shell_ctx: *ShellCtx) ReadUserInputError!void {
    const line = shell_ctx.stdin().takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return error.LineTooLong,
        error.ReadFailed => return error.ReadFailed,
    } orelse return error.EndOfInput;

    const stdout = shell_ctx.stdout();
    try stdout.print("{s}\n", .{line});
    try stdout.flush();
}

test {
    std.testing.refAllDecls(@This());
}
