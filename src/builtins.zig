//! Builtins that compute a value from their arguments (spec §5.8). Command
//! builtins and `for` need the interpreter and live in `eval.zig`.
const std = @import("std");

const ast = @import("ast.zig");
const value = @import("value.zig");

const Allocator = std.mem.Allocator;
const Value = value.Value;

/// Calls one of `lines`, `words`, `add`, `sub`, `eq`, `lt`. The resolver has
/// already checked the argument count.
pub fn callPure(
    allocator: Allocator,
    builtin: ast.Builtin,
    arguments: []const Value,
    message: *value.ErrorMessage,
) (Allocator.Error || value.RuntimeError)!Value {
    switch (builtin) {
        .lines => return .{ .list = try splitLines(allocator, try expectText(arguments[0], "lines", message)) },
        .words => return .{ .list = try splitWords(allocator, try expectText(arguments[0], "words", message)) },
        .add, .sub => {
            const left = try value.toInteger(arguments[0], message);
            const right = try value.toInteger(arguments[1], message);
            const result = if (builtin == .add) std.math.add(i64, left, right) else std.math.sub(i64, left, right);
            return .{ .integer = result catch return message.fail("{s} overflowed", .{@tagName(builtin)}) };
        },
        .eq, .lt => {
            const left = try value.toInteger(arguments[0], message);
            const right = try value.toInteger(arguments[1], message);
            return Value.boolean(if (builtin == .eq) left == right else left < right);
        },
        .echo, .skip, .exit, .cd, .@"export", .@"for" => unreachable,
    }
}

fn expectText(argument: Value, builtin_name: []const u8, message: *value.ErrorMessage) value.RuntimeError![]const u8 {
    switch (argument) {
        .string => |text| return text,
        else => return message.fail("{s} expects a string, got {s}", .{ builtin_name, value.describe(argument) }),
    }
}

/// `lines`: splits on `\n`; a final newline does not add an empty element.
pub fn splitLines(allocator: Allocator, text: []const u8) Allocator.Error![]const Value {
    if (text.len == 0) return &.{};
    const without_final_newline = if (std.mem.endsWith(u8, text, "\n")) text[0 .. text.len - 1] else text;
    var elements: std.ArrayList(Value) = .empty;
    var line_iterator = std.mem.splitScalar(u8, without_final_newline, '\n');
    while (line_iterator.next()) |line| try elements.append(allocator, .{ .string = line });
    return elements.toOwnedSlice(allocator);
}

/// `words`: splits on runs of blanks and newlines.
pub fn splitWords(allocator: Allocator, text: []const u8) Allocator.Error![]const Value {
    var elements: std.ArrayList(Value) = .empty;
    var word_iterator = std.mem.tokenizeAny(u8, text, " \t\n");
    while (word_iterator.next()) |word| try elements.append(allocator, .{ .string = word });
    return elements.toOwnedSlice(allocator);
}

fn expectStrings(expected: []const []const u8, actual: []const Value) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |expected_text, actual_value| try std.testing.expectEqualStrings(expected_text, actual_value.string);
}

test "lines and words" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try expectStrings(&.{ "a", "b" }, try splitLines(allocator, "a\nb\n"));
    try expectStrings(&.{ "a", "b" }, try splitLines(allocator, "a\nb"));
    try expectStrings(&.{}, try splitLines(allocator, ""));
    try expectStrings(&.{""}, try splitLines(allocator, "\n"));
    try expectStrings(&.{ "a", "", "b" }, try splitLines(allocator, "a\n\nb"));
    try expectStrings(&.{ "a", "b", "c" }, try splitWords(allocator, "  a  b\tc\n"));
}

test "arithmetic and comparison" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var message: value.ErrorMessage = .{};
    const sum = try callPure(allocator, .add, &.{ .{ .integer = 2 }, .{ .string = "3" } }, &message);
    try std.testing.expectEqual(@as(i64, 5), sum.integer);
    const difference = try callPure(allocator, .sub, &.{ .{ .integer = 2 }, .{ .integer = 3 } }, &message);
    try std.testing.expectEqual(@as(i64, -1), difference.integer);
    const is_less = try callPure(allocator, .lt, &.{ .{ .integer = 2 }, .{ .integer = 3 } }, &message);
    try std.testing.expectEqualStrings("True", is_less.constructor.name);
    const is_equal = try callPure(allocator, .eq, &.{ .{ .string = "2" }, .{ .integer = 3 } }, &message);
    try std.testing.expectEqualStrings("False", is_equal.constructor.name);
    try std.testing.expectError(error.RuntimeError, callPure(allocator, .add, &.{ .{ .integer = std.math.maxInt(i64) }, .{ .integer = 1 } }, &message));
    try std.testing.expectEqualStrings("add overflowed", message.text());
    try std.testing.expectError(error.RuntimeError, callPure(allocator, .lines, &.{.{ .integer = 1 }}, &message));
    try std.testing.expectEqualStrings("lines expects a string, got a number", message.text());
}
