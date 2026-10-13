//! Recursive-descent parser for `grammar.ebnf`. It produces an
//! `ast.Script` whose words are still unclassified; `resolve.zig` decides
//! what they mean.
const std = @import("std");

const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

const Allocator = std.mem.Allocator;
const Token = lexer.Token;
const Tag = Token.Tag;

const ParseError = error{ParseFailed} || Allocator.Error;

/// Parses `tokens` (from `lexer.tokenize`). Syntax errors are added to
/// `diagnostics` and the parser skips to the next statement after each one,
/// so all of them are reported. The tree is only meaningful when no errors
/// were added.
pub fn parse(allocator: Allocator, tokens: []const Token, diagnostics: *Diagnostics) Allocator.Error!*ast.Script {
    var parser: Parser = .{ .allocator = allocator, .tokens = tokens, .diagnostics = diagnostics };
    const statements = try parser.parseSequence(ast.Statement, Parser.parseGlobalStatement, .end_of_input);
    const script = try allocator.create(ast.Script);
    script.* = .{ .statements = statements };
    return script;
}

const Parser = struct {
    allocator: Allocator,
    tokens: []const Token,
    index: usize = 0,
    diagnostics: *Diagnostics,

    fn peek(parser: *const Parser) Token {
        return parser.tokens[parser.index];
    }

    fn peekTag(parser: *const Parser) Tag {
        return parser.peek().tag;
    }

    fn peekTagAfter(parser: *const Parser, distance: usize) Tag {
        return parser.tokens[@min(parser.index + distance, parser.tokens.len - 1)].tag;
    }

    fn advance(parser: *Parser) Token {
        const token = parser.peek();
        if (token.tag != .end_of_input) parser.index += 1;
        return token;
    }

    fn expect(parser: *Parser, tag: Tag, description: []const u8) ParseError!Token {
        if (parser.peekTag() == tag) return parser.advance();
        return parser.fail(parser.peek(), "expected {s}, found {s}", .{ description, lexer.describeTag(parser.peekTag()) });
    }

    fn fail(parser: *Parser, token: Token, comptime format: []const u8, arguments: anytype) ParseError {
        parser.diagnostics.add(token.source_offset, token.source_length, format, arguments) catch |err| return err;
        return error.ParseFailed;
    }

    fn isSeparator(tag: Tag) bool {
        return tag == .newline or tag == .semicolon;
    }

    fn skipSeparators(parser: *Parser) void {
        while (isSeparator(parser.peekTag())) _ = parser.advance();
    }

    /// Parses items separated by new lines or `;` up to `closing_tag`,
    /// which is left for the caller.
    fn parseSequence(
        parser: *Parser,
        comptime Item: type,
        comptime parseItem: fn (*Parser) ParseError!Item,
        closing_tag: Tag,
    ) Allocator.Error![]const Item {
        var items: std.ArrayList(Item) = .empty;
        parser.skipSeparators();
        while (parser.peekTag() != closing_tag and parser.peekTag() != .end_of_input) {
            const item_start = parser.index;
            if (parseItem(parser)) |item| {
                try items.append(parser.allocator, item);
                const next_token = parser.peek();
                if (next_token.tag != closing_tag and next_token.tag != .end_of_input and !isSeparator(next_token.tag)) {
                    try parser.diagnostics.add(next_token.source_offset, next_token.source_length, "expected a new line or ';' before {s}", .{lexer.describeTag(next_token.tag)});
                    parser.skipToStatementEnd();
                }
            } else |err| switch (err) {
                error.ParseFailed => {
                    parser.skipToStatementEnd();
                    // A stray closing bracket would otherwise stop progress.
                    if (parser.index == item_start) _ = parser.advance();
                },
                error.OutOfMemory => |out_of_memory| return out_of_memory,
            }
            parser.skipSeparators();
        }
        return items.toOwnedSlice(parser.allocator);
    }

    /// Error recovery: skips to the next separator, or to a `}` that closes
    /// the enclosing block, ignoring brackets opened while skipping.
    fn skipToStatementEnd(parser: *Parser) void {
        var depth: usize = 0;
        while (true) {
            switch (parser.peekTag()) {
                .end_of_input => return,
                .newline, .semicolon => if (depth == 0) return,
                .left_brace, .left_paren, .left_bracket => depth += 1,
                .right_brace => {
                    if (depth == 0) return;
                    depth -= 1;
                },
                .right_paren, .right_bracket => depth -|= 1,
                else => {},
            }
            _ = parser.advance();
        }
    }

    fn parseGlobalStatement(parser: *Parser) ParseError!ast.Statement {
        switch (parser.peekTag()) {
            .keyword_data => return parser.fail(parser.peek(), "data declarations are not supported yet", .{}),
            .keyword_main => {
                if (parser.peekTagAfter(1) == .double_colon) return parser.parseSignature();
                const main_token = parser.advance();
                _ = try parser.expect(.equals, "'=' after 'main'");
                const definition = try parser.allocator.create(ast.Definition);
                definition.* = .{
                    .source_offset = main_token.source_offset,
                    .name = "main",
                    .parameters = &.{},
                    .body = try parser.parseExpression(),
                };
                return .{ .definition = definition };
            },
            else => {
                if (parser.peekIsIdentifier() and parser.peekTagAfter(1) == .double_colon) return parser.parseSignature();
                return parser.parseLocalStatement();
            },
        }
    }

    fn parseLocalStatement(parser: *Parser) ParseError!ast.Statement {
        if (parser.peekIsIdentifier() and parser.isDefinitionAhead()) {
            return .{ .definition = try parser.parseDefinition() };
        }
        return .{ .expression = try parser.parseExpression() };
    }

    fn peekIsIdentifier(parser: *const Parser) bool {
        const token = parser.peek();
        return token.tag == .word and token.is_plain and lexer.classifyPlainWord(token.plainText()) == .identifier;
    }

    /// True when `=` appears before the end of the statement outside
    /// brackets: `f x = ...` is a definition, `f x` an expression.
    fn isDefinitionAhead(parser: *const Parser) bool {
        var depth: usize = 0;
        for (parser.tokens[parser.index..]) |token| {
            switch (token.tag) {
                .equals => if (depth == 0) return true,
                .left_brace, .left_paren, .left_bracket => depth += 1,
                .right_brace, .right_paren, .right_bracket => {
                    if (depth == 0) return false;
                    depth -= 1;
                },
                .newline, .semicolon, .end_of_input => if (depth == 0) return false,
                else => {},
            }
        }
        return false;
    }

    fn parseDefinition(parser: *Parser) ParseError!*ast.Definition {
        const name_token = parser.advance();
        const name = try parser.checkedName(name_token);
        var parameters: std.ArrayList(ast.Parameter) = .empty;
        while (parser.peekTag() != .equals) {
            try parameters.append(parser.allocator, try parser.parseParameter("a parameter name or '='"));
        }
        _ = parser.advance();
        const definition = try parser.allocator.create(ast.Definition);
        definition.* = .{
            .source_offset = name_token.source_offset,
            .name = name,
            .parameters = try parameters.toOwnedSlice(parser.allocator),
            .body = try parser.parseExpression(),
        };
        return definition;
    }

    fn parseParameter(parser: *Parser, expected: []const u8) ParseError!ast.Parameter {
        const token = parser.peek();
        if (token.tag == .wildcard) {
            _ = parser.advance();
            return .{ .source_offset = token.source_offset, .name = null };
        }
        if (parser.peekIsIdentifier()) {
            _ = parser.advance();
            return .{ .source_offset = token.source_offset, .name = try parser.checkedName(token) };
        }
        return parser.fail(token, "expected {s}, found {s}", .{ expected, lexer.describeTag(token.tag) });
    }

    /// The name of an identifier token; names starting with `__` are reserved.
    fn checkedName(parser: *Parser, token: Token) ParseError![]const u8 {
        const name = token.plainText();
        if (std.mem.startsWith(u8, name, "__")) return parser.fail(token, "names starting with '__' are reserved", .{});
        return name;
    }

    fn parseSignature(parser: *Parser) ParseError!ast.Statement {
        const name_token = parser.advance();
        const name = if (name_token.tag == .keyword_main) "main" else try parser.checkedName(name_token);
        _ = parser.advance(); // `::`
        const signature = try parser.allocator.create(ast.Signature);
        signature.* = .{
            .source_offset = name_token.source_offset,
            .name = name,
            .type_expression = try parser.parseType(),
        };
        return .{ .signature = signature };
    }

    /// `->` is right-associative.
    fn parseType(parser: *Parser) ParseError!*ast.TypeExpression {
        const parameter_type = try parser.parseTypeApplication();
        if (parser.peekTag() != .arrow) return parameter_type;
        _ = parser.advance();
        const result_type = try parser.parseType();
        return parser.newType(.{ .function = .{ .parameter = parameter_type, .result = result_type } });
    }

    fn parseTypeApplication(parser: *Parser) ParseError!*ast.TypeExpression {
        const head = try parser.parseTypeAtom();
        var arguments: std.ArrayList(*ast.TypeExpression) = .empty;
        while (parser.startsTypeAtom()) try arguments.append(parser.allocator, try parser.parseTypeAtom());
        if (arguments.items.len == 0) return head;
        return parser.newType(.{ .application = .{ .head = head, .arguments = try arguments.toOwnedSlice(parser.allocator) } });
    }

    fn startsTypeAtom(parser: *const Parser) bool {
        const token = parser.peek();
        return switch (token.tag) {
            .left_paren, .left_bracket => true,
            .word => token.is_plain and switch (lexer.classifyPlainWord(token.plainText())) {
                .identifier, .constructor => true,
                .integer, .literal => false,
            },
            else => false,
        };
    }

    fn parseTypeAtom(parser: *Parser) ParseError!*ast.TypeExpression {
        const token = parser.peek();
        switch (token.tag) {
            .left_paren => {
                _ = parser.advance();
                const inner = try parser.parseType();
                _ = try parser.expect(.right_paren, "')'");
                return inner;
            },
            .left_bracket => {
                _ = parser.advance();
                const element = try parser.parseType();
                _ = try parser.expect(.right_bracket, "']'");
                return parser.newType(.{ .list = element });
            },
            else => {
                if (!parser.startsTypeAtom()) return parser.fail(token, "expected a type, found {s}", .{lexer.describeTag(token.tag)});
                _ = parser.advance();
                return parser.newType(.{ .named = token.plainText() });
            },
        }
    }

    fn newType(parser: *Parser, type_expression: ast.TypeExpression) Allocator.Error!*ast.TypeExpression {
        const node = try parser.allocator.create(ast.TypeExpression);
        node.* = type_expression;
        return node;
    }

    fn parseExpression(parser: *Parser) ParseError!*ast.Expression {
        return switch (parser.peekTag()) {
            .left_brace => parser.parseBlock(),
            .keyword_match => parser.parseMatch(),
            .lambda => parser.parseLambda(),
            .word, .left_paren, .left_bracket => parser.parseApplication(try parser.parseAtom()),
            else => parser.fail(parser.peek(), "expected an expression, found {s}", .{lexer.describeTag(parser.peekTag())}),
        };
    }

    fn startsAtom(tag: Tag) bool {
        return tag == .word or tag == .left_paren or tag == .left_bracket;
    }

    /// Keywords and `_` are ordinary words when they are arguments
    /// (`git checkout main`); they only mean something at the start of a
    /// statement.
    fn startsArgument(tag: Tag) bool {
        return startsAtom(tag) or tag == .keyword_data or tag == .keyword_main or tag == .keyword_match or tag == .wildcard;
    }

    /// Parses the arguments after `head`, if any. A lambda may be the last
    /// argument without parentheses.
    fn parseApplication(parser: *Parser, head: *ast.Expression) ParseError!*ast.Expression {
        var arguments: std.ArrayList(*ast.Expression) = .empty;
        while (true) {
            const tag = parser.peekTag();
            if (startsArgument(tag)) {
                try arguments.append(parser.allocator, try parser.parseAtom());
            } else if (tag == .lambda) {
                try arguments.append(parser.allocator, try parser.parseLambda());
                break;
            } else break;
        }
        if (arguments.items.len == 0) return head;
        return parser.newExpression(head.source_offset, .{ .call = .{
            .head = head,
            .arguments = try arguments.toOwnedSlice(parser.allocator),
        } });
    }

    /// Callers check `startsArgument` (or `startsAtom`) first.
    fn parseAtom(parser: *Parser) ParseError!*ast.Expression {
        const token = parser.advance();
        switch (token.tag) {
            .word => return parser.newExpression(token.source_offset, .{ .word = .{
                .parts = token.parts,
                .is_plain = token.is_plain,
                .source_length = token.source_length,
            } }),
            .keyword_data, .keyword_main, .keyword_match, .wildcard => {
                const word_text: []const u8 = switch (token.tag) {
                    .keyword_data => "data",
                    .keyword_main => "main",
                    .keyword_match => "match",
                    else => "_",
                };
                const parts = try parser.allocator.alloc(lexer.WordPart, 1);
                parts[0] = .{ .text = word_text };
                return parser.newExpression(token.source_offset, .{ .word = .{
                    .parts = parts,
                    .is_plain = true,
                    .source_length = token.source_length,
                } });
            },
            .left_paren => {
                const inner = try parser.parseExpression();
                _ = try parser.expect(.right_paren, "')'");
                // Inside parentheses a lone plain word is a head: `(ls)`
                // runs `ls`, `(x)` reads `x` once `resolve` sees it is bound.
                if (inner.data == .word and inner.data.word.is_plain) {
                    return parser.newExpression(inner.source_offset, .{ .call = .{ .head = inner, .arguments = &.{} } });
                }
                return inner;
            },
            .left_bracket => {
                var elements: std.ArrayList(*ast.Expression) = .empty;
                if (parser.peekTag() != .right_bracket) {
                    try elements.append(parser.allocator, try parser.parseExpression());
                    while (parser.peekTag() == .comma) {
                        _ = parser.advance();
                        try elements.append(parser.allocator, try parser.parseExpression());
                    }
                }
                _ = try parser.expect(.right_bracket, "',' or ']'");
                return parser.newExpression(token.source_offset, .{ .list = try elements.toOwnedSlice(parser.allocator) });
            },
            else => unreachable,
        }
    }

    fn parseBlock(parser: *Parser) ParseError!*ast.Expression {
        const open_token = parser.advance();
        const statements = try parser.parseSequence(ast.Statement, parseLocalStatement, .right_brace);
        _ = try parser.expect(.right_brace, "'}'");
        return parser.newExpression(open_token.source_offset, .{ .block = statements });
    }

    fn parseMatch(parser: *Parser) ParseError!*ast.Expression {
        const match_token = parser.advance();
        if (!startsAtom(parser.peekTag())) {
            return parser.fail(parser.peek(), "expected what to match on, found {s}", .{lexer.describeTag(parser.peekTag())});
        }
        const starts_with_parenthesis = parser.peekTag() == .left_paren;
        const first_atom = try parser.parseAtom();
        const scrutinee = try parser.parseApplication(first_atom);
        _ = try parser.expect(.left_brace, "'{' to start the match arms");
        const arms = try parser.parseSequence(ast.Arm, parseArm, .right_brace);
        _ = try parser.expect(.right_brace, "'}'");
        return parser.newExpression(match_token.source_offset, .{ .match = .{
            .scrutinee = scrutinee,
            .scrutinee_is_parenthesized = starts_with_parenthesis and scrutinee == first_atom,
            .arms = arms,
        } });
    }

    fn parseArm(parser: *Parser) ParseError!ast.Arm {
        const pattern = try parser.parsePattern();
        _ = try parser.expect(.arrow, "'->' after the pattern");
        return .{ .pattern = pattern, .body = try parser.parseExpression() };
    }

    fn parsePattern(parser: *Parser) ParseError!*ast.Pattern {
        const token = parser.peek();
        if (token.tag == .word and token.is_plain and lexer.classifyPlainWord(token.plainText()) == .constructor) {
            _ = parser.advance();
            var fields: std.ArrayList(*ast.Pattern) = .empty;
            while (startsPatternAtom(parser.peekTag())) try fields.append(parser.allocator, try parser.parsePatternAtom());
            return parser.newPattern(token.source_offset, .{ .constructor = .{
                .name = token.plainText(),
                .fields = try fields.toOwnedSlice(parser.allocator),
            } });
        }
        return parser.parsePatternAtom();
    }

    fn startsPatternAtom(tag: Tag) bool {
        return tag == .word or tag == .wildcard or tag == .left_paren or tag == .left_bracket;
    }

    fn parsePatternAtom(parser: *Parser) ParseError!*ast.Pattern {
        const token = parser.peek();
        switch (token.tag) {
            .wildcard => {
                _ = parser.advance();
                return parser.newPattern(token.source_offset, .wildcard);
            },
            .left_paren => {
                _ = parser.advance();
                const inner = try parser.parsePattern();
                _ = try parser.expect(.right_paren, "')'");
                return inner;
            },
            .left_bracket => {
                _ = parser.advance();
                var elements: std.ArrayList(*ast.Pattern) = .empty;
                if (parser.peekTag() != .right_bracket) {
                    try elements.append(parser.allocator, try parser.parsePattern());
                    while (parser.peekTag() == .comma) {
                        _ = parser.advance();
                        try elements.append(parser.allocator, try parser.parsePattern());
                    }
                }
                _ = try parser.expect(.right_bracket, "',' or ']'");
                return parser.newPattern(token.source_offset, .{ .list = try elements.toOwnedSlice(parser.allocator) });
            },
            .word => {
                _ = parser.advance();
                if (!token.is_plain) {
                    var text: std.ArrayList(u8) = .empty;
                    for (token.parts) |part| switch (part) {
                        .text => |literal_text| try text.appendSlice(parser.allocator, literal_text),
                        .variable => return parser.fail(token, "a pattern cannot contain a variable", .{}),
                    };
                    return parser.newPattern(token.source_offset, .{ .literal_string = try text.toOwnedSlice(parser.allocator) });
                }
                const text = token.plainText();
                switch (lexer.classifyPlainWord(text)) {
                    .identifier => return parser.newPattern(token.source_offset, .{ .binder = try parser.checkedName(token) }),
                    .constructor => return parser.newPattern(token.source_offset, .{ .constructor = .{ .name = text, .fields = &.{} } }),
                    .integer => {
                        const integer = std.fmt.parseInt(i64, text, 10) catch
                            return parser.fail(token, "integer {s} is out of range", .{text});
                        return parser.newPattern(token.source_offset, .{ .literal_integer = integer });
                    },
                    .literal => return parser.newPattern(token.source_offset, .{ .literal_string = text }),
                }
            },
            else => return parser.fail(token, "expected a pattern, found {s}", .{lexer.describeTag(token.tag)}),
        }
    }

    fn parseLambda(parser: *Parser) ParseError!*ast.Expression {
        const lambda_token = parser.advance();
        var parameters: std.ArrayList(ast.Parameter) = .empty;
        try parameters.append(parser.allocator, try parser.parseParameter("a parameter name"));
        while (parser.peekTag() != .arrow) {
            try parameters.append(parser.allocator, try parser.parseParameter("a parameter name or '->'"));
        }
        _ = parser.advance();
        return parser.newExpression(lambda_token.source_offset, .{ .lambda = .{
            .parameters = try parameters.toOwnedSlice(parser.allocator),
            .body = try parser.parseExpression(),
        } });
    }

    fn newExpression(parser: *Parser, source_offset: u32, data: ast.Expression.Data) Allocator.Error!*ast.Expression {
        const expression = try parser.allocator.create(ast.Expression);
        expression.* = .{ .source_offset = source_offset, .data = data };
        return expression;
    }

    fn newPattern(parser: *Parser, source_offset: u32, data: ast.Pattern.Data) Allocator.Error!*ast.Pattern {
        const pattern = try parser.allocator.create(ast.Pattern);
        pattern.* = .{ .source_offset = source_offset, .data = data };
        return pattern;
    }
};

fn expectParse(source_text: []const u8, expected_dump: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var collected: Diagnostics = .init(allocator);
    const tokens = try lexer.tokenize(allocator, source_text, &collected);
    const script = try parse(allocator, tokens, &collected);
    for (collected.items.items) |problem| std.debug.print("unexpected diagnostic: {s}\n", .{problem.message});
    try std.testing.expect(!collected.hasErrors());
    var output: std.Io.Writer.Allocating = .init(allocator);
    try ast.dumpScript(&output.writer, script);
    try std.testing.expectEqualStrings(expected_dump, output.written());
}

fn expectParseErrors(source_text: []const u8, expected_messages: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var collected: Diagnostics = .init(allocator);
    const tokens = try lexer.tokenize(allocator, source_text, &collected);
    _ = try parse(allocator, tokens, &collected);
    try std.testing.expectEqual(expected_messages.len, collected.items.items.len);
    for (expected_messages, collected.items.items) |expected_message, problem| {
        try std.testing.expectEqualStrings(expected_message, problem.message);
    }
}

test "commands and definitions" {
    try expectParse("ip link set dev $name up", "(call ip link set dev \"${name}\" up)\n");
    try expectParse("up name = ip link set dev $name up", "(def up (name) (call ip link set dev \"${name}\" up))\n");
    try expectParse("arch = uname -m", "(def arch () (call uname -m))\n");
    try expectParse("main = {\n  echo hi\n  skip\n}", "(def main () (block (call echo hi) skip))\n");
}

test "keywords and the wildcard are ordinary words as arguments" {
    try expectParse("git checkout main", "(call git checkout main)\n");
    try expectParse("echo data match _", "(call echo data match _)\n");
}

test "match" {
    try expectParse(
        "match ping -c1 $h {\n  Ok -> skip\n  Fail code -> echo $code\n}",
        "(match (call ping -c1 \"${h}\") (Ok -> skip) ((Fail code) -> (call echo \"${code}\")))\n",
    );
    try expectParse(
        "match (uname -m) { \"mips\" -> skip; _ -> skip }",
        "(match (paren (call uname -m)) ('mips' -> skip) (_ -> skip))\n",
    );
}

test "lambdas, parentheses and lists" {
    try expectParse("for xs \\x -> up x", "(call for xs (\\ x -> (call up x)))\n");
    try expectParse("lines (ls)", "(call lines (call ls))\n");
    try expectParse("f [a, b] []", "(call f [a b] [])\n");
}

test "type signatures" {
    try expectParse("wait_for :: String -> Int -> IO Status", "(sig wait_for (-> String (-> Int (IO Status))))\n");
}

test "separators" {
    try expectParse("a; b\n\nc", "a\nb\nc\n");
}

test "syntax errors are all reported" {
    try expectParseErrors("data T = A", &.{"data declarations are not supported yet"});
    try expectParseErrors("f (a", &.{"expected ')', found the end of the input"});
    try expectParseErrors("x = )\ny = )", &.{ "expected an expression, found ')'", "expected an expression, found ')'" });
    try expectParseErrors("f { a }", &.{"expected a new line or ';' before '{'"});
    try expectParseErrors("match x { \"$y\" -> skip }", &.{"a pattern cannot contain a variable"});
}
