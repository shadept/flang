// flang_fmt - the FLang source formatter.
//
// Lossless by construction: the input is lexed and parsed to the CST (every source byte lives in
// some token's leading trivia, text, or trailing trivia), the trivia is rewritten under the style
// policy in FmtConfig, and the tree is re-emitted. Token text is never touched.
//
// Safety gate: before an output is returned it is re-lexed and re-parsed. It must parse cleanly,
// its token stream must match the input's with commas and statement semicolons set aside (the
// tokens separator policy may add or drop), and the two parse trees must have the same shape. Any
// mismatch returns VerifyFailed instead of the output - a formatter must never change what the code
// means.
//
// Style policy (see the Rendering section for the mechanics):
//   - spacing and indentation are recomputed on every line
//   - blank-line runs collapse to `max_blank_lines`
//   - no trailing whitespace; exactly one final newline
//   - the file's prevailing line ending (LF or CRLF) is detected and kept,
//     so a checkout's eol convention never counts as a formatting change
//
// Line breaks: a newline can end a statement in FLang, so structural breaks (between statements,
// inside brace bodies) are always the author's. Breaks inside `(`/`[` groups and before `and`/`or`
// are layout, not structure: with `join_lines` on they re-flow, and `max_width` decides where the
// line breaks. Blank lines and comment placement always survive.

import std.conv
import std.list
import std.option
import std.result
import std.string
import std.string_builder
import std.test
import flang_parser.cst
import flang_parser.lexer
import flang_parser.parser
import flang_parser.token
import flang_parser.trivia

// ─────────────────────────────────────────────────────────────────────────
// Configuration
// ─────────────────────────────────────────────────────────────────────────

// How a separator that the grammar makes optional is written:
//   No        - omitted wherever a newline already separates
//   Multiline - present when the construct spans lines, absent on one line
//   Always    - always present; forces the construct multiline
pub type SeparatorMode = enum {
    No
    Multiline
    Always
}

// Style policy. Loaded from a manifest's `[fmt]` table via `set_option`; `default_config()` is the
// house style.
pub type FmtConfig = struct {
    // Spaces per indentation level.
    indent: usize
    // Wrap trigger in columns; 0 disables wrapping.
    max_width: usize
    // Maximum consecutive blank lines.
    max_blank_lines: usize
    // Trailing comma in comma-separated lists (call args, array literals, struct construction).
    trailing_comma: SeparatorMode
    // Optional separators where a newline already separates (struct fields, enum variants, match
    // arms).
    separators: SeparatorMode
    // Re-flow line breaks inside groups and before and/or, letting max_width decide the layout.
    // Off, authored breaks all stand.
    join_lines: bool
    // Re-fill own-line comment prose to max_width.
    reflow_comments: bool
    // Statement separators: `a(); b()` becomes one statement per line and the enclosing block goes
    // multiline.
    remove_semicolons: bool
    // Force a multiline body on single-line `if`s, by form and position.
    ml_if_stmt: bool
    ml_if_else_stmt: bool
    ml_if_expr: bool
}

pub fn default_config() FmtConfig {
    return FmtConfig {
        indent = 4,
        max_width = 100,
        max_blank_lines = 1,
        trailing_comma = SeparatorMode.Multiline,
        separators = SeparatorMode.No,
        join_lines = true,
        reflow_comments = true,
        remove_semicolons = true,
        ml_if_stmt = true,
        ml_if_else_stmt = true,
        ml_if_expr = false,
    }
}

// Apply one `[fmt]` manifest entry. Returns false for an unknown key or an unparsable value; the
// config is left unchanged in that case.
pub fn set_option(self: &FmtConfig, key: String, val: String) bool {
    if key == "indent" {
        return set_usize(&self.indent, val)
    }
    if key == "max-width" {
        return set_usize(&self.max_width, val)
    }
    if key == "max-blank-lines" {
        return set_usize(&self.max_blank_lines, val)
    }
    if key == "trailing-comma" {
        return set_mode(&self.trailing_comma, val)
    }
    if key == "separators" {
        return set_mode(&self.separators, val)
    }
    if key == "join-lines" {
        return set_bool(&self.join_lines, val)
    }
    if key == "reflow-comments" {
        return set_bool(&self.reflow_comments, val)
    }
    if key == "semicolons" {
        if val == "remove" or val == "keep" {
            self.remove_semicolons = val == "remove"
            return true
        }
        return false
    }
    if key == "if-stmt" {
        return set_layout(&self.ml_if_stmt, val)
    }
    if key == "if-else-stmt" {
        return set_layout(&self.ml_if_else_stmt, val)
    }
    if key == "if-expr" {
        return set_layout(&self.ml_if_expr, val)
    }
    return false
}

fn set_layout(slot: &bool, val: String) bool {
    if val == "multiline" or val == "keep" {
        slot.* = val == "multiline"
        return true
    }
    return false
}

fn set_bool(slot: &bool, val: String) bool {
    if val == "true" {
        slot.* = true
        return true
    }
    if val == "false" {
        slot.* = false
        return true
    }
    return false
}

fn set_usize(slot: &usize, val: String) bool {
    const r = parse_usize(val)
    if r.is_err() {
        return false
    }
    const parsed = r.unwrap()
    if parsed.1 != val.len {
        return false
    }
    slot.* = parsed.0 as usize
    return true
}

fn set_mode(slot: &SeparatorMode, val: String) bool {
    if val == "no" {
        slot.* = SeparatorMode.No
        return true
    }
    if val == "multiline" {
        slot.* = SeparatorMode.Multiline
        return true
    }
    if val == "always" {
        slot.* = SeparatorMode.Always
        return true
    }
    return false
}

// ─────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────

pub type FmtError = enum {
    // The input does not parse; the count is the number of parse diagnostics. Nothing is formatted
    // - broken code stays untouched.
    ParseFailed(usize)
    // The formatted output's token stream differs from the input's. This is a formatter bug; the
    // output is discarded.
    VerifyFailed
}

// Format FLang source text. Pure: no IO, the caller owns both strings.
//
// Formatting runs to a fixpoint: a wrap inserted by one pass is an authored line break to the next,
// which can in turn move a separator. Real inputs settle in one or two passes; an output still
// changing after four is a formatter bug and is refused rather than left oscillating.
pub fn format_source(source: String, cfg: &FmtConfig) Result(OwnedString, FmtError) {
    let current = from_view(source)
    let passes = 0usize
    while passes < 4 {
        const pass = format_once(current.as_view(), cfg)
        if pass.is_err() {
            const e = pass.unwrap_err()
            current.deinit()
            return Err(e)
        }
        let next = pass.unwrap()
        if next.as_view() == current.as_view() {
            next.deinit()
            return Ok(current)
        }
        current.deinit()
        current = next
        passes = passes + 1
    }
    current.deinit()
    return Err(FmtError.VerifyFailed)
}

fn format_once(source: String, cfg: &FmtConfig) Result(OwnedString, FmtError) {
    let lx = lexer(source)
    let tokens = lx.tokenize()
    // `parser` takes the token list into its `Cst`; `p.deinit()` frees both.
    let p = parser(tokens, source)
    defer p.deinit()
    const cst = p.tree.node_at(p.parse_module())

    const parse_errors = p.diagnostics.len
    if parse_errors > 0 {
        return Err(FmtError.ParseFailed(parse_errors))
    }

    const raw_owned = render_module(&cst, cfg)
    const out = normalize(raw_owned.as_view(), source, cfg)
    raw_owned.deinit()

    if !verify_output(&p.tree.tokens, &cst, out.as_view()) {
        out.deinit()
        return Err(FmtError.VerifyFailed)
    }
    return Ok(out)
}

// ─────────────────────────────────────────────────────────────────────────
// Rendering
//
// One depth-first walk over the CST re-emits every token with recomputed trivia. Structural line
// breaks are kept (a newline in FLang can end a statement); layout breaks re-flow under
// `join_lines`; the rest is policy:
//
//   - horizontal space between two tokens on a line comes from the pair's
//     kinds plus the CST node each belongs to (so `-` in `a - b` spaces
//     while `-a` glues, `(` of a call glues while `(A, B)` of a tuple type
//     does not)
//   - a line's indentation is brace depth, plus one step per group (`(`,
//     `[`) still open at the break, plus one step when the line starts
//     with a binary operator or `.`-chain continuation
//   - blank-line runs clamp to `max_blank_lines`
//   - a comment on its own line is indented like the code around it; a
//     comment trailing code gets exactly one space before `//`
//
// Inside an interpolated string ($"..."), authored spacing is preserved verbatim: segment text is
// token text, and hole spacing is the author's.
// ─────────────────────────────────────────────────────────────────────────

// A place the current line may legally break: just after a list comma. `offset` indexes into the
// line buffer; `indent` is the continuation indentation (in spaces) the split-off remainder gets.
type WrapPoint = struct {
    offset: usize
    indent: usize
}

pub fn deinit(self: &WrapPoint) {}

type Renderer = struct {
    // Completed lines. The line being built lives in `line` so it can still be split at a wrap
    // point; it flushes at every line break.
    out: StringBuilder
    line: StringBuilder
    cfg: &FmtConfig
    // Break opportunities on the current line, in order.
    wrap_points: List(WrapPoint)
    // Nesting state while streaming tokens.
    brace_depth: usize
    group_depth: usize
    interp_depth: usize
    // group_depth as it was when each currently-open brace opened. A brace resets continuation
    // indent: groups opened before it stop counting.
    group_marks: List(usize)
    // Newlines seen in trivia since the last emitted token or comment.
    pending_newlines: usize
    // Horizontal whitespace seen since then (drives authored-spacing fallbacks, e.g. inside
    // interpolated strings).
    gap_had_space: bool
    // True once a comment lands on the current line; nothing may be appended to the line after it.
    line_has_comment: bool
    // False until the first token or comment is emitted; leading blank lines of the file are
    // dropped while false.
    started: bool
    prev_kind: TokenKind
    // The last token was a prefix `-` / `!` / `~`: nothing may separate it from its operand (`Less
    // = -1`).
    prev_prefix: bool
    prev_parent: NodeKind
    // Trivia is not stored on tokens; it is the source between them.
    //
    // `prev_end` is where the last emitted token's trailing trivia stopped, so a token's leading
    // trivia is [prev_end, tok.offset). Leading is emitted before the token's text and trailing
    // after it, because guards such as the `OpenBrace` one in the forced-children walk read
    // `pending_newlines` straight after `render_token`.
    //
    // `tokens` and `tok_index` find where the next token starts, which bounds the trailing scan.
    // The bound is load-bearing: inside an interpolated string the bytes after a hole's `}` belong
    // to the segment token, and an unbounded scan would emit them as trivia too.
    source: String
    tokens: &List(Token)
    tok_index: usize
    prev_end: usize
}

fn render_module(cst: &CstNode, cfg: &FmtConfig) OwnedString {
    let r = Renderer {
        out = string_builder(cst.end + 16),
        line = string_builder(128),
        cfg = cfg,
        wrap_points = list(0),
        brace_depth = 0,
        group_depth = 0,
        interp_depth = 0,
        group_marks = list(0),
        pending_newlines = 0,
        gap_had_space = false,
        line_has_comment = false,
        started = false,
        prev_kind = TokenKind.Eof,
        prev_prefix = false,
        prev_parent = NodeKind.Module,
        source = cst.cst.source,
        tokens = &cst.cst.tokens,
        tok_index = 0,
        prev_end = 0,
    }
    render_node(&r, cst, NodeKind.Module)
    flush_line(&r)
    r.line.deinit()
    r.wrap_points.deinit()
    r.group_marks.deinit()
    return r.out.to_string()
}

fn flush_line(r: &Renderer) {
    if r.line.len > 0 {
        r.out.append(r.line.as_view())
        r.line.clear()
    }
    r.wrap_points.clear()
}

fn render_node(r: &Renderer, node: &CstNode, parent: NodeKind) {
    if node.kind == NodeKind.IfExpr {
        // An `if` directly under a block (or at top level) is a statement; anywhere else it is an
        // expression.
        render_if(r, node, parent == NodeKind.BlockExpr or parent == NodeKind.Module)
        return
    }
    if node.kind == NodeKind.BlockExpr {
        render_block(r, node, false)
        return
    }
    for i in 0..node.child_count() {
        const child = node.child(i)
        child match {
            NodeChild(inner) => {
                render_node(r, &inner, node.kind)
                maybe_insert_separator(r, node, i)
            }
            TokenChild(tok) => {
                if tok.kind == TokenKind.Semicolon and r.cfg.remove_semicolons
                    and is_statement_kind(node.kind) {
                    // A statement separator becomes the line break it stood in for.
                    skip_token_keep_trivia(r, tok)
                    if r.pending_newlines == 0 {
                        r.pending_newlines = 1
                    }
                } else if tok.kind == TokenKind.Comma and skip_comma(r, node, i) {
                    skip_token_keep_trivia(r, tok)
                } else {
                    maybe_insert_trailing_comma(r, node, tok)
                    render_token(r, tok, node.kind)
                }
            }
        }
    }
}

fn is_statement_kind(kind: NodeKind) bool {
    return kind == NodeKind.ExpressionStmt or kind == NodeKind.ReturnStmt
        or kind == NodeKind.VariableDecl or kind == NodeKind.BreakStmt
        or kind == NodeKind.ContinueStmt or kind == NodeKind.DeferStmt
}

// An `if` in statement position defaults to a multiline body; in expression position a single-line
// `if c { a } else { b }` may stay. Chained `else if`s inherit the chain head's position.
fn render_if(r: &Renderer, node: &CstNode, stmt_pos: bool) {
    let has_else = false
    for i in 0..node.child_count() {
        node.child(i) match {
            TokenChild(t) => { if t.kind == TokenKind.Else {
                    has_else = true
                } }
            NodeChild(_) => {}
        }
    }
    let force = r.cfg.ml_if_expr
    if stmt_pos {
        force = if has_else { r.cfg.ml_if_else_stmt } else { r.cfg.ml_if_stmt }
    }

    for i in 0..node.child_count() {
        const child = node.child(i)
        child match {
            NodeChild(inner) => {
                if inner.kind == NodeKind.BlockExpr {
                    render_block(r, &inner, force)
                } else if inner.kind == NodeKind.IfExpr {
                    render_if(r, &inner, stmt_pos)
                } else {
                    render_node(r, &inner, node.kind)
                }
            }
            TokenChild(tok) => render_token(r, tok, node.kind)
        }
    }
}

// A block body. `force` puts the braces on their own lines; a block whose statements carry
// semicolons the config removes forces itself.
fn render_block(r: &Renderer, node: &CstNode, force: bool) {
    let f = force or (r.cfg.remove_semicolons and block_has_semicolon(node))
    if element_count(node) == 0 {
        f = false
    }

    for i in 0..node.child_count() {
        const child = node.child(i)
        child match {
            NodeChild(inner) => render_node(r, &inner, node.kind)
            TokenChild(tok) => {
                if tok.kind == TokenKind.CloseBrace and f and r.pending_newlines == 0 {
                    r.pending_newlines = 1
                }
                render_token(r, tok, node.kind)
                if tok.kind == TokenKind.OpenBrace and f and r.pending_newlines == 0 {
                    r.pending_newlines = 1
                }
            }
        }
    }
}

// True when any direct statement of the block ends in a `;` token.
fn block_has_semicolon(node: &CstNode) bool {
    for i in 0..node.child_count() {
        const child = node.child(i)
        const has = child match {
            NodeChild(stmt) => stmt_has_semicolon(&stmt)
            TokenChild(_) => false
        }
        if has {
            return true
        }
    }
    return false
}

fn stmt_has_semicolon(stmt: &CstNode) bool {
    if !is_statement_kind(stmt.kind) {
        return false
    }
    for i in 0..stmt.child_count() {
        const is_semi = stmt.child(i) match {
            TokenChild(t) => t.kind == TokenKind.Semicolon
            NodeChild(_) => false
        }
        if is_semi {
            return true
        }
    }
    return false
}

// ─────────────────────────────────────────────────────────────────────────
// Separator policy
//
// Two families of comma, two knobs:
//
//   trailing_comma - lists whose commas the grammar requires between
//   elements but leaves optional after the last one: call args, params,
//   array literals, struct construction, generic argument lists. The
//   comma before the closer is the only one at stake.
//
//   separators - positions where a newline already separates and the
//   comma itself is optional: struct/enum declaration bodies and match
//   arms.
//
// Both are decided while streaming: a comma is dropped by skipping its token (its trivia still
// flows), and inserted by appending "," at the end of the current line. A line that already carries
// a comment accepts no insertion - the comma would land inside the comment.
// ─────────────────────────────────────────────────────────────────────────

// Whether this comma child of `node` should not be emitted.
fn skip_comma(r: &Renderer, node: &CstNode, i: usize) bool {
    const parent = node.kind

    // A trailing comma: the next child is this list's closing token.
    if is_comma_list(parent) and next_child_is(node, i, list_closer(parent)) {
        // `(T,)` is a one-element tuple and `(T)` is not: that comma is grammar, not style.
        if is_tuple_kind(parent) and element_count(node) < 2 {
            return false
        }
        return r.cfg.trailing_comma match {
            No => true
            // Kept when the list is multiline, dropped on one line.
            Multiline => !newline_after_child(node, i)
            Always => false
        }
    }

    if is_separator_body(parent) {
        // Only commas a newline makes redundant; single-line bodies keep theirs (the grammar needs
        // them there).
        return !mode_on(r.cfg.separators) and newline_after_child(node, i)
    }

    return false
}

// Append a trailing comma before a closer that starts its own line.
fn maybe_insert_trailing_comma(r: &Renderer, node: &CstNode, tok: &Token) {
    const parent = node.kind
    if !is_comma_list(parent) {
        return
    }
    if tok.kind != list_closer(parent) {
        return
    }
    if !mode_on(r.cfg.trailing_comma) {
        return
    }
    // Adding the comma to a one-element tuple form would turn `(T)` into the tuple `(T,)`.
    if is_tuple_kind(parent) and element_count(node) < 2 {
        return
    }
    if !r.started or r.line_has_comment {
        return
    }
    if r.pending_newlines == 0 and !leading_has_newline(r, tok) {
        return
    }
    if r.prev_kind == TokenKind.Comma {
        return
    }
    // An empty list has its opener as the previous token.
    if r.prev_kind == TokenKind.OpenParenthesis or r.prev_kind == TokenKind.OpenBracket
        or r.prev_kind == TokenKind.OpenBrace {
        return
    }
    r.line.append(",")
}

// Under `separators = multiline|always`, every newline-separated field, variant, or arm gets its
// comma.
fn maybe_insert_separator(r: &Renderer, node: &CstNode, i: usize) {
    if !mode_on(r.cfg.separators) {
        return
    }
    if !is_separator_body(node.kind) {
        return
    }
    const child = node.child(i)
    const elem = child match {
        NodeChild(n) => n.kind == NodeKind.StructField or n.kind == NodeKind.EnumVariant
            or n.kind == NodeKind.MatchArm
        TokenChild(_) => false
    }
    if !elem {
        return
    }
    if next_child_is(node, i, TokenKind.Comma) {
        return
    }
    if r.line_has_comment {
        return
    }
    if !newline_after_child(node, i) {
        return
    }
    r.line.append(",")
}

// Emit a skipped token's comments and newlines without the token itself.
fn skip_token_keep_trivia(r: &Renderer, tok: &Token) {
    emit_leading(r, tok)
    emit_trailing(r, tok)
}

fn is_tuple_kind(kind: NodeKind) bool {
    return kind == NodeKind.TupleType or kind == NodeKind.TuplePattern
}

fn element_count(node: &CstNode) usize {
    let n: usize = 0
    for i in 0..node.child_count() {
        node.child(i) match {
            NodeChild(_) => { n = n + 1 }
            TokenChild(_) => {}
        }
    }
    return n
}

// Whether a separator knob asks for commas at all.
fn mode_on(m: SeparatorMode) bool {
    return m match {
        No => false
        Multiline => true
        Always => true
    }
}

fn is_comma_list(kind: NodeKind) bool {
    return kind == NodeKind.CallExpr or kind == NodeKind.FunctionDecl
        or kind == NodeKind.GeneratorInvocation or kind == NodeKind.NamedType
        or kind == NodeKind.FunctionType or kind == NodeKind.LambdaExpr
        or kind == NodeKind.EnumVariant or kind == NodeKind.EnumVariantPattern
        or kind == NodeKind.TupleType or kind == NodeKind.TuplePattern
        or kind == NodeKind.ArrayLiteralExpr or kind == NodeKind.StructConstructionExpr
        or kind == NodeKind.AnonymousStructExpr
}

fn list_closer(kind: NodeKind) TokenKind {
    if kind == NodeKind.ArrayLiteralExpr {
        return TokenKind.CloseBracket
    }
    if kind == NodeKind.StructConstructionExpr or kind == NodeKind.AnonymousStructExpr {
        return TokenKind.CloseBrace
    }
    return TokenKind.CloseParenthesis
}

// Bodies where a newline already separates elements: the `separators` knob governs their commas.
fn is_separator_body(kind: NodeKind) bool {
    return kind == NodeKind.StructDecl or kind == NodeKind.EnumDecl
        or kind == NodeKind.AnonymousStructType or kind == NodeKind.AnonymousEnumType
        or kind == NodeKind.MatchExpr
}

fn next_child_is(node: &CstNode, i: usize, kind: TokenKind) bool {
    if i + 1 >= node.child_count() {
        return false
    }
    return node.child(i + 1) match {
        TokenChild(t) => t.kind == kind
        NodeChild(_) => false
    }
}

// True when a line break sits between child `i` and whatever follows it.
fn newline_after_child(node: &CstNode, i: usize) bool {
    const last = last_token_of(&node.child(i))
    if last.is_none() or i + 1 >= node.child_count() {
        return false
    }
    const next = first_token_of(&node.child(i + 1))
    if next.is_none() {
        return false
    }
    // Everything between the two tokens is trivia, so the only question is whether a newline is in
    // there.
    const l = last.unwrap()
    return spans_newline(node.cst.source, l.offset + l.text.len, next.unwrap().offset)
}

// Emit every piece of trivia between the last token and this one, in order.
//
// The leading/trailing split is not reconstructed: `handle_trivia` counts newlines and spaces
// inside a run and never looks at run boundaries, so one bounded walk of the gap is enough. The
// split matters only where it changes an answer - see `leading_has_newline`.
fn walk_trivia(r: &Renderer, from: usize, to: usize) {
    let it = trivia_in(r.source, from, to)
    loop {
        const t = it.next()
        if t.is_none() {
            break
        }
        const piece = t.unwrap()
        handle_trivia(r, &piece)
    }
}

// Where the token after `tok` starts, bounding how far its trailing trivia may reach. Tokens are
// visited in source order, so the cursor steps forward.
fn next_token_start(r: &Renderer, tok: &Token) usize {
    while r.tok_index < r.tokens.len and r.tokens[r.tok_index].offset < tok.offset {
        r.tok_index = r.tok_index + 1
    }
    if r.tok_index + 1 < r.tokens.len {
        return r.tokens[r.tok_index + 1].offset
    }
    return r.source.len
}

fn emit_leading(r: &Renderer, tok: &Token) {
    walk_trivia(r, r.prev_end, tok.offset)
}

fn emit_trailing(r: &Renderer, tok: &Token) {
    const end = tok.offset + tok.text.len
    const split = trailing_end(r.source, end, next_token_start(r, tok))
    walk_trivia(r, end, split)
    r.prev_end = split
}

// Whether a newline sits in `tok`'s leading trivia, not counting the one that ended the previous
// token's line.
fn leading_has_newline(r: &Renderer, tok: &Token) bool {
    return spans_newline(r.source, r.prev_end, tok.offset)
}

fn first_token_of(child: &CstChild) Token? {
    child.* match {
        TokenChild(t) => return Some(t.*)
        NodeChild(n) => {
            for i in 0..n.child_count() {
                const found = first_token_of(&n.child(i))
                if found.is_some() {
                    return found
                }
            }
        }
    }
    return None
}

fn last_token_of(child: &CstChild) Token? {
    child.* match {
        TokenChild(t) => return Some(t.*)
        NodeChild(n) => {
            let i = n.child_count()
            while i > 0 {
                i = i - 1
                const found = last_token_of(&n.child(i))
                if found.is_some() {
                    return found
                }
            }
        }
    }
    return None
}

fn render_token(r: &Renderer, tok: &Token, parent: NodeKind) {
    emit_leading(r, tok)
    if tok.kind == TokenKind.Eof {
        return
    }

    if r.pending_newlines > 0 and r.started and !joinable(r, tok.kind, parent) {
        emit_line_break(r, tok.kind)
    } else if r.started {
        r.pending_newlines = 0
        // A break may land right before `and` / `or`, so the opportunity is recorded before the
        // operator (and its leading space) lands.
        if (tok.kind == TokenKind.And or tok.kind == TokenKind.Or) and r.interp_depth == 0
            and parent != NodeKind.GeneratorDef {
            record_wrap_point(r, 1)
        }
        let space = needs_space(r, tok.kind, parent)
        const fresh = maybe_wrap(r, tok.text.len + if space { 1usize } else { 0usize })
        if fresh {
            space = false
        }
        if space {
            r.line.append(" ")
        }
    }
    r.pending_newlines = 0
    r.gap_had_space = false

    r.line.append(tok.text)
    update_depths(r, tok.kind)
    if tok.kind == TokenKind.Comma and r.interp_depth == 0 and is_comma_list(parent) {
        record_wrap_point(r, 0)
    }
    // Prefix when the CST says so, or when what precedes cannot end an expression (an enum
    // discriminant's `-1` sits outside any UnaryExpr).
    r.prev_prefix = (tok.kind == TokenKind.Minus or tok.kind == TokenKind.Bang
        or tok.kind == TokenKind.Tilde) and (parent == NodeKind.UnaryExpr
        or !ends_expression(r.prev_kind))
    r.prev_kind = tok.kind
    r.prev_parent = parent
    r.started = true

    emit_trailing(r, tok)
}

// Whether the pending line break may be re-flowed into a space, leaving `max_width` to decide the
// layout. Only a lone newline qualifies (blank lines and comment-carrying breaks are the author's),
// and only where the wrap pass could put a break back:
//   - inside an open `(` / `[` group (commas and operators re-break), or
//   - before `and` / `or`, whose continuation style wrap reproduces, or
//   - before `-`, `(` or `[` continuing the expression above. These three are the tokens that could
//     equally open a statement of their own, so a break in front of one draws two statements where
//     the parse has one. Joining is what removes the ambiguity; `.`, `and` and the rest cannot be
//     misread at the start of a line and keep their authored break.
// A brace body resets the group count, so statements inside a lambda or block passed as an argument
// are never merged.
fn joinable(r: &Renderer, next: TokenKind, parent: NodeKind) bool {
    if !r.cfg.join_lines or r.cfg.max_width == 0 {
        return false
    }
    if parent == NodeKind.GeneratorDef {
        return false
    }
    if r.pending_newlines != 1 {
        return false
    }
    if r.line_has_comment {
        return false
    }
    if r.interp_depth > 0 {
        return false
    }
    const eff = r.group_depth - open_groups_at_brace(r)
    if eff > 0 {
        return true
    }
    if next == TokenKind.OpenParenthesis or next == TokenKind.OpenBracket
        or next == TokenKind.Minus {
        return ends_expression(r.prev_kind)
    }
    return next == TokenKind.And or next == TokenKind.Or
}

// If appending `incoming` more bytes would push the line past max_width, split it at the last
// recorded wrap point. Returns true when the split left the incoming token to start the new line
// (so no space precedes it).
fn maybe_wrap(r: &Renderer, incoming: usize) bool {
    if r.cfg.max_width == 0 {
        return false
    }
    if r.wrap_points.len == 0 {
        return false
    }
    if r.line.len + incoming <= r.cfg.max_width {
        return false
    }

    // The last point that still fits the width; the earliest one when even that is too far out.
    let pick = 0usize
    for i in 0..r.wrap_points.len {
        if r.wrap_points[i].offset <= r.cfg.max_width {
            pick = i
        }
    }
    const wp = r.wrap_points[pick]

    const view = r.line.as_view()
    r.out.append(view[0..wp.offset])
    r.out.append_byte('\n' as u8)
    let s = wp.offset
    while s < view.len and view[s] == ' ' {
        s = s + 1
    }
    const rest = from_view(view[s..view.len])
    r.line.clear()
    for n in 0..wp.indent {
        r.line.append_byte(' ' as u8)
    }
    r.line.append(rest.as_view())
    const fresh = rest.len == 0
    rest.deinit()

    // Points that moved to the new line keep working, re-based onto it - a long joined list may
    // need several breaks.
    let kept: List(WrapPoint) = list(0)
    for i in 0..r.wrap_points.len {
        const p = r.wrap_points[i]
        if p.offset > wp.offset and p.offset >= s {
            kept.push(WrapPoint {
                offset = wp.indent + (p.offset - s),
                indent = p.indent,
            })
        }
    }
    r.wrap_points.deinit()
    r.wrap_points = kept
    return fresh
}

// `min_extra` is 1 for a break before `and` / `or`: the operator starts the next line and indents
// as a continuation even with no group open.
fn record_wrap_point(r: &Renderer, min_extra: usize) {
    let eff = r.group_depth - open_groups_at_brace(r)
    if eff < min_extra {
        eff = min_extra
    }
    r.wrap_points.push(WrapPoint {
        offset = r.line.len,
        indent = (r.brace_depth + eff) * r.cfg.indent,
    })
}

fn handle_trivia(r: &Renderer, t: &Trivia) {
    t.kind match {
        Whitespace => {
            for i in 0..t.text.len {
                const c = t.text[i]
                if c == '\n' {
                    r.pending_newlines = r.pending_newlines + 1
                } else if c == ' ' or c == '\t' {
                    r.gap_had_space = true
                }
            }
        }
        LineComment => emit_comment(r, t.text)
    }
}

// A comment either trails code on the current line (one space before it) or opens a line of its own
// (indented like code). Trailing whitespace inside the comment is stripped.
fn emit_comment(r: &Renderer, text: String) {
    let end = text.len
    while end > 0 and (text[end - 1] == ' ' or text[end - 1] == '\t' or text[end - 1] == '\r') {
        end = end - 1
    }
    const body = text[0..end]

    if !r.started {
        r.pending_newlines = 0
    } else if r.pending_newlines > 0 {
        // Not a closer: comments never adjust the depth they sit at.
        emit_line_break(r, TokenKind.Identifier)
        r.pending_newlines = 0
    } else {
        r.line.append(" ")
    }
    r.line.append(body)
    r.gap_had_space = false
    r.line_has_comment = true
    r.started = true
}

// Emit the newline run (clamped) and the next line's indentation.
fn emit_line_break(r: &Renderer, next: TokenKind) {
    let blanks = 0usize
    if r.pending_newlines > 1 {
        blanks = r.pending_newlines - 1
        if blanks > r.cfg.max_blank_lines {
            blanks = r.cfg.max_blank_lines
        }
    }
    r.pending_newlines = 0
    r.line_has_comment = false
    flush_line(r)
    for n in 0..(blanks + 1) {
        r.out.append_byte('\n' as u8)
    }

    let depth = r.brace_depth
    if next == TokenKind.CloseBrace and depth > 0 {
        depth = depth - 1
    }
    // Groups opened before the innermost open brace stop contributing: inside `f(x, .{ <here> })`
    // the block's brace governs, not f's paren.
    let groups = r.group_depth - open_groups_at_brace(r)
    if (next == TokenKind.CloseParenthesis or next == TokenKind.CloseBracket) and groups > 0 {
        groups = groups - 1
    }
    let extra = groups
    if extra == 0 and is_continuation_start(next, r.prev_kind) {
        extra = 1
    }
    const spaces = (depth + extra) * r.cfg.indent
    for n in 0..spaces {
        r.line.append_byte(' ' as u8)
    }
}

fn open_groups_at_brace(r: &Renderer) usize {
    if r.group_marks.len == 0 {
        return 0
    }
    const at = r.group_marks[r.group_marks.len - 1]
    return if at < r.group_depth { at } else { r.group_depth }
}

fn update_depths(r: &Renderer, kind: TokenKind) {
    if kind == TokenKind.OpenBrace {
        r.brace_depth = r.brace_depth + 1
        r.group_marks.push(r.group_depth)
    }
    if kind == TokenKind.CloseBrace and r.brace_depth > 0 {
        r.brace_depth = r.brace_depth - 1
        if r.group_marks.len > 0 {
            r.group_marks.pop()
        }
    }
    if kind == TokenKind.OpenParenthesis or kind == TokenKind.OpenBracket {
        r.group_depth = r.group_depth + 1
    }
    if (kind == TokenKind.CloseParenthesis or kind == TokenKind.CloseBracket)
        and r.group_depth > 0 {
        r.group_depth = r.group_depth - 1
    }
    if kind == TokenKind.InterpStringStart {
        r.interp_depth = r.interp_depth + 1
    }
    if kind == TokenKind.InterpStringEnd and r.interp_depth > 0 {
        r.interp_depth = r.interp_depth - 1
    }
}

// A line starting with one of these continues the previous line's expression and indents one extra
// step.
//
// `(` and `[` continue only what could already be a complete expression. The parser is greedy: with
// no statement terminator, a bracket opening a line joins the line above as a call or an index, so
// drawing it at statement indent would show two statements where the parse has one. After a token
// that cannot end an expression - an open brace, most obviously - the same bracket opens a
// statement of its own.
fn is_continuation_start(kind: TokenKind, prev: TokenKind) bool {
    if kind == TokenKind.OpenParenthesis or kind == TokenKind.OpenBracket {
        return ends_expression(prev)
    }
    return kind == TokenKind.Dot or kind == TokenKind.QuestionDot
        or kind == TokenKind.QuestionQuestion or kind == TokenKind.And or kind == TokenKind.Or
        or kind == TokenKind.Pipe or kind == TokenKind.Plus or kind == TokenKind.Minus
        or kind == TokenKind.Star or kind == TokenKind.Slash or kind == TokenKind.Percent
        or kind == TokenKind.Caret or kind == TokenKind.EqualsEquals or kind == TokenKind.NotEquals
        or kind == TokenKind.LessThan or kind == TokenKind.GreaterThan
        or kind == TokenKind.LessThanOrEqual or kind == TokenKind.GreaterThanOrEqual
        or kind == TokenKind.ShiftLeft or kind == TokenKind.ShiftRight
        or kind == TokenKind.UnsignedShiftRight or kind == TokenKind.FatArrow
        or kind == TokenKind.Equals or kind == TokenKind.As
}

// ─────────────────────────────────────────────────────────────────────────
// Spacing policy
// ─────────────────────────────────────────────────────────────────────────

// Whether one space separates the previous token from `cur` when both sit on the same line. Default
// is a single space; the rules below carve out the pairs that glue.
fn needs_space(r: &Renderer, cur: TokenKind, parent: NodeKind) bool {
    const prev = r.prev_kind

    // Interpolated strings keep authored spacing.
    if r.interp_depth > 0 {
        return r.gap_had_space
    }
    // So do generator definitions: their body is a template where token adjacency around `#(...)`
    // splices is pasting (`#(Name)Vtable` expands to one identifier), which no spacing rule may
    // disturb.
    if parent == NodeKind.GeneratorDef or r.prev_parent == NodeKind.GeneratorDef {
        return r.gap_had_space
    }
    if r.prev_prefix {
        return false
    }
    // `$sb"..."` appends into a builder: the target identifier glues to the opening quote.
    if cur == TokenKind.InterpStringStart and prev == TokenKind.Identifier {
        return false
    }

    if prev == TokenKind.OpenBrace {
        return cur != TokenKind.CloseBrace
    }
    if cur == TokenKind.OpenBrace {
        // `.{ ... }` anonymous struct literals glue to the dot.
        return prev != TokenKind.Dot
    }
    if cur == TokenKind.CloseBrace {
        return true
    }

    // `+=`, `-=`, ... lex as two tokens inside an AssignmentExpr. The operator's own parent
    // distinguishes them from `x.* = v`, where the `*` belongs to the deref on the left-hand side.
    if cur == TokenKind.Equals and parent == NodeKind.AssignmentExpr and is_binary_op(prev)
        and r.prev_parent == NodeKind.AssignmentExpr {
        return false
    }

    // Match-arm patterns are a flat token run under MatchArm, so a payload paren (`Some(x)`) is
    // recognized by what precedes it.
    if cur == TokenKind.OpenParenthesis and parent == NodeKind.MatchArm {
        return prev != TokenKind.Identifier
    }

    if glue_after(prev, r.prev_parent) {
        return false
    }
    // An open-started range (`for i in ..a.len`) has nothing to glue its `..` to: it spaces off
    // like any prefix. With a left operand present the range glues (`0..n`).
    if (cur == TokenKind.DotDot or cur == TokenKind.DotDotEquals) and !ends_expression(prev) {
        return true
    }
    if glue_before(cur, parent) {
        return false
    }
    return true
}

// No space ever follows these.
fn glue_after(kind: TokenKind, parent: NodeKind) bool {
    if kind == TokenKind.OpenParenthesis or kind == TokenKind.OpenBracket {
        return true
    }
    if is_dot_like(kind) {
        return true
    }
    if kind == TokenKind.Hash or kind == TokenKind.Dollar {
        return true
    }
    // Prefix operators glue to their operand.
    // `&` glues in `&expr`, `&T`, and `for &x in ...` bindings; it spaces as a binary operator.
    if kind == TokenKind.Ampersand {
        return parent != NodeKind.BinaryExpr
    }
    return false
}

// No space ever precedes these.
fn glue_before(kind: TokenKind, parent: NodeKind) bool {
    if kind == TokenKind.CloseParenthesis or kind == TokenKind.CloseBracket {
        return true
    }
    if kind == TokenKind.Comma or kind == TokenKind.Semicolon or kind == TokenKind.Colon {
        return true
    }
    if kind == TokenKind.Question {
        return true
    }
    if is_dot_like(kind) {
        // The leading dot of `.{ ... }` stands off from what precedes it.
        return parent != NodeKind.AnonymousStructExpr
    }
    // `(` glues to a callee, a declared name, or a generic parameter list (`struct(K)`); a tuple or
    // grouping paren stands off.
    if kind == TokenKind.OpenParenthesis {
        return parent == NodeKind.CallExpr or parent == NodeKind.FunctionDecl
            or parent == NodeKind.NamedType or parent == NodeKind.FunctionType
            or parent == NodeKind.LambdaExpr or parent == NodeKind.GeneratorDef
            or parent == NodeKind.GeneratorInvocation or parent == NodeKind.EnumVariant
            or parent == NodeKind.EnumVariantPattern or parent == NodeKind.StructDecl
            or parent == NodeKind.EnumDecl or parent == NodeKind.TypeAliasDecl
            or parent == NodeKind.AnonymousStructType or parent == NodeKind.AnonymousEnumType
    }
    // `[` glues in `a[i]` and `T[]`; an array literal or `[T; N]` type stands off.
    if kind == TokenKind.OpenBracket {
        return parent == NodeKind.IndexExpr or parent == NodeKind.SliceType
    }
    return false
}

// Tokens that can end an expression, i.e. that a postfix `..` glues to.
fn ends_expression(kind: TokenKind) bool {
    return kind == TokenKind.Identifier or kind == TokenKind.Integer or kind == TokenKind.Float
        or kind == TokenKind.StringLiteral or kind == TokenKind.CharLiteral
        or kind == TokenKind.ByteLiteral or kind == TokenKind.True or kind == TokenKind.False
        or kind == TokenKind.Null or kind == TokenKind.Underscore
        or kind == TokenKind.CloseParenthesis or kind == TokenKind.CloseBracket
        or kind == TokenKind.CloseBrace or kind == TokenKind.InterpStringEnd
        or kind == TokenKind.Question
}

fn is_dot_like(kind: TokenKind) bool {
    return kind == TokenKind.Dot or kind == TokenKind.DotDot or kind == TokenKind.DotDotEquals
        or kind == TokenKind.QuestionDot
}

fn is_binary_op(kind: TokenKind) bool {
    return kind == TokenKind.Plus or kind == TokenKind.Minus or kind == TokenKind.Star
        or kind == TokenKind.Slash or kind == TokenKind.Percent or kind == TokenKind.Ampersand
        or kind == TokenKind.Pipe or kind == TokenKind.Caret or kind == TokenKind.ShiftLeft
        or kind == TokenKind.ShiftRight or kind == TokenKind.UnsignedShiftRight
}

// ─────────────────────────────────────────────────────────────────────────
// Verification
// ─────────────────────────────────────────────────────────────────────────

// Re-lex and re-parse the output and require that (1) it parses cleanly, (2) its token stream
// matches the input's with commas and semicolons set aside (the tokens the separator policy may add
// or drop), and (3) the parse trees have the same shape - so a comma edit that would change what
// the code means can never survive.
fn verify_output(tokens: &List(Token), cst: &CstNode, output: String) bool {
    let lx = lexer(output)
    // `parser` takes the list into its `Cst`; `p.deinit()` frees it.
    let p = parser(lx.tokenize(), output)
    defer p.deinit()
    const out_cst = p.tree.node_at(p.parse_module())
    if p.diagnostics.len > 0 {
        return false
    }

    if !same_tokens_modulo_separators(tokens, &p.tree.tokens) {
        return false
    }
    return same_shape(cst, &out_cst)
}

fn same_tokens_modulo_separators(a: &List(Token), b: &List(Token)) bool {
    let i = 0usize
    let j = 0usize
    loop {
        while i < a.len and is_separator_kind(a[i].kind) { i = i + 1 }
        while j < b.len and is_separator_kind(b[j].kind) { j = j + 1 }
        if i >= a.len or j >= b.len {
            break
        }
        if a[i].kind != b[j].kind {
            return false
        }
        if a[i].text != b[j].text {
            return false
        }
        i = i + 1
        j = j + 1
    }
    return i >= a.len and j >= b.len
}

fn is_separator_kind(kind: TokenKind) bool {
    return kind == TokenKind.Comma or kind == TokenKind.Semicolon
}

// Structural equality of two CSTs, ignoring the separator tokens the formatter may add or drop
// (commas and statement semicolons).
fn same_shape(a: &CstNode, b: &CstNode) bool {
    if a.kind != b.kind {
        return false
    }
    let i = 0usize
    let j = 0usize
    loop {
        while i < a.child_count() and is_comma_child(&a.child(i)) { i = i + 1 }
        while j < b.child_count() and is_comma_child(&b.child(j)) { j = j + 1 }
        if i >= a.child_count() or j >= b.child_count() {
            break
        }
        const ok = a.child(i) match {
            NodeChild(xn) => b.child(j) match {
                NodeChild(yn) => same_shape(&xn, &yn)
                TokenChild(_) => false
            }
            TokenChild(xt) => b.child(j) match {
                NodeChild(_) => false
                TokenChild(yt) => xt.kind == yt.kind and xt.text == yt.text
            }
        }
        if !ok {
            return false
        }
        i = i + 1
        j = j + 1
    }
    return i >= a.child_count() and j >= b.child_count()
}

fn is_comma_child(child: &CstChild) bool {
    return child.* match {
        TokenChild(t) => is_separator_kind(t.kind)
        NodeChild(_) => false
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Line hygiene + blank lines
// ─────────────────────────────────────────────────────────────────────────

// The renderer emits LF-only text with no final newline guarantee; this reflows comment prose, adds
// the single trailing newline, and re-expands to CRLF when the original file used it.
fn normalize(rendered: String, original: String, cfg: &FmtConfig) OwnedString {
    const reflow_width = if cfg.reflow_comments { cfg.max_width } else { 0usize }
    const reflowed = reflow_comments(rendered, reflow_width)
    const unix = ensure_single_trailing_newline(reflowed.as_view())
    reflowed.deinit()
    if !uses_crlf(original) {
        return unix
    }
    const final = expand_crlf(unix.as_view())
    unix.deinit()
    return final
}

// ─────────────────────────────────────────────────────────────────────────
// Comment reflow
//
// Consecutive own-line `//` comments that read as plain prose re-fill to `width` columns, so narrow
// historical wrapping widens and over-long prose breaks. Structure is left alone; a line ends its
// paragraph (and is emitted verbatim) when any of these hold:
//
//   - it is not an own-line comment (code, blank line, trailing comment)
//   - its text starts with a list/table/ruler character (* + | > # = ~
//     /), a ``` code fence, or extra indentation (example blocks)
//   - it starts with `- ` outside a paragraph (a bullet); the same dash
//     mid-paragraph is a wrapped aside and joins, unless the previous
//     line ended with `:` (a list intro)
//   - it starts a numbered list ("1. ")
//   - it contains two adjacent spaces (aligned columns)
//   - it contains a non-ASCII byte (box drawing, arrows)
//   - it is an empty `//` (a paragraph separator)
//
// A short line also ends its paragraph: only a line filled past half of `width` joins with its
// successor, so deliberate short lines ("Build: ...", one-line notes) stay put while historical
// 70-80 column fills join. The fill itself never breaks a line before it passes that same halfway
// mark, which keeps refilled output stable under a second reflow.
// ─────────────────────────────────────────────────────────────────────────

fn reflow_comments(text: String, width: usize) OwnedString {
    if width == 0 {
        return from_view(text)
    }
    const threshold = width / 2
    let sb = string_builder(text.len + 64)
    let words: List(String) = list(0)
    defer words.deinit()
    let para_indent: usize = 0
    let last_len: usize = 0
    let last_colon = false

    let pos: usize = 0
    while pos < text.len {
        let nl = pos
        while nl < text.len and text[nl] != '\n' {
            nl = nl + 1
        }
        const line = text[pos..nl]
        const has_nl = nl < text.len

        const parsed = parse_comment_line(line)
        // Mid-paragraph: the previous line was full prose at this indent and did not introduce a
        // list. Decides whether a leading `- ` is a wrapped aside (joins) or a bullet (verbatim).
        const mid = words.len > 0 and parsed.0 == para_indent and last_len > threshold
            and !last_colon
        if parsed.2 and is_comment_prose(parsed.1, mid) {
            if words.len > 0 and (parsed.0 != para_indent or last_len <= threshold) {
                flush_paragraph(&sb, &words, para_indent, width, threshold)
            }
            para_indent = parsed.0
            push_words(&words, parsed.1)
            last_len = line.len
            last_colon = parsed.1.len > 0 and parsed.1[parsed.1.len - 1] == ':'
        } else {
            flush_paragraph(&sb, &words, para_indent, width, threshold)
            sb.append(line)
            if has_nl {
                sb.append_byte('\n' as u8)
            }
            last_colon = false
        }
        pos = nl + 1
    }
    flush_paragraph(&sb, &words, para_indent, width, threshold)
    return sb.to_string()
}

// (indent, text after `// `, is-own-line-comment).
fn parse_comment_line(line: String) (usize, String, bool) {
    let i: usize = 0
    while i < line.len and line[i] == ' ' {
        i = i + 1
    }
    if i + 1 >= line.len {
        return (0, "", false)
    }
    if line[i] != '/' or line[i + 1] != '/' {
        return (0, "", false)
    }
    let content = line[(i + 2)..line.len]
    if content.len > 0 and content[0] == ' ' {
        content = content[1..content.len]
    }
    return (i, content, true)
}

fn is_comment_prose(content: String, mid_paragraph: bool) bool {
    if content.len == 0 {
        return false
    }
    const c0 = content[0]
    if c0 == ' ' or c0 == '*' or c0 == '+' or c0 == '|' or c0 == '>' or c0 == '#' or c0 == '='
        or c0 == '~' or c0 == '/' {
        return false
    }
    // A leading dash mid-paragraph is a wrapped aside ("... the state byte
    // / - and its padding - disappears"); anywhere else it is a bullet.
    if c0 == '-' {
        return mid_paragraph
    }
    // A leading backtick is a code fence only when tripled; a single one opens inline code, which
    // is prose.
    if c0 == '`' {
        if content.len >= 3 and content[1] == '`' and content[2] == '`' {
            return false
        }
    }
    // Numbered-list head: digits, a dot, then a space or the end.
    let d: usize = 0
    while d < content.len and content[d] >= '0' and content[d] <= '9' {
        d = d + 1
    }
    if d > 0 and d < content.len and content[d] == '.' {
        if d + 1 >= content.len or content[d + 1] == ' ' {
            return false
        }
    }
    let i: usize = 0
    while i < content.len {
        if content[i] >= 0x80 as u8 {
            return false
        }
        if content[i] == ' ' and i + 1 < content.len and content[i + 1] == ' ' {
            return false
        }
        i = i + 1
    }
    return true
}

fn push_words(words: &List(String), content: String) {
    let start: usize = 0
    let i: usize = 0
    while i <= content.len {
        const at_break = i == content.len or content[i] == ' '
        if at_break {
            if i > start {
                words.push(content[start..i])
            }
            start = i + 1
        }
        i = i + 1
    }
}

// Greedy fill: a line takes words until the next would pass `width`, but never breaks before
// passing `threshold` - a huge word may push a line over `width` instead of leaving a short line
// behind.
fn flush_paragraph(sb: &StringBuilder, words: &List(String), indent: usize, width: usize,
    threshold: usize) {
    if words.len == 0 {
        return
    }
    let col: usize = 0
    for i in 0..words.len {
        const w = words[i]
        if col == 0 {
            open_comment_line(sb, indent)
            col = indent + 2
        } else if col + 1 + w.len > width and col > threshold {
            sb.append_byte('\n' as u8)
            open_comment_line(sb, indent)
            col = indent + 2
        }
        sb.append(" ")
        sb.append(w)
        col = col + 1 + w.len
    }
    sb.append_byte('\n' as u8)
    words.clear()
}

fn open_comment_line(sb: &StringBuilder, indent: usize) {
    for n in 0..indent {
        sb.append_byte(' ' as u8)
    }
    sb.append("//")
}

// The file's prevailing line ending, decided by its first newline. A file with no newline defaults
// to LF.
fn uses_crlf(source: String) bool {
    let i = 0usize
    while i < source.len {
        if source[i] == '\n' {
            return i > 0 and source[i - 1] == '\r'
        }
        i = i + 1
    }
    return false
}

fn expand_crlf(source: String) OwnedString {
    let sb = string_builder(source.len + source.len / 16)
    let i = 0usize
    while i < source.len {
        if source[i] == '\n' {
            sb.append_byte('\r' as u8)
        }
        sb.append_byte(source[i])
        i = i + 1
    }
    return sb.to_string()
}

fn ensure_single_trailing_newline(source: String) OwnedString {
    let end = source.len
    while end > 0 and (source[end - 1] == ' ' or source[end - 1] == '\t'
        or source[end - 1] == '\n') {
        end = end - 1
    }
    let sb = string_builder(end + 1)
    sb.append(source[0..end])
    if end > 0 {
        sb.append_byte('\n' as u8)
    }
    return sb.to_string()
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

test "line hygiene: trailing ws stripped, final newline added" {
    const cfg = default_config()
    const r = format_source("fn main() i32 {\n    return 0  \n}", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == "fn main() i32 {\n    return 0\n}\n", "normalized")
}

test "crlf files stay crlf, lf files stay lf" {
    const cfg = default_config()
    const rc = format_source("fn a() {}\r\nfn b() {}", &cfg)
    let outc = rc.unwrap()
    defer outc.deinit()
    assert_true(outc.as_view() == "fn a() {}\r\nfn b() {}\r\n", "crlf kept")

    const rl = format_source("fn a() {}\nfn b() {}\r\n", &cfg)
    let outl = rl.unwrap()
    defer outl.deinit()
    assert_true(outl.as_view() == "fn a() {}\nfn b() {}\n", "first ending wins")
}

test "blank lines collapse to max_blank_lines" {
    const cfg = default_config()
    const r = format_source("fn a() {}\n\n\n\n\nfn b() {}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == "fn a() {}\n\nfn b() {}\n", "one blank kept")
}

test "already formatted input is unchanged" {
    const cfg = default_config()
    const src = "// doc\nfn main() i32 {\n    return 0\n}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == src, "idempotent on clean input")
}

test "spacing normalizes around punctuation and operators" {
    const cfg = default_config()
    const r = format_source("fn f(a:i32 ,b : i32) i32 {\n    return a+b\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == "fn f(a: i32, b: i32) i32 {\n    return a + b\n}\n", "spaced")
}

test "unary and call positions glue" {
    const cfg = default_config()
    const r = format_source("fn f(p: bool) bool {\n    return ! g ( p )\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == "fn f(p: bool) bool {\n    return !g(p)\n}\n", "glued")
}

test "indentation recomputed from nesting" {
    const cfg = default_config()
    const r = format_source("fn f() {\nlet x = 1\n        if x > 0 {\n   return\n      }\n}\n",
        &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == "fn f() {\n    let x = 1\n    if x > 0 {\n        return\n    }\n}\n",
        "reindented")
}

test "operator continuation lines join when they fit" {
    const cfg = default_config()
    const r = format_source("fn f(a: bool, b: bool) bool {\n    return a\n    or b\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == "fn f(a: bool, b: bool) bool {\n    return a or b\n}\n", "joined")
}

test "group newlines join and re-wrap at width" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "max-width", "24"), "width set")
    const r = format_source("fn f() {\n    ggg(aaaaaaaa,\n    bbbbbbbb,\n    cccccccc)\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == "fn f() {\n    ggg(aaaaaaaa,\n        bbbbbbbb,\n        cccccccc)\n}\n",
        "rewrapped")
}

test "a call split before its argument list is joined" {
    const cfg = default_config()
    const r = format_source("fn f() i32 {\n    let b = take\n    (4)\n    return b\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == "fn f() i32 {\n    let b = take(4)\n    return b\n}\n",
        "the parser reads one call, so the layout shows one")
}

test "a continuing minus is joined" {
    const cfg = default_config()
    const r = format_source("fn f() i32 {\n    let a = one()\n    - 3\n    return a\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == "fn f() i32 {\n    let a = one() - 3\n    return a\n}\n",
        "a leading `-` continues the line above and reads as a statement otherwise")
}

test "a paren opening a statement is left alone" {
    const cfg = default_config()
    const src = "fn f() i32 {\n    if c {\n        (a ?? b).len()\n    }\n    return 0\n}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == src, "nothing precedes it that could end an expression")
}

test "join-lines false indents the continuation instead" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "join-lines", "false"), "knob set")
    const r = format_source("fn f() i32 {\n    let b = take\n    (4)\n    return b\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == "fn f() i32 {\n    let b = take\n        (4)\n    return b\n}\n",
        "the break is kept, so the indent carries the parse")
}

test "join-lines false keeps authored breaks" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "join-lines", "false"), "knob set")
    const r = format_source("fn f(a: bool, b: bool) bool {\n    return a\n        or b\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == "fn f(a: bool, b: bool) bool {\n    return a\n        or b\n}\n",
        "kept split")
}

test "blank lines and comments block joining" {
    const cfg = default_config()
    const src = "fn f(a: i32, b: i32) i32 {\n    return g(a, // note\n        b)\n}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == src, "comment break kept")
}

test "statements inside a lambda argument never join" {
    const cfg = default_config()
    const src = "fn f() {\n    g(fn() {\n        a()\n        b()\n    })\n}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == src, "lambda body intact")
}

test "trailing comment gets one space, own-line comment indents" {
    const cfg = default_config()
    const r = format_source("fn f() {\n    let x = 1      // note\n        // next\n    return\n}\n",
        &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == "fn f() {\n    let x = 1 // note\n    // next\n    return\n}\n",
        "comments placed")
}

test "interpolated strings keep authored spacing" {
    const cfg = default_config()
    const src = "fn f(a: i32) OwnedString {\n    return $\"x {a} y\"\n}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == src, "interp untouched")
}

test "multiline lists gain a trailing comma, single-line lists lose it" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "join-lines", "false"), "keep layout")
    const r = format_source("fn f(a: i32, b: i32,) i32 {\n    return g(\n        a,\n        b\n    )\n}\n",
        &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == "fn f(a: i32, b: i32) i32 {\n    return g(\n        a,\n        b,\n    )\n}\n",
        "trailing commas normalized")
}

test "trailing-comma no strips multiline trailing commas" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "trailing-comma", "no"), "mode set")
    assert_true(set_option(&cfg, "join-lines", "false"), "keep layout")
    const r = format_source("fn f(a: i32) i32 {\n    return g(\n        a,\n    )\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == "fn f(a: i32) i32 {\n    return g(\n        a\n    )\n}\n",
        "stripped")
}

test "narrow comment prose refills to width" {
    const cfg = default_config()
    const src = "// aaa bbb ccc ddd eee fff ggg hhh iii jjj kkk lll mmm nnn ooo ppp qqq rrr sss ttt\n// uuu vvv www xxx yyy zzz aab aac aad aae aaf aag aah aai aaj aak aal aam aan aao\nfn f() {}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == "// aaa bbb ccc ddd eee fff ggg hhh iii jjj kkk lll mmm nnn ooo ppp qqq rrr sss ttt uuu vvv www xxx\n// yyy zzz aab aac aad aae aaf aag aah aai aaj aak aal aam aan aao\nfn f() {}\n",
        "refilled")
}

test "list and ruler comments are not reflowed" {
    const cfg = default_config()
    const src = "//   - one\n//   - two\n// 1. step\nfn f() {}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == src, "structure kept")
}

test "reflow-comments false keeps narrow prose" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "reflow-comments", "false"), "knob set")
    const src = "// aaa bbb ccc ddd eee fff ggg hhh iii jjj kkk lll mmm nnn ooo ppp qqq rrr sss ttt\n// uuu vvv www\nfn f() {}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == src, "prose untouched")
}

test "newline-separated match arm commas are stripped" {
    const cfg = default_config()
    const r = format_source("fn f(a: i32) i32 {\n    return a match {\n        1 => 2,\n        else => 3,\n    }\n}\n",
        &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == "fn f(a: i32) i32 {\n    return a match {\n        1 => 2\n        else => 3\n    }\n}\n",
        "arm commas dropped")
}

test "single-line bodies keep their commas" {
    const cfg = default_config()
    const src = "fn f(a: i32) i32 {\n    return a match { 1 => 2, else => 3 }\n}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == src, "single-line arms unchanged")
}

test "over-long call wraps at its last fitting comma" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "max-width", "40"), "width set")
    const r = format_source("fn f(aaaaaaaa: i32, bbbbbbbb: i32, cccccccc: i32, dddddddd: i32) i32 {\n    return 0\n}\n",
        &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == "fn f(aaaaaaaa: i32, bbbbbbbb: i32,\n    cccccccc: i32, dddddddd: i32) i32 {\n    return 0\n}\n",
        "wrapped at comma")
}

test "max-width 0 disables wrapping" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "max-width", "0"), "width off")
    const src = "fn f(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: i32, b: i32) i32 {\n    return 0\n}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == src, "long line kept")
}

test "builder-targeted interpolation glues to its identifier" {
    const cfg = default_config()
    const src = "fn f(sb: &StringBuilder, x: i32) {
    $sb\"got {x}\"
}
"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == src, "target form unchanged")
}

test "open-started ranges keep their space" {
    const cfg = default_config()
    const src = "fn f(a: u8[]) {
    for i in ..a.len {
        g(a[0..i], a[i..])
    }
}
"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == src, "prefix .. spaced, infix .. glued")
}

test "generator template bodies are verbatim" {
    const cfg = default_config()
    const src = "#define(iface, Name: Ident) {
    type #(Name)Vtable = struct {
        f: fn(ctx: &u8,
            x: i32) i32
    }
}
"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == src, "splice adjacency and breaks kept")
}

test "enum discriminants keep negative literals glued" {
    const cfg = default_config()
    const src = "type Ord = enum {
    Less = -1
    Equal = 0
}
"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == src, "-1 stays one unit")
}

test "one-element tuple commas are grammar, not style" {
    const cfg = default_config()
    const src = "fn f(x: (i32,)) (i32,) {
    return x
}
"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == src, "(T,) comma kept")
}

test "semicolon chains break into one statement per line" {
    const cfg = default_config()
    const r = format_source("fn f(sb: &StringBuilder) {
    g() match {
        1 => { sb.append(\"a\"); sb.append(\"b\"); sb.append(\"c\") }
        else => {}
    }
}
",
        &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == "fn f(sb: &StringBuilder) {
    g() match {
        1 => {
            sb.append(\"a\")
            sb.append(\"b\")
            sb.append(\"c\")
        }
        else => {}
    }
}
",
        "arm body reflowed")
}

test "semicolons keep leaves them alone" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "semicolons", "keep"), "knob set")
    const src = "fn f() {
    a(); b()
}
"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == src, "kept")
}

test "statement ifs go multiline, guards included" {
    const cfg = default_config()
    const r = format_source("fn f(x: bool) i32 {
    if x { return 1 }
    if x { g() } else { h() }
    return 0
}
",
        &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == "fn f(x: bool) i32 {
    if x {
        return 1
    }
    if x {
        g()
    } else {
        h()
    }
    return 0
}
",
        "stmt ifs broken")
}

test "expression ifs may stay single-line" {
    const cfg = default_config()
    const src = "fn f(c: bool) i32 {
    const x = if c { 1 } else { 2 }
    return if c { x } else { 0 }
}
"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == src, "expr ifs untouched")
}

test "if-stmt keep preserves one-line guards" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "if-stmt", "keep"), "knob set")
    const src = "fn f(x: bool) i32 {
    if x { return 1 }
    return 0
}
"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == src, "guard kept")
}

test "array types keep their semicolon" {
    const cfg = default_config()
    const src = "fn f() {
    let buf = [0u8; 256]
}
"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.as_view() == src, "[T; N] untouched")
}

test "parse errors refuse to format" {
    const cfg = default_config()
    const r = format_source("fn main( {", &cfg)
    assert_true(r.is_err(), "broken input rejected")
}

test "set_option parses knobs and rejects junk" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "indent", "2"), "indent set")
    assert_eq(cfg.indent, 2 as usize, "indent value")
    assert_true(set_option(&cfg, "max-width", "0"), "width set")
    assert_true(set_option(&cfg, "trailing-comma", "always"), "mode set")
    assert_true(!set_option(&cfg, "indent", "x"), "bad value rejected")
    assert_true(!set_option(&cfg, "wat", "1"), "unknown key rejected")
}
