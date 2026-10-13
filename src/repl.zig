//! The interactive read-eval loop: prompt, read a line, run it, repeat.
const std = @import("std");

const ShellCtx = @import("ShellCtx.zig");
const exec = @import("exec.zig");
const prompt_words = @import("prompt_words.zig");
const signals = @import("signals.zig");

/// Runs the interactive read loop until end of input or a termination signal.
pub fn run(init: std.process.Init) !void {
    var shell_ctx: ShellCtx = undefined;
    shell_ctx.init(init.io, init.environ_map);

    // Holds per-line allocations (e.g. argv); reset before each command.
    var line_arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer line_arena.deinit();

    try signals.installHandlers(shell_ctx.stderr());

    while (!signals.shouldExit()) {
        try printPrompt(shell_ctx.stdout());
        const line = readLine(&shell_ctx) catch |err| switch (err) {
            error.EndOfInput => break,
            error.LineTooLong => {
                try shell_ctx.reportError("input line too long", .{});
                // Drop the rest of the oversized line so the next read starts fresh.
                _ = shell_ctx.stdin().discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                    error.EndOfStream => break,
                    error.ReadFailed => return error.ReadFailed,
                };
                continue;
            },
            error.ReadFailed => |fatal_err| return fatal_err,
        };

        _ = line_arena.reset(.retain_capacity);
        const words = prompt_words.splitWords(line_arena.allocator(), line) catch |err| switch (err) {
            error.UnterminatedSingleQuote,
            error.UnterminatedDoubleQuote,
            error.TrailingBackslash,
            => |syntax_err| {
                try shell_ctx.reportError("syntax error: {s}", .{describeSyntaxError(syntax_err)});
                // Matches bash and dash, which use 2 for syntax errors.
                shell_ctx.last_exit_status = 2;
                continue;
            },
            error.OutOfMemory => |fatal_err| return fatal_err,
        };
        try exec.runCommand(&shell_ctx, words);
    }
}

fn describeSyntaxError(syntax_err: prompt_words.SplitWordsError) []const u8 {
    return switch (syntax_err) {
        error.UnterminatedSingleQuote => "unterminated single quote",
        error.UnterminatedDoubleQuote => "unterminated double quote",
        // Line continuation needs a second prompt (PS2), which isn't implemented yet.
        error.TrailingBackslash => "line ends with a backslash",
        error.OutOfMemory => unreachable,
    };
}

fn printPrompt(stdout: *std.Io.Writer) !void {
    try stdout.print("$ ", .{});
    try stdout.flush();
}

const ReadLineError = error{
    /// Stdin reached end-of-file (e.g. Ctrl-D) with no pending input.
    EndOfInput,
    /// The line did not fit in the stdin buffer.
    LineTooLong,
    ReadFailed,
};

/// Returns the next line of input without its trailing newline. The slice
/// points into the stdin buffer and is only valid until the next read.
fn readLine(shell_ctx: *ShellCtx) ReadLineError![]u8 {
    return shell_ctx.stdin().takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return error.LineTooLong,
        error.ReadFailed => return error.ReadFailed,
    } orelse return error.EndOfInput;
}
