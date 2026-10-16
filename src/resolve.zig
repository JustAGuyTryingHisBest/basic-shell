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

/// What the resolver knows about a constructor.
const ConstructorInfo = struct {
    arity: usize,
    /// One per field for a record, in declaration order; empty otherwise.
    field_names: []const []const u8 = &.{},
    is_record: bool = false,

    fn fieldIndex(info: ConstructorInfo, field_name: []const u8) ?usize {
        for (info.field_names, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate, field_name)) return index;
        }
        return null;
    }
};

const Resolver = struct {
    allocator: Allocator,
    diagnostics: *Diagnostics,
    /// Top-level definitions with parameters, visible everywhere.
    functions: std.StringHashMapUnmanaged(*ast.Definition) = .empty,
    /// Every constructor, built in or declared by `data`. Declarations are
    /// hoisted, so this is complete before any expression is resolved.
    constructors: std.StringHashMapUnmanaged(ConstructorInfo) = .empty,

    fn report(resolver: *Resolver, source_offset: u32, comptime format: []const u8, arguments: anytype) Allocator.Error!void {
        try resolver.diagnostics.add(source_offset, 1, format, arguments);
    }

    fn extend(resolver: *Resolver, parent: ?*const Scope, name: []const u8) Allocator.Error!*const Scope {
        const scope = try resolver.allocator.create(Scope);
        scope.* = .{ .parent = parent, .name = name };
        return scope;
    }

    fn resolveScript(resolver: *Resolver, script: *ast.Script) Allocator.Error!void {
        try resolver.collectConstructors(script.statements);

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
            .signature, .data_declaration => {},
            .expression => |expression| try resolver.resolveExpression(expression, scope, .statement),
            .definition => |definition| {
                const runs_as_function = definition.isFunction() or definition == script.main;
                try resolver.resolveDefinitionBody(definition, scope, runs_as_function);
                if (!runs_as_function) scope = try resolver.extend(scope, definition.name);
            },
        };
    }

    /// Registers the built-in constructors and those of every top-level
    /// `data` declaration, rejecting duplicate type and constructor names.
    fn collectConstructors(resolver: *Resolver, statements: []const ast.Statement) Allocator.Error!void {
        for (ast.builtin_constructors) |constructor| {
            try resolver.constructors.put(resolver.allocator, constructor.name, .{ .arity = constructor.arity });
        }
        var type_names: std.StringHashMapUnmanaged(void) = .empty;
        for (ast.builtin_type_names) |type_name| try type_names.put(resolver.allocator, type_name, {});
        for (statements) |statement| {
            const data_declaration = switch (statement) {
                .data_declaration => |data_declaration| data_declaration,
                else => continue,
            };
            if ((try type_names.getOrPut(resolver.allocator, data_declaration.name)).found_existing) {
                try resolver.report(data_declaration.source_offset, "type '{s}' is already defined", .{data_declaration.name});
            }
            for (data_declaration.type_parameters, 0..) |type_parameter, index| {
                for (data_declaration.type_parameters[0..index]) |earlier_type_parameter| {
                    if (std.mem.eql(u8, type_parameter, earlier_type_parameter)) {
                        try resolver.report(data_declaration.source_offset, "type variable '{s}' appears twice in '{s}'", .{ type_parameter, data_declaration.name });
                        break;
                    }
                }
            }
            for (data_declaration.constructors) |constructor| {
                const entry = try resolver.constructors.getOrPut(resolver.allocator, constructor.name);
                if (entry.found_existing) {
                    try resolver.report(constructor.source_offset, "constructor '{s}' is already defined", .{constructor.name});
                    continue;
                }
                entry.value_ptr.* = .{
                    .arity = constructor.field_types.len,
                    .field_names = constructor.field_names,
                    .is_record = constructor.is_record,
                };
                for (constructor.field_names, 0..) |field_name, index| {
                    for (constructor.field_names[0..index]) |earlier_field_name| {
                        if (std.mem.eql(u8, field_name, earlier_field_name)) {
                            try resolver.report(constructor.source_offset, "field '{s}' appears twice in '{s}'", .{ field_name, constructor.name });
                            break;
                        }
                    }
                }
            }
        }
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
            .data_declaration => |data_declaration| try resolver.report(data_declaration.source_offset, "data declarations are only allowed at the top level", .{}),
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
            .record => |record| try resolver.resolveRecord(expression, record, scope),
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
        if (!word.is_plain) return resolver.resolveQuotedWord(expression, word, scope);
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
                if (!isHeadSlot(slot) and !resolver.constructors.contains(text)) {
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

    fn resolveQuotedWord(resolver: *Resolver, expression: *ast.Expression, word: ast.Word, scope: ?*const Scope) Allocator.Error!void {
        if (word.parts.len == 1) {
            expression.data = switch (word.parts[0]) {
                .text => |text| .{ .literal_string = text },
                .variable => |name| .{ .variable = try resolver.dollarVariable(name, scope, expression.source_offset) },
            };
            return;
        }
        const parts = try resolver.allocator.alloc(ast.InterpolationPart, word.parts.len);
        for (parts, word.parts) |*part, word_part| {
            part.* = switch (word_part) {
                .text => |text| .{ .text = text },
                .variable => |name| .{ .variable = try resolver.dollarVariable(name, scope, expression.source_offset) },
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
            .constructor => {
                if (resolver.constructors.get(name)) |info| {
                    call.head_kind = .constructor;
                    call.field_names = info.field_names;
                } else {
                    call.head_kind = .external;
                }
            },
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
                const expected = resolver.constructors.get(call.name).?.arity;
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
        const scrutinee_slot: Slot = if (match.scrutinee_is_parenthesized) .value else .statement;
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
                if (resolver.constructors.get(constructor.name)) |info| {
                    const expected = info.arity;
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
            .record => |record| {
                var extended = scope;
                for (record.fields) |field| extended = try resolver.resolvePattern(field.pattern, extended);
                const info = try resolver.recordConstructor(pattern.source_offset, record.constructor_name) orelse return extended;
                // Fills the fields the record pattern does not name.
                const wildcard = try resolver.allocator.create(ast.Pattern);
                wildcard.* = .{ .source_offset = pattern.source_offset, .data = .wildcard };
                const field_patterns = try resolver.allocator.alloc(*ast.Pattern, info.arity);
                @memset(field_patterns, wildcard);
                var is_valid = true;
                for (record.fields, 0..) |field, index| {
                    const field_index = try resolver.namedFieldIndex(info, record.constructor_name, record.fields[0..index], field.name, field.source_offset) orelse {
                        is_valid = false;
                        continue;
                    };
                    field_patterns[field_index] = field.pattern;
                }
                if (is_valid) pattern.data = .{ .constructor = .{ .name = record.constructor_name, .fields = field_patterns } };
                return extended;
            },
            .list => |elements| {
                var extended = scope;
                for (elements) |element| extended = try resolver.resolvePattern(element, extended);
                return extended;
            },
        }
    }

    /// `Service { name = web; port = 80 }` becomes `Service web 80`, so the
    /// evaluator only sees positional constructor calls.
    fn resolveRecord(resolver: *Resolver, expression: *ast.Expression, record: ast.Record, scope: ?*const Scope) Allocator.Error!void {
        for (record.fields) |field| try resolver.resolveExpression(field.value, scope, .expression_argument);
        const info = try resolver.recordConstructor(expression.source_offset, record.constructor_name) orelse return;
        const arguments = try resolver.allocator.alloc(?*ast.Expression, info.arity);
        @memset(arguments, null);
        var is_valid = true;
        for (record.fields, 0..) |field, index| {
            const field_index = try resolver.namedFieldIndex(info, record.constructor_name, record.fields[0..index], field.name, field.source_offset) orelse {
                is_valid = false;
                continue;
            };
            arguments[field_index] = field.value;
        }
        const positional_arguments = try resolver.allocator.alloc(*ast.Expression, info.arity);
        for (arguments, positional_arguments, info.field_names) |argument, *positional_argument, field_name| {
            positional_argument.* = argument orelse {
                try resolver.report(expression.source_offset, "missing field '{s}' in '{s}'", .{ field_name, record.constructor_name });
                is_valid = false;
                continue;
            };
        }
        if (!is_valid) return;
        const head = try resolver.allocator.create(ast.Expression);
        head.* = .{ .source_offset = expression.source_offset, .data = .{ .literal_string = record.constructor_name } };
        expression.data = .{ .call = .{
            .head = head,
            .arguments = positional_arguments,
            .head_kind = .constructor,
            .name = record.constructor_name,
            .field_names = info.field_names,
        } };
    }

    /// The constructor named in a record expression or pattern, if it is one
    /// declared with fields.
    fn recordConstructor(resolver: *Resolver, source_offset: u32, constructor_name: []const u8) Allocator.Error!?ConstructorInfo {
        const info = resolver.constructors.get(constructor_name) orelse {
            try resolver.report(source_offset, "undefined constructor '{s}'", .{constructor_name});
            return null;
        };
        if (!info.is_record) {
            try resolver.report(source_offset, "'{s}' has no named fields", .{constructor_name});
            return null;
        }
        return info;
    }

    /// The position of `field_name` in a record, reporting unknown fields and
    /// fields already named in `earlier_fields`.
    fn namedFieldIndex(
        resolver: *Resolver,
        info: ConstructorInfo,
        constructor_name: []const u8,
        earlier_fields: anytype,
        field_name: []const u8,
        source_offset: u32,
    ) Allocator.Error!?usize {
        const field_index = info.fieldIndex(field_name) orelse {
            try resolver.report(source_offset, "'{s}' has no field '{s}'", .{ constructor_name, field_name });
            return null;
        };
        for (earlier_fields) |earlier_field| {
            if (std.mem.eql(u8, earlier_field.name, field_name)) {
                try resolver.report(source_offset, "field '{s}' is given twice", .{field_name});
                return null;
            }
        }
        return field_index;
    }

    /// `$name` or `${name.field}`. Only a bound variable can have fields.
    fn dollarVariable(resolver: *Resolver, text: []const u8, scope: ?*const Scope, source_offset: u32) Allocator.Error!ast.Variable {
        const name_end = std.mem.findScalar(u8, text, '.') orelse text.len;
        const name = text[0..name_end];
        const is_bound = isBound(scope, name);
        if (name_end == text.len) return .{ .name = name, .may_be_environment = !is_bound };
        if (!is_bound) try resolver.report(source_offset, "undefined variable '{s}'", .{name});
        var field_path: std.ArrayList([]const u8) = .empty;
        var segments = std.mem.splitScalar(u8, text[name_end + 1 ..], '.');
        while (segments.next()) |segment| try field_path.append(resolver.allocator, segment);
        return .{
            .name = name,
            .field_path = try field_path.toOwnedSlice(resolver.allocator),
            .may_be_environment = false,
        };
    }
};

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

test "user constructors" {
    try expectResolved(
        "show m = match m { Nothing -> echo none; Just x -> echo $x }\nshow (Just 3)\ndata Maybe a = Nothing | Just a",
        "(def show (m) (match $m (Nothing -> (builtin echo 'none')) ((Just x) -> (builtin echo $x))))\n(function show (constructor Just 3))\n(data Maybe a (Nothing) (Just a))\n",
    );
    try expectResolved("data T = A | B\nx = A\nf A", "(data T (A) (B))\n(def x () (constructor A))\n(external:status f 'A')\n");
}

test "records become positional" {
    try expectResolved(
        "data S = S { a :: Int; b :: String }\nx = S { b = \"hi\"; a = 1 }\nmatch x { S { b = v } -> echo ${x.a} $v }",
        "(data S (S { a :: Int; b :: String }))\n(def x () (constructor S 1 'hi'))\n(match $x ((S _ v) -> (builtin echo $x.a $v)))\n",
    );
}

test "record errors" {
    try expectResolveErrors("data S = S { a :: Int; a :: Int }", &.{"field 'a' appears twice in 'S'"});
    try expectResolveErrors("data S = S { a :: Int; b :: Int }\nx = S { a = 1 }", &.{"missing field 'b' in 'S'"});
    try expectResolveErrors("data S = S { a :: Int }\nx = S { a = 1; a = 2 }", &.{"field 'a' is given twice"});
    try expectResolveErrors("data S = S { a :: Int }\nx = S { c = 1; a = 2 }", &.{"'S' has no field 'c'"});
    try expectResolveErrors("data S = P Int\nx = P { a = 1 }", &.{"'P' has no named fields"});
    try expectResolveErrors("x = Q { a = 1 }", &.{"undefined constructor 'Q'"});
    try expectResolveErrors("data S = S { a :: Int }\nmatch S 1 { S { q = _ } -> skip }", &.{"'S' has no field 'q'"});
    try expectResolveErrors("echo ${HOME.x}", &.{"undefined variable 'HOME'"});
}

test "data declaration errors" {
    try expectResolveErrors("data T = A Int\nA", &.{"'A' takes 1 field, got 0"});
    try expectResolveErrors("data T = A\nmatch A { A x -> skip }", &.{"'A' takes 0 fields, got 1"});
    try expectResolveErrors("data T = A\ndata T = B", &.{"type 'T' is already defined"});
    try expectResolveErrors("data T = A | A", &.{"constructor 'A' is already defined"});
    try expectResolveErrors("data T = Ok", &.{"constructor 'Ok' is already defined"});
    try expectResolveErrors("data Bool = Yes | No", &.{"type 'Bool' is already defined"});
    try expectResolveErrors("data P a a = P a", &.{"type variable 'a' appears twice in 'P'"});
    try expectResolveErrors("f x = {\n  data T = A\n  skip\n}", &.{"data declarations are only allowed at the top level"});
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
