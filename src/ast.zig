//! Syntax tree for bs (spec §7.3). The parser builds it with every word
//! unclassified; `resolve.zig` then rewrites `.word` nodes and fills in call
//! metadata in place, so the evaluator never decides what a word means.
const std = @import("std");

const lexer = @import("lexer.zig");

/// A whole parsed script.
pub const Script = struct {
    statements: []const Statement,
    /// Set by `resolve`.
    main: ?*Definition = null,
};

/// One statement of a script or block.
pub const Statement = union(enum) {
    definition: *Definition,
    signature: *Signature,
    expression: *Expression,
};

/// A named value (no parameters) or function (with parameters).
pub const Definition = struct {
    source_offset: u32,
    name: []const u8,
    parameters: []const Parameter,
    body: *Expression,

    /// A definition with parameters is a function; without, it binds a value.
    pub fn isFunction(definition: Definition) bool {
        return definition.parameters.len != 0;
    }
};

/// A parameter of a definition or lambda.
pub const Parameter = struct {
    source_offset: u32,
    /// `null` for `_`.
    name: ?[]const u8,
};

/// A type signature `name :: Type`.
pub const Signature = struct {
    source_offset: u32,
    name: []const u8,
    type_expression: *TypeExpression,
};

/// Parsed but not yet checked (spec §6).
pub const TypeExpression = union(enum) {
    named: []const u8,
    list: *TypeExpression,
    application: struct { head: *TypeExpression, arguments: []const *TypeExpression },
    function: struct { parameter: *TypeExpression, result: *TypeExpression },
};

/// A shell word as the lexer produced it, before `resolve`.
pub const Word = struct {
    parts: []const lexer.WordPart,
    is_plain: bool,
    source_length: u32,
};

/// An expression node with its source position.
pub const Expression = struct {
    source_offset: u32,
    data: Data,

    /// The kinds of expression.
    pub const Data = union(enum) {
        /// Only before `resolve`.
        word: Word,
        literal_string: []const u8,
        literal_integer: i64,
        interpolated: []const InterpolationPart,
        variable: Variable,
        /// A top-level function used as a value, e.g. `for names up`.
        function_reference: *Definition,
        list: []const *Expression,
        call: Call,
        block: []const Statement,
        match: Match,
        lambda: Lambda,
    };
};

/// A piece of an interpolated string.
pub const InterpolationPart = union(enum) {
    text: []const u8,
    variable: Variable,
};

/// A `$name` reference.
pub const Variable = struct {
    name: []const u8,
    /// True for a `$name` that is not bound in the script: it is then read
    /// from the environment at runtime (spec §5.9).
    may_be_environment: bool,
};

/// An application of a head to arguments, plus metadata filled in by `resolve`.
pub const Call = struct {
    head: *Expression,
    arguments: []const *Expression,
    head_kind: HeadKind = .unresolved,
    /// For `.function`.
    function: ?*Definition = null,
    /// For `.builtin`.
    builtin: ?Builtin = null,
    /// The program, function or constructor name.
    name: []const u8 = "",
    /// For `.external` (spec §5.5).
    context: Context = .status,
    /// In tail position of a function or lambda body (spec §8.4).
    is_tail: bool = false,
};

/// What the head of a call turned out to be.
pub const HeadKind = enum { unresolved, closure, function, builtin, constructor, external };

/// How an external command's output is used.
pub const Context = enum {
    /// Run with inherited stdout; produces `Ok` or a failure.
    status,
    /// Capture stdout as a `String`.
    capture,
};

/// A `match` expression.
pub const Match = struct {
    scrutinee: *Expression,
    /// `match (cmd) { ... }` captures; `match cmd { ... }` gives a status.
    scrutinee_is_parenthesized: bool,
    arms: []const Arm,
};

/// One `pattern -> body` arm of a match.
pub const Arm = struct {
    pattern: *Pattern,
    body: *Expression,
};

/// An anonymous function `\\x -> body`.
pub const Lambda = struct {
    parameters: []const Parameter,
    body: *Expression,
};

/// A pattern with its source position.
pub const Pattern = struct {
    source_offset: u32,
    data: Data,

    /// The kinds of pattern.
    pub const Data = union(enum) {
        wildcard,
        binder: []const u8,
        literal_string: []const u8,
        literal_integer: i64,
        constructor: ConstructorPattern,
        list: []const *Pattern,
    };
};

/// A constructor pattern such as `Fail code`.
pub const ConstructorPattern = struct {
    name: []const u8,
    fields: []const *Pattern,
};

/// Builtin commands and functions (spec §5.4).
pub const Builtin = enum {
    echo,
    skip,
    exit,
    cd,
    @"export",
    @"for",
    lines,
    words,
    add,
    sub,
    eq,
    lt,

    /// The builtin called `name`, if any.
    pub fn fromName(name: []const u8) ?Builtin {
        return std.meta.stringToEnum(Builtin, name);
    }

    /// Command builtins read their arguments as shell words, like an
    /// external program (spec §5.4).
    pub fn isCommand(builtin: Builtin) bool {
        return switch (builtin) {
            .echo, .skip, .exit, .cd, .@"export" => true,
            else => false,
        };
    }

    /// Inclusive bounds on a builtin's argument count.
    pub const ArgumentCount = struct { minimum: usize, maximum: usize };

    /// How many arguments the builtin accepts.
    pub fn argumentCount(builtin: Builtin) ArgumentCount {
        return switch (builtin) {
            .echo => .{ .minimum = 0, .maximum = std.math.maxInt(usize) },
            .skip => .{ .minimum = 0, .maximum = 0 },
            .exit => .{ .minimum = 0, .maximum = 1 },
            .cd, .lines, .words => .{ .minimum = 1, .maximum = 1 },
            .@"export", .@"for", .add, .sub, .eq, .lt => .{ .minimum = 2, .maximum = 2 },
        };
    }
};

/// Number of fields of a constructor every script can use (spec §5.2):
/// `data Status = Ok | Fail Int` and `data Bool = False | True`.
pub fn constructorArity(name: []const u8) ?usize {
    const arities = std.StaticStringMap(usize).initComptime(.{
        .{ "Ok", 0 },
        .{ "Fail", 1 },
        .{ "True", 0 },
        .{ "False", 0 },
    });
    return arities.get(name);
}

/// Writes one S-expression line per top-level statement; used by tests.
pub fn dumpScript(writer: *std.Io.Writer, script: *const Script) std.Io.Writer.Error!void {
    for (script.statements) |statement| {
        try dumpStatement(writer, statement);
        try writer.writeByte('\n');
    }
}

/// Writes one statement as an S-expression.
pub fn dumpStatement(writer: *std.Io.Writer, statement: Statement) std.Io.Writer.Error!void {
    switch (statement) {
        .definition => |definition| {
            try writer.print("(def {s} (", .{definition.name});
            try dumpParameters(writer, definition.parameters);
            try writer.writeAll(") ");
            try dumpExpression(writer, definition.body);
            try writer.writeByte(')');
        },
        .signature => |signature| {
            try writer.print("(sig {s} ", .{signature.name});
            try dumpType(writer, signature.type_expression);
            try writer.writeByte(')');
        },
        .expression => |expression| try dumpExpression(writer, expression),
    }
}

fn dumpParameters(writer: *std.Io.Writer, parameters: []const Parameter) std.Io.Writer.Error!void {
    for (parameters, 0..) |parameter, index| {
        if (index != 0) try writer.writeByte(' ');
        try writer.writeAll(parameter.name orelse "_");
    }
}

/// Writes one expression as an S-expression.
pub fn dumpExpression(writer: *std.Io.Writer, expression: *const Expression) std.Io.Writer.Error!void {
    switch (expression.data) {
        .word => |word| try lexer.writeWord(writer, word.parts, word.is_plain),
        .literal_string => |text| try writer.print("'{s}'", .{text}),
        .literal_integer => |integer| try writer.print("{d}", .{integer}),
        .interpolated => |parts| {
            try writer.writeAll("(interp");
            for (parts) |part| switch (part) {
                .text => |text| try writer.print(" '{s}'", .{text}),
                .variable => |variable| {
                    try writer.writeByte(' ');
                    try dumpVariable(writer, variable);
                },
            };
            try writer.writeByte(')');
        },
        .variable => |variable| try dumpVariable(writer, variable),
        .function_reference => |definition| try writer.print("&{s}", .{definition.name}),
        .list => |elements| {
            try writer.writeByte('[');
            for (elements, 0..) |element, index| {
                if (index != 0) try writer.writeByte(' ');
                try dumpExpression(writer, element);
            }
            try writer.writeByte(']');
        },
        .call => |call| try dumpCall(writer, call),
        .block => |statements| {
            try writer.writeAll("(block");
            for (statements) |statement| {
                try writer.writeByte(' ');
                try dumpStatement(writer, statement);
            }
            try writer.writeByte(')');
        },
        .match => |match| {
            try writer.writeAll("(match ");
            if (match.scrutinee_is_parenthesized) {
                try writer.writeAll("(paren ");
                try dumpExpression(writer, match.scrutinee);
                try writer.writeByte(')');
            } else {
                try dumpExpression(writer, match.scrutinee);
            }
            for (match.arms) |arm| {
                try writer.writeAll(" (");
                try dumpPattern(writer, arm.pattern);
                try writer.writeAll(" -> ");
                try dumpExpression(writer, arm.body);
                try writer.writeByte(')');
            }
            try writer.writeByte(')');
        },
        .lambda => |lambda| {
            try writer.writeAll("(\\ ");
            try dumpParameters(writer, lambda.parameters);
            try writer.writeAll(" -> ");
            try dumpExpression(writer, lambda.body);
            try writer.writeByte(')');
        },
    }
}

fn dumpVariable(writer: *std.Io.Writer, variable: Variable) std.Io.Writer.Error!void {
    try writer.print("${s}{s}", .{ variable.name, if (variable.may_be_environment) "?" else "" });
}

fn dumpCall(writer: *std.Io.Writer, call: Call) std.Io.Writer.Error!void {
    if (call.head_kind == .unresolved) {
        try writer.writeAll("(call ");
        try dumpExpression(writer, call.head);
    } else {
        try writer.print("({s}", .{@tagName(call.head_kind)});
        if (call.head_kind == .external) try writer.print(":{s}", .{@tagName(call.context)});
        if (call.is_tail) try writer.writeAll(":tail");
        try writer.writeByte(' ');
        switch (call.head_kind) {
            .closure => try dumpExpression(writer, call.head),
            .builtin => try writer.writeAll(@tagName(call.builtin.?)),
            else => try writer.writeAll(call.name),
        }
    }
    for (call.arguments) |argument| {
        try writer.writeByte(' ');
        try dumpExpression(writer, argument);
    }
    try writer.writeByte(')');
}

fn dumpPattern(writer: *std.Io.Writer, pattern: *const Pattern) std.Io.Writer.Error!void {
    switch (pattern.data) {
        .wildcard => try writer.writeByte('_'),
        .binder => |name| try writer.writeAll(name),
        .literal_string => |text| try writer.print("'{s}'", .{text}),
        .literal_integer => |integer| try writer.print("{d}", .{integer}),
        .constructor => |constructor| {
            if (constructor.fields.len == 0) return writer.writeAll(constructor.name);
            try writer.print("({s}", .{constructor.name});
            for (constructor.fields) |field| {
                try writer.writeByte(' ');
                try dumpPattern(writer, field);
            }
            try writer.writeByte(')');
        },
        .list => |elements| {
            try writer.writeByte('[');
            for (elements, 0..) |element, index| {
                if (index != 0) try writer.writeByte(' ');
                try dumpPattern(writer, element);
            }
            try writer.writeByte(']');
        },
    }
}

fn dumpType(writer: *std.Io.Writer, type_expression: *const TypeExpression) std.Io.Writer.Error!void {
    switch (type_expression.*) {
        .named => |name| try writer.writeAll(name),
        .list => |element| {
            try writer.writeByte('[');
            try dumpType(writer, element);
            try writer.writeByte(']');
        },
        .application => |application| {
            try writer.writeByte('(');
            try dumpType(writer, application.head);
            for (application.arguments) |argument| {
                try writer.writeByte(' ');
                try dumpType(writer, argument);
            }
            try writer.writeByte(')');
        },
        .function => |function| {
            try writer.writeAll("(-> ");
            try dumpType(writer, function.parameter);
            try writer.writeByte(' ');
            try dumpType(writer, function.result);
            try writer.writeByte(')');
        },
    }
}
