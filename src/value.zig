//! Runtime values (spec §5.2) and the conversions shared by the evaluator
//! and the builtins.
const std = @import("std");

const ast = @import("ast.zig");

const Allocator = std.mem.Allocator;

/// A runtime value.
pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    list: []const Value,
    constructor: Constructor,
    closure: *const Closure,
    /// A top-level function used as a value.
    function: *const ast.Definition,

    /// The `Ok` constructor with no fields.
    pub const ok: Value = .{ .constructor = .{ .name = "Ok", .fields = &.{} } };

    /// `True` or `False`.
    pub fn boolean(is_true: bool) Value {
        return .{ .constructor = .{ .name = if (is_true) "True" else "False", .fields = &.{} } };
    }

    /// The exit code, if this is a `Fail` value.
    pub fn failCode(self: Value) ?i64 {
        const constructor = switch (self) {
            .constructor => |constructor| constructor,
            else => return null,
        };
        if (!std.mem.eql(u8, constructor.name, "Fail") or constructor.fields.len != 1) return null;
        return switch (constructor.fields[0]) {
            .integer => |code| code,
            else => 1,
        };
    }
};

/// A `Fail` value carrying `exit_status`.
pub fn makeFail(allocator: Allocator, exit_status: u8) Allocator.Error!Value {
    const fields = try allocator.alloc(Value, 1);
    fields[0] = .{ .integer = exit_status };
    return .{ .constructor = .{ .name = "Fail", .fields = fields } };
}

/// A constructor applied to its fields, such as `Ok` or `Fail 3`.
pub const Constructor = struct {
    name: []const u8,
    fields: []const Value,
    /// For a record, one name per field; they live in the syntax tree.
    field_names: []const []const u8 = &.{},
};

/// A function value made by a `\` lambda, with the environment it closed over.
pub const Closure = struct {
    parameters: []const ast.Parameter,
    body: *const ast.Expression,
    environment: ?*const Environment,
    /// The call frame whose arena holds this closure and its environment.
    /// Frame ids only grow, so a closure made during a call has an id at
    /// least as large as that call's first frame (spec §8.5).
    frame_id: u64,
};

/// Variable bindings, innermost first. Each binding is its own node, so a
/// closure keeps exactly the bindings that existed when it was made.
pub const Environment = struct {
    parent: ?*const Environment,
    name: []const u8,
    value: Value,

    /// The innermost binding of `name`, if any.
    pub fn lookup(environment: ?*const Environment, name: []const u8) ?Value {
        var current = environment;
        while (current) |node| : (current = node.parent) {
            if (std.mem.eql(u8, node.name, name)) return node.value;
        }
        return null;
    }
};

/// The error returned by evaluation functions; the message is in an `ErrorMessage`.
pub const RuntimeError = error{RuntimeError};

/// The message of the most recent `error.RuntimeError`. It is a fixed buffer
/// so that it survives the frame arenas being freed while the error
/// propagates.
pub const ErrorMessage = struct {
    buffer: [512]u8 = undefined,
    length: usize = 0,

    /// Formats the message; an overlong message is truncated.
    pub fn set(message: *ErrorMessage, comptime format: []const u8, arguments: anytype) void {
        var writer: std.Io.Writer = .fixed(&message.buffer);
        writer.print(format, arguments) catch {};
        message.length = writer.end;
    }

    /// Records the message and returns `error.RuntimeError`.
    pub fn fail(message: *ErrorMessage, comptime format: []const u8, arguments: anytype) RuntimeError {
        message.set(format, arguments);
        return error.RuntimeError;
    }

    /// The recorded message.
    pub fn text(message: *const ErrorMessage) []const u8 {
        return message.buffer[0..message.length];
    }
};

/// How a value is named in error messages.
pub fn describe(described: Value) []const u8 {
    return switch (described) {
        .string => "a string",
        .integer => "a number",
        .list => "a list",
        .constructor => |constructor| constructor.name,
        .closure, .function => "a function",
    };
}

/// Appends a value as text: numbers in decimal, lists of strings and numbers
/// joined with single spaces (spec §3.2).
pub fn appendText(
    text: *std.ArrayList(u8),
    allocator: Allocator,
    appended: Value,
    message: *ErrorMessage,
) (Allocator.Error || RuntimeError)!void {
    switch (appended) {
        .string => |string| try text.appendSlice(allocator, string),
        .integer => |integer| try text.print(allocator, "{d}", .{integer}),
        .list => |elements| for (elements, 0..) |element, index| {
            if (index != 0) try text.append(allocator, ' ');
            switch (element) {
                .string, .integer => try appendText(text, allocator, element, message),
                else => return message.fail("cannot use a list containing {s} as text", .{describe(element)}),
            }
        },
        else => return message.fail("cannot use {s} as text", .{describe(appended)}),
    }
}

/// Turns a value into program arguments: one per string or number, one per
/// element of a list. Values are never split (spec §5.6).
pub fn expandArguments(
    words: *std.ArrayList([]const u8),
    allocator: Allocator,
    expanded: Value,
    message: *ErrorMessage,
) (Allocator.Error || RuntimeError)!void {
    switch (expanded) {
        .string => |string| try words.append(allocator, string),
        .integer => |integer| try words.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{integer})),
        .list => |elements| for (elements) |element| switch (element) {
            .string, .integer => try expandArguments(words, allocator, element, message),
            else => return message.fail("cannot pass a list containing {s} to a command", .{describe(element)}),
        },
        else => return message.fail("cannot pass {s} to a command", .{describe(expanded)}),
    }
}

/// Numbers are accepted as `Int` or as a string of decimal digits, so
/// captured output can be used directly (spec §5.8).
pub fn toInteger(converted: Value, message: *ErrorMessage) RuntimeError!i64 {
    switch (converted) {
        .integer => |integer| return integer,
        .string => |string| return std.fmt.parseInt(i64, string, 10) catch
            return message.fail("expected a number, got '{s}'", .{string}),
        else => return message.fail("expected a number, got {s}", .{describe(converted)}),
    }
}

/// Errors from copying a value out of a frame.
pub const CopyError = error{EscapingClosure} || Allocator.Error;

/// Copies a value into `allocator` so that it outlives the frame it was made
/// in. A closure made in a frame whose id is at least
/// `escape_threshold_frame_id` would outlive its environment, which is
/// `error.EscapingClosure`.
pub fn deepCopy(allocator: Allocator, copied: Value, escape_threshold_frame_id: u64) CopyError!Value {
    switch (copied) {
        .string => |string| return .{ .string = try allocator.dupe(u8, string) },
        .integer, .function => return copied,
        .list => |elements| return .{ .list = try deepCopyAll(allocator, elements, escape_threshold_frame_id) },
        .constructor => |constructor| return .{ .constructor = .{
            .name = constructor.name,
            .fields = try deepCopyAll(allocator, constructor.fields, escape_threshold_frame_id),
            .field_names = constructor.field_names,
        } },
        .closure => |closure| {
            if (closure.frame_id >= escape_threshold_frame_id) return error.EscapingClosure;
            return copied;
        },
    }
}

/// `deepCopy` applied to each element of `values`.
pub fn deepCopyAll(allocator: Allocator, values: []const Value, escape_threshold_frame_id: u64) CopyError![]const Value {
    const copies = try allocator.alloc(Value, values.len);
    for (copies, values) |*copy, original| copy.* = try deepCopy(allocator, original, escape_threshold_frame_id);
    return copies;
}

/// True if any of `values` contains a closure made in frame `frame_id`.
pub fn anyClosureFrom(values: []const Value, frame_id: u64) bool {
    for (values) |checked| {
        const found = switch (checked) {
            .closure => |closure| closure.frame_id == frame_id,
            .list => |elements| anyClosureFrom(elements, frame_id),
            .constructor => |constructor| anyClosureFrom(constructor.fields, frame_id),
            .string, .integer, .function => false,
        };
        if (found) return true;
    }
    return false;
}

test "values as text and as program arguments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var message: ErrorMessage = .{};
    const list: Value = .{ .list = &.{ .{ .string = "a b" }, .{ .integer = 7 } } };

    var text: std.ArrayList(u8) = .empty;
    try appendText(&text, allocator, list, &message);
    try std.testing.expectEqualStrings("a b 7", text.items);

    var words: std.ArrayList([]const u8) = .empty;
    try expandArguments(&words, allocator, .{ .string = "x y" }, &message);
    try expandArguments(&words, allocator, list, &message);
    try std.testing.expectEqual(@as(usize, 3), words.items.len);
    try std.testing.expectEqualStrings("x y", words.items[0]);
    try std.testing.expectEqualStrings("a b", words.items[1]);
    try std.testing.expectEqualStrings("7", words.items[2]);

    try std.testing.expectError(error.RuntimeError, expandArguments(&words, allocator, Value.ok, &message));
    try std.testing.expectEqualStrings("cannot pass Ok to a command", message.text());
}

test "numbers from strings" {
    var message: ErrorMessage = .{};
    try std.testing.expectEqual(@as(i64, 42), try toInteger(.{ .string = "42" }, &message));
    try std.testing.expectEqual(@as(i64, -3), try toInteger(.{ .integer = -3 }, &message));
    try std.testing.expectError(error.RuntimeError, toInteger(.{ .string = "two" }, &message));
    try std.testing.expectEqualStrings("expected a number, got 'two'", message.text());
}

test "Fail values carry their code" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const failed = try makeFail(arena.allocator(), 3);
    try std.testing.expectEqual(@as(?i64, 3), failed.failCode());
    try std.testing.expectEqual(@as(?i64, null), Value.ok.failCode());
}

test "deep copies refuse closures from frames being freed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var body: ast.Expression = .{ .source_offset = 0, .data = .{ .literal_integer = 1 } };
    const closure: Closure = .{ .parameters = &.{}, .body = &body, .environment = null, .frame_id = 5 };
    const holding_closure: Value = .{ .list = &.{.{ .closure = &closure }} };

    try std.testing.expectError(error.EscapingClosure, deepCopy(allocator, holding_closure, 5));
    _ = try deepCopy(allocator, holding_closure, 6);
    try std.testing.expect(anyClosureFrom(&.{holding_closure}, 5));
    try std.testing.expect(!anyClosureFrom(&.{holding_closure}, 4));

    const copied = try deepCopy(allocator, .{ .string = "text" }, 0);
    try std.testing.expectEqualStrings("text", copied.string);
}
