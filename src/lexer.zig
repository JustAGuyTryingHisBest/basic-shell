//! Splits bs source text into tokens (spec §3).
//!
//! Source is read as shell-like words: a word runs up to a blank, a newline
//! or a structural character. Words keep their parts (literal text and
//! `$variables`) so that later stages can decide what a word means from
//! where it appears. Plain words that spell a keyword or a structural token
//! (`=`, `->`, `::`, `|`, `_`) become those tokens here.
const std = @import("std");

const Diagnostics = @import("diagnostics.zig").Diagnostics;

/// A piece of a word: literal text or a variable reference.
pub const WordPart = union(enum) {
    text: []const u8,
    /// The name of a variable, without `$` or braces.
    variable: []const u8,
};

/// One lexical token with its location in the source.
pub const Token = struct {
    tag: Tag,
    source_offset: u32,
    source_length: u32,
    /// Only for `.word`. Adjacent literal text is merged into one part.
    parts: []const WordPart = &.{},
    /// Only for `.word`: a single unquoted, unescaped text part.
    is_plain: bool = false,

    /// What kind of token this is.
    pub const Tag = enum {
        word,
        newline,
        semicolon,
        left_brace,
        right_brace,
        left_paren,
        right_paren,
        left_bracket,
        right_bracket,
        comma,
        equals,
        arrow,
        double_colon,
        pipe,
        lambda,
        wildcard,
        keyword_data,
        keyword_main,
        keyword_match,
        end_of_input,
    };

    /// The text of a plain word.
    pub fn plainText(token: Token) []const u8 {
        std.debug.assert(token.tag == .word and token.is_plain);
        return token.parts[0].text;
    }
};

/// What a plain word means in expression context (spec §3.3).
pub const WordClass = enum { identifier, constructor, integer, literal };

/// Classifies a plain word by its shape.
pub fn classifyPlainWord(text: []const u8) WordClass {
    if (isIntegerText(text)) return .integer;
    if (text.len == 0 or !isNameStart(text[0])) return .literal;
    for (text[1..]) |character| {
        if (!isNameCharacter(character)) return .literal;
    }
    return if (std.ascii.isUpper(text[0])) .constructor else .identifier;
}

/// Reports whether `character` can start a name.
pub fn isNameStart(character: u8) bool {
    return std.ascii.isAlphabetic(character) or character == '_';
}

/// Reports whether `character` can continue a name.
pub fn isNameCharacter(character: u8) bool {
    return std.ascii.isAlphanumeric(character) or character == '_';
}

fn isIntegerText(text: []const u8) bool {
    const digits = if (text.len > 1 and text[0] == '-') text[1..] else text;
    if (digits.len == 0) return false;
    for (digits) |character| {
        if (!std.ascii.isDigit(character)) return false;
    }
    return true;
}

fn isValidName(text: []const u8) bool {
    if (text.len == 0 or !isNameStart(text[0])) return false;
    for (text[1..]) |character| {
        if (!isNameCharacter(character)) return false;
    }
    return true;
}

/// How a token is named in error messages.
pub fn describeTag(tag: Token.Tag) []const u8 {
    return switch (tag) {
        .word => "a word",
        .newline => "a new line",
        .semicolon => "';'",
        .left_brace => "'{'",
        .right_brace => "'}'",
        .left_paren => "'('",
        .right_paren => "')'",
        .left_bracket => "'['",
        .right_bracket => "']'",
        .comma => "','",
        .equals => "'='",
        .arrow => "'->'",
        .double_colon => "'::'",
        .pipe => "'|'",
        .lambda => "'\\'",
        .wildcard => "'_'",
        .keyword_data => "'data'",
        .keyword_main => "'main'",
        .keyword_match => "'match'",
        .end_of_input => "the end of the input",
    };
}

/// Writes a word for dumps and tests: plain words as-is, others in double
/// quotes with variables shown as `${name}`.
pub fn writeWord(writer: *std.Io.Writer, parts: []const WordPart, is_plain: bool) std.Io.Writer.Error!void {
    if (is_plain) return writer.writeAll(parts[0].text);
    try writer.writeByte('"');
    for (parts) |part| switch (part) {
        .text => |text| try writer.writeAll(text),
        .variable => |name| try writer.print("${{{s}}}", .{name}),
    };
    try writer.writeByte('"');
}

/// Splits `text` into tokens ending with `.end_of_input`. Errors are added
/// to `diagnostics` and lexing continues, so every lexical error is reported.
pub fn tokenize(
    allocator: std.mem.Allocator,
    text: []const u8,
    diagnostics: *Diagnostics,
) std.mem.Allocator.Error![]const Token {
    var tokenizer: Tokenizer = .{ .allocator = allocator, .text = text, .diagnostics = diagnostics };
    try tokenizer.tokenizeAll();
    return dropOptionalNewlines(allocator, tokenizer.tokens.items);
}

const Tokenizer = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    diagnostics: *Diagnostics,
    index: usize = 0,
    tokens: std.ArrayList(Token) = .empty,
    /// Brackets opened and not yet closed, innermost last: `(`, `[` or `{`.
    open_brackets: std.ArrayList(u8) = .empty,

    fn tokenizeAll(tokenizer: *Tokenizer) std.mem.Allocator.Error!void {
        while (tokenizer.index < tokenizer.text.len) {
            const character = tokenizer.text[tokenizer.index];
            switch (character) {
                ' ', '\t' => tokenizer.index += 1,
                '\n' => {
                    const innermost = tokenizer.innermostBracket();
                    if (innermost == '(' or innermost == '[') {
                        tokenizer.index += 1;
                    } else {
                        try tokenizer.addPunctuation(.newline);
                    }
                },
                ';' => try tokenizer.addPunctuation(.semicolon),
                '{' => try tokenizer.openBracket(.left_brace, '{'),
                '(' => try tokenizer.openBracket(.left_paren, '('),
                '[' => try tokenizer.openBracket(.left_bracket, '['),
                '}' => try tokenizer.closeBracket(.right_brace),
                ')' => try tokenizer.closeBracket(.right_paren),
                ']' => try tokenizer.closeBracket(.right_bracket),
                '#' => tokenizer.skipComment(),
                else => {
                    const next_index = tokenizer.index + 1;
                    if (character == ',' and tokenizer.innermostBracket() == '[') {
                        try tokenizer.addPunctuation(.comma);
                    } else if (character == '\\' and next_index < tokenizer.text.len and isNameStart(tokenizer.text[next_index])) {
                        try tokenizer.addPunctuation(.lambda);
                    } else {
                        try tokenizer.lexWord();
                    }
                },
            }
        }
        try tokenizer.tokens.append(tokenizer.allocator, .{
            .tag = .end_of_input,
            .source_offset = @intCast(tokenizer.text.len),
            .source_length = 0,
        });
    }

    fn innermostBracket(tokenizer: *const Tokenizer) u8 {
        const brackets = tokenizer.open_brackets.items;
        return if (brackets.len == 0) 0 else brackets[brackets.len - 1];
    }

    fn addPunctuation(tokenizer: *Tokenizer, tag: Token.Tag) std.mem.Allocator.Error!void {
        try tokenizer.tokens.append(tokenizer.allocator, .{
            .tag = tag,
            .source_offset = @intCast(tokenizer.index),
            .source_length = 1,
        });
        tokenizer.index += 1;
    }

    fn openBracket(tokenizer: *Tokenizer, tag: Token.Tag, bracket: u8) std.mem.Allocator.Error!void {
        try tokenizer.open_brackets.append(tokenizer.allocator, bracket);
        try tokenizer.addPunctuation(tag);
    }

    fn closeBracket(tokenizer: *Tokenizer, tag: Token.Tag) std.mem.Allocator.Error!void {
        // Mismatched brackets are the parser's to report.
        _ = tokenizer.open_brackets.pop();
        try tokenizer.addPunctuation(tag);
    }

    fn skipComment(tokenizer: *Tokenizer) void {
        while (tokenizer.index < tokenizer.text.len and tokenizer.text[tokenizer.index] != '\n') {
            tokenizer.index += 1;
        }
    }

    fn endsWord(tokenizer: *const Tokenizer, character: u8) bool {
        return switch (character) {
            ' ', '\t', '\n', ';', '{', '}', '(', ')', '[', ']' => true,
            ',' => tokenizer.innermostBracket() == '[',
            else => false,
        };
    }

    fn lexWord(tokenizer: *Tokenizer) std.mem.Allocator.Error!void {
        const word_start = tokenizer.index;
        var builder: WordBuilder = .{ .allocator = tokenizer.allocator };
        while (tokenizer.index < tokenizer.text.len) {
            const character = tokenizer.text[tokenizer.index];
            if (tokenizer.endsWord(character)) break;
            switch (character) {
                '\\' => try tokenizer.lexEscape(&builder),
                '\'' => try tokenizer.lexSingleQuoted(&builder),
                '"' => try tokenizer.lexDoubleQuoted(&builder),
                '$' => try tokenizer.lexVariable(&builder),
                else => {
                    try builder.appendText(tokenizer.text[tokenizer.index .. tokenizer.index + 1]);
                    tokenizer.index += 1;
                },
            }
        }
        var token: Token = .{
            .tag = .word,
            .source_offset = @intCast(word_start),
            .source_length = @intCast(tokenizer.index - word_start),
            .parts = try builder.finish(),
            .is_plain = builder.is_plain,
        };
        if (token.is_plain and token.parts.len != 0) {
            token.tag = plainWordTag(token.plainText());
            if (token.tag != .word) token.parts = &.{};
        }
        try tokenizer.tokens.append(tokenizer.allocator, token);
    }

    fn lexEscape(tokenizer: *Tokenizer, builder: *WordBuilder) std.mem.Allocator.Error!void {
        builder.is_plain = false;
        const escaped_index = tokenizer.index + 1;
        if (escaped_index >= tokenizer.text.len or tokenizer.text[escaped_index] == '\n') {
            try tokenizer.diagnostics.add(@intCast(tokenizer.index), 1, "a backslash cannot end a line", .{});
            tokenizer.index += 1;
            return;
        }
        try builder.appendText(tokenizer.text[escaped_index .. escaped_index + 1]);
        tokenizer.index += 2;
    }

    fn lexSingleQuoted(tokenizer: *Tokenizer, builder: *WordBuilder) std.mem.Allocator.Error!void {
        builder.is_plain = false;
        const quote_index = tokenizer.index;
        const closing_index = std.mem.findScalarPos(u8, tokenizer.text, quote_index + 1, '\'') orelse {
            try tokenizer.diagnostics.add(@intCast(quote_index), 1, "unterminated single quote", .{});
            tokenizer.index = tokenizer.text.len;
            return;
        };
        try builder.appendText(tokenizer.text[quote_index + 1 .. closing_index]);
        tokenizer.index = closing_index + 1;
    }

    fn lexDoubleQuoted(tokenizer: *Tokenizer, builder: *WordBuilder) std.mem.Allocator.Error!void {
        builder.is_plain = false;
        const quote_index = tokenizer.index;
        // `""` is an empty word, not no word.
        try builder.appendText("");
        tokenizer.index += 1;
        while (tokenizer.index < tokenizer.text.len) {
            const character = tokenizer.text[tokenizer.index];
            switch (character) {
                '"' => {
                    tokenizer.index += 1;
                    return;
                },
                '\\' => {
                    const next_index = tokenizer.index + 1;
                    if (next_index < tokenizer.text.len and isEscapableInDoubleQuotes(tokenizer.text[next_index])) {
                        try builder.appendText(tokenizer.text[next_index .. next_index + 1]);
                        tokenizer.index += 2;
                    } else {
                        try builder.appendText("\\");
                        tokenizer.index += 1;
                    }
                },
                '$' => try tokenizer.lexVariable(builder),
                else => {
                    try builder.appendText(tokenizer.text[tokenizer.index .. tokenizer.index + 1]);
                    tokenizer.index += 1;
                },
            }
        }
        try tokenizer.diagnostics.add(@intCast(quote_index), 1, "unterminated double quote", .{});
    }

    /// At a `$`: adds a variable part for `$name` or `${name}`. A `$` not
    /// followed by a name or `{` is literal text.
    fn lexVariable(tokenizer: *Tokenizer, builder: *WordBuilder) std.mem.Allocator.Error!void {
        const text = tokenizer.text;
        const dollar_index = tokenizer.index;
        const after_dollar = dollar_index + 1;
        if (after_dollar < text.len and isNameStart(text[after_dollar])) {
            var name_end = after_dollar + 1;
            while (name_end < text.len and isNameCharacter(text[name_end])) name_end += 1;
            try builder.appendVariable(text[after_dollar..name_end]);
            tokenizer.index = name_end;
            return;
        }
        if (after_dollar < text.len and text[after_dollar] == '{') {
            const name_start = after_dollar + 1;
            if (std.mem.findScalarPos(u8, text, name_start, '}')) |closing_index| {
                const name = text[name_start..closing_index];
                if (isValidName(name)) {
                    try builder.appendVariable(name);
                    tokenizer.index = closing_index + 1;
                    return;
                }
            }
            builder.is_plain = false;
            try tokenizer.diagnostics.add(@intCast(dollar_index), 2, "expected a variable name and '}}' after '${{'", .{});
            tokenizer.index = name_start;
            return;
        }
        try builder.appendText("$");
        tokenizer.index = after_dollar;
    }
};

fn isEscapableInDoubleQuotes(character: u8) bool {
    return character == '"' or character == '\\' or character == '$';
}

fn plainWordTag(text: []const u8) Token.Tag {
    const reserved = std.StaticStringMap(Token.Tag).initComptime(.{
        .{ "data", .keyword_data },
        .{ "main", .keyword_main },
        .{ "match", .keyword_match },
        .{ "=", .equals },
        .{ "->", .arrow },
        .{ "::", .double_colon },
        .{ "|", .pipe },
        .{ "_", .wildcard },
    });
    return reserved.get(text) orelse .word;
}

/// Accumulates the parts of one word, merging adjacent text.
const WordBuilder = struct {
    allocator: std.mem.Allocator,
    parts: std.ArrayList(WordPart) = .empty,
    pending_text: std.ArrayList(u8) = .empty,
    /// Set once any text (even empty quoted text) follows the last variable.
    has_pending_text: bool = false,
    is_plain: bool = true,

    fn appendText(builder: *WordBuilder, text: []const u8) std.mem.Allocator.Error!void {
        try builder.pending_text.appendSlice(builder.allocator, text);
        builder.has_pending_text = true;
    }

    fn appendVariable(builder: *WordBuilder, name: []const u8) std.mem.Allocator.Error!void {
        try builder.flushText();
        try builder.parts.append(builder.allocator, .{ .variable = name });
        builder.is_plain = false;
    }

    fn flushText(builder: *WordBuilder) std.mem.Allocator.Error!void {
        if (!builder.has_pending_text) return;
        const text = try builder.pending_text.toOwnedSlice(builder.allocator);
        try builder.parts.append(builder.allocator, .{ .text = text });
        builder.has_pending_text = false;
    }

    fn finish(builder: *WordBuilder) std.mem.Allocator.Error![]const WordPart {
        try builder.flushText();
        return builder.parts.toOwnedSlice(builder.allocator);
    }
};

/// Drops newlines that cannot end a statement: after `=`, `->`, `::`, `|`
/// or a lambda, and before `|` (spec §3.6).
fn dropOptionalNewlines(allocator: std.mem.Allocator, tokens: []const Token) std.mem.Allocator.Error![]const Token {
    var kept: std.ArrayList(Token) = .empty;
    for (tokens, 0..) |token, index| {
        if (token.tag == .newline) {
            if (kept.items.len != 0 and continuesOnNextLine(kept.items[kept.items.len - 1].tag)) continue;
            if (nextNonNewlineTag(tokens[index + 1 ..]) == .pipe) continue;
        }
        try kept.append(allocator, token);
    }
    return kept.toOwnedSlice(allocator);
}

fn continuesOnNextLine(tag: Token.Tag) bool {
    return switch (tag) {
        .equals, .arrow, .double_colon, .pipe, .lambda => true,
        else => false,
    };
}

fn nextNonNewlineTag(tokens: []const Token) Token.Tag {
    for (tokens) |token| {
        if (token.tag != .newline) return token.tag;
    }
    return .end_of_input;
}

fn testSymbol(tag: Token.Tag) []const u8 {
    return switch (tag) {
        .newline => "NL",
        .semicolon => ";",
        .left_brace => "{",
        .right_brace => "}",
        .left_paren => "(",
        .right_paren => ")",
        .left_bracket => "[",
        .right_bracket => "]",
        .comma => ",",
        .equals => "=",
        .arrow => "->",
        .double_colon => "::",
        .pipe => "|",
        .lambda => "\\",
        .wildcard => "_",
        .keyword_data => "kw:data",
        .keyword_main => "kw:main",
        .keyword_match => "kw:match",
        .word, .end_of_input => unreachable,
    };
}

/// Tokenizes `source_text` and compares a compact rendering with `expected`:
/// plain words as-is, other words quoted with `${name}` for variables,
/// punctuation as in `testSymbol`, all separated by single spaces.
fn expectTokens(source_text: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var collected: Diagnostics = .init(allocator);
    const tokens = try tokenize(allocator, source_text, &collected);
    for (collected.items.items) |problem| std.debug.print("unexpected diagnostic: {s}\n", .{problem.message});
    try std.testing.expect(!collected.hasErrors());
    var output: std.Io.Writer.Allocating = .init(allocator);
    for (tokens) |token| {
        if (token.tag == .end_of_input) break;
        if (output.written().len != 0) try output.writer.writeByte(' ');
        if (token.tag == .word) {
            try writeWord(&output.writer, token.parts, token.is_plain);
        } else {
            try output.writer.writeAll(testSymbol(token.tag));
        }
    }
    try std.testing.expectEqualStrings(expected, output.written());
}

fn expectLexError(source_text: []const u8, expected_message: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var collected: Diagnostics = .init(arena.allocator());
    _ = try tokenize(arena.allocator(), source_text, &collected);
    try std.testing.expectEqual(@as(usize, 1), collected.items.items.len);
    try std.testing.expectEqualStrings(expected_message, collected.items.items[0].message);
}

test "blanks separate shell-like words" {
    try expectTokens("ip link set dev eth0 up", "ip link set dev eth0 up");
    try expectTokens("ls -l --all /tmp a.b=c 192.168.1.1", "ls -l --all /tmp a.b=c 192.168.1.1");
}

test "structural tokens only as whole words" {
    try expectTokens("x = 1", "x = 1");
    try expectTokens("x=1", "x=1");
    try expectTokens("f -> g :: h | _ _x", "f -> g :: h | _ _x");
    try expectTokens("a->b", "a->b");
    try expectTokens("data main match datum", "kw:data kw:main kw:match datum");
}

test "quoted parts and variables" {
    try expectTokens("'a b'\"c $x\"d", "\"a bc ${x}d\"");
    try expectTokens("'' \"\"", "\"\" \"\"");
    try expectTokens("$name ${name}_x pre$x.txt $ a$", "\"${name}\" \"${name}_x\" \"pre${x}.txt\" $ a$");
    try expectTokens("\\$x a\\ b", "\"$x\" \"a b\"");
}

test "backslash in double quotes escapes only quote, backslash and dollar" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var collected: Diagnostics = .init(arena.allocator());
    const tokens = try tokenize(arena.allocator(), "\"a\\\"b\\\\c\\$d\\ne\"", &collected);
    try std.testing.expect(!collected.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), tokens[0].parts.len);
    try std.testing.expectEqualStrings("a\"b\\c$d\\ne", tokens[0].parts[0].text);
}

test "commas split words only inside square brackets" {
    try expectTokens("ps -o pid,comm", "ps -o pid,comm");
    try expectTokens("[a, b]", "[ a , b ]");
    try expectTokens("[(a,b)]", "[ ( a,b ) ]");
}

test "comments, shebang and missing final newline" {
    try expectTokens("#!/usr/bin/bs\necho a#b # c\n", "NL echo a#b NL");
    try expectTokens("echo hi # bye", "echo hi");
}

test "newline rules" {
    try expectTokens("f (a\nb)\n[c\nd]", "f ( a b ) NL [ c d ]");
    try expectTokens("x =\n  1", "x = 1");
    try expectTokens("data T = A\n  | B", "kw:data T = A | B");
    try expectTokens("f x ->\n  y", "f x -> y");
    try expectTokens("a\n\nb", "a NL NL b");
    try expectTokens("{\na\n}", "{ NL a NL }");
}

test "lambda token" {
    try expectTokens("\\x -> f x", "\\ x -> f x");
}

test "non-ASCII text passes through unchanged" {
    try expectTokens("echo \"héllo\" ünï", "echo \"héllo\" ünï");
}

test "plain words are classified by shape" {
    for ([_][]const u8{ "name", "_x", "eth0" }) |text| try std.testing.expectEqual(WordClass.identifier, classifyPlainWord(text));
    for ([_][]const u8{ "Ok", "Fail" }) |text| try std.testing.expectEqual(WordClass.constructor, classifyPlainWord(text));
    for ([_][]const u8{ "0", "-12" }) |text| try std.testing.expectEqual(WordClass.integer, classifyPlainWord(text));
    for ([_][]const u8{ "-", "-l", "/tmp", "a.b", "192.168.1.1", "ünï" }) |text| try std.testing.expectEqual(WordClass.literal, classifyPlainWord(text));
}

test "lexical errors" {
    try expectLexError("echo 'abc", "unterminated single quote");
    try expectLexError("echo \"abc", "unterminated double quote");
    try expectLexError("echo abc\\", "a backslash cannot end a line");
    try expectLexError("echo ${1x}", "expected a variable name and '}' after '${'");
    try expectLexError("echo ${}", "expected a variable name and '}' after '${'");
    try expectLexError("echo ${", "expected a variable name and '}' after '${'");
}
