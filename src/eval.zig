//! The tree-walking evaluator (spec §8).
//!
//! Failure travels as Zig errors: a failing command records its status in
//! `Interpreter.failure` and returns `error.CommandFailed`, which every
//! caller propagates with `try` until a `match` scrutinee catches it. Calls
//! in tail position return a `TailCall` instead of recursing, and
//! `callCallee` loops over them, so tail recursion runs in constant space.
const std = @import("std");

const ast = @import("ast.zig");
const builtins = @import("builtins.zig");
const diagnostics = @import("diagnostics.zig");
const exec = @import("exec.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const resolve = @import("resolve.zig");
const value = @import("value.zig");
const ShellCtx = @import("ShellCtx.zig");
const Source = @import("Source.zig");

const Allocator = std.mem.Allocator;
const Closure = value.Closure;
const Environment = value.Environment;
const Value = value.Value;

/// Errors that end evaluation; details are in `Interpreter.failure` / `exit_status`.
pub const EvalError = error{ CommandFailed, ScriptExit, RuntimeError } || exec.CaptureError;

/// Largest captured output, in bytes (spec §5.5).
pub const capture_limit_bytes = 1024 * 1024;

/// Stack the evaluator may use before reporting "recursion too deep"
/// instead of crashing. Main-thread stacks are 8 MiB by default on Linux
/// and macOS.
pub const default_stack_budget_bytes = 4 * 1024 * 1024;

/// The most recent unhandled failure: its status, location and command line.
pub const Failure = struct {
    exit_status: u8 = 0,
    source_offset: u32 = 0,
    kind: Kind = .command,
    description_buffer: [256]u8 = undefined,
    description_length: usize = 0,

    /// What produced a `Failure`.
    pub const Kind = enum {
        /// A command or `Fail` value; reported as "'…' failed with status N"
        /// if nothing handles it.
        command,
        /// A runtime error; its message was printed when it happened.
        runtime,
    };

    /// The failing command line, truncated to the buffer.
    pub fn description(failure: *const Failure) []const u8 {
        return failure.description_buffer[0..failure.description_length];
    }

    fn setDescription(failure: *Failure, words: []const []const u8) void {
        var writer: std.Io.Writer = .fixed(&failure.description_buffer);
        for (words, 0..) |word, index| {
            if (index != 0) writer.writeByte(' ') catch break;
            writer.writeAll(word) catch break;
        }
        failure.description_length = writer.end;
    }
};

const Frame = struct {
    arena: std.heap.ArenaAllocator,
    /// See `Closure.frame_id`.
    id: u64,
};

const Callee = union(enum) {
    function: *const ast.Definition,
    closure: *const Closure,
};

const TailCall = struct {
    callee: Callee,
    arguments: []const Value,
};

const TailResult = union(enum) {
    value: Value,
    tail_call: TailCall,
};

fn plural(count: usize) []const u8 {
    return if (count == 1) "" else "s";
}

/// Evaluates a resolved script; initialize in place with `init` and never move.
pub const Interpreter = struct {
    gpa: Allocator,
    shell_ctx: *ShellCtx,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    source: Source,
    stack_budget_bytes: usize,
    global_frame: Frame,
    current_frame: *Frame,
    global_environment: ?*const Environment = null,
    next_frame_id: u64 = 1,
    /// Address near the start of the evaluator's stack; see `callCallee`.
    stack_base_address: usize = 0,
    failure: Failure = .{},
    error_message: value.ErrorMessage = .{},
    /// Set by `exit` before it returns `error.ScriptExit`.
    exit_status: u8 = 0,

    /// Everything an interpreter needs from its host.
    pub const Options = struct {
        gpa: Allocator,
        shell_ctx: *ShellCtx,
        /// Where `echo` writes; flushed before every child process starts.
        stdout: *std.Io.Writer,
        /// Where runtime errors are reported.
        stderr: *std.Io.Writer,
        /// For runtime error messages.
        source: Source,
        stack_budget_bytes: usize = default_stack_budget_bytes,
    };

    /// Initializes in place: `current_frame` points into the interpreter, so
    /// it must not be copied or moved afterwards.
    pub fn init(interpreter: *Interpreter, options: Options) void {
        interpreter.* = .{
            .gpa = options.gpa,
            .shell_ctx = options.shell_ctx,
            .stdout = options.stdout,
            .stderr = options.stderr,
            .source = options.source,
            .stack_budget_bytes = options.stack_budget_bytes,
            .global_frame = .{ .arena = .init(options.gpa), .id = 0 },
            .current_frame = undefined,
        };
        interpreter.current_frame = &interpreter.global_frame;
    }

    /// Frees the global frame.
    pub fn deinit(interpreter: *Interpreter) void {
        interpreter.global_frame.arena.deinit();
    }

    /// Runs a resolved script: top-level statements in order, then `main` if
    /// it is defined (spec §5.10). Flushes stdout on success.
    pub fn runScript(interpreter: *Interpreter, script: *const ast.Script, script_arguments: []const []const u8) EvalError!void {
        interpreter.stack_base_address = @frameAddress();
        const argument_values = try interpreter.allocator().alloc(Value, script_arguments.len);
        for (argument_values, script_arguments) |*argument_value, argument| argument_value.* = .{ .string = argument };
        interpreter.global_environment = try interpreter.bind(null, "args", .{ .list = argument_values });

        for (script.statements) |statement| switch (statement) {
            .signature, .data_declaration => {},
            .definition => |definition| {
                if (definition.isFunction() or definition == script.main) continue;
                const bound_value = try interpreter.evalExpression(definition.body, interpreter.global_environment);
                interpreter.global_environment = try interpreter.bind(interpreter.global_environment, definition.name, bound_value);
            },
            .expression => |expression| {
                const statement_value = try interpreter.evalExpression(expression, interpreter.global_environment);
                try interpreter.checkStatementStatus(statement_value, expression.source_offset);
            },
        };
        if (script.main) |main_definition| {
            const main_result = try interpreter.callCallee(.{ .function = main_definition }, &.{}, main_definition.source_offset, interpreter.allocator());
            try interpreter.checkStatementStatus(main_result, main_definition.source_offset);
        }
        try interpreter.stdout.flush();
    }

    fn allocator(interpreter: *Interpreter) Allocator {
        return interpreter.current_frame.arena.allocator();
    }

    fn newFrameId(interpreter: *Interpreter) u64 {
        const frame_id = interpreter.next_frame_id;
        interpreter.next_frame_id += 1;
        return frame_id;
    }

    fn bind(interpreter: *Interpreter, parent: ?*const Environment, name: []const u8, bound_value: Value) Allocator.Error!*const Environment {
        const environment = try interpreter.allocator().create(Environment);
        environment.* = .{ .parent = parent, .name = name, .value = bound_value };
        return environment;
    }

    /// Reports a runtime error at `source_offset` and fails with status 1 (spec §9).
    fn raise(interpreter: *Interpreter, source_offset: u32, comptime format: []const u8, arguments: anytype) EvalError {
        interpreter.error_message.set(format, arguments);
        return interpreter.raiseMessage(source_offset);
    }

    /// Like `raise`, for a message already in `error_message`.
    fn raiseMessage(interpreter: *Interpreter, source_offset: u32) EvalError {
        interpreter.stdout.flush() catch |err| return err;
        diagnostics.render(interpreter.stderr, interpreter.source, .{
            .source_offset = source_offset,
            .length = 1,
            .message = interpreter.error_message.text(),
        }) catch |err| return err;
        interpreter.stderr.flush() catch |err| return err;
        interpreter.failure = .{ .exit_status = 1, .source_offset = source_offset, .kind = .runtime };
        return error.RuntimeError;
    }

    /// Records a failed command and returns `error.CommandFailed` (spec §5.7).
    fn failCommand(interpreter: *Interpreter, exit_status: u8, source_offset: u32, words: []const []const u8) EvalError {
        interpreter.failure = .{ .exit_status = exit_status, .source_offset = source_offset, .kind = .command };
        interpreter.failure.setDescription(words);
        return error.CommandFailed;
    }

    /// A statement whose value is `Fail n` stops the current function.
    fn checkStatementStatus(interpreter: *Interpreter, statement_value: Value, source_offset: u32) EvalError!void {
        const code = statement_value.failCode() orelse return;
        const line_text = std.mem.trim(u8, interpreter.source.locate(source_offset).line_text, " \t");
        // A failure must never look like success, even for `Fail 0` or `Fail 256`.
        const status: u8 = @intCast(@mod(code, 256));
        return interpreter.failCommand(if (status == 0) 1 else status, source_offset, &.{line_text});
    }

    fn evalStatements(interpreter: *Interpreter, statements: []const ast.Statement, environment: ?*const Environment, is_tail: bool) EvalError!TailResult {
        var current_environment = environment;
        for (statements, 0..) |statement, index| {
            const is_last = index + 1 == statements.len;
            switch (statement) {
                .signature, .data_declaration => {},
                .definition => |definition| {
                    const bound_value = try interpreter.evalExpression(definition.body, current_environment);
                    current_environment = try interpreter.bind(current_environment, definition.name, bound_value);
                    if (is_last) return .{ .value = bound_value };
                },
                .expression => |expression| {
                    if (is_last and is_tail) {
                        const result = try interpreter.evalTail(expression, current_environment);
                        if (result == .value) try interpreter.checkStatementStatus(result.value, expression.source_offset);
                        return result;
                    }
                    const statement_value = try interpreter.evalExpression(expression, current_environment);
                    try interpreter.checkStatementStatus(statement_value, expression.source_offset);
                    if (is_last) return .{ .value = statement_value };
                },
            }
        }
        return .{ .value = Value.ok };
    }

    fn evalExpression(interpreter: *Interpreter, expression: *const ast.Expression, environment: ?*const Environment) EvalError!Value {
        switch (expression.data) {
            .word => unreachable, // `resolve` rewrites every word
            .literal_string => |text| return .{ .string = text },
            .literal_integer => |integer| return .{ .integer = integer },
            .interpolated => |parts| return interpreter.evalInterpolated(parts, environment, expression.source_offset),
            .variable => |variable| return interpreter.lookupVariable(variable, environment, expression.source_offset),
            .function_reference => |definition| return .{ .function = definition },
            .list => |elements| return .{ .list = try interpreter.evalValues(elements, environment) },
            .call => |*call| return (try interpreter.evalCall(expression, call, environment, false)).value,
            .block => |statements| return (try interpreter.evalStatements(statements, environment, false)).value,
            .match => |*match| return (try interpreter.evalMatch(match, environment, false)).value,
            .lambda => |lambda| {
                const closure = try interpreter.allocator().create(Closure);
                closure.* = .{
                    .parameters = lambda.parameters,
                    .body = lambda.body,
                    .environment = environment,
                    .frame_id = interpreter.current_frame.id,
                };
                return .{ .closure = closure };
            },
        }
    }

    /// Evaluates an expression in tail position: a call marked `is_tail`
    /// comes back as a `TailCall` for `callCallee` to run.
    fn evalTail(interpreter: *Interpreter, expression: *const ast.Expression, environment: ?*const Environment) EvalError!TailResult {
        return switch (expression.data) {
            .call => |*call| interpreter.evalCall(expression, call, environment, true),
            .block => |statements| interpreter.evalStatements(statements, environment, true),
            .match => |*match| interpreter.evalMatch(match, environment, true),
            else => .{ .value = try interpreter.evalExpression(expression, environment) },
        };
    }

    fn evalValues(interpreter: *Interpreter, expressions: []const *ast.Expression, environment: ?*const Environment) EvalError![]const Value {
        const values = try interpreter.allocator().alloc(Value, expressions.len);
        for (values, expressions) |*slot, expression| slot.* = try interpreter.evalExpression(expression, environment);
        return values;
    }

    fn evalInterpolated(interpreter: *Interpreter, parts: []const ast.InterpolationPart, environment: ?*const Environment, source_offset: u32) EvalError!Value {
        var text: std.ArrayList(u8) = .empty;
        for (parts) |part| switch (part) {
            .text => |literal_text| try text.appendSlice(interpreter.allocator(), literal_text),
            .variable => |variable| {
                const part_value = try interpreter.lookupVariable(variable, environment, source_offset);
                value.appendText(&text, interpreter.allocator(), part_value, &interpreter.error_message) catch |err| switch (err) {
                    error.RuntimeError => return interpreter.raiseMessage(source_offset),
                    error.OutOfMemory => return error.OutOfMemory,
                };
            },
        };
        return .{ .string = text.items };
    }

    fn lookupVariable(interpreter: *Interpreter, variable: ast.Variable, environment: ?*const Environment, source_offset: u32) EvalError!Value {
        if (Environment.lookup(environment, variable.name)) |found| return found;
        if (variable.may_be_environment) {
            const text = interpreter.shell_ctx.env_vars.get(variable.name) orelse
                return interpreter.raise(source_offset, "environment variable '{s}' is not set", .{variable.name});
            // `export` frees the map's copy when it replaces the value.
            return .{ .string = try interpreter.allocator().dupe(u8, text) };
        }
        return interpreter.raise(source_offset, "'{s}' is used before its definition runs", .{variable.name});
    }

    fn evalCall(interpreter: *Interpreter, expression: *const ast.Expression, call: *const ast.Call, environment: ?*const Environment, allow_tail_call: bool) EvalError!TailResult {
        switch (call.head_kind) {
            .unresolved => unreachable,
            .function, .closure => {
                const callee: Callee = if (call.head_kind == .function)
                    .{ .function = call.function.? }
                else
                    try interpreter.calleeFromValue(try interpreter.evalExpression(call.head, environment), call.head.source_offset);
                const arguments = try interpreter.evalValues(call.arguments, environment);
                if (allow_tail_call and call.is_tail) return .{ .tail_call = .{ .callee = callee, .arguments = arguments } };
                return .{ .value = try interpreter.callCallee(callee, arguments, expression.source_offset, interpreter.allocator()) };
            },
            .constructor => return .{ .value = .{ .constructor = .{
                .name = call.name,
                .fields = try interpreter.evalValues(call.arguments, environment),
            } } },
            .builtin => return .{ .value = try interpreter.evalBuiltin(expression, call, environment) },
            .external => return .{ .value = try interpreter.evalExternal(expression, call, environment) },
        }
    }

    fn calleeFromValue(interpreter: *Interpreter, callee_value: Value, source_offset: u32) EvalError!Callee {
        return switch (callee_value) {
            .closure => |closure| .{ .closure = closure },
            .function => |definition| .{ .function = definition },
            else => interpreter.raise(source_offset, "{s} is not a function", .{value.describe(callee_value)}),
        };
    }

    /// Calls a function or lambda and copies its result into
    /// `result_allocator`. Tail calls made by the body reuse this loop
    /// instead of recursing (spec §8.4).
    fn callCallee(interpreter: *Interpreter, initial_callee: Callee, initial_arguments: []const Value, source_offset: u32, result_allocator: Allocator) EvalError!Value {
        // The stack grows down on every supported target.
        const stack_used = interpreter.stack_base_address -| @frameAddress();
        if (stack_used > interpreter.stack_budget_bytes) return interpreter.raise(source_offset, "recursion too deep", .{});

        const caller_frame = interpreter.current_frame;
        const first_frame_id = interpreter.next_frame_id;
        var frame: Frame = .{ .arena = .init(interpreter.gpa), .id = interpreter.newFrameId() };
        // Frames kept alive because a closure made in them was passed to a tail call.
        var retained_arenas: std.ArrayList(std.heap.ArenaAllocator) = .empty;
        interpreter.current_frame = &frame;
        defer {
            interpreter.current_frame = caller_frame;
            frame.arena.deinit();
            for (retained_arenas.items) |retained_arena| retained_arena.deinit();
            retained_arenas.deinit(interpreter.gpa);
        }

        var callee = initial_callee;
        var arguments = initial_arguments;
        while (true) {
            const parameters: []const ast.Parameter, const body: *const ast.Expression, const base_environment: ?*const Environment = switch (callee) {
                .function => |definition| .{ definition.parameters, definition.body, interpreter.global_environment },
                .closure => |closure| .{ closure.parameters, closure.body, closure.environment },
            };
            if (arguments.len != parameters.len) {
                return interpreter.raise(source_offset, "the function takes {d} argument{s}, got {d}", .{ parameters.len, plural(parameters.len), arguments.len });
            }
            var environment = base_environment;
            for (parameters, arguments) |parameter, argument| {
                if (parameter.name) |name| environment = try interpreter.bind(environment, name, argument);
            }
            switch (try interpreter.evalTail(body, environment)) {
                .value => |result| return value.deepCopy(result_allocator, result, first_frame_id) catch |err| switch (err) {
                    error.EscapingClosure => return interpreter.raise(source_offset, "a lambda cannot be returned from the function that created it", .{}),
                    error.OutOfMemory => return error.OutOfMemory,
                },
                .tail_call => |tail_call| {
                    var next_arena: std.heap.ArenaAllocator = .init(interpreter.gpa);
                    errdefer next_arena.deinit();
                    const copied_arguments = value.deepCopyAll(next_arena.allocator(), tail_call.arguments, std.math.maxInt(u64)) catch |err| switch (err) {
                        error.EscapingClosure => unreachable, // the threshold admits every closure
                        error.OutOfMemory => return error.OutOfMemory,
                    };
                    const callee_made_here = tail_call.callee == .closure and tail_call.callee.closure.frame_id == frame.id;
                    if (callee_made_here or value.anyClosureFrom(tail_call.arguments, frame.id)) {
                        try retained_arenas.append(interpreter.gpa, frame.arena);
                    } else {
                        frame.arena.deinit();
                    }
                    frame = .{ .arena = next_arena, .id = interpreter.newFrameId() };
                    callee = tail_call.callee;
                    arguments = copied_arguments;
                },
            }
        }
    }

    fn evalMatch(interpreter: *Interpreter, match: *const ast.Match, environment: ?*const Environment, is_tail: bool) EvalError!TailResult {
        const scrutinee_value = try interpreter.evalScrutinee(match.scrutinee, environment);
        for (match.arms) |arm| {
            var arm_environment = environment;
            if (try interpreter.matchPattern(arm.pattern, scrutinee_value, &arm_environment)) {
                if (is_tail) return interpreter.evalTail(arm.body, arm_environment);
                return .{ .value = try interpreter.evalExpression(arm.body, arm_environment) };
            }
        }
        return interpreter.raise(match.scrutinee.source_offset, "no match arm fits {s}", .{value.describe(scrutinee_value)});
    }

    /// The scrutinee of a `match` is the only place a failure is caught: it
    /// becomes a `Fail code` value (spec §5.7).
    fn evalScrutinee(interpreter: *Interpreter, scrutinee: *const ast.Expression, environment: ?*const Environment) EvalError!Value {
        return interpreter.evalExpression(scrutinee, environment) catch |err| switch (err) {
            error.CommandFailed, error.RuntimeError => return value.makeFail(interpreter.allocator(), interpreter.failure.exit_status),
            else => |other| return other,
        };
    }

    fn matchPattern(interpreter: *Interpreter, pattern: *const ast.Pattern, candidate: Value, environment: *?*const Environment) Allocator.Error!bool {
        switch (pattern.data) {
            .wildcard => return true,
            .binder => |name| {
                environment.* = try interpreter.bind(environment.*, name, candidate);
                return true;
            },
            .literal_string => |text| return switch (candidate) {
                .string => |candidate_text| std.mem.eql(u8, candidate_text, text),
                .integer => |candidate_integer| integerEqualsText(candidate_integer, text),
                else => false,
            },
            .literal_integer => |integer| return switch (candidate) {
                .integer => |candidate_integer| candidate_integer == integer,
                .string => |candidate_text| integerEqualsText(integer, candidate_text),
                else => false,
            },
            .constructor => |constructor| {
                const candidate_constructor = switch (candidate) {
                    .constructor => |candidate_constructor| candidate_constructor,
                    else => return false,
                };
                if (!std.mem.eql(u8, candidate_constructor.name, constructor.name)) return false;
                if (candidate_constructor.fields.len != constructor.fields.len) return false;
                for (constructor.fields, candidate_constructor.fields) |field_pattern, field_value| {
                    if (!try interpreter.matchPattern(field_pattern, field_value, environment)) return false;
                }
                return true;
            },
            .list => |element_patterns| {
                const elements = switch (candidate) {
                    .list => |elements| elements,
                    else => return false,
                };
                if (elements.len != element_patterns.len) return false;
                for (element_patterns, elements) |element_pattern, element| {
                    if (!try interpreter.matchPattern(element_pattern, element, environment)) return false;
                }
                return true;
            },
        }
    }

    fn evalBuiltin(interpreter: *Interpreter, expression: *const ast.Expression, call: *const ast.Call, environment: ?*const Environment) EvalError!Value {
        const builtin = call.builtin.?;
        if (builtin.isCommand()) {
            const words = try interpreter.evalWords(call.arguments, environment);
            return interpreter.runCommandBuiltin(builtin, words, expression.source_offset);
        }
        if (builtin == .@"for") return interpreter.evalFor(call, environment, expression.source_offset);
        const arguments = try interpreter.evalValues(call.arguments, environment);
        return builtins.callPure(interpreter.allocator(), builtin, arguments, &interpreter.error_message) catch |err| switch (err) {
            error.RuntimeError => return interpreter.raiseMessage(expression.source_offset),
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    /// Evaluates command arguments into words (spec §5.6).
    fn evalWords(interpreter: *Interpreter, arguments: []const *ast.Expression, environment: ?*const Environment) EvalError![]const []const u8 {
        var words: std.ArrayList([]const u8) = .empty;
        for (arguments) |argument| {
            const argument_value = try interpreter.evalExpression(argument, environment);
            value.expandArguments(&words, interpreter.allocator(), argument_value, &interpreter.error_message) catch |err| switch (err) {
                error.RuntimeError => return interpreter.raiseMessage(argument.source_offset),
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        return words.items;
    }

    fn runCommandBuiltin(interpreter: *Interpreter, builtin: ast.Builtin, words: []const []const u8, source_offset: u32) EvalError!Value {
        // Lists can expand to a different number of words than were written.
        const allowed = builtin.argumentCount();
        if (words.len < allowed.minimum or words.len > allowed.maximum) {
            return interpreter.raise(source_offset, "'{s}' got {d} argument{s} after expansion", .{ @tagName(builtin), words.len, plural(words.len) });
        }
        switch (builtin) {
            .echo => {
                for (words, 0..) |word, index| {
                    if (index != 0) try interpreter.stdout.writeByte(' ');
                    try interpreter.stdout.writeAll(word);
                }
                try interpreter.stdout.writeByte('\n');
            },
            .skip => {},
            .exit => {
                interpreter.exit_status = if (words.len == 0) 0 else std.fmt.parseInt(u8, words[0], 10) catch
                    return interpreter.raise(source_offset, "exit expects a status from 0 to 255, got '{s}'", .{words[0]});
                return error.ScriptExit;
            },
            .cd, .@"export" => return interpreter.runEnvironmentBuiltin(builtin, words, source_offset),
            .@"for", .lines, .words, .add, .sub, .eq, .lt => unreachable,
        }
        return Value.ok;
    }

    /// `cd dir` and `export NAME value`.
    fn runEnvironmentBuiltin(interpreter: *Interpreter, builtin: ast.Builtin, words: []const []const u8, source_offset: u32) EvalError!Value {
        switch (builtin) {
            .cd => std.process.setCurrentPath(interpreter.shell_ctx.io, words[0]) catch |err| {
                try interpreter.stdout.flush();
                try interpreter.stderr.print("bs: cd: {s}: {s}\n", .{ words[0], ShellCtx.describeFileError(err) });
                try interpreter.stderr.flush();
                return interpreter.failCommand(1, source_offset, &.{ "cd", words[0] });
            },
            .@"export" => {
                const name = words[0];
                if (name.len == 0 or std.mem.findScalar(u8, name, '=') != null or std.mem.findScalar(u8, name, 0) != null) {
                    return interpreter.raise(source_offset, "'{s}' is not a valid environment variable name", .{name});
                }
                try interpreter.shell_ctx.env_vars.put(name, words[1]);
            },
            else => unreachable,
        }
        return Value.ok;
    }

    fn evalFor(interpreter: *Interpreter, call: *const ast.Call, environment: ?*const Environment, source_offset: u32) EvalError!Value {
        const list_value = try interpreter.evalExpression(call.arguments[0], environment);
        const body_value = try interpreter.evalExpression(call.arguments[1], environment);
        const elements = switch (list_value) {
            .list => |elements| elements,
            else => return interpreter.raise(call.arguments[0].source_offset, "for expects a list, got {s}", .{value.describe(list_value)}),
        };
        const callee = try interpreter.calleeFromValue(body_value, call.arguments[1].source_offset);
        // Each iteration's result is only checked, so it lives in an arena
        // that is reset every iteration (spec §8.5).
        var iteration_arena: std.heap.ArenaAllocator = .init(interpreter.gpa);
        defer iteration_arena.deinit();
        for (elements) |element| {
            _ = iteration_arena.reset(.retain_capacity);
            const iteration_result = try interpreter.callCallee(callee, &.{element}, source_offset, iteration_arena.allocator());
            try interpreter.checkStatementStatus(iteration_result, call.arguments[1].source_offset);
        }
        return Value.ok;
    }

    /// Runs a program from `$PATH` (spec §5.5): in `.status` context it
    /// inherits stdout and produces `Ok` or a failure; in `.capture` context
    /// its stdout, minus one trailing newline, is the value.
    fn evalExternal(interpreter: *Interpreter, expression: *const ast.Expression, call: *const ast.Call, environment: ?*const Environment) EvalError!Value {
        const words = try interpreter.evalWords(call.arguments, environment);
        const argv = try interpreter.allocator().alloc([]const u8, words.len + 1);
        argv[0] = call.name;
        @memcpy(argv[1..], words);
        // Keep our own output ahead of the child's.
        try interpreter.stdout.flush();
        switch (call.context) {
            .status => {
                const exit_status = try exec.runExternalCommand(interpreter.shell_ctx, argv);
                if (exit_status == 0) return Value.ok;
                argv[0] = call.name; // `runExternalCommand` replaced it with the full path
                return interpreter.failCommand(exit_status, expression.source_offset, argv);
            },
            .capture => {
                const capture = exec.captureExternalCommand(interpreter.shell_ctx, interpreter.allocator(), argv, capture_limit_bytes) catch |err| switch (err) {
                    error.CaptureTooLarge => return interpreter.raise(expression.source_offset, "output of '{s}' is larger than {d} bytes", .{ call.name, capture_limit_bytes }),
                    else => |other| return other,
                };
                if (capture.exit_status != 0) {
                    argv[0] = call.name;
                    return interpreter.failCommand(capture.exit_status, expression.source_offset, argv);
                }
                const output = capture.output;
                return .{ .string = if (std.mem.endsWith(u8, output, "\n")) output[0 .. output.len - 1] else output };
            },
        }
    }
};

fn integerEqualsText(integer: i64, text: []const u8) bool {
    const parsed = std.fmt.parseInt(i64, text, 10) catch return false;
    return parsed == integer;
}

const TestOutcome = struct {
    stdout: []const u8,
    stderr: []const u8,
    /// `null` when the script ran to completion.
    script_error: ?EvalError,
    exit_status: u8,
    failure_description: []const u8,
};

const TestOptions = struct {
    gpa: Allocator = std.testing.allocator,
    script_arguments: []const []const u8 = &.{},
    stack_budget_bytes: usize = default_stack_budget_bytes,
};

/// Lexes, parses, resolves and runs `source_text`. Allocations other than
/// the interpreter's own go to `arena`.
fn runForTest(arena: Allocator, source_text: []const u8, options: TestOptions) !TestOutcome {
    var problems: diagnostics.Diagnostics = .init(arena);
    const tokens = try lexer.tokenize(arena, source_text, &problems);
    const script = try parser.parse(arena, tokens, &problems);
    if (!problems.hasErrors()) try resolve.resolve(arena, script, &problems);
    for (problems.items.items) |problem| std.debug.print("unexpected diagnostic: {s}\n", .{problem.message});
    try std.testing.expect(!problems.hasErrors());

    var environment: std.process.Environ.Map = .init(arena);
    try environment.put("PATH", "/usr/bin:/bin");
    try environment.put("GREETING", "hi");
    var shell_ctx: ShellCtx = undefined;
    shell_ctx.init(std.testing.io, &environment);
    var stdout: std.Io.Writer.Allocating = .init(arena);
    var stderr: std.Io.Writer.Allocating = .init(arena);

    var interpreter: Interpreter = undefined;
    interpreter.init(.{
        .gpa = options.gpa,
        .shell_ctx = &shell_ctx,
        .stdout = &stdout.writer,
        .stderr = &stderr.writer,
        .source = .{ .display_name = "test.bs", .text = source_text },
        .stack_budget_bytes = options.stack_budget_bytes,
    });
    defer interpreter.deinit();

    var outcome: TestOutcome = .{ .stdout = "", .stderr = "", .script_error = null, .exit_status = 0, .failure_description = "" };
    interpreter.runScript(script, options.script_arguments) catch |err| {
        outcome.script_error = err;
        outcome.exit_status = if (err == error.ScriptExit) interpreter.exit_status else interpreter.failure.exit_status;
        outcome.failure_description = try arena.dupe(u8, interpreter.failure.description());
    };
    outcome.stdout = stdout.written();
    outcome.stderr = stderr.written();
    return outcome;
}

fn expectOutput(source_text: []const u8, expected_stdout: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const outcome = try runForTest(arena.allocator(), source_text, .{});
    if (outcome.script_error) |err| std.debug.print("script failed: {s}\n{s}", .{ @errorName(err), outcome.stderr });
    try std.testing.expect(outcome.script_error == null);
    try std.testing.expectEqualStrings(expected_stdout, outcome.stdout);
}

test "bindings and interpolation" {
    try expectOutput("name = \"eth0\"\necho \"dev=$name\" dev=$name ${name}_x\n", "dev=eth0 dev=eth0 eth0_x\n");
}

test "functions return their last value" {
    try expectOutput("twice x = add x x\necho (twice 21)\n", "42\n");
}

test "match on builtin results" {
    try expectOutput("n = add 2 3\nmatch lt n 10 {\n  True -> echo small\n  False -> echo big\n}\n", "small\n");
}

test "blocks are values and bindings shadow" {
    try expectOutput("x = 1\ny = {\n  x = add x 1\n  x\n}\necho $x $y\n", "1 2\n");
}

test "tail recursion" {
    try expectOutput("count n = match lt n 100000 {\n  True -> count (add n 1)\n  False -> echo $n\n}\ncount 0\n", "100000\n");
}

test "user data types" {
    try expectOutput(
        "data Maybe a = Nothing | Just a\nshow m = match m {\n  Nothing -> echo none\n  Just (Just x) -> echo \"nested $x\"\n  Just x -> echo \"just $x\"\n}\nshow Nothing\nshow (Just 4)\nshow (Just (Just 5))\n",
        "none\njust 4\nnested 5\n",
    );
}

test "a constructor can be used before its declaration" {
    try expectOutput("x = Box [1, 2]\nmatch x { Box [a, b] -> echo $a $b }\ndata Box a = Box a\n", "1 2\n");
}

test "a Fail value is caught by an outer match" {
    try expectOutput(
        "check n = match eq n 0 {\n  True -> Fail 7\n  False -> Ok\n}\nmatch check 0 {\n  Ok -> echo ok\n  Fail code -> echo \"caught $code\"\n}\n",
        "caught 7\n",
    );
}

test "failure propagates through functions to a handler" {
    try expectOutput(
        "inner x = Fail 4\nouter x = {\n  inner x\n  echo unreachable\n}\nmatch outer 1 {\n  Ok -> echo ok\n  Fail code -> echo \"caught $code\"\n}\n",
        "caught 4\n",
    );
}

test "closures are passed down, including through tail calls" {
    try expectOutput(
        "apply f x = f x\napply (\\v -> echo $v) \"hi\"\nrun x = apply (\\v -> echo \"run $v\") x\nrun \"there\"\n",
        "hi\nrun there\n",
    );
}

test "script arguments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const outcome = try runForTest(arena.allocator(), "for $args \\a -> echo $a\n", .{ .script_arguments = &.{ "x", "y" } });
    try std.testing.expect(outcome.script_error == null);
    try std.testing.expectEqualStrings("x\ny\n", outcome.stdout);
}

test "an unhandled failure stops the script" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const outcome = try runForTest(arena.allocator(), "echo before\nFail 3\necho after\n", .{});
    try std.testing.expectEqual(@as(?EvalError, error.CommandFailed), outcome.script_error);
    try std.testing.expectEqual(@as(u8, 3), outcome.exit_status);
    try std.testing.expectEqualStrings("Fail 3", outcome.failure_description);
    try std.testing.expectEqualStrings("before\n", outcome.stdout);
}

test "runtime errors are reported and catchable" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const outcome = try runForTest(arena.allocator(), "match add 1 \"x\" {\n  Fail code -> echo \"caught $code\"\n  _ -> skip\n}\n", .{});
    try std.testing.expect(outcome.script_error == null);
    try std.testing.expectEqualStrings("caught 1\n", outcome.stdout);
    try std.testing.expect(std.mem.find(u8, outcome.stderr, "expected a number, got 'x'") != null);
}

test "exit ends the script" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const outcome = try runForTest(arena.allocator(), "echo a\nexit 4\necho b\n", .{});
    try std.testing.expectEqual(@as(?EvalError, error.ScriptExit), outcome.script_error);
    try std.testing.expectEqual(@as(u8, 4), outcome.exit_status);
    try std.testing.expectEqualStrings("a\n", outcome.stdout);
}

test "for stops at the first failure" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const outcome = try runForTest(arena.allocator(), "for [\"1\", \"2\", \"3\"] \\x -> match eq x 2 {\n  True -> Fail 9\n  False -> echo $x\n}\n", .{});
    try std.testing.expectEqual(@as(?EvalError, error.CommandFailed), outcome.script_error);
    try std.testing.expectEqual(@as(u8, 9), outcome.exit_status);
    try std.testing.expectEqualStrings("1\n", outcome.stdout);
}

test "lambdas cannot escape the call that made them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const outcome = try runForTest(arena.allocator(), "make x = \\y -> echo $y\nf = make 1\n", .{});
    try std.testing.expectEqual(@as(?EvalError, error.RuntimeError), outcome.script_error);
    try std.testing.expect(std.mem.find(u8, outcome.stderr, "a lambda cannot be returned from the function that created it") != null);
}

test "environment variables" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const outcome = try runForTest(arena.allocator(), "echo $GREETING\necho $MISSING\n", .{});
    try std.testing.expectEqualStrings("hi\n", outcome.stdout);
    try std.testing.expectEqual(@as(?EvalError, error.RuntimeError), outcome.script_error);
    try std.testing.expect(std.mem.find(u8, outcome.stderr, "environment variable 'MISSING' is not set") != null);
}

test "a match with no fitting arm is a runtime error" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const outcome = try runForTest(arena.allocator(), "match \"x\" {\n  \"y\" -> skip\n}\n", .{});
    try std.testing.expectEqual(@as(?EvalError, error.RuntimeError), outcome.script_error);
    try std.testing.expect(std.mem.find(u8, outcome.stderr, "no match arm fits a string") != null);
}

test "too-deep non-tail recursion is an error, not a crash" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const outcome = try runForTest(arena.allocator(), "deep n = {\n  deep (add n 1)\n  skip\n}\ndeep 0\n", .{ .stack_budget_bytes = 256 * 1024 });
    try std.testing.expectEqual(@as(?EvalError, error.RuntimeError), outcome.script_error);
    try std.testing.expect(std.mem.find(u8, outcome.stderr, "recursion too deep") != null);
}

/// Wraps an allocator and records the largest number of bytes live at once.
const PeakTrackingAllocator = struct {
    backing_allocator: Allocator,
    live_bytes: usize = 0,
    peak_live_bytes: usize = 0,

    fn allocator(tracking: *PeakTrackingAllocator) Allocator {
        return .{ .ptr = tracking, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn record(tracking: *PeakTrackingAllocator, old_length: usize, new_length: usize) void {
        tracking.live_bytes = tracking.live_bytes - old_length + new_length;
        tracking.peak_live_bytes = @max(tracking.peak_live_bytes, tracking.live_bytes);
    }

    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const tracking: *PeakTrackingAllocator = @ptrCast(@alignCast(context));
        const memory = tracking.backing_allocator.rawAlloc(length, alignment, return_address) orelse return null;
        tracking.record(0, length);
        return memory;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_length: usize, return_address: usize) bool {
        const tracking: *PeakTrackingAllocator = @ptrCast(@alignCast(context));
        if (!tracking.backing_allocator.rawResize(memory, alignment, new_length, return_address)) return false;
        tracking.record(memory.len, new_length);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_length: usize, return_address: usize) ?[*]u8 {
        const tracking: *PeakTrackingAllocator = @ptrCast(@alignCast(context));
        const remapped = tracking.backing_allocator.rawRemap(memory, alignment, new_length, return_address) orelse return null;
        tracking.record(memory.len, new_length);
        return remapped;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const tracking: *PeakTrackingAllocator = @ptrCast(@alignCast(context));
        tracking.backing_allocator.rawFree(memory, alignment, return_address);
        tracking.record(memory.len, 0);
    }
};

fn peakBytesForCount(arena: Allocator, iterations: u32) !usize {
    const source_text = try std.fmt.allocPrint(arena, "count n = match lt n {d} {{\n  True -> count (add n 1)\n  False -> skip\n}}\ncount 0\n", .{iterations});
    var tracking: PeakTrackingAllocator = .{ .backing_allocator = std.testing.allocator };
    const outcome = try runForTest(arena, source_text, .{ .gpa = tracking.allocator() });
    try std.testing.expect(outcome.script_error == null);
    return tracking.peak_live_bytes;
}

test "tail-recursive loops run in constant memory" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const small_peak = try peakBytesForCount(arena.allocator(), 1_000);
    const large_peak = try peakBytesForCount(arena.allocator(), 100_000);
    try std.testing.expect(large_peak <= small_peak + 16 * 1024);
}

test "external commands run and their failures can be caught" {
    try expectOutput("sh -c 'exit 0'\nmatch sh -c 'exit 5' {\n  Ok -> echo ok\n  Fail code -> echo \"status $code\"\n}\n", "status 5\n");
}

test "capture removes exactly one trailing newline" {
    try expectOutput("x = printf \"a\\n\\n\"\necho \"[$x]\"\ny = printf abc\necho $y\n", "[a\n]\nabc\n");
}

test "lists expand to one argument per element and are never split" {
    try expectOutput("items = [\"a b\", \"c\"]\nx = printf \"<%s>\" $items \"d e\"\necho $x\n", "<a b><c><d e>\n");
}

test "export reaches child processes" {
    try expectOutput("export FOO bar\nx = sh -c 'printf %s \"$FOO\"'\necho $x\n", "bar\n");
}

test "a command that is not found fails with 127" {
    try expectOutput("match definitely-not-a-command-xyz {\n  Fail code -> echo \"status $code\"\n  _ -> skip\n}\n", "status 127\n");
}

test "a failing capture propagates with the command line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const outcome = try runForTest(arena.allocator(), "x = sh -c 'printf partial; exit 2'\necho unreachable\n", .{});
    try std.testing.expectEqual(@as(?EvalError, error.CommandFailed), outcome.script_error);
    try std.testing.expectEqual(@as(u8, 2), outcome.exit_status);
    try std.testing.expectEqualStrings("sh -c printf partial; exit 2", outcome.failure_description);
    try std.testing.expectEqualStrings("", outcome.stdout);
}

test "a function body that is a quoted word returns the string" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const outcome = try runForTest(arena.allocator(), "f a = \"hello\"\necho (f 1)\n", .{});
    try std.testing.expectEqual(@as(?EvalError, null), outcome.script_error);
    try std.testing.expectEqualStrings("hello\n", outcome.stdout);
}
