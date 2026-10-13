//! Turns a line of input into words, applying POSIX quoting rules
//! (XCU §2.2 "Quoting") and removing the quote characters.
//!
//! Not supported yet: operators (`|`, `;`, `&`, `<`, `>`, ...), which are
//! currently ordinary word characters, and expansions (`$`, `` ` ``), which
//! are kept literally even inside double quotes.
const std = @import("std");

pub const SplitWordsError = error{
    /// A `'` was opened but not closed before the end of the line.
    UnterminatedSingleQuote,
    /// A `"` was opened but not closed before the end of the line.
    UnterminatedDoubleQuote,
    /// The line ended with an unquoted `\`, which would escape the newline
    /// (a line continuation).
    TrailingBackslash,
} || std.mem.Allocator.Error;

/// Splits `line` into words on unquoted blanks (spaces and tabs).
///
/// - `'...'` preserves every character inside literally.
/// - `"..."` preserves every character inside literally, except that `\`
///   escapes `$`, `` ` ``, `"` and `\`; before any other character the
///   backslash is kept.
/// - An unquoted `\` preserves the character after it literally.
///
/// Quoted and unquoted parts concatenate into one word (`a'b c'"d"` is the
/// single word `ab cd`), and a quoted empty string is an empty word.
///
/// The words, and the list holding them, are allocated with `allocator`;
/// an arena that is reset per line is the intended use.
pub fn splitWords(allocator: std.mem.Allocator, line: []const u8) SplitWordsError![][]const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var current_word: std.ArrayList(u8) = .empty;
    // Distinguishes "no word yet" from "an empty word", e.g. from `''`.
    var is_in_word = false;

    var index: usize = 0;
    while (index < line.len) {
        switch (line[index]) {
            ' ', '\t' => {
                if (is_in_word) {
                    try words.append(allocator, try current_word.toOwnedSlice(allocator));
                    is_in_word = false;
                }
                index += 1;
            },
            '\\' => {
                if (index + 1 == line.len) return error.TrailingBackslash;
                try current_word.append(allocator, line[index + 1]);
                is_in_word = true;
                index += 2;
            },
            '\'' => {
                const closing_quote_index = std.mem.findScalarPos(u8, line, index + 1, '\'') orelse
                    return error.UnterminatedSingleQuote;
                try current_word.appendSlice(allocator, line[index + 1 .. closing_quote_index]);
                is_in_word = true;
                index = closing_quote_index + 1;
            },
            '"' => {
                index = try appendDoubleQuoted(allocator, &current_word, line, index + 1);
                is_in_word = true;
            },
            else => |character| {
                try current_word.append(allocator, character);
                is_in_word = true;
                index += 1;
            },
        }
    }
    if (is_in_word) try words.append(allocator, try current_word.toOwnedSlice(allocator));

    return words.items;
}

/// Appends the contents of a double-quoted string starting at `start_index`
/// (just past the opening `"`) to `word`, and returns the index just past
/// the closing `"`.
fn appendDoubleQuoted(
    allocator: std.mem.Allocator,
    word: *std.ArrayList(u8),
    line: []const u8,
    start_index: usize,
) SplitWordsError!usize {
    var index = start_index;
    while (index < line.len) {
        switch (line[index]) {
            '"' => return index + 1,
            '\\' => {
                if (index + 1 < line.len and isEscapableInDoubleQuotes(line[index + 1])) {
                    try word.append(allocator, line[index + 1]);
                    index += 2;
                } else {
                    try word.append(allocator, '\\');
                    index += 1;
                }
            },
            else => |character| {
                try word.append(allocator, character);
                index += 1;
            },
        }
    }
    return error.UnterminatedDoubleQuote;
}

/// Characters a backslash escapes inside double quotes. POSIX also lists
/// newline, but input lines never contain one.
fn isEscapableInDoubleQuotes(character: u8) bool {
    return switch (character) {
        '$', '`', '"', '\\' => true,
        else => false,
    };
}

fn expectWords(line: []const u8, expected_words: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualDeep(expected_words, try splitWords(arena.allocator(), line));
}

fn expectSplitError(line: []const u8, expected_error: SplitWordsError) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(expected_error, splitWords(arena.allocator(), line));
}

test "blanks separate words" {
    try expectWords("echo hello   world", &.{ "echo", "hello", "world" });
    try expectWords("\t ls\t-l  ", &.{ "ls", "-l" });
    try expectWords("   ", &.{});
    try expectWords("", &.{});
}

test "single quotes preserve everything literally" {
    try expectWords("echo 'a b'", &.{ "echo", "a b" });
    try expectWords("'  leading and trailing  '", &.{"  leading and trailing  "});
    try expectWords("'no \\escapes \"here\" $HOME'", &.{"no \\escapes \"here\" $HOME"});
    try expectWords("'tab\there'", &.{"tab\there"});
}

test "double quotes preserve blanks and single quotes" {
    try expectWords("echo \"a b\"", &.{ "echo", "a b" });
    try expectWords("\"it's\"", &.{"it's"});
}

test "backslash in double quotes escapes only $ ` \" and \\" {
    try expectWords("\"\\$ \\` \\\" \\\\\"", &.{"$ ` \" \\"});
    try expectWords("\"\\n \\a\"", &.{"\\n \\a"});
    try expectWords("\"ends with \\\\\"", &.{"ends with \\"});
}

test "unquoted backslash preserves the next character" {
    try expectWords("a\\ b", &.{"a b"});
    try expectWords("\\'not quoted\\'", &.{ "'not", "quoted'" });
    try expectWords("\\\\", &.{"\\"});
    try expectWords("\\n", &.{"n"});
}

test "adjacent quoted and unquoted parts form one word" {
    try expectWords("a'b c'\"d\"", &.{"ab cd"});
    try expectWords("--message='feat: x'", &.{"--message=feat: x"});
    try expectWords("git commit -m 'feat(ShellCtx): spawn subprocesses from path'", &.{
        "git", "commit", "-m", "feat(ShellCtx): spawn subprocesses from path",
    });
}

test "quoted empty strings are empty words" {
    try expectWords("''", &.{""});
    try expectWords("\"\"", &.{""});
    try expectWords("a '' b", &.{ "a", "", "b" });
    try expectWords("a''b", &.{"ab"});
}

test "unterminated quoting is an error" {
    try expectSplitError("echo 'abc", error.UnterminatedSingleQuote);
    try expectSplitError("echo \"abc", error.UnterminatedDoubleQuote);
    try expectSplitError("echo \"abc\\\"", error.UnterminatedDoubleQuote);
    try expectSplitError("echo abc\\", error.TrailingBackslash);
}
