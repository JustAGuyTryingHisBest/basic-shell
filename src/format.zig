//! `bs fmt` (formatter spec §3.2–§5): rewrites a script into the canonical
//! layout, then checks that the result means the same and keeps every
//! comment.
const std = @import("std");

const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

const Allocator = std.mem.Allocator;
const Token = lexer.Token;
const Tag = Token.Tag;

/// The result of formatting a script.
pub const Outcome = union(enum) {
    formatted: []const u8,
    /// Diagnostics were added; the input is not formatted.
    syntax_errors,
    /// The printer's output failed `verify`: a formatter bug.
    verification_failed,
};

/// Formats `source_text` (spec §3.2). Syntax errors are added to
/// `diagnostics`. Does no I/O.
pub fn format(allocator: Allocator, source_text: []const u8, diagnostics: *Diagnostics) Allocator.Error!Outcome {
    const tokens = try lexer.tokenize(allocator, source_text, diagnostics);
    _ = try parser.parse(allocator, tokens, diagnostics);
    if (diagnostics.hasErrors()) return .syntax_errors;
    const formatted = try print(allocator, source_text, try lexer.tokenizeWithTrivia(allocator, source_text, diagnostics));
    if (!try verify(allocator, source_text, formatted)) return .verification_failed;
    return .{ .formatted = formatted };
}

const indent_width = 2;

/// Prints a trivia token stream by the rules of spec §4.
fn print(allocator: Allocator, source_text: []const u8, tokens: []const Token) Allocator.Error![]const u8 {
    var printer: Printer = .{ .allocator = allocator, .source_text = source_text };
    try printer.contexts.append(allocator, .{
        .opener = .end_of_input,
        .contents_level = 0,
        .closer_level = 0,
        .separators_break_lines = true,
    });
    var index: usize = 0;
    while (true) {
        const gap_start = index;
        while (isTrivia(tokens[index].tag)) index += 1; // `.end_of_input` is not trivia
        try printer.printGap(tokens[gap_start..index], tokens[index]);
        if (tokens[index].tag == .end_of_input) break;
        try printer.printToken(tokens, index);
        index += 1;
    }
    printer.trimOutputBlanks();
    if (printer.output.items.len != 0) try printer.output.append(allocator, '\n');
    return printer.output.toOwnedSlice(allocator);
}

/// Separators and comments: what lies between two printed tokens.
fn isTrivia(tag: Tag) bool {
    return tag == .newline or tag == .semicolon or tag == .comment;
}

fn isCloser(tag: Tag) bool {
    return tag == .right_brace or tag == .right_paren or tag == .right_bracket;
}

/// A line break after one of these cannot end a statement (lexer
/// `continuesOnNextLine`), so the next line continues it.
fn continuesStatement(tag: Tag) bool {
    return switch (tag) {
        .equals, .arrow, .double_colon, .pipe, .lambda => true,
        else => false,
    };
}

/// Whether one space goes between two tokens on the same line (spec §4.4).
fn needsSpace(previous_tag: Tag, next_tag: Tag) bool {
    if (previous_tag == .left_paren or previous_tag == .left_bracket or previous_tag == .lambda) return false;
    if (next_tag == .right_paren or next_tag == .right_bracket or next_tag == .comma) return false;
    if (previous_tag == .left_brace and next_tag == .right_brace) return false;
    return true;
}

/// An open bracket, or the top level.
const Context = struct {
    /// `.left_brace`, `.left_paren` or `.left_bracket`; `.end_of_input` for
    /// the top level.
    opener: Tag,
    /// Indentation level of lines directly inside.
    contents_level: usize,
    /// Indentation level of a line that starts with the closer.
    closer_level: usize,
    /// A `;` between two items becomes a line break (spec §4.2 rule 5).
    separators_break_lines: bool,

    /// Statements continue onto later lines only in blocks and at the top
    /// level (spec §4.3).
    fn allowsContinuation(context: Context) bool {
        return context.opener == .left_brace or context.opener == .end_of_input;
    }
};

const Printer = struct {
    allocator: Allocator,
    source_text: []const u8,
    output: std.ArrayList(u8) = .empty,
    /// Innermost last; the first entry is the top level.
    contexts: std.ArrayList(Context) = .empty,
    /// The last printed token that is not trivia.
    previous_tag: ?Tag = null,
    /// The last thing printed was a `{` (spec §4.2 rule 2).
    follows_left_brace: bool = false,
    /// Indentation level of the line being written.
    line_level: usize = 0,

    fn innermost(printer: *const Printer) Context {
        return printer.contexts.items[printer.contexts.items.len - 1];
    }

    /// Prints the separators and comments before `next` and the line break,
    /// indentation or space that puts `next` in place.
    fn printGap(printer: *Printer, gap: []const Token, next: Token) Allocator.Error!void {
        const context = printer.innermost();
        var has_semicolon = false;
        var has_line_break = false;
        for (gap) |token| switch (token.tag) {
            .semicolon => has_semicolon = true,
            .newline => has_line_break = true,
            else => {},
        };
        const is_at_end = next.tag == .end_of_input;
        const semicolon_separates = has_semicolon and printer.previous_tag != null and
            printer.previous_tag.? != .left_brace and !isCloser(next.tag) and !is_at_end;

        if (!has_line_break and !(semicolon_separates and context.separators_break_lines)) {
            if (semicolon_separates) {
                try printer.output.appendSlice(printer.allocator, "; ");
            } else if (printer.previous_tag) |previous_tag| {
                if (!is_at_end and needsSpace(previous_tag, next.tag)) try printer.output.append(printer.allocator, ' ');
            }
            // Only a comment at the very end of the input ends a gap
            // without a line break.
            for (gap) |token| {
                if (token.tag == .comment) try printer.printComment(token, printer.previous_tag != null);
            }
            return;
        }

        const next_level = printer.levelOfLine(next.tag, has_semicolon);
        // A comment before a closer belongs to the bracket's contents.
        const comment_level = if (isCloser(next.tag) or is_at_end) context.contents_level else next_level;
        var pending_line_breaks: usize = 0;
        var is_on_previous_line = true;
        for (gap) |token| switch (token.tag) {
            .semicolon => {},
            .newline => {
                pending_line_breaks += 1;
                is_on_previous_line = false;
            },
            .comment => {
                if (is_on_previous_line and printer.previous_tag != null) {
                    try printer.printComment(token, true);
                } else {
                    try printer.startLine(pending_line_breaks, comment_level, false);
                    try printer.printComment(token, false);
                }
                pending_line_breaks = 0;
            },
            else => unreachable,
        };
        if (is_at_end) return;
        try printer.startLine(pending_line_breaks, next_level, next.tag == .right_brace);
    }

    /// The indentation level of a line starting with `next_tag` (spec §4.3).
    fn levelOfLine(printer: *const Printer, next_tag: Tag, gap_has_semicolon: bool) usize {
        const context = printer.innermost();
        if (isCloser(next_tag)) return context.closer_level;
        if (!context.allowsContinuation()) return context.contents_level;
        const follows_operator = if (printer.previous_tag) |previous_tag| continuesStatement(previous_tag) else false;
        const continues = !gap_has_semicolon and (follows_operator or next_tag == .pipe);
        return context.contents_level + @intFromBool(continues);
    }

    /// Ends the current line and indents the next one. Two or more
    /// requested line breaks leave one blank line, except where spec §4.2
    /// rule 2 forbids it. Nothing is written before the first line.
    fn startLine(printer: *Printer, requested_line_breaks: usize, level: usize, is_before_right_brace: bool) Allocator.Error!void {
        printer.line_level = level;
        if (printer.output.items.len == 0) return;
        printer.trimOutputBlanks();
        const keeps_blank_line = requested_line_breaks >= 2 and !printer.follows_left_brace and !is_before_right_brace;
        try printer.output.appendNTimes(printer.allocator, '\n', if (keeps_blank_line) 2 else 1);
        try printer.output.appendNTimes(printer.allocator, ' ', level * indent_width);
    }

    fn printComment(printer: *Printer, comment: Token, is_after_code: bool) Allocator.Error!void {
        if (is_after_code) try printer.output.append(printer.allocator, ' ');
        try printer.output.appendSlice(printer.allocator, trimTrailingBlanks(tokenText(printer.source_text, comment)));
        printer.follows_left_brace = false;
    }

    fn printToken(printer: *Printer, tokens: []const Token, index: usize) Allocator.Error!void {
        const token = tokens[index];
        try printer.output.appendSlice(printer.allocator, tokenText(printer.source_text, token));
        switch (token.tag) {
            .left_brace, .left_paren, .left_bracket => {
                const following_tag = tokens[index + 1].tag; // `.end_of_input` is always last
                try printer.contexts.append(printer.allocator, .{
                    .opener = token.tag,
                    .contents_level = printer.line_level + 1,
                    .closer_level = printer.line_level,
                    .separators_break_lines = token.tag == .left_brace and
                        (following_tag == .newline or following_tag == .comment),
                });
            },
            .right_brace, .right_paren, .right_bracket => {
                // The parser rejected unbalanced brackets; keep the top level regardless.
                if (printer.contexts.items.len > 1) _ = printer.contexts.pop();
            },
            else => {},
        }
        printer.previous_tag = token.tag;
        printer.follows_left_brace = token.tag == .left_brace;
    }

    fn trimOutputBlanks(printer: *Printer) void {
        printer.output.shrinkRetainingCapacity(trimTrailingBlanks(printer.output.items).len);
    }
};

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

/// Formats `input`, expects `expected`, and checks that formatting
/// `expected` again changes nothing (spec §7, item 2).
fn expectFormat(input: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var problems: Diagnostics = .init(allocator);
    const outcome = try format(allocator, input, &problems);
    for (problems.items.items) |problem| std.debug.print("unexpected diagnostic: {s}\n", .{problem.message});
    try std.testing.expect(outcome == .formatted);
    try std.testing.expectEqualStrings(expected, outcome.formatted);
    const formatted_again = try format(allocator, expected, &problems);
    try std.testing.expect(formatted_again == .formatted);
    try std.testing.expectEqualStrings(expected, formatted_again.formatted);
}

test "rule 1: runs of blank lines become one" {
    try expectFormat("a\n\n\n\nb\n", "a\n\nb\n");
}

test "rule 2: no blank lines at the start, after { or before }" {
    try expectFormat("\n\nx = {\n\n  a\n\n}\n", "x = {\n  a\n}\n");
}

test "rule 3: exactly one final new line" {
    try expectFormat("a", "a\n");
    try expectFormat("a\n\n\n", "a\n");
    try expectFormat("  \n\t\n", "");
    try expectFormat("", "");
}

test "rule 4: no trailing blanks" {
    try expectFormat("a   \n# c  \t\n", "a\n# c\n");
}

test "rule 5: ; becomes a line break in multi-line contexts" {
    try expectFormat("a; b\n", "a\nb\n");
    try expectFormat("f = {\n  a; b\n}\n", "f = {\n  a\n  b\n}\n");
    try expectFormat("f = { a; b }\n", "f = { a; b }\n");
    try expectFormat("match x { A -> a\n  B -> b }\n", "match x { A -> a\n  B -> b }\n");
}

test "rule 6: a ; that separates nothing is removed" {
    try expectFormat("a;\n", "a\n");
    try expectFormat("f = { a; }\n", "f = { a }\n");
    try expectFormat("a; # c\n", "a # c\n");
}

test "indentation follows brackets" {
    try expectFormat("f = {\nmatch x {\nA -> a\n}\n}\n", "f = {\n  match x {\n    A -> a\n  }\n}\n");
    try expectFormat("f = {\n    a\n        }\n", "f = {\n  a\n}\n");
    try expectFormat("echo (add 1\n2)\n", "echo (add 1\n  2)\n");
    // Several brackets opened on one line indent once.
    try expectFormat("for xs (\\x -> {\necho $x\n})\n", "for xs (\\x -> {\n  echo $x\n})\n");
    try expectFormat(
        "data S = S {\nname :: String\nport :: Int\n} | D {}\n",
        "data S = S {\n  name :: String\n  port :: Int\n} | D {}\n",
    );
}

test "continuation lines get one extra level" {
    try expectFormat("x =\nadd 1 2\n", "x =\n  add 1 2\n");
    try expectFormat("f x = match x {\nA ->\necho a\n}\n", "f x = match x {\n  A ->\n    echo a\n}\n");
    try expectFormat("f ::\nInt\n", "f ::\n  Int\n");
    try expectFormat("data T = A\n| B\n    | C\n", "data T = A\n  | B\n  | C\n");
    try expectFormat("x = 1\ny = 2\n", "x = 1\ny = 2\n");
}

test "spacing within a line" {
    try expectFormat("echo   a    b\n", "echo a b\n");
    try expectFormat("echo ( add 1 2 )\n", "echo (add 1 2)\n");
    try expectFormat("f [ a ,b , c ]\n", "f [a, b, c]\n");
    try expectFormat("for xs \\x  ->  echo $x\n", "for xs \\x -> echo $x\n");
    try expectFormat("f = {a; b}\n", "f = { a; b }\n");
    try expectFormat("f = { a ;b }\n", "f = { a; b }\n");
    try expectFormat("x = D { }\n", "x = D {}\n");
    try expectFormat("echo a(b)c\n", "echo a (b) c\n");
    try expectFormat("a    # c\n", "a # c\n");
}

test "words are copied verbatim" {
    try expectFormat("echo 'a  b' \"$x\"y x=1 ${s.p}\n", "echo 'a  b' \"$x\"y x=1 ${s.p}\n");
}

test "comments in every position" {
    try expectFormat("#!/usr/bin/bs\necho hi\n", "#!/usr/bin/bs\necho hi\n");
    try expectFormat("# only\n", "# only\n");
    try expectFormat("# a\n\n\n# b", "# a\n\n# b\n");
    try expectFormat("a # c", "a # c\n");
    try expectFormat("f = {\n      # c\n  a\n}\n", "f = {\n  # c\n  a\n}\n");
    try expectFormat("f = {\n  a\n# c\n}\n", "f = {\n  a\n  # c\n}\n");
    try expectFormat("f = { # c\n  a\n}\n", "f = { # c\n  a\n}\n");
    try expectFormat("data T = A\n# b next\n  | B\n", "data T = A\n  # b next\n  | B\n");
    try expectFormat("f [a, # first\nb]\n", "f [a, # first\n  b]\n");
}

test "tabs and UTF-8" {
    try expectFormat("f = {\n\ta\n}\n", "f = {\n  a\n}\n");
    try expectFormat("echo 'a\tb' \"é\" # ünïcode\t\n", "echo 'a\tb' \"é\" # ünïcode\n");
}

test "carriage returns are kept" {
    try expectFormat("echo hi\r\n", "echo hi\r\n");
}

test "the spec example" {
    try expectFormat(
        \\#!/usr/bin/bs
        \\data Shape = Circle Int
        \\ | Rect Int Int
        \\
        \\
        \\area s   =  match s {
        \\
        \\   Circle r ->  add r r;Rect w h -> add w h    # sum
        \\   }
        \\for [Circle 2 ,Rect 3 4] \s -> echo ( area s );echo done;
        \\
    ,
        \\#!/usr/bin/bs
        \\data Shape = Circle Int
        \\  | Rect Int Int
        \\
        \\area s = match s {
        \\  Circle r -> add r r
        \\  Rect w h -> add w h # sum
        \\}
        \\for [Circle 2, Rect 3 4] \s -> echo (area s)
        \\echo done
        \\
    );
}

test "syntax errors are reported, not formatted" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var problems: Diagnostics = .init(arena.allocator());
    const outcome = try format(arena.allocator(), "f (a", &problems);
    try std.testing.expect(outcome == .syntax_errors);
    try std.testing.expectEqualStrings("expected ')', found the end of the input", problems.items.items[0].message);
}
