// Parser - turns a Token stream into a CstNode tree.
//
// Recursive descent. Every Token from the input stream lands somewhere in the produced tree - error
// recovery wraps unrecognised runs in `Error` subtrees rather than dropping tokens, so the
// formatter can still round-trip broken source. Diagnostics accumulate on `self.diagnostics` for
// tooling to consume.
//
// Module
//   ImportDecl* | Directive* + (FunctionDecl | StructDecl | EnumDecl |
//                               TypeAliasDecl | TestDecl |
//                               GeneratorDef | GeneratorInvocation |
//                               VariableDecl /* const */ | Error)
//   Eof token

import std.allocator
import std.collections.list
import std.string
import std.string_builder

import flang_core.diagnostic
import flang_core.span

import flang_parser.cst
import flang_parser.token
import flang_parser.trivia

// Internal builder for an in-progress CST node. The parser pushes Tokens and finished sub-nodes
// onto `children`; `start`/`end` track the byte span covered so far.
type NodeBuilder = struct {
    kind: NodeKind
    start: usize
    end: usize
    // Height of `Parser.scratch` when this node opened.
    mark: usize
}

pub type Parser = struct {
    // The tree under construction; owns the token list moved in from the lexer.
    tree: Cst
    // Children of the nodes currently open, innermost last. `open` records the height and `finish`
    // moves everything above that mark into `tree.children` as one contiguous block. Nodes close
    // innermost-first, so a stack is enough bookkeeping.
    scratch: List(CstChildSlot)
    position: usize
    // Backs every CST node's child list. Stored as-passed (`null` = global allocator) and forwarded
    // to the optional allocator slots of lists and Tokens; leaves that allocate resolve it per use.
    allocator: &Allocator
    // Accumulated parse-time diagnostics. The parser never throws - it records an error here,
    // recovers, and keeps going. Callers may read after `parse_module()`.
    diagnostics: List(Diagnostic)
    // SourceSpan file id used in recorded diagnostics. Default `-1` (none); CLI/LSP callers
    // overwrite this before calling `parse_module()` so spans reach back to the source.
    file_id: i32
    // True while parsing the condition of an `if`/`for`/`while` without parens - `{` then
    // terminates the expression instead of starting a struct construction or block literal.
    stop_at_brace: bool
    // Enclosing loop bodies being parsed. `break` / `continue` outside every one of them is E1006 /
    // E1007. A lambda body starts it again at zero: a loop outside the lambda is out of reach.
    loop_depth: usize
    // Enclosing lambda bodies being parsed. `return` inside one is E1054 (RFC-039).
    lambda_depth: usize
}

// Construct a Parser over the given token list. The list is borrowed - every CST node will
// reference the original tokens, so `tokens` must outlive the produced tree. `allocator` backs
// every CST child list and the diagnostics list; pass `null` to default to the global allocator
// (resolved per use at the allocation leaves).
pub fn parser(
    tokens: move List(Token),
    source: String,
    allocator: &Allocator = context.allocator,
) Parser {
    return .{
        tree = cst(tokens, source, allocator),
        scratch = list(64, allocator),
        position = 0,
        allocator = allocator,
        diagnostics = list(0, allocator),
        file_id = -1,
        stop_at_brace = false,
        loop_depth = 0,
        lambda_depth = 0,
    }
}

// Release the parser's diagnostics list. The token list is borrowed from the caller and is NOT
// freed here. Each `Diagnostic` owns its `message` / `hint` OwnedStrings - those are freed by the
// list's element walk inside `deinit()`.
pub fn deinit(self: move Parser) {
    self.diagnostics.deinit()
    self.scratch.deinit()
    self.tree.deinit()
}

// ─────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────

// Position control for callers that drive the parser over a token stream they scan themselves (the
// template body parser, RFC-021): jump to a token index, read where parsing stopped.
pub fn set_file_id(self: &Parser, file_id: i32) {
    self.file_id = file_id
}

pub fn seek(self: &Parser, index: usize) {
    self.position = index
}

pub fn token_index(self: &Parser) usize {
    return self.position
}

// Parse the expression in an `if` / `while` / `for` / `#if` / `#for` header: an ordinary
// expression, except that the body's `{` ends it instead of starting a struct literal or a block. A
// leading `(` is a grouped sub-expression like anywhere else, so `if (a) and b { ... }` continues
// past the closing paren.
pub fn parse_condition_expression(self: &Parser) CstNodeId {
    const saved = self.stop_at_brace
    self.stop_at_brace = true
    const e = self.parse_expression()
    self.stop_at_brace = saved
    return e
}

// Suspend the `{`-terminates-an-expression rule for a delimited sub-parse, returning the setting to
// restore.
//
// `stop_at_brace` exists so the body brace of `if` / `while` / `for` is not mistaken for a struct
// literal or a block while the header is being parsed. That is only ambiguous at the header's own
// nesting level: inside `(...)`, `[...]` or `{...}` a brace cannot be the body brace, because the
// delimiter has to close first. Every parse that descends into one suspends the rule, so a header
// like `if take(P { x = 1 }) > 0 {` reads the struct literal and still finds its body.
//
// Pair with `restore_brace_stop`, by `defer` where the sub-parse can return early.
fn suspend_brace_stop(self: &Parser) bool {
    const saved = self.stop_at_brace
    self.stop_at_brace = false
    return saved
}

fn restore_brace_stop(self: &Parser, saved: bool) {
    self.stop_at_brace = saved
}

fn current(self: &Parser) Token {
    if self.position < self.tree.tokens.len {
        return self.tree.tokens[self.position]
    }
    // Past Eof - should not happen if the lexer terminates with Eof - but synthesise one as a guard
    // so misuse doesn't index out of bounds.
    return synth_eof(self)
}

fn synth_eof(self: &Parser) Token {
    if self.tree.tokens.len > 0 {
        return self.tree.tokens[self.tree.tokens.len - 1]
    }
    // Zero-token input - caller misuse. Hand back a degenerate Eof.
    return Token { kind = TokenKind.Eof, text = "", offset = 0usize }
}

fn current_kind(self: &Parser) TokenKind {
    return self.current().kind
}

fn at_eof(self: &Parser) bool {
    return self.current_kind() == TokenKind.Eof
}

fn peek_kind(self: &Parser, ahead: usize) TokenKind {
    const idx = self.position + ahead
    if idx < self.tree.tokens.len {
        return self.tree.tokens[idx].kind
    }
    return TokenKind.Eof
}

fn eat(self: &Parser) Token {
    const tok = self.current()
    if self.position < self.tree.tokens.len and tok.kind != TokenKind.Eof {
        self.position = self.position + 1
    }
    return tok
}

fn token_end(tok: Token) usize {
    return tok.offset + tok.text.len
}

fn open(self: &Parser, kind: NodeKind) NodeBuilder {
    const tok = self.current()
    return .{ kind = kind, start = tok.offset, end = tok.offset, mark = self.scratch.len }
}

// Close the node: move its buffered children into the flat array and register it. Returns the id,
// which the caller hands to `push_node_into` (or keeps, for the root).
fn finish(self: &Parser, b: NodeBuilder) CstNodeId {
    const start = self.tree.children.len
    for i in b.mark..self.scratch.len {
        self.tree.children.push(self.scratch[i])
    }
    self.scratch.truncate(b.mark)
    const id = self.tree.nodes.len as CstNodeId
    self.tree.nodes.push(CstNodeData {
        kind = b.kind,
        start = b.start as u32,
        end = b.end as u32,
        children = ChildSpan {
            start = start as u32,
            len = (self.tree.children.len - start) as u32,
        },
    })
    return id
}

fn eat_into(self: &Parser, b: &NodeBuilder) {
    const id = self.position as CstTokenId
    const tok = self.eat()
    const te = token_end(tok)
    if te > b.end {
        b.end = te
    }
    self.scratch.push(CstChildSlot.TokenSlot(id))
}

fn push_node_into(self: &Parser, b: &NodeBuilder, id: CstNodeId) {
    const e = self.tree.nodes[id].end as usize
    if e > b.end {
        b.end = e
    }
    self.scratch.push(CstChildSlot.NodeSlot(id))
}

// If the current token matches `kind`, eat it into `b` and return true. Otherwise record a
// diagnostic against the current token (or last position, if at Eof) and return false WITHOUT
// advancing.
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

fn record_error_at(
    self: &Parser,
    code: String,
    message: move OwnedString,
    start: usize,
    length: usize,
) {
    const sp: SourceSpan = .{ file_id = self.file_id, start = start, length = length }
    self.diagnostics.push(error(code, message, sp))
}

fn record_error_here(self: &Parser, code: String, message: move OwnedString) {
    const tok = self.current()
    self.record_error_at(code, message, tok.offset, tok.text.len)
}

// ─────────────────────────────────────────────────────────────────────────
// Module
// ─────────────────────────────────────────────────────────────────────────

// Parse the entire token stream as a top-level module: imports, declarations, tests. Always returns
// a `Module` CST node, even on malformed input - bad subtrees are wrapped in `NodeKind.Error` so
// the formatter and CST consumers can still round-trip the source. Consumes every token up to and
// including `Eof`.
pub fn parse_module(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.Module)

    // Imports come first (per known-issues: parser only accepts them at
    // the top). Both `import …` and `pub import …`.
    loop {
        const is_import = self.current_kind() match {
            Import => true
            Pub => self.peek_kind(1) == TokenKind.Import
            _ => false
        }
        if !is_import {
            break
        }
        const node = self.parse_import()
        self.push_node_into(&b, node)
    }

    // Declarations until Eof.
    loop {
        if self.at_eof() {
            break
        }
        const node = self.parse_top_level()
        self.push_node_into(&b, node)
    }

    // Trailing Eof token rounds out the module - consume it into the node so trailing trivia
    // attached to it is preserved.
    if self.current_kind() == TokenKind.Eof {
        self.eat_into(&b)
    }

    const id = self.finish(b)
    self.tree.set_root(id)
    return id
}

// Parse one top-level item: directives + (fn | type | test | const | generator def/invocation). On
// unexpected input, wraps the offending run in an `Error` node so progress is guaranteed.
fn parse_top_level(self: &Parser) CstNodeId {
    // Generator def `#define(...)` and generator invocation `#name(...)` are recognised before
    // generic-directive parsing because they take no leading directives themselves.
    if self.current_kind() == TokenKind.Hash {
        self.peek_kind(1) match {
            // Decl-level `#if` before generic-directive collection - `if` is a keyword token, so it
            // can never be a directive name.
            If => return self.parse_if_directive_decl()
            Identifier => {
                const ident = self.tree.tokens[self.position + 1].text
                if ident == "define" {
                    return self.parse_generator_def()
                }
                if !is_known_directive(ident) and self.peek_kind(2) == TokenKind.OpenParenthesis {
                    return self.parse_generator_invocation()
                }
            }
            _ => {}
        }
    }

    // Collect leading directives. We push them as children of whatever declaration follows, so open
    // a tentative builder and decide its final kind after we see the decl starter.
    let leading: List(CstNodeId) = list(0, self.allocator)
    while self.current_kind() == TokenKind.Hash {
        const d = self.parse_directive()
        leading.push(d)
    }

    return self.current_kind() match {
        Pub => self.parse_pub_decl(leading)
        Fn => self.parse_function_with_directives(leading)
        Type => self.parse_type_decl_with_directives(leading)
        Struct => self.parse_legacy_type_decl(leading, true)
        Enum => self.parse_legacy_type_decl(leading, false)
        Test => self.parse_test_with_directives(leading)
        Const | Let => self.parse_variable_decl_with_directives(leading)
        Context => self.parse_context_decl(leading)
        _ => self.recover_unexpected_top_level(leading)
    }
}

// The declaration a leading `pub` opens: the forms that take one.
fn parse_pub_decl(self: &Parser, leading: move List(CstNodeId)) CstNodeId {
    return self.peek_kind(1) match {
        Fn => self.parse_function_with_directives(leading)
        Type => self.parse_type_decl_with_directives(leading)
        Struct => self.parse_legacy_type_decl(leading, true)
        Enum => self.parse_legacy_type_decl(leading, false)
        Const => self.parse_variable_decl_with_directives(leading)
        Context => self.parse_context_decl(leading)
        // `pub import` should have been consumed in parse_module's header. If it reaches us, hoist
        // it anyway - but it counts as an out-of-order import.
        Import => {
            leading.deinit()
            self.record_error_here("E1003", $"imports must precede declarations")
            self.parse_import()
        }
        // Unknown form after `pub` - recover by wrapping the run in Error.
        _ => self.recover_unexpected_top_level(leading)
    }
}

// Names that bind as plain `Directive` rather than `GeneratorInvocation` at top level. Mirrors the
// C# stage-0 parser's `_knownDirectiveNames`. Everything else (`#interface`, `#implement`,
// `#derive`, `#enum_utils`,
// `#string_reader`, …) routes through generator invocation.
fn is_known_directive(name: String) bool {
    return name match {
        "foreign" | "inline" | "deprecated" | "simd" | "allow" => true
        _ => false
    }
}

fn recover_unexpected_top_level(self: &Parser, leading: move List(CstNodeId)) CstNodeId {
    let b = self.open(NodeKind.Error)
    for i in 0..leading.len {
        self.push_node_into(&b, leading[i])
    }
    const msg = $"unexpected `{self.current().text}` at top level"
    self.record_error_here("E1001", msg)
    // Consume until we hit a recognisable top-level starter.
    loop {
        if self.at_eof() {
            break
        }
        if self.is_top_level_starter() {
            break
        }
        self.eat_into(&b)
    }
    leading.deinit()
    return self.finish(b)
}

fn is_top_level_starter(self: &Parser) bool {
    return self.current_kind() match {
        Pub | Fn | Type | Test | Const | Let | Import | Hash | Context => true
        _ => false
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Imports
// ─────────────────────────────────────────────────────────────────────────

fn parse_import(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.ImportDecl)
    if self.current_kind() == TokenKind.Pub {
        self.eat_into(&b)
    }
    self.expect_into(&b, TokenKind.Import, "E1002")
    self.eat_identifier_or_keyword(&b)
    while self.current_kind() == TokenKind.Dot {
        self.eat_into(&b)
        self.eat_identifier_or_keyword(&b)
    }
    return self.finish(b)
}

// Any identifier or keyword is accepted as a path component (so a module named `as` or `match` is
// still importable).
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

// `#name` or `#name(arg, arg, ...)`. Args inside parens are parsed loosely - any tokens until
// matched `)` are accepted, since directive arguments cover identifiers, literals, types, and
// anonymous-struct shapes.
fn parse_directive(self: &Parser) CstNodeId {
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
    return self.finish(b)
}

// Eat the opener, then every token until the matching closer (tracking nesting on the SAME pair).
// Used for directive arg lists and generator template bodies where the inner grammar isn't
// structurally important to the CST.
fn consume_balanced(self: &Parser, b: &NodeBuilder, open_kind: TokenKind, close_kind: TokenKind) {
    if self.current_kind() != open_kind {
        self.record_expected(open_kind, "E1002")
        return
    }
    self.eat_into(b)
    let depth: usize = 1
    loop {
        if self.at_eof() {
            break
        }
        const k = self.current_kind()
        if k == open_kind {
            depth = depth + 1
            self.eat_into(b)
            continue
        }
        if k == close_kind {
            depth = depth - 1
            self.eat_into(b)
            if depth == 0 {
                break
            }
            continue
        }
        self.eat_into(b)
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Generator definitions / invocations
// ─────────────────────────────────────────────────────────────────────────

// `#define(name, Param: Kind, ...) { template body }`. Args list is consumed structurally; body is
// captured as one balanced-brace run.
fn parse_generator_def(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.GeneratorDef)
    self.eat_into(&b) // `#`
    self.eat_into(&b) // `define`
    if self.current_kind() == TokenKind.OpenParenthesis {
        self.consume_balanced(&b, TokenKind.OpenParenthesis, TokenKind.CloseParenthesis)
    }
    if self.current_kind() == TokenKind.OpenBrace {
        self.consume_balanced(&b, TokenKind.OpenBrace, TokenKind.CloseBrace)
    }
    return self.finish(b)
}

// One generator argument: a bare identifier (`Point`, `eq`) is a token
// child; something that starts a type (`struct { … }`, `List(i32)`, `&T`)
// is a type node; anything else (`3`, `"x"`, `[…]`) is an expression node.
fn parse_generator_arg_into(self: &Parser, b: &NodeBuilder) {
    const k = self.current_kind()
    if k == TokenKind.Identifier {
        const next = self.peek_kind(1)
        if next == TokenKind.Comma or next == TokenKind.CloseParenthesis {
            self.eat_into(b)
            return
        }
    }
    if k == TokenKind.Identifier or self.can_start_type(k) {
        const t = self.parse_type()
        self.push_node_into(b, t)
        return
    }
    const e = self.parse_expression()
    self.push_node_into(b, e)
}

// `#name(args)` standalone at top level (not preceded by `#define`, and `name` not in the
// known-directive set). Arguments captured balanced - same shape as a directive call.
fn parse_generator_invocation(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.GeneratorInvocation)
    self.eat_into(&b) // `#`
    self.eat_into(&b) // identifier
    if self.current_kind() == TokenKind.OpenParenthesis {
        self.eat_into(&b)
        while !self.at_eof() and self.current_kind() != TokenKind.CloseParenthesis {
            self.parse_generator_arg_into(&b)
            if !self.eat_list_comma(&b, TokenKind.CloseParenthesis) {
                break
            }
        }
        self.expect_into(&b, TokenKind.CloseParenthesis, "E1002")
    }
    return self.finish(b)
}

// ─────────────────────────────────────────────────────────────────────────
// Functions
// ─────────────────────────────────────────────────────────────────────────

fn parse_function_with_directives(self: &Parser, leading: move List(CstNodeId)) CstNodeId {
    let b = self.open(NodeKind.FunctionDecl)
    for i in 0..leading.len { self.push_node_into(&b, leading[i]) }
    leading.deinit()
    self.parse_function_into(&b)
    return self.finish(b)
}

// Function body builder - fills `b` with: [pub] fn name(params) ret_type? where? { body } or [pub]
// fn name(params) ret_type (no body, for `#foreign`).
fn parse_function_into(self: &Parser, b: &NodeBuilder) {
    if self.current_kind() == TokenKind.Pub {
        self.eat_into(b)
    }
    self.expect_into(b, TokenKind.Fn, "E1002")
    if self.current_kind() == TokenKind.Identifier {
        self.eat_into(b)
    } else {
        self.record_expected(TokenKind.Identifier, "E1002")
    }
    self.parse_function_params(b)
    if self.can_start_type(self.current_kind()) and !self.at_where_clause() {
        const t = self.parse_type()
        self.push_node_into(b, t)
    }
    if self.at_where_clause() {
        self.parse_where_into(b)
    }
    if self.current_kind() == TokenKind.OpenBrace {
        const body = self.parse_block_expr()
        self.push_node_into(b, body)
    }
    // No body? Foreign functions go without one - that's fine, we just stop here. Anything else (a
    // stray statement) bubbles up to the top-level error recovery.
}

// `where` is contextual: a bound list starts with `where Name :` or `where Name.Item :`, so a type
// named `where` still parses as a return type.
fn at_where_clause(self: &Parser) bool {
    if self.current_kind() != TokenKind.Identifier or self.current().text != "where" {
        return false
    }
    return self.at_bound_subject(1)
}

// Whether `Name :` or `Name.Item :` starts `i` tokens ahead.
fn at_bound_subject(self: &Parser, from: usize) bool {
    let i = from
    while self.peek_kind(i) == TokenKind.Identifier and self.peek_kind(i + 1) == TokenKind.Dot {
        i = i + 2
    }
    return self.peek_kind(i) == TokenKind.Identifier and self.peek_kind(i + 1) == TokenKind.Colon
}

// `where T: copyable, I: Iterator, I.Item: Hash` - one `WhereBound` node per entry. A trailing
// comma is allowed.
fn parse_where_into(self: &Parser, b: &NodeBuilder) {
    self.eat_into(b)
    loop {
        let wb = self.open(NodeKind.WhereBound)
        self.expect_into(&wb, TokenKind.Identifier, "E1002")
        while self.current_kind() == TokenKind.Dot {
            self.eat_into(&wb)
            self.expect_into(&wb, TokenKind.Identifier, "E1002")
        }
        self.expect_into(&wb, TokenKind.Colon, "E1002")
        const t = self.parse_bound_type()
        self.push_node_into(&wb, t)
        const node = self.finish(wb)
        self.push_node_into(b, node)
        if self.current_kind() != TokenKind.Comma {
            break
        }
        self.eat_into(b)
        if !self.at_bound_subject(0) {
            break
        }
    }
}

// A type in bound position: `A + B + ...`, one `CombinedType` node when `+` joins two or more.
fn parse_bound_type(self: &Parser) CstNodeId {
    const first = self.parse_type()
    if self.current_kind() != TokenKind.Plus {
        return first
    }
    let b = self.open(NodeKind.CombinedType)
    b.start = self.tree.nodes[first].start as usize
    self.push_node_into(&b, first)
    while self.current_kind() == TokenKind.Plus {
        self.eat_into(&b)
        const t = self.parse_type()
        self.push_node_into(&b, t)
    }
    return self.finish(b)
}

fn parse_function_params(self: &Parser, b: &NodeBuilder) {
    if !self.expect_into(b, TokenKind.OpenParenthesis, "E1002") {
        return
    }
    while !self.at_eof() and self.current_kind() != TokenKind.CloseParenthesis {
        const param = self.parse_function_param()
        self.push_node_into(b, param)
        if self.current_kind() == TokenKind.Comma {
            self.eat_into(b)
            continue
        }
        if self.current_kind() != TokenKind.CloseParenthesis {
            break
        }
    }
    self.expect_into(b, TokenKind.CloseParenthesis, "E1002")
}

fn parse_function_param(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.FunctionParam)
    // Variadic prefix `..`
    if self.current_kind() == TokenKind.DotDot {
        self.eat_into(&b)
    }
    if self.current_kind() == TokenKind.Identifier {
        self.eat_into(&b)
    } else {
        self.record_expected(TokenKind.Identifier, "E1002")
    }
    self.expect_into(&b, TokenKind.Colon, "E1002")
    // `name: move T` - the slot consumes whatever fills it, whether or not its type says so.
    if self.current_kind() == TokenKind.Move {
        self.eat_into(&b)
    }
    const t = self.parse_type()
    self.push_node_into(&b, t)
    // Optional default value
    if self.current_kind() == TokenKind.Equals {
        self.eat_into(&b)
        const def = self.parse_expression()
        self.push_node_into(&b, def)
    }
    return self.finish(b)
}

// True when the current token can begin a type expression. Used to decide whether a function
// declaration has an explicit return type.
fn can_start_type(self: &Parser, k: TokenKind) bool {
    return k match {
        Identifier | Ampersand | Dollar | OpenBracket | OpenParenthesis | Fn | Struct | Enum
            | Contract => true
        _ => false
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Type declarations
// ─────────────────────────────────────────────────────────────────────────

// `struct Name { … }` / `enum Name { … }` - the pre-`type` declaration
// syntax. Removed from the language; parsed anyway so the rest of the file still reads, but
// rejected at its keyword (E1050 / E1051).
fn parse_legacy_type_decl(self: &Parser, leading: move List(CstNodeId), is_struct: bool) CstNodeId {
    let b = self.open(if is_struct { NodeKind.StructDecl } else { NodeKind.EnumDecl })
    for i in 0..leading.len { self.push_node_into(&b, leading[i]) }
    leading.deinit()
    if self.current_kind() == TokenKind.Pub {
        self.eat_into(&b)
    }
    if is_struct {
        self.record_error_here(
            "E1050",
            from_view(
                "`struct Name { ... }` syntax has been removed, use `type Name = struct { ... }` instead",
            ),
        )
    } else {
        self.record_error_here(
            "E1051",
            from_view(
                "`enum Name { ... }` syntax has been removed, use `type Name = enum { ... }` instead",
            ),
        )
    }
    self.eat_into(&b) // `struct` / `enum`
    if self.current_kind() == TokenKind.Identifier {
        self.eat_into(&b)
    } else {
        self.record_expected(TokenKind.Identifier, "E1002")
    }
    if is_struct {
        self.parse_struct_body_into(&b)
    } else {
        self.parse_enum_body_into(&b)
    }
    return self.finish(b)
}

fn parse_type_decl_with_directives(self: &Parser, leading: move List(CstNodeId)) CstNodeId {
    // We don't know yet whether the rhs is `struct` or `enum`, so open with a placeholder kind and
    // rewrite it once we see the `=` rhs.
    let b = self.open(NodeKind.TypeAliasDecl)
    // `#simd` / `#foreign` describe the type EXPRESSION, so they belong after the `=`. Detached,
    // they read as decl attributes and would be silently dropped (E1001).
    for i in 0..leading.len {
        const dn = self.directive_name_of(leading[i])
        if dn == "simd" or dn == "foreign" {
            const d = self.tree.node_at(leading[i])
            self.record_error_at(
                "E1001",
                $"`#{dn}` must appear after `=` in a type declaration - write `type Name = #{dn} struct {{ ... }}`",
                d.start as usize,
                (d.end - d.start) as usize,
            )
        }
    }
    for i in 0..leading.len { self.push_node_into(&b, leading[i]) }
    leading.deinit()
    if self.current_kind() == TokenKind.Pub {
        self.eat_into(&b)
    }
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
        self.push_node_into(&b, d)
    }
    self.current_kind() match {
        Struct => {
            b.kind = NodeKind.StructDecl
            self.eat_into(&b)
            self.parse_struct_body_into(&b)
        }
        Enum => {
            b.kind = NodeKind.EnumDecl
            self.eat_into(&b)
            self.parse_enum_body_into(&b)
        }
        // Plain alias `type T = OtherType` - parse a type expression. `type K = A + B` names a
        // combined contract.
        _ => {
            const t = self.parse_bound_type()
            self.push_node_into(&b, t)
        }
    }
    return self.finish(b)
}

// The identifier a `#name` directive node carries, or the empty string.
fn directive_name_of(self: &Parser, id: CstNodeId) String {
    const node = self.tree.node_at(id)
    for i in 0..node.child_count() {
        node.child(i) match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.Identifier {
                    return tok.text
                }
            }
            NodeChild(_) => {}
        }
    }
    return ""
}

fn parse_struct_body_into(self: &Parser, b: &NodeBuilder) {
    self.parse_type_params_into(b)
    if !self.expect_into(b, TokenKind.OpenBrace, "E1002") {
        return
    }
    while !self.at_eof() and self.current_kind() != TokenKind.CloseBrace {
        const field = self.parse_struct_field()
        self.push_node_into(b, field)
        if self.current_kind() == TokenKind.Comma {
            self.eat_into(b)
        }
    }
    self.expect_into(b, TokenKind.CloseBrace, "E1002")
}

// `(T, U: Bound)` on a struct, enum or contract, when present. A bound sits on the parameter it
// constrains; `where` after the list is refused (E2145), since each position has one spelling.
fn parse_type_params_into(self: &Parser, b: &NodeBuilder) {
    if self.current_kind() == TokenKind.OpenParenthesis {
        let pl = self.open(NodeKind.TypeParamList)
        self.eat_into(&pl)
        while !self.at_eof() and self.current_kind() != TokenKind.CloseParenthesis {
            let tp = self.open(NodeKind.TypeParam)
            self.expect_into(&tp, TokenKind.Identifier, "E1002")
            if self.current_kind() == TokenKind.Colon {
                self.eat_into(&tp)
                const t = self.parse_bound_type()
                self.push_node_into(&tp, t)
            }
            const node = self.finish(tp)
            self.push_node_into(&pl, node)
            if !self.eat_list_comma(&pl, TokenKind.CloseParenthesis) {
                break
            }
        }
        self.expect_into(&pl, TokenKind.CloseParenthesis, "E1002")
        const node = self.finish(pl)
        self.push_node_into(b, node)
    }
    if self.at_where_clause() {
        self.record_error_here(
            "E2145",
            from_view(
                "a type declares its bounds on its parameters: `struct(T: Bound)`, not `where`",
            ),
        )
        self.parse_where_into(b)
    }
}

fn parse_struct_field(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.StructField)
    // `owned` is contextual: a modifier when another identifier follows, the field's own name when
    // a colon does. Eating it here leaves the name as the field's second identifier token.
    if self.current_kind() == TokenKind.Identifier and self.current().text == "owned"
        and self.peek_kind(1) == TokenKind.Identifier {
        self.eat_into(&b)
    }
    if self.current_kind() == TokenKind.Identifier {
        self.eat_into(&b)
    } else {
        self.record_expected(TokenKind.Identifier, "E1002")
        // Skip to next comma / `}` to make progress.
        loop {
            self.current_kind() match {
                Eof | Comma | CloseBrace => break
                _ => self.eat_into(&b)
            }
        }
        return self.finish(b)
    }
    self.expect_into(&b, TokenKind.Colon, "E1002")
    const t = self.parse_type()
    self.push_node_into(&b, t)
    return self.finish(b)
}

fn parse_enum_body_into(self: &Parser, b: &NodeBuilder) {
    self.parse_type_params_into(b)
    if !self.expect_into(b, TokenKind.OpenBrace, "E1002") {
        return
    }
    while !self.at_eof() and self.current_kind() != TokenKind.CloseBrace {
        const variant = self.parse_enum_variant()
        self.push_node_into(b, variant)
        if self.current_kind() == TokenKind.Comma {
            self.eat_into(b)
        }
    }
    self.expect_into(b, TokenKind.CloseBrace, "E1002")
}

fn parse_enum_variant(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.EnumVariant)
    if self.current_kind() == TokenKind.Identifier {
        self.eat_into(&b)
    } else {
        self.record_expected(TokenKind.Identifier, "E1002")
        return self.finish(b)
    }
    // Payload types `(T1, T2)`.
    if self.current_kind() == TokenKind.OpenParenthesis {
        self.eat_into(&b)
        while !self.at_eof() and self.current_kind() != TokenKind.CloseParenthesis {
            const t = self.parse_type()
            self.push_node_into(&b, t)
            if !self.eat_list_comma(&b, TokenKind.CloseParenthesis) {
                break
            }
        }
        self.expect_into(&b, TokenKind.CloseParenthesis, "E1002")
    }
    // Explicit tag `= <int>` or `= -<int>`.
    if self.current_kind() == TokenKind.Equals {
        self.eat_into(&b)
        if self.current_kind() == TokenKind.Minus {
            self.eat_into(&b)
        }
        if self.current_kind() == TokenKind.Integer {
            self.eat_into(&b)
        }
    }
    return self.finish(b)
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

fn parse_test_with_directives(self: &Parser, leading: move List(CstNodeId)) CstNodeId {
    let b = self.open(NodeKind.TestDecl)
    for i in 0..leading.len { self.push_node_into(&b, leading[i]) }
    leading.deinit()
    self.expect_into(&b, TokenKind.Test, "E1002")
    if self.current_kind() == TokenKind.StringLiteral {
        self.eat_into(&b)
    } else {
        self.record_expected(TokenKind.StringLiteral, "E1002")
    }
    if self.current_kind() == TokenKind.OpenBrace {
        const body = self.parse_block_expr()
        self.push_node_into(&b, body)
    }
    return self.finish(b)
}

// ─────────────────────────────────────────────────────────────────────────
// Variable declarations (let / const)
// ─────────────────────────────────────────────────────────────────────────

fn parse_variable_decl_with_directives(self: &Parser, leading: move List(CstNodeId)) CstNodeId {
    let b = self.open(NodeKind.VariableDecl)
    for i in 0..leading.len { self.push_node_into(&b, leading[i]) }
    leading.deinit()
    self.parse_variable_decl_into(&b)
    return self.finish(b)
}

fn parse_variable_decl_into(self: &Parser, b: &NodeBuilder) {
    if self.current_kind() == TokenKind.Pub {
        self.eat_into(b)
    }
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
        self.push_node_into(b, t)
    }
    if self.current_kind() == TokenKind.Equals {
        self.eat_into(b)
        const init = self.parse_expression()
        self.push_node_into(b, init)
    }
}

// `[pub] context name: Type = default` (RFC-038). The type and the default are both required.
fn parse_context_decl(self: &Parser, leading: move List(CstNodeId)) CstNodeId {
    let b = self.open(NodeKind.ContextDecl)
    for i in 0..leading.len { self.push_node_into(&b, leading[i]) }
    leading.deinit()
    if self.current_kind() == TokenKind.Pub {
        self.eat_into(&b)
    }
    self.eat_into(&b) // `context`
    self.expect_into(&b, TokenKind.Identifier, "E1002")
    if self.expect_into(&b, TokenKind.Colon, "E1002") {
        const t = self.parse_type()
        self.push_node_into(&b, t)
    }
    if self.expect_into(&b, TokenKind.Equals, "E1002") {
        const init = self.parse_expression()
        self.push_node_into(&b, init)
    }
    return self.finish(b)
}

// ─────────────────────────────────────────────────────────────────────────
// Statements
// ─────────────────────────────────────────────────────────────────────────

// `{ … }` block expression with a sequence of statements and an
// optional trailing expression. Always returns a `BlockExpr` node.
fn parse_block_expr(self: &Parser) CstNodeId {
    const saved_brace = self.suspend_brace_stop()
    defer self.restore_brace_stop(saved_brace)
    let b = self.open(NodeKind.BlockExpr)
    if !self.expect_into(&b, TokenKind.OpenBrace, "E1002") {
        return self.finish(b)
    }
    while !self.at_eof() and self.current_kind() != TokenKind.CloseBrace {
        const stmt = self.parse_statement()
        self.push_node_into(&b, stmt)
    }
    self.expect_into(&b, TokenKind.CloseBrace, "E1002")
    return self.finish(b)
}

fn parse_statement(self: &Parser) CstNodeId {
    return self.current_kind() match {
        Let | Const => {
            let b = self.open(NodeKind.VariableDecl)
            self.parse_variable_decl_into(&b)
            self.eat_optional_semicolon(&b)
            self.finish(b)
        }
        // Local type decl - wrap in TypeAliasDecl (kind may be rewritten by
        // parse_type_decl_with_directives). We bypass directive collection because the spec
        // disallows them on local types.
        Type => self.parse_type_decl_with_directives(list(0, self.allocator))
        Return => self.parse_return_stmt()
        Break => self.parse_single_keyword_stmt(NodeKind.BreakStmt)
        Continue => self.parse_single_keyword_stmt(NodeKind.ContinueStmt)
        Defer => self.parse_defer_stmt()
        For => self.parse_for_loop()
        Loop => self.parse_loop_expr()
        While => self.parse_while_loop()
        If => self.parse_if_expr()
        OpenBrace => if self.at_lambda_brace() {
            self.parse_expression_stmt()
        } else {
            self.parse_block_expr()
        }
        // `#if cond { ... } else { ... }` directive-driven branch; any other directive is
        // free-floating - a directive node, and parsing continues.
        Hash => if self.peek_kind(1) == TokenKind.If {
            self.parse_if_directive_stmt()
        } else {
            self.parse_directive()
        }
        _ => self.parse_expression_stmt()
    }
}

fn parse_expression_stmt(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.ExpressionStmt)
    const expr = self.parse_expression()
    self.push_node_into(&b, expr)
    self.eat_optional_semicolon(&b)
    return self.finish(b)
}

fn eat_optional_semicolon(self: &Parser, b: &NodeBuilder) {
    if self.current_kind() == TokenKind.Semicolon {
        self.eat_into(b)
    }
}

fn parse_return_stmt(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.ReturnStmt)
    if self.lambda_depth > 0 {
        self.record_error_here(
            "E1054",
            from_view("`return` inside a lambda: its value is the body's last expression"),
        )
    }
    self.eat_into(&b) // `return`
    if !self.is_bare_return_terminator() {
        const e = self.parse_expression()
        self.push_node_into(&b, e)
    }
    self.eat_optional_semicolon(&b)
    return self.finish(b)
}

// A `return` takes an operand only from its own line. Statements are newline-terminated, so an
// expression opening a later line is the next statement; `return` alone on a line is bare. The
// keyword set covers same-line forms, where no expression can start.
fn is_bare_return_terminator(self: &Parser) bool {
    if self.at_line_start() {
        return true
    }
    return self.current_kind() match {
        CloseBrace | Eof | Semicolon | Let | Const | Return | Break | Continue | Defer => true
        _ => false
    }
}

// Whether the current token opens a line the previous token did not sit on.
fn at_line_start(self: &Parser) bool {
    if self.position == 0 or self.position >= self.tree.tokens.len {
        return false
    }
    const prev = self.tree.tokens[self.position - 1]
    return spans_newline(
        self.tree.source,
        prev.offset + prev.text.len,
        self.tree.tokens[self.position].offset,
    )
}

fn parse_single_keyword_stmt(self: &Parser, kind: NodeKind) CstNodeId {
    let b = self.open(kind)
    // `break` / `continue` need a loop to act on (E1006 / E1007).
    if self.loop_depth == 0 {
        kind match {
            BreakStmt => self.record_error_here("E1006", from_view("`break` outside of a loop"))
            ContinueStmt => self.record_error_here(
                "E1007",
                from_view("`continue` outside of a loop"),
            )
            _ => {}
        }
    }
    self.eat_into(&b)
    self.eat_optional_semicolon(&b)
    return self.finish(b)
}

fn parse_defer_stmt(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.DeferStmt)
    self.eat_into(&b) // `defer`
    const e = self.parse_expression()
    self.push_node_into(&b, e)
    self.eat_optional_semicolon(&b)
    return self.finish(b)
}

// `#if cond { … } [else { … }]`. The condition is an ordinary FLang
// expression (the #if condition language is a FLang expression subset), parsed structurally so the
// projector can surface it for evaluation.
// Parens are optional — `#if(cond)` parses as a parenthesized expression.
fn parse_if_directive_stmt(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.IfDirectiveStmt)
    self.eat_into(&b) // `#`
    self.eat_into(&b) // `if`
    self.parse_if_directive_condition_into(&b)
    if self.current_kind() == TokenKind.OpenBrace {
        const then_block = self.parse_block_expr()
        self.push_node_into(&b, then_block)
    }
    if self.current_kind() == TokenKind.Else {
        self.eat_into(&b)
        if self.current_kind() == TokenKind.OpenBrace {
            const else_block = self.parse_block_expr()
            self.push_node_into(&b, else_block)
        }
    }
    return self.finish(b)
}

// The shared condition grammar of both #if forms: parenthesized, or bare with the struct-literal
// ambiguity suppressed (`stop_at_brace`).
fn parse_if_directive_condition_into(self: &Parser, b: &NodeBuilder) {
    if self.current_kind() == TokenKind.OpenBrace {
        return
    }
    // A leading `(` is a grouped sub-expression like anywhere else - `#if (runtime.env["X"] ?? "")
    // == "y" {` continues past it.
    const cond = self.parse_condition_expression()
    self.push_node_into(b, cond)
}

// Decl-level `#if cond { decls… } [else { decls… }]`. Same node kind as
// the statement form - the projector decides by position (module child vs block child). Branch
// bodies hold top-level items, not statements.
fn parse_if_directive_decl(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.IfDirectiveStmt)
    self.eat_into(&b) // `#`
    self.eat_into(&b) // `if`
    self.parse_if_directive_condition_into(&b)
    if self.current_kind() == TokenKind.OpenBrace {
        const then_block = self.parse_decl_block()
        self.push_node_into(&b, then_block)
    }
    if self.current_kind() == TokenKind.Else {
        self.eat_into(&b)
        if self.current_kind() == TokenKind.OpenBrace {
            const else_block = self.parse_decl_block()
            self.push_node_into(&b, else_block)
        }
    }
    return self.finish(b)
}

// `{ top-level items… }` - a decl-level #if branch body.
fn parse_decl_block(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.BlockExpr)
    self.eat_into(&b) // `{`
    loop {
        if self.at_eof() {
            break
        }
        if self.current_kind() == TokenKind.CloseBrace {
            break
        }
        const node = self.parse_top_level()
        self.push_node_into(&b, node)
    }
    self.expect_into(&b, TokenKind.CloseBrace, "E1002")
    return self.finish(b)
}

// ─────────────────────────────────────────────────────────────────────────
// Control-flow expressions
// ─────────────────────────────────────────────────────────────────────────

fn parse_if_expr(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.IfExpr)
    self.eat_into(&b) // `if`
    // A leading `(` is an ordinary grouped expression, NOT a header
    // wrapper: consuming it as one made `if (a) and b { … }` stop at the
    // closing paren and report the operator as unexpected.
    const cond = self.parse_condition_expression()
    self.push_node_into(&b, cond)
    if self.current_kind() == TokenKind.OpenBrace {
        const then_block = self.parse_block_expr()
        self.push_node_into(&b, then_block)
    }
    if self.current_kind() == TokenKind.Else {
        self.eat_into(&b)
        self.current_kind() match {
            If => {
                const else_if = self.parse_if_expr()
                self.push_node_into(&b, else_if)
            }
            OpenBrace => {
                const else_block = self.parse_block_expr()
                self.push_node_into(&b, else_block)
            }
            _ => {}
        }
    }
    return self.finish(b)
}

fn parse_for_loop(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.ForLoopExpr)
    self.eat_into(&b) // `for`
    // `for (i in 0..5) { … }` - the parenthesised header form was removed
    // (RFC-006). Parsed defensively so the body still reads (E1010).
    let parenthesised = self.current_kind() == TokenKind.OpenParenthesis
    if parenthesised {
        self.record_error_here(
            "E1010",
            from_view(
                "parentheses around the `for` header are not allowed - write `for x in xs { ... }`",
            ),
        )
        self.eat_into(&b)
    }
    if self.current_kind() == TokenKind.Ampersand {
        self.eat_into(&b)
    } // `for &x in` (iter_ref)
    if self.current_kind() == TokenKind.Identifier {
        self.eat_into(&b)
    }
    self.expect_into(&b, TokenKind.In, "E1002")
    const iterable = self.parse_condition_expression()
    self.push_node_into(&b, iterable)
    if parenthesised and self.current_kind() == TokenKind.CloseParenthesis {
        self.eat_into(&b)
    }
    if self.current_kind() == TokenKind.OpenBrace {
        self.loop_depth = self.loop_depth + 1
        const body = self.parse_block_expr()
        self.loop_depth = self.loop_depth - 1
        self.push_node_into(&b, body)
    }
    return self.finish(b)
}

fn parse_loop_expr(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.LoopExpr)
    self.eat_into(&b) // `loop`
    if self.current_kind() == TokenKind.OpenBrace {
        self.loop_depth = self.loop_depth + 1
        const body = self.parse_block_expr()
        self.loop_depth = self.loop_depth - 1
        self.push_node_into(&b, body)
    }
    return self.finish(b)
}

fn parse_while_loop(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.WhileExpr)
    self.eat_into(&b) // `while`
    const cond = self.parse_condition_expression()
    self.push_node_into(&b, cond)
    if self.current_kind() == TokenKind.OpenBrace {
        self.loop_depth = self.loop_depth + 1
        const body = self.parse_block_expr()
        self.loop_depth = self.loop_depth - 1
        self.push_node_into(&b, body)
    }
    return self.finish(b)
}

// `expr match { pat => result, ... }` - postfix, parsed after a unary expression in
// parse_binary_expression. `scrutinee` is the left-hand side; this method consumes the `match`
// keyword and arms.
fn parse_match_tail(self: &Parser, scrutinee: CstNodeId) CstNodeId {
    const saved_brace = self.suspend_brace_stop()
    defer self.restore_brace_stop(saved_brace)
    let b = self.open(NodeKind.MatchExpr)
    // Re-anchor `start` to scrutinee since the open() above pointed at `match`.
    b.start = self.tree.nodes[scrutinee].start as usize
    self.push_node_into(&b, scrutinee)
    self.eat_into(&b) // `match`
    if !self.expect_into(&b, TokenKind.OpenBrace, "E1002") {
        return self.finish(b)
    }
    while !self.at_eof() and self.current_kind() != TokenKind.CloseBrace {
        const arm = self.parse_match_arm()
        self.push_node_into(&b, arm)
        if self.current_kind() == TokenKind.Comma {
            self.eat_into(&b)
        }
    }
    self.expect_into(&b, TokenKind.CloseBrace, "E1002")
    return self.finish(b)
}

// Pattern is parsed as a token run up to the `=>` arrow (with optional `if guard`) - full pattern
// grammar (RFC-010) isn't structurally surfaced yet, but every token stays accounted for.
fn parse_match_arm(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.MatchArm)
    loop {
        self.current_kind() match {
            Eof | FatArrow | CloseBrace | Comma => break
            // `if cond` guard - eat `if` then parse a regular expression so the guard sits in the
            // arm with full structure preserved.
            If => {
                self.eat_into(&b)
                const guard = self.parse_expression()
                self.push_node_into(&b, guard)
            }
            // Balance any nested parens/brackets/braces inside the pattern (e.g. `Some(x)` payload
            // or `Point { x, y }` struct pattern).
            OpenParenthesis => self.consume_balanced(
                &b,
                TokenKind.OpenParenthesis,
                TokenKind.CloseParenthesis,
            )
            OpenBracket => self.consume_balanced(&b, TokenKind.OpenBracket, TokenKind.CloseBracket)
            OpenBrace => self.consume_balanced(&b, TokenKind.OpenBrace, TokenKind.CloseBrace)
            _ => self.eat_into(&b)
        }
    }
    if self.current_kind() == TokenKind.FatArrow {
        self.eat_into(&b)
        const rhs = self.parse_arm_body()
        self.push_node_into(&b, rhs)
    }
    return self.finish(b)
}

// Match arm RHS - accepts `return expr`, bare `break` / `continue`, a block expression, or a plain
// expression. These divergent forms are expressions of type `never` in spec terms but the
// recursive-descent path through parse_expression doesn't enter them directly.
fn parse_arm_body(self: &Parser) CstNodeId {
    return self.current_kind() match {
        Return => self.parse_return_stmt()
        Break => self.parse_single_keyword_stmt(NodeKind.BreakStmt)
        Continue => self.parse_single_keyword_stmt(NodeKind.ContinueStmt)
        OpenBrace => if self.at_lambda_brace() {
            self.parse_expression()
        } else {
            self.parse_block_expr()
        }
        _ => self.parse_expression()
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Expressions - Pratt parser
// ─────────────────────────────────────────────────────────────────────────

pub fn parse_expression(self: &Parser) CstNodeId {
    return self.parse_binary_expression(0i32)
}

fn parse_binary_expression(self: &Parser, parent_precedence: i32) CstNodeId {
    let left = self.parse_unary_expression()
    left = self.parse_postfix_chain(left)
    // Cast chain `expr as Type as Type`.
    while self.current_kind() == TokenKind.As {
        let b = self.open(NodeKind.CastExpr)
        b.start = self.tree.nodes[left].start as usize
        self.push_node_into(&b, left)
        self.eat_into(&b) // `as`
        const t = self.parse_type()
        self.push_node_into(&b, t)
        left = self.finish(b)
    }
    // Postfix `match`.
    if self.current_kind() == TokenKind.Match {
        left = self.parse_match_tail(left)
    }

    loop {
        const k = self.current_kind()
        // Assignment is right-associative and only at the top level - we detect it here before
        // falling through to the precedence ladder.
        if k == TokenKind.Equals and parent_precedence == 0i32 {
            let b = self.open(NodeKind.AssignmentExpr)
            b.start = self.tree.nodes[left].start as usize
            self.push_node_into(&b, left)
            self.eat_into(&b)
            const rhs = self.parse_expression()
            self.push_node_into(&b, rhs)
            return self.finish(b)
        }
        const prec = binary_op_precedence(k)
        if prec == 0i32 or prec <= parent_precedence {
            break
        }
        if k == TokenKind.DotDot {
            // A `..` opening a line starts a prefix range there (a match arm's `..0x20` pattern),
            // not a range over the line above.
            if self.at_line_start() {
                break
            }
            // Range - right side optional.
            let b = self.open(NodeKind.RangeExpr)
            b.start = self.tree.nodes[left].start as usize
            self.push_node_into(&b, left)
            self.eat_into(&b) // `..`
            if !is_range_delimiter(self.current_kind()) {
                const r = self.parse_binary_expression(prec)
                self.push_node_into(&b, r)
            }
            left = self.finish(b)
            continue
        }
        if k == TokenKind.QuestionQuestion {
            // Right-associative null-coalesce.
            let b = self.open(NodeKind.CoalesceExpr)
            b.start = self.tree.nodes[left].start as usize
            self.push_node_into(&b, left)
            self.eat_into(&b)
            const rhs = self.parse_binary_expression(prec - 1i32)
            self.push_node_into(&b, rhs)
            left = self.finish(b)
            continue
        }
        let b = self.open(NodeKind.BinaryExpr)
        b.start = self.tree.nodes[left].start as usize
        self.push_node_into(&b, left)
        self.eat_into(&b) // operator token
        const right = self.parse_binary_expression(prec)
        self.push_node_into(&b, right)
        left = self.finish(b)
    }

    return left
}

fn parse_unary_expression(self: &Parser) CstNodeId {
    return self.current_kind() match {
        Ampersand => self.parse_prefix_op(NodeKind.AddressOfExpr)
        Move => self.parse_prefix_op(NodeKind.MoveExpr)
        Minus | Bang | Tilde => self.parse_prefix_op(NodeKind.UnaryExpr)
        // Prefix range `..end` / `..`.
        DotDot => {
            let b = self.open(NodeKind.RangeExpr)
            self.eat_into(&b)
            if !is_range_delimiter(self.current_kind()) {
                const r = self.parse_binary_expression(0i32)
                self.push_node_into(&b, r)
            }
            self.finish(b)
        }
        _ => self.parse_primary_expression()
    }
}

// A prefix operator node of `kind` over the unary expression after it, postfix chain included.
fn parse_prefix_op(self: &Parser, kind: NodeKind) CstNodeId {
    let b = self.open(kind)
    self.eat_into(&b)
    const inner = self.parse_unary_expression()
    const tail = self.parse_postfix_chain(inner)
    self.push_node_into(&b, tail)
    return self.finish(b)
}

fn parse_postfix_chain(self: &Parser, expr: CstNodeId) CstNodeId {
    let cur = expr
    loop {
        cur = self.current_kind() match {
            Dot => self.parse_member_or_call_or_deref(cur)
            QuestionDot => {
                let b = self.open_around(NodeKind.NullPropagationExpr, cur)
                self.eat_into(&b)
                if self.current_kind() == TokenKind.Identifier {
                    self.eat_into(&b)
                }
                self.finish(b)
            }
            OpenBracket => {
                let b = self.open_around(NodeKind.IndexExpr, cur)
                self.eat_into(&b)
                const saved_brace = self.suspend_brace_stop()
                const idx = self.parse_expression()
                self.restore_brace_stop(saved_brace)
                self.push_node_into(&b, idx)
                self.expect_into(&b, TokenKind.CloseBracket, "E1002")
                self.finish(b)
            }
            Question => {
                let b = self.open_around(NodeKind.TryExpr, cur)
                self.eat_into(&b)
                self.finish(b)
            }
            // Call against an expression value (e.g. `(get())(x)`). For simple `name(args)` calls
            // the identifier branch in parse_primary_expression already wraps them - this handles
            // the chained / parenthesised cases.
            OpenParenthesis => {
                let b = self.open_around(NodeKind.CallExpr, cur)
                self.parse_call_args_into(&b)
                self.finish(b)
            }
            _ => break
        }
    }
    return cur
}

// A node of `kind` opened at `first`'s start, with `first` as its first child: the postfix and
// infix forms whose left operand is already parsed.
fn open_around(self: &Parser, kind: NodeKind, first: CstNodeId) NodeBuilder {
    let b = self.open(kind)
    b.start = self.tree.nodes[first].start as usize
    self.push_node_into(&b, first)
    return b
}

// `.field` / `.method(args)` / `.0` (tuple index) / `.*` (deref).
fn parse_member_or_call_or_deref(self: &Parser, recv: CstNodeId) CstNodeId {
    return self.peek_kind(1) match {
        // `.*` dereference.
        Star => {
            let b = self.open_around(NodeKind.DereferenceExpr, recv)
            self.eat_into(&b) // `.`
            self.eat_into(&b) // `*`
            self.finish(b)
        }
        // `.0` tuple field access.
        Integer => {
            let b = self.open_around(NodeKind.MemberAccessExpr, recv)
            self.eat_into(&b)
            self.eat_into(&b)
            self.finish(b)
        }
        // `.identifier` - may be followed by `(args)` for UFCS call.
        Identifier => {
            let b = self.open_around(NodeKind.MemberAccessExpr, recv)
            self.eat_into(&b) // `.`
            const name = self.current().text
            self.eat_into(&b) // identifier
            if self.current_kind() == TokenKind.OpenParenthesis {
                // Promote to UFCS call.
                b.kind = NodeKind.CallExpr
                self.parse_call_args_into(&b)
            }
            if !starts_uppercase(name) and self.at_trailing_lambda() {
                b.kind = NodeKind.CallExpr
                const lam = self.parse_brace_lambda()
                self.push_node_into(&b, lam)
            }
            self.finish(b)
        }
        // Stray `.` - record error and return a member-access shell.
        _ => {
            let b = self.open_around(NodeKind.MemberAccessExpr, recv)
            self.eat_into(&b)
            self.record_error_here("E1002", $"expected identifier, integer, or `*` after `.`")
            self.finish(b)
        }
    }
}

fn parse_call_args_into(self: &Parser, b: &NodeBuilder) {
    const saved_brace = self.suspend_brace_stop()
    defer self.restore_brace_stop(saved_brace)
    self.expect_into(b, TokenKind.OpenParenthesis, "E1002")
    while !self.at_eof() and self.current_kind() != TokenKind.CloseParenthesis {
        const arg = self.parse_call_arg()
        self.push_node_into(b, arg)
        if !self.eat_list_comma(b, TokenKind.CloseParenthesis) {
            break
        }
    }
    self.expect_into(b, TokenKind.CloseParenthesis, "E1002")
}

// After a list element: eat the `,` separating it from the next one. False when the list cannot
// continue - neither a comma nor `closer` follows.
fn eat_list_comma(self: &Parser, b: &NodeBuilder, closer: TokenKind) bool {
    const k = self.current_kind()
    if k == TokenKind.Comma {
        self.eat_into(b)
        return true
    }
    return k == closer
}

// `name = value` becomes a NamedArgumentExpr; otherwise just an expression. In argument position a
// `{` always opens a lambda (RFC-039).
fn parse_call_arg(self: &Parser) CstNodeId {
    if self.current_kind() == TokenKind.Identifier and self.peek_kind(1) == TokenKind.Equals
        and self.peek_kind(2) != TokenKind.Equals {
        let b = self.open(NodeKind.NamedArgumentExpr)
        self.eat_into(&b) // name
        self.eat_into(&b) // `=`
        const value = self.parse_arg_value()
        self.push_node_into(&b, value)
        return self.finish(b)
    }
    return self.parse_arg_value()
}

fn parse_arg_value(self: &Parser) CstNodeId {
    if self.current_kind() == TokenKind.OpenBrace {
        return self.parse_brace_lambda()
    }
    return self.parse_expression()
}

fn parse_primary_expression(self: &Parser) CstNodeId {
    return self.current_kind() match {
        Integer => self.single_token_node(NodeKind.IntegerLiteralExpr)
        Float => self.single_token_node(NodeKind.FloatLiteralExpr)
        StringLiteral => self.single_token_node(NodeKind.StringLiteralExpr)
        CharLiteral => self.single_token_node(NodeKind.CharLiteralExpr)
        ByteLiteral => self.single_token_node(NodeKind.ByteLiteralExpr)
        True | False => self.single_token_node(NodeKind.BooleanLiteralExpr)
        Null => self.single_token_node(NodeKind.NullLiteralExpr)
        Identifier => self.parse_identifier_primary()
        OpenParenthesis => self.parse_paren_expression()
        OpenBracket => self.parse_array_literal()
        OpenBrace => if self.at_lambda_brace() and !self.stop_at_brace {
            self.parse_brace_lambda()
        } else if self.stop_at_brace {
            self.error_token_node(
                "E1001",
                $"unexpected `{{` (block here would shadow control-flow body)",
            )
        } else {
            self.parse_block_expr()
        }
        If => self.parse_if_expr()
        For => self.parse_for_loop()
        Loop => self.parse_loop_expr()
        While => self.parse_while_loop()
        Fn => self.parse_lambda_expression()
        Context => if self.peek_kind(1) == TokenKind.OpenParenthesis {
            self.parse_context_bind()
        } else {
            self.single_token_node(NodeKind.ContextExpr)
        }
        // `.{ ... }` anonymous struct construction.
        Dot => if self.peek_kind(1) == TokenKind.OpenBrace {
            self.parse_anonymous_struct()
        } else {
            self.error_token_node("E1001", $"unexpected `.` in expression")
        }
        Dollar => self.parse_interpolated_string()
        Underscore => self.single_token_node(NodeKind.IdentifierExpr)
        InterpStringStart => self.parse_interp_string_body()
        _ => self.error_token_node(
            "E1001",
            $"unexpected token `{self.current().text}` in expression",
        )
    }
}

// `context(base?, name = value, ...) { body }` (RFC-038). The arguments take the call grammar; the
// body is always a block, whatever the surrounding header's brace rule.
fn parse_context_bind(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.ContextBindExpr)
    self.eat_into(&b) // `context`
    self.parse_call_args_into(&b)
    if self.current_kind() == TokenKind.OpenBrace {
        const body = self.parse_block_expr()
        self.push_node_into(&b, body)
    } else {
        self.record_expected(TokenKind.OpenBrace, "E1002")
    }
    return self.finish(b)
}

fn single_token_node(self: &Parser, kind: NodeKind) CstNodeId {
    let b = self.open(kind)
    self.eat_into(&b)
    return self.finish(b)
}

fn error_token_node(self: &Parser, code: String, message: move OwnedString) CstNodeId {
    let b = self.open(NodeKind.Error)
    self.record_error_at(code, message, self.current().offset, self.current().text.len)
    self.eat_into(&b)
    return self.finish(b)
}

// Identifier-starting primaries: bare name, function call, generic call, nominal struct
// construction (`Type { x = 1 }`), or generic struct construction (`Type(T) { x = 1 }`).
//
// A `{` after the name or its `(args)` is construction when the name starts uppercase, and a
// trailing lambda (RFC-039) when it starts lowercase and the `{` sits on the same line.
fn parse_identifier_primary(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.IdentifierExpr)
    const name = self.current().text
    const is_type = starts_uppercase(name) or is_primitive_name(name)
    self.eat_into(&b) // identifier

    if self.current_kind() == TokenKind.OpenParenthesis {
        b.kind = NodeKind.CallExpr
        self.parse_call_args_into(&b)
    }
    const brace_opens = self.current_kind() == TokenKind.OpenBrace and !self.stop_at_brace
    if brace_opens and is_type {
        // `Type { ... }` / `Type(T) { ... }` construction; a generic one's first children are the
        // type name and its arguments.
        b.kind = NodeKind.StructConstructionExpr
        self.parse_struct_construction_body(&b)
        return self.finish(b)
    }
    if !is_type and self.at_trailing_lambda() {
        b.kind = NodeKind.CallExpr
        const lam = self.parse_brace_lambda()
        self.push_node_into(&b, lam)
    }
    return self.finish(b)
}

// The case rule (RFC-039): a type's name starts uppercase, a function's lowercase or `_`.
fn starts_uppercase(name: String) bool {
    return name.len > 0 and name[0] >= 'A' and name[0] <= 'Z'
}

// A `{` opening a trailing lambda: on the line of what it follows, outside a control-flow header.
fn at_trailing_lambda(self: &Parser) bool {
    if self.current_kind() != TokenKind.OpenBrace or self.stop_at_brace {
        return false
    }
    return !self.at_line_start()
}

// Whether the `{` here opens a lambda outside argument and trailing position: the two tokens after
// it are `=>`, `ident =>`, `ident ,` or `ident :`, none of which can start a block.
fn at_lambda_brace(self: &Parser) bool {
    if self.current_kind() != TokenKind.OpenBrace {
        return false
    }
    if self.peek_kind(1) == TokenKind.FatArrow {
        return true
    }
    if self.peek_kind(1) != TokenKind.Identifier {
        return false
    }
    return self.peek_kind(2) match {
        FatArrow | Comma | Colon => true
        _ => false
    }
}

fn parse_struct_construction_body(self: &Parser, b: &NodeBuilder) {
    const saved_brace = self.suspend_brace_stop()
    defer self.restore_brace_stop(saved_brace)
    if !self.expect_into(b, TokenKind.OpenBrace, "E1002") {
        return
    }
    while !self.at_eof() and self.current_kind() != TokenKind.CloseBrace {
        if self.current_kind() == TokenKind.Identifier {
            self.eat_into(b)
            if self.current_kind() == TokenKind.Equals {
                self.eat_into(b)
                const value = self.parse_expression()
                self.push_node_into(b, value)
            }
            // Shorthand `field` - no `=`, name speaks for itself.
            if self.current_kind() == TokenKind.Comma {
                self.eat_into(b)
            }
        } else {
            self.record_expected(TokenKind.Identifier, "E1002")
            // Skip a token to break the loop on malformed input.
            self.eat_into(b)
            if self.current_kind() == TokenKind.Comma {
                self.eat_into(b)
            }
        }
    }
    self.expect_into(b, TokenKind.CloseBrace, "E1002")
}

fn parse_anonymous_struct(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.AnonymousStructExpr)
    self.eat_into(&b) // `.`
    self.parse_struct_construction_body(&b)
    return self.finish(b)
}

// `(a)` grouped expression, `(a, b)` tuple, `(a,)` 1-tuple. We don't surface different node kinds
// yet - both become a parenthesised run of expressions / commas under one node.
fn parse_paren_expression(self: &Parser) CstNodeId {
    // Empty `()` → unit, modelled as the zero-element tuple expression so
    // it projects (and type-checks) like any other tuple literal.
    if self.peek_kind(1) == TokenKind.CloseParenthesis {
        let b = self.open(NodeKind.AnonymousStructExpr)
        self.eat_into(&b)
        self.eat_into(&b)
        return self.finish(b)
    }
    let b = self.open(NodeKind.ParenExpr)
    self.eat_into(&b) // `(`
    const saved_brace = self.suspend_brace_stop()
    let count = 0usize
    let saw_comma = false
    while !self.at_eof() and self.current_kind() != TokenKind.CloseParenthesis {
        const e = self.parse_expression()
        self.push_node_into(&b, e)
        count = count + 1
        if self.current_kind() == TokenKind.Comma {
            self.eat_into(&b)
            saw_comma = true
            continue
        }
        break
    }
    self.expect_into(&b, TokenKind.CloseParenthesis, "E1002")
    self.restore_brace_stop(saved_brace)
    // A single expression with no trailing comma is a grouped expression; anything else (a comma,
    // zero elements, or several) is a tuple.
    if saw_comma or count != 1 {
        b.kind = NodeKind.AnonymousStructExpr
    }
    return self.finish(b)
}

fn parse_array_literal(self: &Parser) CstNodeId {
    const saved_brace = self.suspend_brace_stop()
    defer self.restore_brace_stop(saved_brace)
    let b = self.open(NodeKind.ArrayLiteralExpr)
    self.eat_into(&b) // `[`
    while !self.at_eof() and self.current_kind() != TokenKind.CloseBracket {
        const e = self.parse_expression()
        self.push_node_into(&b, e)
        self.current_kind() match {
            Comma => self.eat_into(&b)
            // `[T; N]` size syntax in expression position - preserve it.
            Semicolon => {
                self.eat_into(&b)
                const size_expr = self.parse_expression()
                self.push_node_into(&b, size_expr)
                break
            }
            CloseBracket => {}
            _ => break
        }
    }
    self.expect_into(&b, TokenKind.CloseBracket, "E1002")
    return self.finish(b)
}

// `fn(params) R { body }` - the removed lambda form (RFC-039). Parsed anyway so the rest of the
// file still reads, but rejected at its keyword (E1053).
fn parse_lambda_expression(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.LambdaExpr)
    self.record_error_here(
        "E1053",
        from_view(
            "`fn(params) R { body }` lambdas have been removed, use `{ params => body }` instead",
        ),
    )
    self.eat_into(&b) // `fn`
    if self.current_kind() == TokenKind.OpenParenthesis {
        self.eat_into(&b)
        while !self.at_eof() and self.current_kind() != TokenKind.CloseParenthesis {
            if self.current_kind() == TokenKind.Identifier {
                self.eat_into(&b)
            }
            if self.current_kind() == TokenKind.Colon {
                self.eat_into(&b)
                if self.current_kind() == TokenKind.Move {
                    self.eat_into(&b)
                }
                const t = self.parse_type()
                self.push_node_into(&b, t)
            }
            if !self.eat_list_comma(&b, TokenKind.CloseParenthesis) {
                break
            }
        }
        self.expect_into(&b, TokenKind.CloseParenthesis, "E1002")
    }
    if self.can_start_type(self.current_kind()) and self.current_kind() != TokenKind.OpenBrace {
        const t = self.parse_type()
        self.push_node_into(&b, t)
    }
    if self.current_kind() == TokenKind.OpenBrace {
        const body = self.parse_block_expr()
        self.push_node_into(&b, body)
    }
    return self.finish(b)
}

// `{ params => body }` or the arrow-less `{ body }` (RFC-039). Parameters are `name` or `name:
// [move] Type`, comma-separated. The body is a `BlockExpr` without an opening brace that takes the
// lambda's closing `}`.
fn parse_brace_lambda(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.LambdaExpr)
    const has_arrow = self.at_lambda_brace()
    self.eat_into(&b) // `{`
    if has_arrow {
        self.parse_brace_lambda_params(&b)
    }
    const body = self.parse_lambda_body()
    self.push_node_into(&b, body)
    return self.finish(b)
}

fn parse_brace_lambda_params(self: &Parser, b: &NodeBuilder) {
    loop {
        self.current_kind() match {
            Eof | FatArrow | CloseBrace => break
            _ => {}
        }
        if self.current_kind() == TokenKind.Identifier {
            self.eat_into(b)
        } else {
            self.record_expected(TokenKind.Identifier, "E1002")
            self.eat_into(b)
            continue
        }
        if self.current_kind() == TokenKind.Colon {
            self.eat_into(b)
            if self.current_kind() == TokenKind.Move {
                self.eat_into(b)
            }
            const t = self.parse_type()
            self.push_node_into(b, t)
        }
        if self.current_kind() == TokenKind.Comma {
            self.eat_into(b)
        }
    }
    self.expect_into(b, TokenKind.FatArrow, "E1002")
}

fn parse_lambda_body(self: &Parser) CstNodeId {
    const saved_brace = self.suspend_brace_stop()
    defer self.restore_brace_stop(saved_brace)
    const saved_loops = self.loop_depth
    self.loop_depth = 0
    self.lambda_depth = self.lambda_depth + 1
    defer self.leave_lambda(saved_loops)
    let b = self.open(NodeKind.BlockExpr)
    while !self.at_eof() and self.current_kind() != TokenKind.CloseBrace {
        const stmt = self.parse_statement()
        self.push_node_into(&b, stmt)
    }
    self.expect_into(&b, TokenKind.CloseBrace, "E1002")
    return self.finish(b)
}

fn leave_lambda(self: &Parser, saved_loops: usize) {
    self.loop_depth = saved_loops
    self.lambda_depth = self.lambda_depth - 1
}

// `$"…"` / `$(args)"…"` / `$ident"…"`. The lexer resolves all three
// forms on its own (`interp_prefix_quote`), so the builder arguments of form 2 parse as a real
// argument list - the projector reads them as expression children.
fn parse_interpolated_string(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.InterpolatedStringExpr)
    self.eat_into(&b) // `$`
    self.current_kind() match {
        OpenParenthesis => self.parse_call_args_into(&b)
        Identifier => self.eat_into(&b)
        _ => {}
    }
    self.current_kind() match {
        InterpStringStart => self.parse_interp_body_into(&b)
        StringLiteral => self.eat_into(&b)
        // `$123"…"` - only `"`, `(args)` and an identifier may follow a
        // `$` that opens an interpolated string (E1020).
        _ => self.record_error_here(
            "E1020",
            from_view("expected `\"`, `(`, or an identifier after `$`"),
        )
    }
    return self.finish(b)
}

// When the lexer hands us a pre-positioned InterpStringStart (the
// inline `$"…"` form, recognised by adjacency in lex_token_text), we
// parse the body straight in without a wrapping `$`.
fn parse_interp_string_body(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.InterpolatedStringExpr)
    self.parse_interp_body_into(&b)
    return self.finish(b)
}

fn parse_interp_body_into(self: &Parser, b: &NodeBuilder) {
    self.eat_into(b) // InterpStringStart
    loop {
        self.current_kind() match {
            InterpStringEnd | Eof | BadToken => break
            InterpHoleStart => self.parse_interp_hole_into(b)
            // A segment, or anything unknown - eaten to keep position progressing.
            _ => self.eat_into(b)
        }
    }
    if self.current_kind() == TokenKind.InterpStringEnd {
        self.eat_into(b)
    } else {
        // The scanner ran to end-of-source (or a bad token) with the string still open (E1024).
        self.record_error_here("E1024", from_view("unterminated interpolated string"))
    }
}

// `{expr}` or `{expr:spec}` inside an interpolated string.
fn parse_interp_hole_into(self: &Parser, b: &NodeBuilder) {
    self.eat_into(b)
    const saved_brace = self.suspend_brace_stop()
    const expr = self.parse_expression()
    self.restore_brace_stop(saved_brace)
    self.push_node_into(b, expr)
    if self.current_kind() == TokenKind.InterpFormatSep {
        self.eat_into(b)
        if self.current_kind() == TokenKind.InterpFormatSpec {
            self.eat_into(b)
        }
    }
    if self.current_kind() == TokenKind.InterpHoleEnd {
        self.eat_into(b)
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────

pub fn parse_type(self: &Parser) CstNodeId {
    const inner = self.parse_prefix_type()
    // Postfix `?` for optional.
    let cur = inner
    while self.current_kind() == TokenKind.Question {
        let b = self.open(NodeKind.OptionalType)
        b.start = self.tree.nodes[cur].start as usize
        self.push_node_into(&b, cur)
        self.eat_into(&b)
        cur = self.finish(b)
    }
    return cur
}

fn parse_prefix_type(self: &Parser) CstNodeId {
    if self.current_kind() == TokenKind.Ampersand {
        let b = self.open(NodeKind.ReferenceType)
        self.eat_into(&b)
        // `&move T` - a slot the callee may take from, declared in `core` alone (RFC-033). The
        // `move` rides on the reference node; the type itself is `&T`.
        if self.current_kind() == TokenKind.Move {
            self.eat_into(&b)
        }
        const inner = self.parse_prefix_type()
        self.push_node_into(&b, inner)
        return self.finish(b)
    }
    let cur = self.parse_primary_type()
    // Postfix `[]` for slice (only when `]` immediately follows `[`).
    while self.current_kind() == TokenKind.OpenBracket
        and self.peek_kind(1) == TokenKind.CloseBracket {
        let b = self.open(NodeKind.SliceType)
        b.start = self.tree.nodes[cur].start as usize
        self.push_node_into(&b, cur)
        self.eat_into(&b)
        self.eat_into(&b)
        cur = self.finish(b)
    }
    return cur
}

fn parse_primary_type(self: &Parser) CstNodeId {
    return self.current_kind() match {
        Identifier => self.parse_named_type()
        // Generic type-parameter binder `$T` - single Dollar + identifier.
        Dollar => {
            let b = self.open(NodeKind.NamedType)
            self.eat_into(&b)
            if self.current_kind() == TokenKind.Identifier {
                self.eat_into(&b)
            }
            self.finish(b)
        }
        OpenBracket => self.parse_array_type()
        OpenParenthesis => self.parse_tuple_type()
        Fn => {
            let b = self.open(NodeKind.FunctionType)
            self.eat_into(&b)
            self.parse_fn_type_tail_into(&b)
            self.finish(b)
        }
        Contract => self.parse_contract_type()
        Struct => {
            let b = self.open(NodeKind.AnonymousStructType)
            self.eat_into(&b)
            self.parse_struct_body_into(&b)
            self.finish(b)
        }
        Enum => {
            let b = self.open(NodeKind.AnonymousEnumType)
            self.eat_into(&b)
            self.parse_enum_body_into(&b)
            self.finish(b)
        }
        // Fall through - wrap into Error so the formatter still has the bytes.
        _ => {
            let b = self.open(NodeKind.Error)
            self.record_error_here("E1002", $"expected a type, found `{self.current().text}`")
            if !self.at_eof() {
                self.eat_into(&b)
            }
            self.finish(b)
        }
    }
}

// `Name`, `Name(args)`, and the projections `I.Item`, `C.Iter.Item` a dotted name in type position
// spells.
fn parse_named_type(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.NamedType)
    self.eat_into(&b)
    if self.current_kind() == TokenKind.OpenParenthesis {
        self.parse_type_args_into(&b)
    }
    let cur = self.finish(b)
    while self.current_kind() == TokenKind.Dot and self.peek_kind(1) == TokenKind.Identifier {
        let p = self.open_around(NodeKind.ProjectionType, cur)
        self.eat_into(&p)
        self.eat_into(&p)
        cur = self.finish(p)
    }
    return cur
}

// `[T; N]` fixed-size array.
fn parse_array_type(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.ArrayType)
    self.eat_into(&b)
    const elem = self.parse_type()
    self.push_node_into(&b, elem)
    if self.current_kind() == TokenKind.Semicolon {
        self.eat_into(&b)
        // `[i32; "five"]` - a fixed array's length is a compile-time integer, not any expression
        // (E1004). Identifiers are let through: a `const` length resolves later.
        self.current_kind() match {
            Integer | Identifier => {}
            _ => self.record_error_here(
                "E1004",
                from_view("invalid array length - the length must be an integer literal"),
            )
        }
        const size = self.parse_expression()
        self.push_node_into(&b, size)
    }
    self.expect_into(&b, TokenKind.CloseBracket, "E1002")
    return self.finish(b)
}

// `(A, B)` tuple type or `()` unit.
fn parse_tuple_type(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.TupleType)
    self.eat_into(&b)
    while !self.at_eof() and self.current_kind() != TokenKind.CloseParenthesis {
        const t = self.parse_type()
        self.push_node_into(&b, t)
        if !self.eat_list_comma(&b, TokenKind.CloseParenthesis) {
            break
        }
    }
    self.expect_into(&b, TokenKind.CloseParenthesis, "E1002")
    return self.finish(b)
}

// `(params) ret?` of a function type or a contract requirement.
fn parse_fn_type_tail_into(self: &Parser, b: &NodeBuilder) {
    if self.current_kind() == TokenKind.OpenParenthesis {
        self.eat_into(b)
        while !self.at_eof() and self.current_kind() != TokenKind.CloseParenthesis {
            // Optional parameter name: `fn(x: T)` - peek `ident :` then eat both before falling
            // through to the type expr.
            if self.current_kind() == TokenKind.Identifier
                and self.peek_kind(1) == TokenKind.Colon {
                self.eat_into(b)
                self.eat_into(b)
            }
            if self.current_kind() == TokenKind.Move {
                self.eat_into(b)
            }
            const t = self.parse_type()
            self.push_node_into(b, t)
            if !self.eat_list_comma(b, TokenKind.CloseParenthesis) {
                break
            }
        }
        self.expect_into(b, TokenKind.CloseParenthesis, "E1002")
    }
    // The return type shares the `)`'s line: a type opening the next line starts the next member.
    if self.can_start_type(self.current_kind()) and !self.at_line_start() {
        const ret = self.parse_type()
        self.push_node_into(b, ret)
    }
}

// `contract(T: B) { members }` - members are requirements (`fn name(params) ret`) and associated
// types (`type S`, `type S: Bound`, `type S = T`), separated by newlines or commas.
fn parse_contract_type(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.ContractType)
    self.eat_into(&b)
    self.parse_type_params_into(&b)
    if !self.expect_into(&b, TokenKind.OpenBrace, "E1002") {
        return self.finish(b)
    }
    while !self.at_eof() and self.current_kind() != TokenKind.CloseBrace {
        self.current_kind() match {
            Fn => {
                let m = self.open(NodeKind.ContractRequirement)
                self.eat_into(&m)
                self.expect_into(&m, TokenKind.Identifier, "E1002")
                self.parse_fn_type_tail_into(&m)
                const node = self.finish(m)
                self.push_node_into(&b, node)
            }
            Type => {
                const node = self.parse_contract_assoc_type()
                self.push_node_into(&b, node)
            }
            _ => {
                self.record_error_here(
                    "E1002",
                    $"expected `fn` or `type` in a contract body, found `{self.current().text}`",
                )
                self.eat_into(&b)
            }
        }
        if self.current_kind() == TokenKind.Comma {
            self.eat_into(&b)
        }
    }
    self.expect_into(&b, TokenKind.CloseBrace, "E1002")
    return self.finish(b)
}

// `type S`, `type S: Bound` or `type S = T` in a contract body.
fn parse_contract_assoc_type(self: &Parser) CstNodeId {
    let m = self.open(NodeKind.ContractAssocType)
    self.eat_into(&m)
    self.expect_into(&m, TokenKind.Identifier, "E1002")
    self.current_kind() match {
        Colon => {
            self.eat_into(&m)
            const t = self.parse_bound_type()
            self.push_node_into(&m, t)
        }
        Equals => {
            self.eat_into(&m)
            const t = self.parse_type()
            self.push_node_into(&m, t)
        }
        _ => {}
    }
    return self.finish(m)
}

fn parse_type_args_into(self: &Parser, b: &NodeBuilder) {
    self.eat_into(b) // `(`
    while !self.at_eof() and self.current_kind() != TokenKind.CloseParenthesis {
        const named = self.current_kind() == TokenKind.Identifier
            and (self.peek_kind(1) == TokenKind.Equals or self.peek_kind(1) == TokenKind.Colon)
        const t = if named { self.parse_named_type_arg() } else { self.parse_type() }
        self.push_node_into(b, t)
        if !self.eat_list_comma(b, TokenKind.CloseParenthesis) {
            break
        }
    }
    self.expect_into(b, TokenKind.CloseParenthesis, "E1002")
}

// `Item = T` pins a contract's associated type, `Item: Bound` bounds it.
fn parse_named_type_arg(self: &Parser) CstNodeId {
    let b = self.open(NodeKind.NamedTypeArg)
    self.eat_into(&b)
    const pins = self.current_kind() == TokenKind.Equals
    self.eat_into(&b)
    const t = if pins { self.parse_type() } else { self.parse_bound_type() }
    self.push_node_into(&b, t)
    return self.finish(b)
}

// ─────────────────────────────────────────────────────────────────────────
// Precedence table - mirrors docs/syntax.md operator table.
// ─────────────────────────────────────────────────────────────────────────

fn binary_op_precedence(kind: TokenKind) i32 {
    return kind match {
        TokenKind.Star => 12i32
        TokenKind.Slash => 12i32
        TokenKind.Percent => 12i32
        TokenKind.Plus => 11i32
        TokenKind.Minus => 11i32
        TokenKind.ShiftLeft => 10i32
        TokenKind.ShiftRight => 10i32
        TokenKind.UnsignedShiftRight => 10i32
        TokenKind.Ampersand => 9i32
        TokenKind.Caret => 8i32
        TokenKind.Pipe => 7i32
        TokenKind.DotDot => 6i32
        TokenKind.LessThan => 5i32
        TokenKind.GreaterThan => 5i32
        TokenKind.LessThanOrEqual => 5i32
        TokenKind.GreaterThanOrEqual => 5i32
        TokenKind.EqualsEquals => 4i32
        TokenKind.NotEquals => 4i32
        TokenKind.And => 3i32
        TokenKind.Or => 2i32
        TokenKind.QuestionQuestion => 1i32
        else => 0i32
    }
}

fn is_range_delimiter(kind: TokenKind) bool {
    return kind == TokenKind.CloseBracket or kind == TokenKind.CloseParenthesis
        or kind == TokenKind.Comma or kind == TokenKind.CloseBrace or kind == TokenKind.Semicolon
        or kind == TokenKind.Eof
}
