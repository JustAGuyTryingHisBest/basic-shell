//! Turns a line of input into words.
const std = @import("std");

/// Splits `line` into words on blanks (spaces and tabs). The words are slices
/// of `line`; only the returned list itself is allocated with `allocator`.
/// Quoting, escapes and operators are not supported yet.
pub fn splitWords(allocator: std.mem.Allocator, line: []const u8) std.mem.Allocator.Error![][]const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var word_iterator = std.mem.tokenizeAny(u8, line, " \t");
    while (word_iterator.next()) |word| try words.append(allocator, word);
    return words.items;
}

test splitWords {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualDeep(&[_][]const u8{ "echo", "hello", "world" }, try splitWords(allocator, "echo hello   world"));
    try std.testing.expectEqualDeep(&[_][]const u8{ "ls", "-l" }, try splitWords(allocator, "\t ls\t-l  "));
    try std.testing.expectEqual(0, (try splitWords(allocator, "   ")).len);
    try std.testing.expectEqual(0, (try splitWords(allocator, "")).len);
}
