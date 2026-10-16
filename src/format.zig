//! `bs fmt` (formatter spec §3.2–§5): rewrites a script into the canonical
//! layout, then checks that the result means the same and keeps every
//! comment.
const std = @import("std");

const lexer = @import("lexer.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

const Allocator = std.mem.Allocator;
const Token = lexer.Token;
const Tag = Token.Tag;

/// True when `after` means the same as `before` and keeps its comments
/// (spec §5). `before` must lex without errors.
fn verify(allocator: Allocator, before: []const u8, after: []const u8) Allocator.Error!bool {
    var before_problems: Diagnostics = .init(allocator);
    var after_problems: Diagnostics = .init(allocator);
    const before_tokens = try normalizeSeparators(allocator, try lexer.tokenize(allocator, before, &before_problems));
    const after_tokens = try normalizeSeparators(allocator, try lexer.tokenize(allocator, after, &after_problems));
    if (before_problems.hasErrors() or after_problems.hasErrors()) return false;
    if (before_tokens.len != after_tokens.len) return false;
    for (before_tokens, after_tokens) |before_token, after_token| {
        if (before_token.tag != after_token.tag) return false;
        if (before_token.tag == .word and !std.mem.eql(u8, tokenText(before, before_token), tokenText(after, after_token))) return false;
    }
    const before_comments = try commentTexts(allocator, before, try lexer.tokenizeWithTrivia(allocator, before, &before_problems));
    const after_comments = try commentTexts(allocator, after, try lexer.tokenizeWithTrivia(allocator, after, &after_problems));
    if (before_comments.len != after_comments.len) return false;
    for (before_comments, after_comments) |before_comment, after_comment| {
        if (!std.mem.eql(u8, before_comment, after_comment)) return false;
    }
    return true;
}

fn isSeparator(tag: Tag) bool {
    return tag == .newline or tag == .semicolon;
}

/// A program-mode token stream with its separators normalised (spec §5): a
/// run of separators counts as one `.semicolon`, and none is kept at the
/// start, after `{`, before `}` or before the end of the input. The parser
/// treats all of these the same way.
fn normalizeSeparators(allocator: Allocator, tokens: []const Token) Allocator.Error![]const Token {
    var kept: std.ArrayList(Token) = .empty;
    var index: usize = 0;
    while (index < tokens.len) {
        const token = tokens[index];
        if (!isSeparator(token.tag)) {
            try kept.append(allocator, token);
            index += 1;
            continue;
        }
        var run_end = index;
        while (isSeparator(tokens[run_end].tag)) run_end += 1; // `.end_of_input` ends every run
        const next_tag = tokens[run_end].tag;
        const is_dropped = kept.items.len == 0 or
            kept.items[kept.items.len - 1].tag == .left_brace or
            next_tag == .right_brace or next_tag == .end_of_input;
        if (!is_dropped) try kept.append(allocator, .{ .tag = .semicolon, .source_offset = token.source_offset, .source_length = 1 });
        index = run_end;
    }
    return kept.toOwnedSlice(allocator);
}

/// The text of every comment in `tokens`, without trailing blanks.
fn commentTexts(allocator: Allocator, source_text: []const u8, tokens: []const Token) Allocator.Error![]const []const u8 {
    var texts: std.ArrayList([]const u8) = .empty;
    for (tokens) |token| {
        if (token.tag == .comment) try texts.append(allocator, trimTrailingBlanks(tokenText(source_text, token)));
    }
    return texts.toOwnedSlice(allocator);
}

/// The source text a token was lexed from.
fn tokenText(source_text: []const u8, token: Token) []const u8 {
    return source_text[token.source_offset..][0..token.source_length];
}

fn trimTrailingBlanks(text: []const u8) []const u8 {
    return std.mem.trimEnd(u8, text, " \t");
}

fn expectVerified(before: []const u8, after: []const u8, expected: bool) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(expected, try verify(arena.allocator(), before, after));
}

test "verification accepts the formatter's freedoms" {
    try expectVerified("a; b", "a\nb", true);
    try expectVerified("a\n\n\nb", "a\nb", true);
    try expectVerified("f = { a; }", "f = { a }", true);
    try expectVerified("f = {\n\n  a\n\n}", "f = {\n  a\n}", true);
    try expectVerified("a # c  ", "a # c", true);
    try expectVerified("x =\n1", "x = 1", true);
    try expectVerified("echo a(b)", "echo a (b)", true);
}

test "verification rejects changes in meaning or comments" {
    try expectVerified("echo a b", "echo a", false); // dropped word
    try expectVerified("echo a", "echo b", false); // changed word
    try expectVerified("echo a b", "echo a\nb", false); // separator added inside a line
    try expectVerified("echo ab", "echo a b", false); // word split
    try expectVerified("a # c", "a", false); // lost comment
    try expectVerified("a # c", "a # d", false); // changed comment
    try expectVerified("echo a", "echo (a", false); // output that does not lex the same
}
