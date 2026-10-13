//! A script's text and the mapping from byte offsets to lines and columns,
//! used by every error message.
const std = @import("std");

const Source = @This();
/// Name shown in messages: the script path, or `-c`.
display_name: []const u8,
text: []const u8,

pub const Location = struct {
    /// 1-based.
    line_number: u32,
    /// 1-based, counted in bytes.
    column_number: u32,
    /// The whole line containing the offset, without its newline.
    line_text: []const u8,
};

/// Largest script accepted; scripts are read whole before running.
pub const max_script_bytes = 16 * 1024 * 1024;

/// Reads the script at `path`. The text is allocated with `allocator`.
pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Source {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_script_bytes));
    return .{ .display_name = path, .text = text };
}

/// Maps a byte offset (clamped to the end of the text) to its line and column.
pub fn locate(source: Source, offset: u32) Location {
    const clamped_offset = @min(offset, source.text.len);
    const line_start = if (std.mem.findScalarLast(u8, source.text[0..clamped_offset], '\n')) |newline_index|
        newline_index + 1
    else
        0;
    const line_end = std.mem.findScalarPos(u8, source.text, clamped_offset, '\n') orelse source.text.len;
    const line_number = std.mem.count(u8, source.text[0..line_start], "\n") + 1;
    return .{
        .line_number = @intCast(line_number),
        .column_number = @intCast(clamped_offset - line_start + 1),
        .line_text = source.text[line_start..line_end],
    };
}



test "locate finds line, column and line text" {
    const source: Source = .{ .display_name = "t.bs", .text = "echo hi\nip link\n" };
    const first = source.locate(0);
    try std.testing.expectEqual(@as(u32, 1), first.line_number);
    try std.testing.expectEqual(@as(u32, 1), first.column_number);
    try std.testing.expectEqualStrings("echo hi", first.line_text);

    const second = source.locate(11);
    try std.testing.expectEqual(@as(u32, 2), second.line_number);
    try std.testing.expectEqual(@as(u32, 4), second.column_number);
    try std.testing.expectEqualStrings("ip link", second.line_text);

    // The newline belongs to the line it ends.
    const at_newline = source.locate(7);
    try std.testing.expectEqual(@as(u32, 1), at_newline.line_number);
    try std.testing.expectEqual(@as(u32, 8), at_newline.column_number);

    // Past the end clamps to the end.
    const past_end = source.locate(100);
    try std.testing.expectEqual(@as(u32, 3), past_end.line_number);
    try std.testing.expectEqualStrings("", past_end.line_text);
}
