// Parser — turns a Token stream into a CstNode tree.
//
// Recursive descent. Every Token from the input stream lands somewhere in
// the produced tree — error recovery wraps unrecognised runs in `Error`
// subtrees rather than dropping tokens, so the formatter can still
// round-trip broken source. Diagnostics accumulate on `self.diagnostics`
// for tooling to consume.
//
// Module
//   ImportDecl* | Directive* + (FunctionDecl | StructDecl | EnumDecl |
//                               TypeAliasDecl | TestDecl |
//                               GeneratorDef | GeneratorInvocation |
//                               VariableDecl /* const */ | Error)
//   Eof token

import std.allocator
import std.list
import std.option
import std.string
import std.string_builder
import flang_parser.token
import flang_parser.lexer
import flang_parser.cst
import flang_parser.trivia
import flang_core.diagnostic
import flang_core.span

// Internal builder for an in-progress CST node. The parser pushes Tokens
// and finished sub-nodes onto `children`; `start`/`end` track the byte
// span covered so far.
type NodeBuilder = struct {
    kind: NodeKind
    start: usize
    end: usize
    children: List(CstChild)
}

pub type Parser = struct {
    tokens: List(Token)
    position: usize
    // Backs every CST node's child list. Resolved at construction so
    // internal call sites just forward `self.allocator` without
    // re-resolving.
    allocator: &Allocator
    // Accumulated parse-time diagnostics. The parser never throws — it
    // records an error here, recovers, and keeps going. Callers may
    // read after `parse_module()`.
    diagnostics: List(Diagnostic)
    // SourceSpan file id used in recorded diagnostics. Default `-1`
    // (none); CLI/LSP callers overwrite this before calling
    // `parse_module()` so spans reach back to the source.
    file_id: i32
    // True while parsing the condition of an `if`/`for`/`while` without
    // parens — `{` then terminates the expression instead of starting a
    // struct construction or block literal.
    stop_at_brace: bool
}

// Construct a Parser over the given token list. The list is borrowed
// — every CST node will reference the original tokens, so `tokens`
// must outlive the produced tree. `allocator` backs every CST child
// list and the diagnostics list; pass `null` to default to the global
// allocator (resolved once here via `or_global()`).
pub fn parser(tokens: List(Token), allocator: &Allocator? = null) Parser {
    const a = allocator.or_global()
    return .{
        tokens = tokens,
        position = 0,
        allocator = a,
        diagnostics = list(0, a),
        file_id = -1,
        stop_at_brace = false,
    }
}

// Release the parser's diagnostics list. The token list is borrowed
// from the caller and is NOT freed here. Each `Diagnostic` owns its
// `message` / `hint` OwnedStrings — those are freed by the list's
// element walk inside `deinit()`.
pub fn deinit(self: &Parser) {
    self.diagnostics.deinit()
}

// ─────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────

fn current(self: &Parser) Token {
    if self.position < self.tokens.len {
        return self.tokens[self.position]
    }
    // Past Eof — should not happen if the lexer terminates with Eof — but
    // synthesise one as a guard so misuse doesn't index out of bounds.
    return synth_eof(self)
}

fn synth_eof(self: &Parser) Token {
    if self.tokens.len > 0 {
        return self.tokens[self.tokens.len - 1]
    }
    // Zero-token input — caller misuse. Hand back a degenerate Eof.
    let zero: usize = 0
    return Token {
        kind = TokenKind.Eof,
        text = "",
        offset = 0,
        line = 0,
        leading = slice_from_raw_parts(zero as &Trivia, 0),
        trailing = slice_from_raw_parts(zero as &Trivia, 0),
        allocator = self.allocator,
    }
}

fn current_kind(self: &Parser) TokenKind {
    return self.current().kind
}

fn at_eof(self: &Parser) bool {
    return self.current_kind() == TokenKind.Eof
}

fn peek_kind(self: &Parser, ahead: usize) TokenKind {
    const idx = self.position + ahead
    if idx < self.tokens.len {
        return self.tokens[idx].kind
    }
    return TokenKind.Eof
}

fn eat(self: &Parser) Token {
    const tok = self.current()
    if self.position < self.tokens.len and tok.kind != TokenKind.Eof {
        self.position = self.position + 1
    }
    return tok
}

fn token_end(tok: Token) usize {
    return tok.offset + tok.text.len
}

fn open(self: &Parser, kind: NodeKind) NodeBuilder {
    const tok = self.current()
    return .{
        kind = kind,
        start = tok.offset,
        end = tok.offset,
        children = list(4, self.allocator),
    }
}

fn finish(b: NodeBuilder) CstNode {
    return .{
        kind = b.kind,
        start = b.start,
        end = b.end,
        children = b.children,
    }
}

fn eat_into(self: &Parser, b: &NodeBuilder) {
    const tok = self.eat()
    const te = token_end(tok)
    if te > b.end { b.end = te }
    b.children.push(CstChild.TokenChild(tok))
}

fn push_node_into(b: &NodeBuilder, node: CstNode) {
    if node.end > b.end { b.end = node.end }
    b.children.push(CstChild.NodeChild(node))
}

// If the current token matches `kind`, eat it into `b` and return true.
// Otherwise record a diagnostic against the current token (or last
// position, if at Eof) and return false WITHOUT advancing.
fn expect_into(self: &Parser, b: &NodeBuilder, kind: TokenKind, code: String) bool {
    if self.current_kind() == kind {
        self.eat_into(b)
        return true
    }
    self.record_expected(kind, code)
    return false
}

fn record_expected(self: &Parser, kind: TokenKind, code: String) {
    const tok = self.current()
    const msg = $"expected `{kind.to_string()}`, found `{tok.text}`"
    self.record_error_at(code, msg, tok.offset, tok.text.len)
}

fn record_error_at(self: &Parser, code: String, message: OwnedString, start: usize, length: usize) {
    const sp: SourceSpan = .{ file_id = self.file_id, start = start, length = length }
    self.diagnostics.push(error(code, message, sp))
}

fn record_error_here(self: &Parser, code: String, message: OwnedString) {
    const tok = self.current()
    self.record_error_at(code, message, tok.offset, tok.text.len)
}

// ─────────────────────────────────────────────────────────────────────────
// Module
// ─────────────────────────────────────────────────────────────────────────

// Parse the entire token stream as a top-level module: imports,
// declarations, tests. Always returns a `Module` CST node, even on
// malformed input — bad subtrees are wrapped in `NodeKind.Error` so
// the formatter and CST consumers can still round-trip the source.
// Consumes every token up to and including `Eof`.
pub fn parse_module(self: &Parser) CstNode {
    let b = self.open(NodeKind.Module)

    // Imports come first (per known-issues: parser only accepts them at
    // the top). Both `import …` and `pub import …`.
    loop {
        if self.at_eof() { break }
        const k = self.current_kind()
        if k == TokenKind.Import {
            const node = self.parse_import()
            push_node_into(&b, node)
            continue
        }
        if k == TokenKind.Pub and self.peek_kind(1) == TokenKind.Import {
            const node = self.parse_import()
            push_node_into(&b, node)
            continue
        }
        break
    }

    // Declarations until Eof.
    loop {
        if self.at_eof() { break }
        const node = self.parse_top_level()
        push_node_into(&b, node)
    }

    // Trailing Eof token rounds out the module — consume it into the
    // node so trailing trivia attached to it is preserved.
    if self.current_kind() == TokenKind.Eof {
        self.eat_into(&b)
    }

    return finish(b)
}

// Parse one top-level item: directives + (fn | type | test | const |
// generator def/invocation). On unexpected input, wraps the offending
// run in an `Error` node so progress is guaranteed.
fn parse_top_level(self: &Parser) CstNode {
    // Generator def `#define(...)` and generator invocation `#name(...)`
    // are recognised before generic-directive parsing because they take
    // no leading directives themselves.
    if self.current_kind() == TokenKind.Hash {
        const next = self.peek_kind(1)
        if next == TokenKind.Identifier {
            const ident = self.tokens[self.position + 1].text
            if ident == "define" { return self.parse_generator_def() }
            if !is_known_directive(ident) and self.peek_kind(2) == TokenKind.OpenParenthesis {
                return self.parse_generator_invocation()
            }
        }
    }

    // Collect leading directives. We push them as children of whatever
    // declaration follows, so open a tentative builder and decide its
    // final kind after we see the decl starter.
    let leading: List(CstNode) = list(0, self.allocator)
    while self.current_kind() == TokenKind.Hash {
        const d = self.parse_directive()
        leading.push(d)
    }

    const k = self.current_kind()

    if k == TokenKind.Pub {
        const next = self.peek_kind(1)
        if next == TokenKind.Fn { return self.parse_function_with_directives(leading) }
        if next == TokenKind.Type { return self.parse_type_decl_with_directives(leading) }
        if next == TokenKind.Const { return self.parse_variable_decl_with_directives(leading) }
        if next == TokenKind.Import {
            // `pub import` should have been consumed in parse_module's
            // header. If it reaches us, hoist it anyway — but it counts
            // as an out-of-order import.
            self.record_error_here(
                "E1003",
                $"imports must precede declarations")
            return self.parse_import()
        }
        // Unknown form after `pub` — recover by wrapping the run in Error.
        return self.recover_unexpected_top_level(leading)
    }

    if k == TokenKind.Fn { return self.parse_function_with_directives(leading) }
    if k == TokenKind.Type { return self.parse_type_decl_with_directives(leading) }
    if k == TokenKind.Test { return self.parse_test_with_directives(leading) }
    if k == TokenKind.Const or k == TokenKind.Let {
        return self.parse_variable_decl_with_directives(leading)
    }

    return self.recover_unexpected_top_level(leading)
}

// Names that bind as plain `Directive` rather than `GeneratorInvocation`
// at top level. Mirrors the C# stage-0 parser's `_knownDirectiveNames`.
// Everything else (`#interface`, `#implement`, `#derive`, `#enum_utils`,
// `#string_reader`, …) routes through generator invocation.
fn is_known_directive(name: String) bool {
    return name == "foreign"
        or name == "inline"
        or name == "deprecated"
        or name == "simd"
}

fn recover_unexpected_top_level(self: &Parser, leading: List(CstNode)) CstNode {
    let b = self.open(NodeKind.Error)
    for i in 0..leading.len {
        push_node_into(&b, leading[i])
    }
    const msg = $"unexpected `{self.current().text}` at top level"
    self.record_error_here("E1001", msg)
    // Consume until we hit a recognisable top-level starter.
    loop {
        if self.at_eof() { break }
        if self.is_top_level_starter() { break }
        self.eat_into(&b)
    }
    leading.deinit()
    return finish(b)
}

fn is_top_level_starter(self: &Parser) bool {
    const k = self.current_kind()
    return k == TokenKind.Pub
        or k == TokenKind.Fn
        or k == TokenKind.Type
        or k == TokenKind.Test
        or k == TokenKind.Const
        or k == TokenKind.Let
        or k == TokenKind.Import
        or k == TokenKind.Hash
}

// ─────────────────────────────────────────────────────────────────────────
// Imports
// ─────────────────────────────────────────────────────────────────────────

fn parse_import(self: &Parser) CstNode {
    let b = self.open(NodeKind.ImportDecl)
    if self.current_kind() == TokenKind.Pub { self.eat_into(&b) }
    self.expect_into(&b, TokenKind.Import, "E1002")
    self.eat_identifier_or_keyword(&b)
    while self.current_kind() == TokenKind.Dot {
        self.eat_into(&b)
        self.eat_identifier_or_keyword(&b)
    }
    return finish(b)
}

// Any identifier or keyword is accepted as a path component (so a
// module named `as` or `match` is still importable).
fn eat_identifier_or_keyword(self: &Parser, b: &NodeBuilder) {
    const k = self.current_kind()
    if k == TokenKind.Identifier or is_keyword(k) {
        self.eat_into(b)
        return
    }
    self.record_expected(TokenKind.Identifier, "E1002")
}

// ─────────────────────────────────────────────────────────────────────────
// Directives
// ─────────────────────────────────────────────────────────────────────────

// `#name` or `#name(arg, arg, ...)`. Args inside parens are parsed
// loosely — any tokens until matched `)` are accepted, since directive
// arguments cover identifiers, literals, types, and anonymous-struct
// shapes.
fn parse_directive(self: &Parser) CstNode {
    let b = self.open(NodeKind.Directive)
    self.expect_into(&b, TokenKind.Hash, "E1002")
    if self.current_kind() == TokenKind.Identifier {
        self.eat_into(&b)
    } else {
        self.record_expected(TokenKind.Identifier, "E1002")
    }
    if self.current_kind() == TokenKind.OpenParenthesis {
        self.consume_balanced(&b, TokenKind.OpenParenthesis, TokenKind.CloseParenthesis)
    }
    return finish(b)
}

// Eat the opener, then every token until the matching closer (tracking
// nesting on the SAME pair). Used for directive arg lists and generator
// template bodies where the inner grammar isn't structurally important
// to the CST.
fn consume_balanced(self: &Parser, b: &NodeBuilder, open_kind: TokenKind, close_kind: TokenKind) {
    if self.current_kind() != open_kind {
        self.record_expected(open_kind, "E1002")
        return
    }
    self.eat_into(b)
    let depth: usize = 1
    loop {
        if self.at_eof() { break }
        const k = self.current_kind()
        if k == open_kind {
            depth = depth + 1
            self.eat_into(b)
            continue
        }
        if k == close_kind {
            depth = depth - 1
            self.eat_into(b)
            if depth == 0 { break }
            continue
        }
        self.eat_into(b)
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Generator definitions / invocations
// ─────────────────────────────────────────────────────────────────────────

// `#define(name, Param: Kind, ...) { template body }`. Args list is
// consumed structurally; body is captured as one balanced-brace run.
fn parse_generator_def(self: &Parser) CstNode {
    let b = self.open(NodeKind.GeneratorDef)
    self.eat_into(&b)                                                       // `#`
    self.eat_into(&b)                                                       // `define`
    if self.current_kind() == TokenKind.OpenParenthesis {
        self.consume_balanced(&b, TokenKind.OpenParenthesis, TokenKind.CloseParenthesis)
    }
    if self.current_kind() == TokenKind.OpenBrace {
        self.consume_balanced(&b, TokenKind.OpenBrace, TokenKind.CloseBrace)
    }
    return finish(b)
}

// `#name(args)` standalone at top level (not preceded by `#define`,
// and `name` not in the known-directive set). Arguments captured
// balanced — same shape as a directive call.
fn parse_generator_invocation(self: &Parser) CstNode {
    let b = self.open(NodeKind.GeneratorInvocation)
    self.eat_into(&b)                                                       // `#`
    self.eat_into(&b)                                                       // identifier
    if self.current_kind() == TokenKind.OpenParenthesis {
        self.consume_balanced(&b, TokenKind.OpenParenthesis, TokenKind.CloseParenthesis)
    }
    return finish(b)
}

// ─────────────────────────────────────────────────────────────────────────
// Functions
// ─────────────────────────────────────────────────────────────────────────

fn parse_function_with_directives(self: &Parser, leading: List(CstNode)) CstNode {
    let b = self.open(NodeKind.FunctionDecl)
    for i in 0..leading.len { push_node_into(&b, leading[i]) }
    leading.deinit()
    self.parse_function_into(&b)
    return finish(b)
}

// Function body builder — fills `b` with: [pub] fn name(params) ret_type? { body }
// or [pub] fn name(params) ret_type (no body, for `#foreign`).
fn parse_function_into(self: &Parser, b: &NodeBuilder) {
    if self.current_kind() == TokenKind.Pub { self.eat_into(b) }
    self.expect_into(b, TokenKind.Fn, "E1002")
    if self.current_kind() == TokenKind.Identifier {
        self.eat_into(b)
    } else {
        self.record_expected(TokenKind.Identifier, "E1002")
    }
    self.parse_function_params(b)
    if self.can_start_type(self.current_kind()) {
        const t = self.parse_type()
        push_node_into(b, t)
    }
    if self.current_kind() == TokenKind.OpenBrace {
        const body = self.parse_block_expr()
        push_node_into(b, body)
    }
    // No body? Foreign functions go without one — that's fine, we just
    // stop here. Anything else (a stray statement) bubbles up to the
    // top-level error recovery.
}

fn parse_function_params(self: &Parser, b: &NodeBuilder) {
    if !self.expect_into(b, TokenKind.OpenParenthesis, "E1002") { return }
    while !self.at_eof() and self.current_kind() != TokenKind.CloseParenthesis {
        const param = self.parse_function_param()
        push_node_into(b, param)
        if self.current_kind() == TokenKind.Comma {
            self.eat_into(b)
            continue
        }
        if self.current_kind() != TokenKind.CloseParenthesis { break }
    }
    self.expect_into(b, TokenKind.CloseParenthesis, "E1002")
}

fn parse_function_param(self: &Parser) CstNode {
    let b = self.open(NodeKind.FunctionParam)
    // Variadic prefix `..`
    if self.current_kind() == TokenKind.DotDot { self.eat_into(&b) }
    if self.current_kind() == TokenKind.Identifier {
        self.eat_into(&b)
    } else {
        self.record_expected(TokenKind.Identifier, "E1002")
    }
    self.expect_into(&b, TokenKind.Colon, "E1002")
    const t = self.parse_type()
    push_node_into(&b, t)
    // Optional default value
    if self.current_kind() == TokenKind.Equals {
        self.eat_into(&b)
        const def = self.parse_expression()
        push_node_into(&b, def)
    }
    return finish(b)
}

// True when the current token can begin a type expression. Used to
// decide whether a function declaration has an explicit return type.
fn can_start_type(self: &Parser, k: TokenKind) bool {
    return k == TokenKind.Identifier
        or k == TokenKind.Ampersand
        or k == TokenKind.Dollar
        or k == TokenKind.OpenBracket
        or k == TokenKind.OpenParenthesis
        or k == TokenKind.Fn
        or k == TokenKind.Struct
        or k == TokenKind.Enum
}

// ─────────────────────────────────────────────────────────────────────────
// Type declarations
// ─────────────────────────────────────────────────────────────────────────

fn parse_type_decl_with_directives(self: &Parser, leading: List(CstNode)) CstNode {
    // We don't know yet whether the rhs is `struct` or `enum`, so open
    // with a placeholder kind and rewrite it once we see the `=` rhs.
    let b = self.open(NodeKind.TypeAliasDecl)
    for i in 0..leading.len { push_node_into(&b, leading[i]) }
    leading.deinit()
    if self.current_kind() == TokenKind.Pub { self.eat_into(&b) }
    self.expect_into(&b, TokenKind.Type, "E1002")
    if self.current_kind() == TokenKind.Identifier {
        self.eat_into(&b)
    } else {
        self.record_expected(TokenKind.Identifier, "E1002")
    }
    self.expect_into(&b, TokenKind.Equals, "E1002")
    // Inline directives on the rhs (e.g. `type X = #foreign struct {...}`).
    while self.current_kind() == TokenKind.Hash {
        const d = self.parse_directive()
        push_node_into(&b, d)
    }
    const k = self.current_kind()
    if k == TokenKind.Struct {
        b.kind = NodeKind.StructDecl
        self.eat_into(&b)
        self.parse_struct_body_into(&b)
    } else if k == TokenKind.Enum {
        b.kind = NodeKind.EnumDecl
        self.eat_into(&b)
        self.parse_enum_body_into(&b)
    } else {
        // Plain alias `type T = OtherType` — parse a type expression.
        const t = self.parse_type()
        push_node_into(&b, t)
    }
    return finish(b)
}

fn parse_struct_body_into(self: &Parser, b: &NodeBuilder) {
    // Optional generic params `(T1, T2)`.
    if self.current_kind() == TokenKind.OpenParenthesis {
        self.consume_balanced(b, TokenKind.OpenParenthesis, TokenKind.CloseParenthesis)
    }
    if !self.expect_into(b, TokenKind.OpenBrace, "E1002") { return }
    while !self.at_eof() and self.current_kind() != TokenKind.CloseBrace {
        const field = self.parse_struct_field()
        push_node_into(b, field)
        if self.current_kind() == TokenKind.Comma { self.eat_into(b) }
    }
    self.expect_into(b, TokenKind.CloseBrace, "E1002")
}

fn parse_struct_field(self: &Parser) CstNode {
    let b = self.open(NodeKind.StructField)
    if self.current_kind() == TokenKind.Identifier {
        self.eat_into(&b)
    } else {
        self.record_expected(TokenKind.Identifier, "E1002")
        // Skip to next comma / `}` to make progress.
        loop {
            if self.at_eof() { break }
            const k = self.current_kind()
            if k == TokenKind.Comma or k == TokenKind.CloseBrace { break }
            self.eat_into(&b)
        }
        return finish(b)
    }
    self.expect_into(&b, TokenKind.Colon, "E1002")
    const t = self.parse_type()
    push_node_into(&b, t)
    return finish(b)
}

fn parse_enum_body_into(self: &Parser, b: &NodeBuilder) {
    if self.current_kind() == TokenKind.OpenParenthesis {
        self.consume_balanced(b, TokenKind.OpenParenthesis, TokenKind.CloseParenthesis)
    }
    if !self.expect_into(b, TokenKind.OpenBrace, "E1002") { return }
    while !self.at_eof() and self.current_kind() != TokenKind.CloseBrace {
        const variant = self.parse_enum_variant()
        push_node_into(b, variant)
        if self.current_kind() == TokenKind.Comma { self.eat_into(b) }
    }
    self.expect_into(b, TokenKind.CloseBrace, "E1002")
}

fn parse_enum_variant(self: &Parser) CstNode {
    let b = self.open(NodeKind.EnumVariant)
    if self.current_kind() == TokenKind.Identifier {
        self.eat_into(&b)
    } else {
        self.record_expected(TokenKind.Identifier, "E1002")
        return finish(b)
    }
    // Payload types `(T1, T2)`.
    if self.current_kind() == TokenKind.OpenParenthesis {
        self.eat_into(&b)
        while !self.at_eof() and self.current_kind() != TokenKind.CloseParenthesis {
            const t = self.parse_type()
            push_node_into(&b, t)
            if self.current_kind() == TokenKind.Comma { self.eat_into(&b) }
            else if self.current_kind() != TokenKind.CloseParenthesis { break }
        }
        self.expect_into(&b, TokenKind.CloseParenthesis, "E1002")
    }
    // Explicit tag `= <int>` or `= -<int>`.
    if self.current_kind() == TokenKind.Equals {
        self.eat_into(&b)
        if self.current_kind() == TokenKind.Minus { self.eat_into(&b) }
        if self.current_kind() == TokenKind.Integer { self.eat_into(&b) }
    }
    return finish(b)
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

fn parse_test_with_directives(self: &Parser, leading: List(CstNode)) CstNode {
    let b = self.open(NodeKind.TestDecl)
    for i in 0..leading.len { push_node_into(&b, leading[i]) }
    leading.deinit()
    self.expect_into(&b, TokenKind.Test, "E1002")
    if self.current_kind() == TokenKind.StringLiteral {
        self.eat_into(&b)
    } else {
        self.record_expected(TokenKind.StringLiteral, "E1002")
    }
    if self.current_kind() == TokenKind.OpenBrace {
        const body = self.parse_block_expr()
        push_node_into(&b, body)
    }
    return finish(b)
}

// ─────────────────────────────────────────────────────────────────────────
// Variable declarations (let / const)
// ─────────────────────────────────────────────────────────────────────────

fn parse_variable_decl_with_directives(self: &Parser, leading: List(CstNode)) CstNode {
    let b = self.open(NodeKind.VariableDecl)
    for i in 0..leading.len { push_node_into(&b, leading[i]) }
    leading.deinit()
    self.parse_variable_decl_into(&b)
    return finish(b)
}

fn parse_variable_decl_into(self: &Parser, b: &NodeBuilder) {
    if self.current_kind() == TokenKind.Pub { self.eat_into(b) }
    const k = self.current_kind()
    if k == TokenKind.Let or k == TokenKind.Const {
        self.eat_into(b)
    } else {
        self.record_expected(TokenKind.Let, "E1002")
    }
    if self.current_kind() == TokenKind.Identifier {
        self.eat_into(b)
    } else {
        self.record_expected(TokenKind.Identifier, "E1002")
    }
    if self.current_kind() == TokenKind.Colon {
        self.eat_into(b)
        const t = self.parse_type()
        push_node_into(b, t)
    }
    if self.current_kind() == TokenKind.Equals {
        self.eat_into(b)
        const init = self.parse_expression()
        push_node_into(b, init)
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Statements
// ─────────────────────────────────────────────────────────────────────────

// `{ … }` block expression with a sequence of statements and an
// optional trailing expression. Always returns a `BlockExpr` node.
fn parse_block_expr(self: &Parser) CstNode {
    let b = self.open(NodeKind.BlockExpr)
    if !self.expect_into(&b, TokenKind.OpenBrace, "E1002") { return finish(b) }
    while !self.at_eof() and self.current_kind() != TokenKind.CloseBrace {
        const stmt = self.parse_statement()
        push_node_into(&b, stmt)
    }
    self.expect_into(&b, TokenKind.CloseBrace, "E1002")
    return finish(b)
}

fn parse_statement(self: &Parser) CstNode {
    const k = self.current_kind()
    if k == TokenKind.Let or k == TokenKind.Const {
        let b = self.open(NodeKind.VariableDecl)
        self.parse_variable_decl_into(&b)
        self.eat_optional_semicolon(&b)
        return finish(b)
    }
    if k == TokenKind.Type {
        // Local type decl — wrap in TypeAliasDecl (kind may be rewritten
        // by parse_type_decl_with_directives). We bypass directive
        // collection because the spec disallows them on local types.
        let empty: List(CstNode) = list(0, self.allocator)
        return self.parse_type_decl_with_directives(empty)
    }
    if k == TokenKind.Return { return self.parse_return_stmt() }
    if k == TokenKind.Break { return self.parse_single_keyword_stmt(NodeKind.BreakStmt) }
    if k == TokenKind.Continue { return self.parse_single_keyword_stmt(NodeKind.ContinueStmt) }
    if k == TokenKind.Defer { return self.parse_defer_stmt() }
    if k == TokenKind.For { return self.parse_for_loop() }
    if k == TokenKind.Loop { return self.parse_loop_expr() }
    if k == TokenKind.While { return self.parse_while_loop() }
    if k == TokenKind.If { return self.parse_if_expr() }
    if k == TokenKind.OpenBrace { return self.parse_block_expr() }
    if k == TokenKind.Hash {
        // `#if(...) { ... } else { ... }` directive-driven branch.
        if self.peek_kind(1) == TokenKind.If {
            return self.parse_if_directive_stmt()
        }
        // Free-floating directive — treat as a directive node and continue.
        return self.parse_directive()
    }
    // Default: expression statement.
    let b = self.open(NodeKind.ExpressionStmt)
    const expr = self.parse_expression()
    push_node_into(&b, expr)
    self.eat_optional_semicolon(&b)
    return finish(b)
}

fn eat_optional_semicolon(self: &Parser, b: &NodeBuilder) {
    if self.current_kind() == TokenKind.Semicolon { self.eat_into(b) }
}

fn parse_return_stmt(self: &Parser) CstNode {
    let b = self.open(NodeKind.ReturnStmt)
    self.eat_into(&b)                                                       // `return`
    if !self.is_bare_return_terminator() {
        const e = self.parse_expression()
        push_node_into(&b, e)
    }
    self.eat_optional_semicolon(&b)
    return finish(b)
}

fn is_bare_return_terminator(self: &Parser) bool {
    const k = self.current_kind()
    return k == TokenKind.CloseBrace
        or k == TokenKind.Eof
        or k == TokenKind.Semicolon
        or k == TokenKind.Let
        or k == TokenKind.Const
        or k == TokenKind.Return
        or k == TokenKind.Break
        or k == TokenKind.Continue
        or k == TokenKind.Defer
}

fn parse_single_keyword_stmt(self: &Parser, kind: NodeKind) CstNode {
    let b = self.open(kind)
    self.eat_into(&b)
    self.eat_optional_semicolon(&b)
    return finish(b)
}

fn parse_defer_stmt(self: &Parser) CstNode {
    let b = self.open(NodeKind.DeferStmt)
    self.eat_into(&b)                                                       // `defer`
    const e = self.parse_expression()
    push_node_into(&b, e)
    self.eat_optional_semicolon(&b)
    return finish(b)
}

// `#if(cond) { … } [else { … }]`. Condition tokens are consumed
// structurally — the template-expression grammar lives one layer up
// and isn't surfaced in the CST yet.
fn parse_if_directive_stmt(self: &Parser) CstNode {
    let b = self.open(NodeKind.IfDirectiveStmt)
    self.eat_into(&b)                                                       // `#`
    self.eat_into(&b)                                                       // `if`
    if self.current_kind() == TokenKind.OpenParenthesis {
        self.consume_balanced(&b, TokenKind.OpenParenthesis, TokenKind.CloseParenthesis)
    }
    if self.current_kind() == TokenKind.OpenBrace {
        const then_block = self.parse_block_expr()
        push_node_into(&b, then_block)
    }
    if self.current_kind() == TokenKind.Else {
        self.eat_into(&b)
        if self.current_kind() == TokenKind.OpenBrace {
            const else_block = self.parse_block_expr()
            push_node_into(&b, else_block)
        }
    }
    return finish(b)
}

// ─────────────────────────────────────────────────────────────────────────
// Control-flow expressions
// ─────────────────────────────────────────────────────────────────────────

fn parse_if_expr(self: &Parser) CstNode {
    let b = self.open(NodeKind.IfExpr)
    self.eat_into(&b)                                                       // `if`
    if self.current_kind() == TokenKind.OpenParenthesis {
        self.eat_into(&b)
        const cond = self.parse_expression()
        push_node_into(&b, cond)
        self.expect_into(&b, TokenKind.CloseParenthesis, "E1002")
    } else {
        const saved = self.stop_at_brace
        self.stop_at_brace = true
        const cond = self.parse_expression()
        self.stop_at_brace = saved
        push_node_into(&b, cond)
    }
    if self.current_kind() == TokenKind.OpenBrace {
        const then_block = self.parse_block_expr()
        push_node_into(&b, then_block)
    }
    if self.current_kind() == TokenKind.Else {
        self.eat_into(&b)
        if self.current_kind() == TokenKind.If {
            const else_if = self.parse_if_expr()
            push_node_into(&b, else_if)
        } else if self.current_kind() == TokenKind.OpenBrace {
            const else_block = self.parse_block_expr()
            push_node_into(&b, else_block)
        }
    }
    return finish(b)
}

fn parse_for_loop(self: &Parser) CstNode {
    let b = self.open(NodeKind.ForLoopExpr)
    self.eat_into(&b)                                                       // `for`
    if self.current_kind() == TokenKind.Identifier { self.eat_into(&b) }
    self.expect_into(&b, TokenKind.In, "E1002")
    const saved = self.stop_at_brace
    self.stop_at_brace = true
    const iterable = self.parse_expression()
    self.stop_at_brace = saved
    push_node_into(&b, iterable)
    if self.current_kind() == TokenKind.OpenBrace {
        const body = self.parse_block_expr()
        push_node_into(&b, body)
    }
    return finish(b)
}

fn parse_loop_expr(self: &Parser) CstNode {
    let b = self.open(NodeKind.LoopExpr)
    self.eat_into(&b)                                                       // `loop`
    if self.current_kind() == TokenKind.OpenBrace {
        const body = self.parse_block_expr()
        push_node_into(&b, body)
    }
    return finish(b)
}

fn parse_while_loop(self: &Parser) CstNode {
    let b = self.open(NodeKind.WhileExpr)
    self.eat_into(&b)                                                       // `while`
    if self.current_kind() == TokenKind.OpenParenthesis {
        self.eat_into(&b)
        const cond = self.parse_expression()
        push_node_into(&b, cond)
        self.expect_into(&b, TokenKind.CloseParenthesis, "E1002")
    } else {
        const saved = self.stop_at_brace
        self.stop_at_brace = true
        const cond = self.parse_expression()
        self.stop_at_brace = saved
        push_node_into(&b, cond)
    }
    if self.current_kind() == TokenKind.OpenBrace {
        const body = self.parse_block_expr()
        push_node_into(&b, body)
    }
    return finish(b)
}

// `expr match { pat => result, ... }` — postfix, parsed after a unary
// expression in parse_binary_expression. `scrutinee` is the left-hand
// side; this method consumes the `match` keyword and arms.
fn parse_match_tail(self: &Parser, scrutinee: CstNode) CstNode {
    let b = self.open(NodeKind.MatchExpr)
    // Re-anchor `start` to scrutinee since the open() above pointed at
    // `match`.
    b.start = scrutinee.start
    push_node_into(&b, scrutinee)
    self.eat_into(&b)                                                       // `match`
    if !self.expect_into(&b, TokenKind.OpenBrace, "E1002") { return finish(b) }
    while !self.at_eof() and self.current_kind() != TokenKind.CloseBrace {
        const arm = self.parse_match_arm()
        push_node_into(&b, arm)
        if self.current_kind() == TokenKind.Comma { self.eat_into(&b) }
    }
    self.expect_into(&b, TokenKind.CloseBrace, "E1002")
    return finish(b)
}

// Pattern is parsed as a token run up to the `=>` arrow (with optional
// `if guard`) — full pattern grammar (RFC-010) isn't structurally
// surfaced yet, but every token stays accounted for.
fn parse_match_arm(self: &Parser) CstNode {
    let b = self.open(NodeKind.MatchArm)
    loop {
        if self.at_eof() { break }
        const k = self.current_kind()
        if k == TokenKind.FatArrow { break }
        if k == TokenKind.CloseBrace { break }
        if k == TokenKind.Comma { break }
        // `if cond` guard — eat `if` then parse a regular expression so
        // the guard sits in the arm with full structure preserved.
        if k == TokenKind.If {
            self.eat_into(&b)
            const guard = self.parse_expression()
            push_node_into(&b, guard)
            continue
        }
        // Balance any nested parens/brackets/braces inside the pattern
        // (e.g. `Some(x)` payload or `Point { x, y }` struct pattern).
        if k == TokenKind.OpenParenthesis {
            self.consume_balanced(&b, TokenKind.OpenParenthesis, TokenKind.CloseParenthesis)
            continue
        }
        if k == TokenKind.OpenBracket {
            self.consume_balanced(&b, TokenKind.OpenBracket, TokenKind.CloseBracket)
            continue
        }
        if k == TokenKind.OpenBrace {
            self.consume_balanced(&b, TokenKind.OpenBrace, TokenKind.CloseBrace)
            continue
        }
        self.eat_into(&b)
    }
    if self.current_kind() == TokenKind.FatArrow {
        self.eat_into(&b)
        const rhs = self.parse_arm_body()
        push_node_into(&b, rhs)
    }
    return finish(b)
}

// Match arm RHS — accepts `return expr`, bare `break` / `continue`, a
// block expression, or a plain expression. These divergent forms are
// expressions of type `never` in spec terms but the recursive-descent
// path through parse_expression doesn't enter them directly.
fn parse_arm_body(self: &Parser) CstNode {
    const k = self.current_kind()
    if k == TokenKind.Return { return self.parse_return_stmt() }
    if k == TokenKind.Break { return self.parse_single_keyword_stmt(NodeKind.BreakStmt) }
    if k == TokenKind.Continue { return self.parse_single_keyword_stmt(NodeKind.ContinueStmt) }
    if k == TokenKind.OpenBrace { return self.parse_block_expr() }
    return self.parse_expression()
}

// ─────────────────────────────────────────────────────────────────────────
// Expressions — Pratt parser
// ─────────────────────────────────────────────────────────────────────────

pub fn parse_expression(self: &Parser) CstNode {
    return self.parse_binary_expression(0i32)
}

fn parse_binary_expression(self: &Parser, parent_precedence: i32) CstNode {
    let left = self.parse_unary_expression()
    left = self.parse_postfix_chain(left)
    // Cast chain `expr as Type as Type`.
    while self.current_kind() == TokenKind.As {
        let b = self.open(NodeKind.CastExpr)
        b.start = left.start
        push_node_into(&b, left)
        self.eat_into(&b)                                                   // `as`
        const t = self.parse_type()
        push_node_into(&b, t)
        left = finish(b)
    }
    // Postfix `match`.
    if self.current_kind() == TokenKind.Match {
        left = self.parse_match_tail(left)
    }

    loop {
        const k = self.current_kind()
        // Assignment is right-associative and only at the top level — we
        // detect it here before falling through to the precedence ladder.
        if k == TokenKind.Equals and parent_precedence == 0i32 {
            let b = self.open(NodeKind.AssignmentExpr)
            b.start = left.start
            push_node_into(&b, left)
            self.eat_into(&b)
            const rhs = self.parse_expression()
            push_node_into(&b, rhs)
            return finish(b)
        }
        const prec = binary_op_precedence(k)
        if prec == 0i32 or prec <= parent_precedence { break }
        if k == TokenKind.DotDot {
            // Range — right side optional.
            let b = self.open(NodeKind.RangeExpr)
            b.start = left.start
            push_node_into(&b, left)
            self.eat_into(&b)                                               // `..`
            if !is_range_delimiter(self.current_kind()) {
                const r = self.parse_binary_expression(prec)
                push_node_into(&b, r)
            }
            left = finish(b)
            continue
        }
        if k == TokenKind.QuestionQuestion {
            // Right-associative null-coalesce.
            let b = self.open(NodeKind.CoalesceExpr)
            b.start = left.start
            push_node_into(&b, left)
            self.eat_into(&b)
            const rhs = self.parse_binary_expression(prec - 1i32)
            push_node_into(&b, rhs)
            left = finish(b)
            continue
        }
        let b = self.open(NodeKind.BinaryExpr)
        b.start = left.start
        push_node_into(&b, left)
        self.eat_into(&b)                                                   // operator token
        const right = self.parse_binary_expression(prec)
        push_node_into(&b, right)
        left = finish(b)
    }

    return left
}

fn parse_unary_expression(self: &Parser) CstNode {
    const k = self.current_kind()
    if k == TokenKind.Ampersand {
        let b = self.open(NodeKind.AddressOfExpr)
        self.eat_into(&b)
        const inner = self.parse_unary_expression()
        const tail = self.parse_postfix_chain(inner)
        push_node_into(&b, tail)
        return finish(b)
    }
    if k == TokenKind.Minus or k == TokenKind.Bang or k == TokenKind.Tilde {
        let b = self.open(NodeKind.UnaryExpr)
        self.eat_into(&b)
        const inner = self.parse_unary_expression()
        const tail = self.parse_postfix_chain(inner)
        push_node_into(&b, tail)
        return finish(b)
    }
    if k == TokenKind.DotDot {
        // Prefix range `..end` / `..`.
        let b = self.open(NodeKind.RangeExpr)
        self.eat_into(&b)
        if !is_range_delimiter(self.current_kind()) {
            const r = self.parse_binary_expression(0i32)
            push_node_into(&b, r)
        }
        return finish(b)
    }
    return self.parse_primary_expression()
}

fn parse_postfix_chain(self: &Parser, expr: CstNode) CstNode {
    let cur = expr
    loop {
        const k = self.current_kind()
        if k == TokenKind.Dot {
            cur = self.parse_member_or_call_or_deref(cur)
            continue
        }
        if k == TokenKind.QuestionDot {
            let b = self.open(NodeKind.NullPropagationExpr)
            b.start = cur.start
            push_node_into(&b, cur)
            self.eat_into(&b)
            if self.current_kind() == TokenKind.Identifier { self.eat_into(&b) }
            cur = finish(b)
            continue
        }
        if k == TokenKind.OpenBracket {
            let b = self.open(NodeKind.IndexExpr)
            b.start = cur.start
            push_node_into(&b, cur)
            self.eat_into(&b)
            const idx = self.parse_expression()
            push_node_into(&b, idx)
            self.expect_into(&b, TokenKind.CloseBracket, "E1002")
            cur = finish(b)
            continue
        }
        if k == TokenKind.Question {
            let b = self.open(NodeKind.TryExpr)
            b.start = cur.start
            push_node_into(&b, cur)
            self.eat_into(&b)
            cur = finish(b)
            continue
        }
        if k == TokenKind.OpenParenthesis {
            // Call against an expression value (e.g. `(get())(x)`). For
            // simple `name(args)` calls the identifier branch in
            // parse_primary_expression already wraps them — this handles
            // the chained / parenthesised cases.
            let b = self.open(NodeKind.CallExpr)
            b.start = cur.start
            push_node_into(&b, cur)
            self.parse_call_args_into(&b)
            cur = finish(b)
            continue
        }
        break
    }
    return cur
}

// `.field` / `.method(args)` / `.0` (tuple index) / `.*` (deref).
fn parse_member_or_call_or_deref(self: &Parser, recv: CstNode) CstNode {
    const dot_pos = self.position
    self.eat()                                                              // consume `.` (re-added below)
    const next = self.current_kind()
    // `.*` dereference.
    if next == TokenKind.Star {
        self.position = dot_pos                                             // rewind
        let b = self.open(NodeKind.DereferenceExpr)
        b.start = recv.start
        push_node_into(&b, recv)
        self.eat_into(&b)                                                   // `.`
        self.eat_into(&b)                                                   // `*`
        return finish(b)
    }
    // `.0` tuple field access.
    if next == TokenKind.Integer {
        self.position = dot_pos
        let b = self.open(NodeKind.MemberAccessExpr)
        b.start = recv.start
        push_node_into(&b, recv)
        self.eat_into(&b)
        self.eat_into(&b)
        return finish(b)
    }
    // `.identifier` — may be followed by `(args)` for UFCS call.
    if next == TokenKind.Identifier {
        self.position = dot_pos
        let b = self.open(NodeKind.MemberAccessExpr)
        b.start = recv.start
        push_node_into(&b, recv)
        self.eat_into(&b)                                                   // `.`
        self.eat_into(&b)                                                   // identifier
        if self.current_kind() == TokenKind.OpenParenthesis {
            // Promote to UFCS call.
            b.kind = NodeKind.CallExpr
            self.parse_call_args_into(&b)
        }
        return finish(b)
    }
    // Stray `.` — record error and return a member-access shell.
    self.position = dot_pos
    let b = self.open(NodeKind.MemberAccessExpr)
    b.start = recv.start
    push_node_into(&b, recv)
    self.eat_into(&b)
    self.record_error_here("E1002", $"expected identifier, integer, or `*` after `.`")
    return finish(b)
}

fn parse_call_args_into(self: &Parser, b: &NodeBuilder) {
    self.expect_into(b, TokenKind.OpenParenthesis, "E1002")
    while !self.at_eof() and self.current_kind() != TokenKind.CloseParenthesis {
        const arg = self.parse_call_arg()
        push_node_into(b, arg)
        if self.current_kind() == TokenKind.Comma { self.eat_into(b) }
        else if self.current_kind() != TokenKind.CloseParenthesis { break }
    }
    self.expect_into(b, TokenKind.CloseParenthesis, "E1002")
}

// `name = value` becomes a NamedArgumentExpr; otherwise just an expression.
fn parse_call_arg(self: &Parser) CstNode {
    if self.current_kind() == TokenKind.Identifier
        and self.peek_kind(1) == TokenKind.Equals
        and self.peek_kind(2) != TokenKind.Equals {
        let b = self.open(NodeKind.NamedArgumentExpr)
        self.eat_into(&b)                                                   // name
        self.eat_into(&b)                                                   // `=`
        const value = self.parse_expression()
        push_node_into(&b, value)
        return finish(b)
    }
    return self.parse_expression()
}

fn parse_primary_expression(self: &Parser) CstNode {
    const k = self.current_kind()
    if k == TokenKind.Integer { return self.single_token_node(NodeKind.IntegerLiteralExpr) }
    if k == TokenKind.Float { return self.single_token_node(NodeKind.FloatLiteralExpr) }
    if k == TokenKind.StringLiteral { return self.single_token_node(NodeKind.StringLiteralExpr) }
    if k == TokenKind.CharLiteral { return self.single_token_node(NodeKind.CharLiteralExpr) }
    if k == TokenKind.ByteLiteral { return self.single_token_node(NodeKind.ByteLiteralExpr) }
    if k == TokenKind.True or k == TokenKind.False { return self.single_token_node(NodeKind.BooleanLiteralExpr) }
    if k == TokenKind.Null { return self.single_token_node(NodeKind.NullLiteralExpr) }

    if k == TokenKind.Identifier {
        return self.parse_identifier_primary()
    }
    if k == TokenKind.OpenParenthesis {
        return self.parse_paren_expression()
    }
    if k == TokenKind.OpenBracket {
        return self.parse_array_literal()
    }
    if k == TokenKind.OpenBrace {
        if self.stop_at_brace {
            return self.error_token_node(
                "E1001",
                $"unexpected `{{` (block here would shadow control-flow body)")
        }
        return self.parse_block_expr()
    }
    if k == TokenKind.If { return self.parse_if_expr() }
    if k == TokenKind.For { return self.parse_for_loop() }
    if k == TokenKind.Loop { return self.parse_loop_expr() }
    if k == TokenKind.While { return self.parse_while_loop() }
    if k == TokenKind.Fn { return self.parse_lambda_expression() }
    if k == TokenKind.Dot {
        // `.{ ... }` anonymous struct construction.
        if self.peek_kind(1) == TokenKind.OpenBrace {
            return self.parse_anonymous_struct()
        }
        return self.error_token_node(
            "E1001",
            $"unexpected `.` in expression")
    }
    if k == TokenKind.Dollar { return self.parse_interpolated_string() }
    if k == TokenKind.Underscore { return self.single_token_node(NodeKind.IdentifierExpr) }
    if k == TokenKind.InterpStringStart { return self.parse_interp_string_body() }

    return self.error_token_node(
        "E1001",
        $"unexpected token `{self.current().text}` in expression")
}

fn single_token_node(self: &Parser, kind: NodeKind) CstNode {
    let b = self.open(kind)
    self.eat_into(&b)
    return finish(b)
}

fn error_token_node(self: &Parser, code: String, message: OwnedString) CstNode {
    let b = self.open(NodeKind.Error)
    self.record_error_at(code, message, self.current().offset, self.current().text.len)
    self.eat_into(&b)
    return finish(b)
}

// Identifier-starting primaries: bare name, function call, generic call,
// nominal struct construction (`Type { x = 1 }`), or generic struct
// construction (`Type(T) { x = 1 }`).
fn parse_identifier_primary(self: &Parser) CstNode {
    let b = self.open(NodeKind.IdentifierExpr)
    self.eat_into(&b)                                                       // identifier

    if self.current_kind() == TokenKind.OpenBrace and !self.stop_at_brace {
        // `Type { ... }` struct construction.
        b.kind = NodeKind.StructConstructionExpr
        self.parse_struct_construction_body(&b)
        return finish(b)
    }
    if self.current_kind() == TokenKind.OpenParenthesis {
        b.kind = NodeKind.CallExpr
        self.parse_call_args_into(&b)
        if self.current_kind() == TokenKind.OpenBrace and !self.stop_at_brace {
            // Generic struct construction: rewrite as StructConstructionExpr
            // (its first children are the type name and its generic args).
            b.kind = NodeKind.StructConstructionExpr
            self.parse_struct_construction_body(&b)
        }
        return finish(b)
    }
    return finish(b)
}

fn parse_struct_construction_body(self: &Parser, b: &NodeBuilder) {
    if !self.expect_into(b, TokenKind.OpenBrace, "E1002") { return }
    while !self.at_eof() and self.current_kind() != TokenKind.CloseBrace {
        if self.current_kind() == TokenKind.Identifier {
            self.eat_into(b)
            if self.current_kind() == TokenKind.Equals {
                self.eat_into(b)
                const value = self.parse_expression()
                push_node_into(b, value)
            }
            // Shorthand `field` — no `=`, name speaks for itself.
            if self.current_kind() == TokenKind.Comma { self.eat_into(b) }
        } else {
            self.record_expected(TokenKind.Identifier, "E1002")
            // Skip a token to break the loop on malformed input.
            self.eat_into(b)
            if self.current_kind() == TokenKind.Comma { self.eat_into(b) }
        }
    }
    self.expect_into(b, TokenKind.CloseBrace, "E1002")
}

fn parse_anonymous_struct(self: &Parser) CstNode {
    let b = self.open(NodeKind.AnonymousStructExpr)
    self.eat_into(&b)                                                       // `.`
    self.parse_struct_construction_body(&b)
    return finish(b)
}

// `(a)` grouped expression, `(a, b)` tuple, `(a,)` 1-tuple. We don't
// surface different node kinds yet — both become a parenthesised run
// of expressions / commas under one node.
fn parse_paren_expression(self: &Parser) CstNode {
    // Empty `()` → unit.
    if self.peek_kind(1) == TokenKind.CloseParenthesis {
        let b = self.open(NodeKind.TupleType)
        self.eat_into(&b)
        self.eat_into(&b)
        return finish(b)
    }
    let b = self.open(NodeKind.BlockExpr)                                   // placeholder kind
    self.eat_into(&b)                                                       // `(`
    let count = 0usize
    let saw_comma = false
    while !self.at_eof() and self.current_kind() != TokenKind.CloseParenthesis {
        const e = self.parse_expression()
        push_node_into(&b, e)
        count = count + 1
        if self.current_kind() == TokenKind.Comma {
            self.eat_into(&b)
            saw_comma = true
            continue
        }
        break
    }
    self.expect_into(&b, TokenKind.CloseParenthesis, "E1002")
    // Single expression with no trailing comma → grouped; otherwise tuple.
    // We model both as BlockExpr / AnonymousStructExpr respectively —
    // a follow-up may introduce dedicated kinds.
    if saw_comma or count != 1 {
        b.kind = NodeKind.AnonymousStructExpr
    }
    return finish(b)
}

fn parse_array_literal(self: &Parser) CstNode {
    let b = self.open(NodeKind.ArrayLiteralExpr)
    self.eat_into(&b)                                                       // `[`
    while !self.at_eof() and self.current_kind() != TokenKind.CloseBracket {
        const e = self.parse_expression()
        push_node_into(&b, e)
        if self.current_kind() == TokenKind.Comma { self.eat_into(&b) }
        else if self.current_kind() == TokenKind.Semicolon {
            // `[T; N]` size syntax in expression position — preserve it.
            self.eat_into(&b)
            const size_expr = self.parse_expression()
            push_node_into(&b, size_expr)
            break
        }
        else if self.current_kind() != TokenKind.CloseBracket { break }
    }
    self.expect_into(&b, TokenKind.CloseBracket, "E1002")
    return finish(b)
}

fn parse_lambda_expression(self: &Parser) CstNode {
    let b = self.open(NodeKind.LambdaExpr)
    self.eat_into(&b)                                                       // `fn`
    if self.current_kind() == TokenKind.OpenParenthesis {
        self.eat_into(&b)
        while !self.at_eof() and self.current_kind() != TokenKind.CloseParenthesis {
            if self.current_kind() == TokenKind.Identifier { self.eat_into(&b) }
            if self.current_kind() == TokenKind.Colon {
                self.eat_into(&b)
                const t = self.parse_type()
                push_node_into(&b, t)
            }
            if self.current_kind() == TokenKind.Comma { self.eat_into(&b) }
            else if self.current_kind() != TokenKind.CloseParenthesis { break }
        }
        self.expect_into(&b, TokenKind.CloseParenthesis, "E1002")
    }
    if self.can_start_type(self.current_kind()) and self.current_kind() != TokenKind.OpenBrace {
        const t = self.parse_type()
        push_node_into(&b, t)
    }
    if self.current_kind() == TokenKind.OpenBrace {
        const body = self.parse_block_expr()
        push_node_into(&b, body)
    }
    return finish(b)
}

// `$"…"` / `$(args)"…"` / `$ident"…"`. Forms 2 and 3 only resolve when
// the parser drives the lexer one token at a time (see known-issues —
// the bootstrap parser pre-tokenises, so 2 and 3 fall back to plain
// string literals with a leading `$`/`$ident`/`$(args)` run).
fn parse_interpolated_string(self: &Parser) CstNode {
    let b = self.open(NodeKind.InterpolatedStringExpr)
    self.eat_into(&b)                                                       // `$`
    if self.current_kind() == TokenKind.OpenParenthesis {
        self.consume_balanced(&b, TokenKind.OpenParenthesis, TokenKind.CloseParenthesis)
    } else if self.current_kind() == TokenKind.Identifier {
        self.eat_into(&b)
    }
    if self.current_kind() == TokenKind.InterpStringStart {
        self.parse_interp_body_into(&b)
    } else if self.current_kind() == TokenKind.StringLiteral {
        self.eat_into(&b)
    }
    return finish(b)
}

// When the lexer hands us a pre-positioned InterpStringStart (the
// inline `$"…"` form, recognised by adjacency in lex_token_text), we
// parse the body straight in without a wrapping `$`.
fn parse_interp_string_body(self: &Parser) CstNode {
    let b = self.open(NodeKind.InterpolatedStringExpr)
    self.parse_interp_body_into(&b)
    return finish(b)
}

fn parse_interp_body_into(self: &Parser, b: &NodeBuilder) {
    self.eat_into(b)                                                        // InterpStringStart
    loop {
        const k = self.current_kind()
        if k == TokenKind.InterpStringEnd { break }
        if k == TokenKind.Eof or k == TokenKind.BadToken { break }
        if k == TokenKind.InterpSegment {
            self.eat_into(b)
            continue
        }
        if k == TokenKind.InterpHoleStart {
            self.eat_into(b)
            const saved = self.stop_at_brace
            self.stop_at_brace = false
            const expr = self.parse_expression()
            self.stop_at_brace = saved
            push_node_into(b, expr)
            if self.current_kind() == TokenKind.InterpFormatSep {
                self.eat_into(b)
                if self.current_kind() == TokenKind.InterpFormatSpec { self.eat_into(b) }
            }
            if self.current_kind() == TokenKind.InterpHoleEnd { self.eat_into(b) }
            continue
        }
        // Unknown — eat it to keep position progressing.
        self.eat_into(b)
    }
    if self.current_kind() == TokenKind.InterpStringEnd { self.eat_into(b) }
}

// ─────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────

pub fn parse_type(self: &Parser) CstNode {
    const inner = self.parse_prefix_type()
    // Postfix `?` for optional.
    let cur = inner
    while self.current_kind() == TokenKind.Question {
        let b = self.open(NodeKind.OptionalType)
        b.start = cur.start
        push_node_into(&b, cur)
        self.eat_into(&b)
        cur = finish(b)
    }
    return cur
}

fn parse_prefix_type(self: &Parser) CstNode {
    if self.current_kind() == TokenKind.Ampersand {
        let b = self.open(NodeKind.ReferenceType)
        self.eat_into(&b)
        const inner = self.parse_prefix_type()
        push_node_into(&b, inner)
        return finish(b)
    }
    let cur = self.parse_primary_type()
    // Postfix `[]` for slice (only when `]` immediately follows `[`).
    while self.current_kind() == TokenKind.OpenBracket
        and self.peek_kind(1) == TokenKind.CloseBracket {
        let b = self.open(NodeKind.SliceType)
        b.start = cur.start
        push_node_into(&b, cur)
        self.eat_into(&b)
        self.eat_into(&b)
        cur = finish(b)
    }
    return cur
}

fn parse_primary_type(self: &Parser) CstNode {
    const k = self.current_kind()
    if k == TokenKind.Identifier {
        let b = self.open(NodeKind.NamedType)
        self.eat_into(&b)
        if self.current_kind() == TokenKind.OpenParenthesis {
            self.parse_type_args_into(&b)
        }
        return finish(b)
    }
    if k == TokenKind.Dollar {
        // Generic type-parameter binder `$T` — single Dollar + identifier.
        let b = self.open(NodeKind.NamedType)
        self.eat_into(&b)
        if self.current_kind() == TokenKind.Identifier { self.eat_into(&b) }
        return finish(b)
    }
    if k == TokenKind.OpenBracket {
        // `[T; N]` fixed-size array.
        let b = self.open(NodeKind.ArrayType)
        self.eat_into(&b)
        const elem = self.parse_type()
        push_node_into(&b, elem)
        if self.current_kind() == TokenKind.Semicolon {
            self.eat_into(&b)
            const size = self.parse_expression()
            push_node_into(&b, size)
        }
        self.expect_into(&b, TokenKind.CloseBracket, "E1002")
        return finish(b)
    }
    if k == TokenKind.OpenParenthesis {
        // `(A, B)` tuple type or `()` unit.
        let b = self.open(NodeKind.TupleType)
        self.eat_into(&b)
        while !self.at_eof() and self.current_kind() != TokenKind.CloseParenthesis {
            const t = self.parse_type()
            push_node_into(&b, t)
            if self.current_kind() == TokenKind.Comma { self.eat_into(&b) }
            else if self.current_kind() != TokenKind.CloseParenthesis { break }
        }
        self.expect_into(&b, TokenKind.CloseParenthesis, "E1002")
        return finish(b)
    }
    if k == TokenKind.Fn {
        let b = self.open(NodeKind.FunctionType)
        self.eat_into(&b)
        if self.current_kind() == TokenKind.OpenParenthesis {
            self.eat_into(&b)
            while !self.at_eof() and self.current_kind() != TokenKind.CloseParenthesis {
                // Optional parameter name: `fn(x: T)` — peek `ident :`
                // then eat both before falling through to the type expr.
                if self.current_kind() == TokenKind.Identifier
                    and self.peek_kind(1) == TokenKind.Colon {
                    self.eat_into(&b)
                    self.eat_into(&b)
                }
                const t = self.parse_type()
                push_node_into(&b, t)
                if self.current_kind() == TokenKind.Comma { self.eat_into(&b) }
                else if self.current_kind() != TokenKind.CloseParenthesis { break }
            }
            self.expect_into(&b, TokenKind.CloseParenthesis, "E1002")
        }
        if self.can_start_type(self.current_kind()) {
            const ret = self.parse_type()
            push_node_into(&b, ret)
        }
        return finish(b)
    }
    if k == TokenKind.Struct {
        let b = self.open(NodeKind.AnonymousStructType)
        self.eat_into(&b)
        if self.current_kind() == TokenKind.OpenBrace {
            self.consume_balanced(&b, TokenKind.OpenBrace, TokenKind.CloseBrace)
        }
        return finish(b)
    }
    if k == TokenKind.Enum {
        let b = self.open(NodeKind.AnonymousEnumType)
        self.eat_into(&b)
        if self.current_kind() == TokenKind.OpenBrace {
            self.consume_balanced(&b, TokenKind.OpenBrace, TokenKind.CloseBrace)
        }
        return finish(b)
    }
    // Fall through — wrap into Error so the formatter still has the bytes.
    let b = self.open(NodeKind.Error)
    self.record_error_here("E1002", $"expected a type, found `{self.current().text}`")
    if !self.at_eof() { self.eat_into(&b) }
    return finish(b)
}

fn parse_type_args_into(self: &Parser, b: &NodeBuilder) {
    self.eat_into(b)                                                        // `(`
    while !self.at_eof() and self.current_kind() != TokenKind.CloseParenthesis {
        const t = self.parse_type()
        push_node_into(b, t)
        if self.current_kind() == TokenKind.Comma { self.eat_into(b) }
        else if self.current_kind() != TokenKind.CloseParenthesis { break }
    }
    self.expect_into(b, TokenKind.CloseParenthesis, "E1002")
}

// ─────────────────────────────────────────────────────────────────────────
// Precedence table — mirrors docs/syntax.md operator table.
// ─────────────────────────────────────────────────────────────────────────

fn binary_op_precedence(kind: TokenKind) i32 {
    return kind match {
        TokenKind.Star => 12i32,
        TokenKind.Slash => 12i32,
        TokenKind.Percent => 12i32,
        TokenKind.Plus => 11i32,
        TokenKind.Minus => 11i32,
        TokenKind.ShiftLeft => 10i32,
        TokenKind.ShiftRight => 10i32,
        TokenKind.UnsignedShiftRight => 10i32,
        TokenKind.Ampersand => 9i32,
        TokenKind.Caret => 8i32,
        TokenKind.Pipe => 7i32,
        TokenKind.DotDot => 6i32,
        TokenKind.LessThan => 5i32,
        TokenKind.GreaterThan => 5i32,
        TokenKind.LessThanOrEqual => 5i32,
        TokenKind.GreaterThanOrEqual => 5i32,
        TokenKind.EqualsEquals => 4i32,
        TokenKind.NotEquals => 4i32,
        TokenKind.And => 3i32,
        TokenKind.Or => 2i32,
        TokenKind.QuestionQuestion => 1i32,
        else => 0i32,
    }
}

fn is_range_delimiter(kind: TokenKind) bool {
    return kind == TokenKind.CloseBracket
        or kind == TokenKind.CloseParenthesis
        or kind == TokenKind.Comma
        or kind == TokenKind.CloseBrace
        or kind == TokenKind.Semicolon
        or kind == TokenKind.Eof
}
