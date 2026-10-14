//! The `bs` command line (spec §7.1): runs a script file or `-c` code, prints
//! the version for `-v`/`--version`, or starts the prompt when given no
//! arguments.
const std = @import("std");

const diagnostics = @import("diagnostics.zig");
const eval = @import("eval.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const repl = @import("repl.zig");
const resolve = @import("resolve.zig");
const ShellCtx = @import("ShellCtx.zig");
const signals = @import("signals.zig");
const Source = @import("Source.zig");
const version = @import("version");

const Allocator = std.mem.Allocator;

/// Entry point: returns the process exit status.
pub fn main(init: std.process.Init) !u8 {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const command_line = try init.minimal.args.toSlice(arena.allocator());
    if (command_line.len <= 1) {
        try repl.run(init);
        return 0;
    }

    var shell_ctx: ShellCtx = undefined;
    shell_ctx.init(init.io, init.environ_map);
    // Script mode uses default signal dispositions (spec §8.6).
    signals.restoreDefaultPipeSignal();

    var source: Source = undefined;
    var first_script_argument: usize = undefined;
    if (std.mem.eql(u8, command_line[1], "-c")) {
        if (command_line.len < 3) {
            try shell_ctx.reportError("-c requires the code to run", .{});
            return 2;
        }
        source = .{ .display_name = "-c", .text = command_line[2] };
        first_script_argument = 3;
    } else if (std.mem.eql(u8, command_line[1], "-v") or std.mem.eql(u8, command_line[1], "--version")) {
        const stdout = shell_ctx.stdout();
        try writeVersion(stdout);
        try stdout.flush();
        return 0;
    } else {
        source = Source.load(init.io, arena.allocator(), command_line[1]) catch |err| {
            try shell_ctx.reportError("{s}: {s}", .{ command_line[1], ShellCtx.describeFileError(err) });
            return 127;
        };
        first_script_argument = 2;
    }

    const script_arguments = try arena.allocator().alloc([]const u8, command_line.len - first_script_argument);
    for (script_arguments, command_line[first_script_argument..]) |*script_argument, argument| script_argument.* = argument;
    return runSource(init.gpa, &shell_ctx, shell_ctx.stdout(), shell_ctx.stderr(), source, script_arguments) catch |err| {
        shell_ctx.reportError("{s}", .{@errorName(err)}) catch {};
        return 1;
    };
}

/// Lexes, parses, resolves and runs `source`, and returns the exit status
/// (spec §9). Nothing runs if any stage before evaluation reports an error.
pub fn runSource(
    gpa: Allocator,
    shell_ctx: *ShellCtx,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    source: Source,
    script_arguments: []const []const u8,
) !u8 {
    var tree_arena: std.heap.ArenaAllocator = .init(gpa);
    defer tree_arena.deinit();
    const tree_allocator = tree_arena.allocator();

    var problems: diagnostics.Diagnostics = .init(tree_allocator);
    const tokens = try lexer.tokenize(tree_allocator, source.text, &problems);
    const script = try parser.parse(tree_allocator, tokens, &problems);
    // Resolving a tree with syntax errors would only add confusing errors.
    if (!problems.hasErrors()) try resolve.resolve(tree_allocator, script, &problems);
    if (problems.hasErrors()) {
        std.mem.sort(diagnostics.Diagnostic, problems.items.items, {}, isEarlier);
        for (problems.items.items) |problem| try diagnostics.render(stderr, source, problem);
        try stderr.flush();
        return 2;
    }

    var interpreter: eval.Interpreter = undefined;
    interpreter.init(.{ .gpa = gpa, .shell_ctx = shell_ctx, .stdout = stdout, .stderr = stderr, .source = source });
    defer interpreter.deinit();
    interpreter.runScript(script, script_arguments) catch |err| {
        // The output may be going to a closed pipe; the status matters more.
        stdout.flush() catch {};
        switch (err) {
            error.ScriptExit => return interpreter.exit_status,
            // The message was printed when the error happened.
            error.RuntimeError => return interpreter.failure.exit_status,
            error.CommandFailed => {
                const failure = &interpreter.failure;
                try stderr.print("{s}:{d}: '{s}' failed with status {d}\n", .{
                    source.display_name,
                    source.locate(failure.source_offset).line_number,
                    failure.description(),
                    failure.exit_status,
                });
                try stderr.flush();
                return failure.exit_status;
            },
            else => |other| return other,
        }
    };
    return 0;
}

/// Writes `bs <version> (<git revision>)` and a newline; both values are
/// embedded at build time (see createVersionModule in build.zig).
fn writeVersion(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print("bs {s} ({s})\n", .{ version.version, version.git_revision });
}

fn isEarlier(_: void, left: diagnostics.Diagnostic, right: diagnostics.Diagnostic) bool {
    return left.source_offset < right.source_offset;
}

const TestRun = struct {
    exit_status: u8,
    stdout: []const u8,
    stderr: []const u8,
};

fn runForTest(arena: Allocator, source_text: []const u8, script_arguments: []const []const u8) !TestRun {
    var environment: std.process.Environ.Map = .init(arena);
    try environment.put("PATH", "/usr/bin:/bin");
    var shell_ctx: ShellCtx = undefined;
    shell_ctx.init(std.testing.io, &environment);
    var stdout: std.Io.Writer.Allocating = .init(arena);
    var stderr: std.Io.Writer.Allocating = .init(arena);
    const exit_status = try runSource(
        std.testing.allocator,
        &shell_ctx,
        &stdout.writer,
        &stderr.writer,
        .{ .display_name = "test.bs", .text = source_text },
        script_arguments,
    );
    return .{ .exit_status = exit_status, .stdout = stdout.written(), .stderr = stderr.written() };
}

test "the version line names the package version and git revision" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeVersion(&output.writer);
    const expected_line = "bs " ++ version.version ++ " (" ++ version.git_revision ++ ")\n";
    try std.testing.expectEqualStrings(expected_line, output.written());
    try std.testing.expect(version.version.len > 0);
    try std.testing.expect(version.git_revision.len > 0);
}

test "empty scripts and shebang-only scripts succeed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u8, 0), (try runForTest(arena.allocator(), "", &.{})).exit_status);
    try std.testing.expectEqual(@as(u8, 0), (try runForTest(arena.allocator(), "#!/usr/bin/bs\n", &.{})).exit_status);
}

test "a script runs and sees its arguments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try runForTest(arena.allocator(), "echo hi\nfor $args \\a -> echo $a\n", &.{ "x", "y" });
    try std.testing.expectEqual(@as(u8, 0), result.exit_status);
    try std.testing.expectEqualStrings("hi\nx\ny\n", result.stdout);
}

test "syntax and resolve errors are all reported, in order, with status 2" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try runForTest(arena.allocator(), "echo 'open\n", &.{});
    try std.testing.expectEqual(@as(u8, 2), result.exit_status);
    try std.testing.expectEqualStrings(
        \\test.bs:1:6: error: unterminated single quote
        \\    1 | echo 'open
        \\      |      ^
        \\
    , result.stderr);

    const resolve_result = try runForTest(arena.allocator(), "add x 1\nadd y 1\n", &.{});
    try std.testing.expectEqual(@as(u8, 2), resolve_result.exit_status);
    const first_error = std.mem.find(u8, resolve_result.stderr, "undefined variable 'x'").?;
    const second_error = std.mem.find(u8, resolve_result.stderr, "undefined variable 'y'").?;
    try std.testing.expect(first_error < second_error);
}

test "an unhandled failure is reported with its line and status" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try runForTest(arena.allocator(), "echo before\nFail 3\n", &.{});
    try std.testing.expectEqual(@as(u8, 3), result.exit_status);
    try std.testing.expectEqualStrings("before\n", result.stdout);
    try std.testing.expectEqualStrings("test.bs:2: 'Fail 3' failed with status 3\n", result.stderr);
}

test "an unhandled Fail 0 or Fail 256 still exits non-zero" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u8, 1), (try runForTest(arena.allocator(), "Fail 256\n", &.{})).exit_status);
    try std.testing.expectEqual(@as(u8, 1), (try runForTest(arena.allocator(), "Fail 0\n", &.{})).exit_status);
}

test "a missing command is reported with the bs prefix" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const result = try runForTest(arena.allocator(), "cd /definitely/not/a/directory\n", &.{});
    try std.testing.expectEqual(@as(u8, 1), result.exit_status);
    try std.testing.expect(std.mem.find(u8, result.stderr, "bs: cd: /definitely/not/a/directory: no such file or directory\n") != null);
}

test "exit and runtime errors set the status" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(u8, 4), (try runForTest(arena.allocator(), "exit 4\n", &.{})).exit_status);
    try std.testing.expectEqual(@as(u8, 1), (try runForTest(arena.allocator(), "add 1 \"two\"\n", &.{})).exit_status);
}
