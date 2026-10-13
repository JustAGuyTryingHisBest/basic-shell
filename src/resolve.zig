//! Name resolution (spec §5.3–§5.5, §7.3): decides what every word means,
//! classifies call heads, and marks capture and tail positions. After it
//! succeeds, the tree has no `.word` nodes and no unresolved calls.
const std = @import("std");

const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

const Allocator = std.mem.Allocator;

/// Resolves `script` in place. Errors are added to `diagnostics`.
pub fn resolve(allocator: Allocator, script: *ast.Script, diagnostics: *Diagnostics) Allocator.Error!void {
    var resolver: Resolver = .{ .allocator = allocator, .diagnostics = diagnostics };
    try resolver.resolveScript(script);
}

/// Names in lexical scope, innermost first. Each binding is its own node,
/// so extending a scope never changes the scopes it extends.
const Scope = struct {
    parent: ?*const Scope,
    name: []const u8,
};

fn isBound(scope: ?*const Scope, name: []const u8) bool {
    var current = scope;
    while (current) |node| : (current = node.parent) {
        if (std.mem.eql(u8, node.name, name)) return true;
    }
    return false;
}

/// Where an expression appears. It decides what a lone word means and
/// whether an external program's output is captured.
const Slot = enum {
    /// A statement, a bare `match` scrutinee, or a function or lambda body:
    /// a lone word is a command; external calls produce a status.
    statement,
    /// A right-hand side, a parenthesised expression or a match arm in a
    /// value: a lone word is a command; external calls capture output.
    value,
    /// A direct argument of an external program or a command builtin.
    command_argument,
    /// Any other argument, or a list element.
    expression_argument,
};

fn isHeadSlot(slot: Slot) bool {
    return slot == .statement or slot == .value;
}

fn plural(count: usize) []const u8 {
    return if (count == 1) "" else "s";
}

const Resolver = struct {
    allocator: Allocator,
    diagnostics: *Diagnostics,
    /// Top-level definitions with parameters, visible everywhere.
    functions: std.StringHashMapUnmanaged(*ast.Definition) = .empty,

    fn report(resolver: *Resolver, source_offset: u32, comptime format: []const u8, arguments: anytype) Allocator.Error!void {
        try resolver.diagnostics.add(source_offset, 1, format, arguments);
    }

    fn extend(resolver: *Resolver, parent: ?*const Scope, name: []const u8) Allocator.Error!*const Scope {
        const scope = try resolver.allocator.create(Scope);
        scope.* = .{ .parent = parent, .name = name };
        return scope;
    }

    fn resolveScript(resolver: *Resolver, script: *ast.Script) Allocator.Error!void {
        // Hoist functions, find `main`, and reject duplicate top-level names.
        var top_level_names: std.StringHashMapUnmanaged(void) = .empty;
        for (script.statements) |statement| {
            const definition = switch (statement) {
                .definition => |definition| definition,
                else => continue,
            };
            const entry = try top_level_names.getOrPut(resolver.allocator, definition.name);
            if (entry.found_existing) {
                try resolver.report(definition.source_offset, "'{s}' is already defined", .{definition.name});
                continue;
            }
            if (std.mem.eql(u8, definition.name, "main")) {
                script.main = definition;
            } else if (definition.isFunction()) {
                try resolver.functions.put(resolver.allocator, definition.name, definition);
            }
        }
        if (script.main != null) {
            for (script.statements) |statement| {
                if (statement == .expression) {
                    try resolver.report(statement.expression.source_offset, "statements outside definitions are not allowed when 'main' is defined", .{});
                }
            }
        }

        var scope: ?*const Scope = try resolver.extend(null, "args");
        for (script.statements) |statement| switch (statement) {
            .signature => {},
            .expression => |expression| try resolver.resolveExpression(expression, scope, .statement),
            .definition => |definition| {
                const runs_as_function = definition.isFunction() or definition == script.main;
                try resolver.resolveDefinitionBody(definition, scope, runs_as_function);
                if (!runs_as_function) scope = try resolver.extend(scope, definition.name);
            },
        };
    }

    fn resolveDefinitionBody(resolver: *Resolver, definition: *ast.Definition, scope: ?*const Scope, runs_as_function: bool) Allocator.Error!void {
        if (!runs_as_function) return resolver.resolveExpression(definition.body, scope, .value);
        var body_scope = scope;
        for (definition.parameters) |parameter| {
            if (parameter.name) |name| body_scope = try resolver.extend(body_scope, name);
        }
        try resolver.resolveExpression(definition.body, body_scope, .statement);
        markTail(definition.body);
    }

    fn resolveBlock(resolver: *Resolver, statements: []const ast.Statement, scope: ?*const Scope) Allocator.Error!void {
        var block_scope = scope;
        for (statements) |statement| switch (statement) {
            .signature => |signature| try resolver.report(signature.source_offset, "type signatures are only allowed at the top level", .{}),
            .expression => |expression| try resolver.resolveExpression(expression, block_scope, .statement),
            .definition => |definition| {
                if (definition.isFunction()) {
                    try resolver.report(definition.source_offset, "local functions are not supported yet; use a lambda or a top-level definition", .{});
                    continue;
                }
                try resolver.resolveExpression(definition.body, block_scope, .value);
                block_scope = try resolver.extend(block_scope, definition.name);
            },
        };
    }

    fn resolveExpression(resolver: *Resolver, expression: *ast.Expression, scope: ?*const Scope, slot: Slot) Allocator.Error!void {
        switch (expression.data) {
            .word => |word| try resolver.resolveWord(expression, word, scope, slot),
            .list => |elements| for (elements) |element| {
                try resolver.resolveExpression(element, scope, .expression_argument);
            },
            .call => try resolver.resolveCall(expression, scope, slot),
            .block => |statements| try resolver.resolveBlock(statements, scope),
            .match => |match| try resolver.resolveMatch(match, scope, slot),
            .lambda => |lambda| {
                var body_scope = scope;
                for (lambda.parameters) |parameter| {
                    if (parameter.name) |name| body_scope = try resolver.extend(body_scope, name);
                }
                try resolver.resolveExpression(lambda.body, body_scope, .statement);
                markTail(lambda.body);
            },
            .literal_string, .literal_integer, .interpolated, .variable, .function_reference => {},
        }
    }

    fn resolveWord(resolver: *Resolver, expression: *ast.Expression, word: ast.Word, scope: ?*const Scope, slot: Slot) Allocator.Error!void {
        if (!word.is_plain) {
            // A lone quoted word as a statement runs as a command, like
            // `resolveHead` treats a quoted head with arguments.
            if (slot == .statement and !containsVariable(word)) return resolver.resolveLoneWordAsCall(expression, scope, slot);
            return resolver.resolveQuotedWord(expression, word, scope);
        }
        const text = word.parts[0].text;
        if (slot == .command_argument) {
            expression.data = .{ .literal_string = text };
            return;
        }
        switch (lexer.classifyPlainWord(text)) {
            .integer => {
                const integer = std.fmt.parseInt(i64, text, 10) catch
                    return resolver.report(expression.source_offset, "integer {s} is out of range", .{text});
                expression.data = .{ .literal_integer = integer };
            },
            .literal => {
                if (isHeadSlot(slot)) return resolver.resolveLoneWordAsCall(expression, scope, slot);
                expression.data = .{ .literal_string = text };
            },
            .constructor => {
                if (!isHeadSlot(slot) and ast.constructorArity(text) == null) {
                    return resolver.report(expression.source_offset, "undefined constructor '{s}'", .{text});
                }
                try resolver.resolveLoneWordAsCall(expression, scope, if (isHeadSlot(slot)) slot else .value);
            },
            .identifier => {
                if (isHeadSlot(slot)) return resolver.resolveLoneWordAsCall(expression, scope, slot);
                try resolver.resolveNameArgument(expression, text, scope);
            },
        }
    }

    /// A lone word where a command may stand (`reboot`, `today = date`,
    /// `x = name`) is a call with no arguments; `resolveCall` turns it back
    /// into a variable when the name is bound.
    fn resolveLoneWordAsCall(resolver: *Resolver, expression: *ast.Expression, scope: ?*const Scope, slot: Slot) Allocator.Error!void {
        const head = try resolver.allocator.create(ast.Expression);
        head.* = expression.*;
        expression.data = .{ .call = .{ .head = head, .arguments = &.{} } };
        try resolver.resolveCall(expression, scope, slot);
    }

    fn resolveNameArgument(resolver: *Resolver, expression: *ast.Expression, name: []const u8, scope: ?*const Scope) Allocator.Error!void {
        if (isBound(scope, name)) {
            expression.data = .{ .variable = .{ .name = name, .may_be_environment = false } };
        } else if (resolver.functions.get(name)) |definition| {
            expression.data = .{ .function_reference = definition };
        } else if (ast.Builtin.fromName(name) != null) {
            try resolver.report(expression.source_offset, "builtin '{s}' cannot be used as a value", .{name});
        } else {
            try resolver.report(expression.source_offset, "undefined variable '{s}'", .{name});
        }
    }

    fn containsVariable(word: ast.Word) bool {
        for (word.parts) |part| switch (part) {
            .variable => return true,
            .text => {},
        };
        return false;
    }

    fn resolveQuotedWord(resolver: *Resolver, expression: *ast.Expression, word: ast.Word, scope: ?*const Scope) Allocator.Error!void {
        if (word.parts.len == 1) {
            expression.data = switch (word.parts[0]) {
                .text => |text| .{ .literal_string = text },
                .variable => |name| .{ .variable = dollarVariable(name, scope) },
            };
            return;
        }
        const parts = try resolver.allocator.alloc(ast.InterpolationPart, word.parts.len);
        for (parts, word.parts) |*part, word_part| {
            part.* = switch (word_part) {
                .text => |text| .{ .text = text },
                .variable => |name| .{ .variable = dollarVariable(name, scope) },
            };
        }
        expression.data = .{ .interpolated = parts };
    }

    fn resolveCall(resolver: *Resolver, expression: *ast.Expression, scope: ?*const Scope, slot: Slot) Allocator.Error!void {
        const call = &expression.data.call;
        call.context = if (slot == .statement) .status else .capture;
        try resolver.resolveHead(call, scope);
        if (call.head_kind == .unresolved) return;
        const argument_slot: Slot = switch (call.head_kind) {
            .external => .command_argument,
            .builtin => if (call.builtin.?.isCommand()) .command_argument else .expression_argument,
            else => .expression_argument,
        };
        for (call.arguments) |argument| {
            // Non-word arguments are parenthesised expressions or lists.
            const effective_slot: Slot = if (argument.data == .word) argument_slot else switch (argument.data) {
                .list => argument_slot,
                else => .value,
            };
            try resolver.resolveExpression(argument, scope, effective_slot);
        }
        try resolver.checkArity(call.*, expression.source_offset);
        if (call.arguments.len == 0 and call.head_kind == .closure and call.head.data == .variable) {
            expression.data = call.head.data;
        }
    }

    fn resolveHead(resolver: *Resolver, call: *ast.Call, scope: ?*const Scope) Allocator.Error!void {
        const head = call.head;
        if (head.data != .word) {
            try resolver.resolveExpression(head, scope, .value);
            call.head_kind = .closure;
            return;
        }
        const word = head.data.word;
        if (!word.is_plain) {
            var name: std.ArrayList(u8) = .empty;
            for (word.parts) |part| switch (part) {
                .text => |text| try name.appendSlice(resolver.allocator, text),
                .variable => return resolver.report(head.source_offset, "a command name cannot contain variables (not supported yet)", .{}),
            };
            call.head_kind = .external;
            call.name = try name.toOwnedSlice(resolver.allocator);
            return;
        }
        const name = word.parts[0].text;
        call.name = name;
        switch (lexer.classifyPlainWord(name)) {
            .identifier => {
                if (isBound(scope, name)) {
                    head.data = .{ .variable = .{ .name = name, .may_be_environment = false } };
                    call.head_kind = .closure;
                } else if (resolver.functions.get(name)) |definition| {
                    call.head_kind = .function;
                    call.function = definition;
                } else if (ast.Builtin.fromName(name)) |builtin| {
                    call.head_kind = .builtin;
                    call.builtin = builtin;
                } else {
                    call.head_kind = .external;
                }
            },
            .constructor => call.head_kind = if (ast.constructorArity(name) != null) .constructor else .external,
            .integer, .literal => call.head_kind = .external,
        }
    }

    fn checkArity(resolver: *Resolver, call: ast.Call, source_offset: u32) Allocator.Error!void {
        const argument_count = call.arguments.len;
        switch (call.head_kind) {
            .function => {
                const expected = call.function.?.parameters.len;
                if (argument_count != expected) {
                    try resolver.report(source_offset, "'{s}' takes {d} argument{s}, got {d}", .{ call.name, expected, plural(expected), argument_count });
                }
            },
            .constructor => {
                const expected = ast.constructorArity(call.name).?;
                if (argument_count != expected) {
                    try resolver.report(source_offset, "'{s}' takes {d} field{s}, got {d}", .{ call.name, expected, plural(expected), argument_count });
                }
            },
            .builtin => {
                const allowed = call.builtin.?.argumentCount();
                if (argument_count < allowed.minimum or argument_count > allowed.maximum) {
                    if (allowed.minimum == allowed.maximum) {
                        try resolver.report(source_offset, "'{s}' takes {d} argument{s}, got {d}", .{ call.name, allowed.minimum, plural(allowed.minimum), argument_count });
                    } else {
                        try resolver.report(source_offset, "'{s}' takes {d} to {d} arguments, got {d}", .{ call.name, allowed.minimum, allowed.maximum, argument_count });
                    }
                }
            },
            .unresolved, .closure, .external => {},
        }
    }

    fn resolveMatch(resolver: *Resolver, match: ast.Match, scope: ?*const Scope, slot: Slot) Allocator.Error!void {
        // A quoted word scrutinee is a string to match on, not a command.
        const scrutinee_is_quoted_word = match.scrutinee.data == .word and !match.scrutinee.data.word.is_plain;
        const scrutinee_slot: Slot = if (match.scrutinee_is_parenthesized or scrutinee_is_quoted_word) .value else .statement;
        try resolver.resolveExpression(match.scrutinee, scope, scrutinee_slot);
        const arm_slot: Slot = if (slot == .statement) .statement else .value;
        for (match.arms) |arm| {
            const arm_scope = try resolver.resolvePattern(arm.pattern, scope);
            try resolver.resolveExpression(arm.body, arm_scope, arm_slot);
        }
    }

    /// Checks constructors in `pattern` and returns `scope` extended with its binders.
    fn resolvePattern(resolver: *Resolver, pattern: *ast.Pattern, scope: ?*const Scope) Allocator.Error!?*const Scope {
        switch (pattern.data) {
            .wildcard, .literal_string, .literal_integer => return scope,
            .binder => |name| return try resolver.extend(scope, name),
            .constructor => |constructor| {
                if (ast.constructorArity(constructor.name)) |expected| {
                    if (expected != constructor.fields.len) {
                        try resolver.report(pattern.source_offset, "'{s}' takes {d} field{s}, got {d}", .{ constructor.name, expected, plural(expected), constructor.fields.len });
                    }
                } else {
                    try resolver.report(pattern.source_offset, "undefined constructor '{s}'", .{constructor.name});
                }
                var extended = scope;
                for (constructor.fields) |field| extended = try resolver.resolvePattern(field, extended);
                return extended;
            },
            .list => |elements| {
                var extended = scope;
                for (elements) |element| extended = try resolver.resolvePattern(element, extended);
                return extended;
            },
        }
    }
};

fn dollarVariable(name: []const u8, scope: ?*const Scope) ast.Variable {
    return .{ .name = name, .may_be_environment = !isBound(scope, name) };
}

/// Marks the calls in tail position of a function or lambda body, so the
/// evaluator runs them without growing the stack (spec §8.4).
fn markTail(expression: *ast.Expression) void {
    switch (expression.data) {
        .call => |*call| {
            if (call.head_kind == .function or call.head_kind == .closure) call.is_tail = true;
        },
        .block => |statements| {
            if (statements.len == 0) return;
            switch (statements[statements.len - 1]) {
                .expression => |last| markTail(last),
                else => {},
            }
        },
        .match => |match| for (match.arms) |arm| markTail(arm.body),
        else => {},
    }
}

fn resolveSource(allocator: Allocator, source_text: []const u8, collected: *Diagnostics) !*ast.Script {
    const tokens = try lexer.tokenize(allocator, source_text, collected);
    const script = try parser.parse(allocator, tokens, collected);
    try std.testing.expect(!collected.hasErrors());
    try resolve(allocator, script, collected);
    return script;
}

fn expectResolved(source_text: []const u8, expected_dump: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var collected: Diagnostics = .init(allocator);
    const script = try resolveSource(allocator, source_text, &collected);
    for (collected.items.items) |problem| std.debug.print("unexpected diagnostic: {s}\n", .{problem.message});
    try std.testing.expect(!collected.hasErrors());
    var output: std.Io.Writer.Allocating = .init(allocator);
    try ast.dumpScript(&output.writer, script);
    try std.testing.expectEqualStrings(expected_dump, output.written());
}

fn expectResolveErrors(source_text: []const u8, expected_messages: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var collected: Diagnostics = .init(arena.allocator());
    _ = try resolveSource(arena.allocator(), source_text, &collected);
    try std.testing.expectEqual(expected_messages.len, collected.items.items.len);
    for (expected_messages, collected.items.items) |expected_message, problem| {
        try std.testing.expectEqualStrings(expected_message, problem.message);
    }
}

test "external commands take literal words" {
    try expectResolved("ip link set dev $name up", "(external:status ip 'link' 'set' 'dev' $name? 'up')\n");
    try expectResolved(
        "up name = ip link set dev $name up\nup \"eth0\"",
        "(def up (name) (external:status ip 'link' 'set' 'dev' $name 'up'))\n(function up 'eth0')\n",
    );
}

test "value positions capture; arguments are expressions" {
    try expectResolved("arch = uname -m", "(def arch () (external:capture uname '-m'))\n");
    try expectResolved("f a n = add n 1\nf 192.168.1.1 0", "(def f (a n) (builtin add $n 1))\n(function f '192.168.1.1' 0)\n");
}

test "keywords and the wildcard are literals in command arguments" {
    try expectResolved("git checkout main", "(external:status git 'checkout' 'main')\n");
    try expectResolved("echo data match _", "(builtin echo 'data' 'match' '_')\n");
}

test "a lone quoted word is a command only as a statement" {
    try expectResolved("'/opt/my tool'", "(external:status /opt/my tool)\n");
    try expectResolved("x = \"eth0\"", "(def x () 'eth0')\n");
}

test "lone words" {
    try expectResolved(
        "reboot\nskip\ntoday = date\nx = 5\ny = x",
        "(external:status reboot)\n(builtin skip)\n(def today () (external:capture date))\n(def x () 5)\n(def y () $x)\n",
    );
}

test "tail calls are marked" {
    try expectResolved(
        "loop n = match lt n 10 {\n  True -> loop (add n 1)\n  False -> skip\n}",
        "(def loop (n) (match (builtin lt $n 10) (True -> (function:tail loop (builtin add $n 1))) (False -> (builtin skip))))\n",
    );
    try expectResolved(
        "apply f x = f x\nshow v = echo $v\napply show \"hi\"",
        "(def apply (f x) (closure:tail $f $x))\n(def show (v) (builtin echo $v))\n(function apply &show 'hi')\n",
    );
}

test "lambdas and nested captures" {
    try expectResolved(
        "for (lines (ls)) \\x -> echo $x",
        "(builtin for (builtin lines (external:capture ls)) (\\ x -> (builtin echo $x)))\n",
    );
}

test "match scrutinees" {
    try expectResolved(
        "match ping h { Ok -> skip; Fail c -> echo $c }",
        "(match (external:status ping 'h') (Ok -> (builtin skip)) ((Fail c) -> (builtin echo $c)))\n",
    );
    try expectResolved(
        "match (uname -m) { _ -> skip }",
        "(match (paren (external:capture uname '-m')) (_ -> (builtin skip)))\n",
    );
}

test "interpolation and environment variables" {
    try expectResolved(
        "name = \"eth0\"\necho \"eth $name\" $HOME",
        "(def name () 'eth0')\n(builtin echo (interp 'eth ' $name) $HOME?)\n",
    );
}

test "resolve errors" {
    try expectResolveErrors("add x 1", &.{"undefined variable 'x'"});
    try expectResolveErrors("f a = skip\nf", &.{"'f' takes 1 argument, got 0"});
    try expectResolveErrors("a = 1\na = 2", &.{"'a' is already defined"});
    try expectResolveErrors("main = skip\necho hi", &.{"statements outside definitions are not allowed when 'main' is defined"});
    try expectResolveErrors("f x = {\n  g y = skip\n  skip\n}", &.{"local functions are not supported yet; use a lambda or a top-level definition"});
    try expectResolveErrors("match x { Just y -> skip }", &.{"undefined constructor 'Just'"});
    try expectResolveErrors("add _ 1", &.{"undefined variable '_'"});
    try expectResolveErrors("Fail", &.{"'Fail' takes 1 field, got 0"});
    try expectResolveErrors("exit 1 2", &.{"'exit' takes 0 to 1 arguments, got 2"});
    try expectResolveErrors("\"$cmd\" x", &.{"a command name cannot contain variables (not supported yet)"});
    try expectResolveErrors("f x = add later 1\nlater = 1", &.{"undefined variable 'later'"});
}
