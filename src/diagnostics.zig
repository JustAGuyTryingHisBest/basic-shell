//! Error messages with source excerpts, shared by every stage (spec §9).
const std = @import("std");

const Source = @import("Source.zig");

/// One error, located by a byte offset into its source.
pub const Diagnostic = struct {
    source_offset: u32,
    /// Bytes underlined in the excerpt; at least 1.
    length: u32,
    message: []const u8,
};

/// Collects the errors of the lexer, parser and resolver so that all of them
/// are reported before anything runs.
pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Diagnostic) = .empty,

    /// `allocator` holds the messages; an arena that outlives reporting is intended.
    pub fn init(allocator: std.mem.Allocator) Diagnostics {
        return .{ .allocator = allocator };
    }

    /// Formats a message with `arguments` and records it at `source_offset`.
    pub fn add(
        diagnostics: *Diagnostics,
        source_offset: u32,
        length: u32,
        comptime format: []const u8,
        arguments: anytype,
    ) std.mem.Allocator.Error!void {
        const message = try std.fmt.allocPrint(diagnostics.allocator, format, arguments);
        try diagnostics.items.append(diagnostics.allocator, .{
            .source_offset = source_offset,
            .length = @max(length, 1),
            .message = message,
        });
    }

    /// Reports whether any error has been recorded.
    pub fn hasErrors(diagnostics: Diagnostics) bool {
        return diagnostics.items.items.len != 0;
    }
};

/// Width of the line-number gutter in excerpts.
const gutter_width = 5;

/// Writes one diagnostic:
///
///     up.bs:2:17: error: undefined variable 'nmae'
///         2 | ip link set dev $nmae up
///           |                 ^~~~~
pub fn render(writer: *std.Io.Writer, source: Source, diagnostic: Diagnostic) std.Io.Writer.Error!void {
    const location = source.locate(diagnostic.source_offset);
    try writer.print("{s}:{d}:{d}: error: {s}\n", .{
        source.display_name, location.line_number, location.column_number, diagnostic.message,
    });
    try writer.print("{d: >5} | {s}\n", .{ location.line_number, location.line_text });
    try writer.splatByteAll(' ', gutter_width);
    try writer.writeAll(" | ");
    try writer.splatByteAll(' ', location.column_number - 1);
    const columns_left_on_line = location.line_text.len -| (location.column_number - 1);
    const underline_length = @max(@min(diagnostic.length, columns_left_on_line), 1);
    try writer.writeByte('^');
    try writer.splatByteAll('~', underline_length - 1);
    try writer.writeByte('\n');
}

test "render prints location, message, line and underline" {
    const source: Source = .{ .display_name = "up.bs", .text = "echo hi\nip link set dev $nmae up\n" };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try render(&output.writer, source, .{ .source_offset = 24, .length = 5, .message = "undefined variable 'nmae'" });
    try std.testing.expectEqualStrings(
        \\up.bs:2:17: error: undefined variable 'nmae'
        \\    2 | ip link set dev $nmae up
        \\      |                 ^~~~~
        \\
    , output.written());
}

test "underline never runs past the end of the line" {
    const source: Source = .{ .display_name = "t.bs", .text = "ab" };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try render(&output.writer, source, .{ .source_offset = 1, .length = 50, .message = "m" });
    try std.testing.expectEqualStrings(
        \\t.bs:1:2: error: m
        \\    1 | ab
        \\      |  ^
        \\
    , output.written());
}

test "Diagnostics collects formatted messages" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var collected: Diagnostics = .init(arena.allocator());
    try std.testing.expect(!collected.hasErrors());
    try collected.add(3, 0, "bad {s}", .{"thing"});
    try std.testing.expect(collected.hasErrors());
    try std.testing.expectEqualStrings("bad thing", collected.items.items[0].message);
    try std.testing.expectEqual(@as(u32, 1), collected.items.items[0].length);
}
