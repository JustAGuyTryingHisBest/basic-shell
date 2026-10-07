//! Buffered handles to the shell's standard streams.
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

pub fn init(ctx: *ShellCtx, io: std.Io) void {
    ctx.stdin_file_reader = .init(.stdin(), io, &ctx.stdin_buffer);
    ctx.stdout_file_writer = .init(.stdout(), io, &ctx.stdout_buffer);
    ctx.stderr_file_writer = .init(.stderr(), io, &ctx.stderr_buffer);
}

pub fn stdin(ctx: *ShellCtx) *std.Io.Reader {
    return &ctx.stdin_file_reader.interface;
}

pub fn stdout(ctx: *ShellCtx) *std.Io.Writer {
    return &ctx.stdout_file_writer.interface;
}

pub fn stderr(ctx: *ShellCtx) *std.Io.Writer {
    return &ctx.stderr_file_writer.interface;
}
