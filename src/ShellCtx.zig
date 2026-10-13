//! State shared by every stage of the shell: buffered standard streams,
//! environment variables and the last exit status.
//!
//! Each reader/writer holds a slice into a buffer stored in this same struct,
//! and the `interface` fields locate their parent via `@fieldParentPtr`.
//! A `ShellCtx` must therefore be initialized in place with `init` and never
//! copied or moved afterwards; pass it around as `*ShellCtx`.

const ShellCtx = @This();
const std = @import("std");

const buffer_size = 1024;

stdin_buffer: [buffer_size]u8,
stdout_buffer: [buffer_size]u8,
stderr_buffer: [buffer_size]u8,

stdin_file_reader: std.Io.File.Reader,
stdout_file_writer: std.Io.File.Writer,
stderr_file_writer: std.Io.File.Writer,

io: std.Io,

// this is NOT threadsafe.
env_vars: *std.process.Environ.Map,

/// Exit status of the most recently completed command; the future `$?`.
last_exit_status: u8,

pub fn init(ctx: *ShellCtx, io: std.Io, env_vars: *std.process.Environ.Map) void {
    ctx.stdin_file_reader = .initStreaming(.stdin(), io, &ctx.stdin_buffer);
    ctx.stdout_file_writer = .initStreaming(.stdout(), io, &ctx.stdout_buffer);
    ctx.stderr_file_writer = .initStreaming(.stderr(), io, &ctx.stderr_buffer);
    ctx.io = io;
    ctx.env_vars = env_vars;
    ctx.last_exit_status = 0;
}

/// The buffered standard input.
pub fn stdin(ctx: *ShellCtx) *std.Io.Reader {
    return &ctx.stdin_file_reader.interface;
}

/// The buffered standard output.
pub fn stdout(ctx: *ShellCtx) *std.Io.Writer {
    return &ctx.stdout_file_writer.interface;
}

/// The buffered standard error.
pub fn stderr(ctx: *ShellCtx) *std.Io.Writer {
    return &ctx.stderr_file_writer.interface;
}

/// Readable text for the common file-system errors; other errors keep their
/// Zig name.
pub fn describeFileError(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "no such file or directory",
        error.AccessDenied => "permission denied",
        error.NotDir => "not a directory",
        error.IsDir => "is a directory",
        else => @errorName(err),
    };
}

/// Writes `bs: <message>` plus a newline to stderr and flushes it.
pub fn reportError(ctx: *ShellCtx, comptime format: []const u8, arguments: anytype) std.Io.Writer.Error!void {
    const stderr_writer = ctx.stderr();
    try stderr_writer.print("bs: " ++ format ++ "\n", arguments);
    try stderr_writer.flush();
}
