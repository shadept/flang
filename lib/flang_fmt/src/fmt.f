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
//   - the file's prevailing line ending (LF or CRLF) is detected once and written at every break,
//     so a checkout's eol convention never counts as a formatting change
//
// Line breaks: a newline can end a statement in FLang, so structural breaks (between statements,
// inside brace bodies) are always the author's. Breaks inside `(`/`[` groups and before `and`/`or`
// are layout, not structure: with `join_lines` on they re-flow, and `max_width` decides where the
// line breaks. Blank lines and comment placement always survive.

import std.collections.list
import std.conv
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

import flang_fmt.imports

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
    // Sort the leading import block: core, std, dependencies, own modules (see imports.f).
    sort_imports: bool
    // The manifest's project name, which decides the last group. A view into the caller's manifest;
    // empty when there is none.
    project: String
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
        sort_imports = true,
        project = "",
    }
}

// Name the project so its own imports group last. Viewed, not copied: it must outlive the config.
pub fn set_project(self: &FmtConfig, project: String) {
    self.project = project
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
    if key == "sort-imports" {
        return set_bool(&self.sort_imports, val)
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
    let current = if cfg.sort_imports {
        sort_imports(source, cfg.project, line_ending_of(source))
    } else {
        from_view(source)
    }
    let passes = 0usize
    while passes < 4 {
        const pass = format_once(current.view, cfg)
        if pass.is_err() {
            const e = pass.unwrap_err()
            current.deinit()
            return Err(e)
        }
        let next = pass.unwrap()
        if next.view == current.view {
            next.deinit()
            return Ok(move current)
        }
        install(&current, next)
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

    const eol = line_ending_of(source)
    const raw_owned = render_module(&cst, cfg, eol)
    const out = normalize(raw_owned.view, cfg, eol)
    raw_owned.deinit()

    if !verify_output(&p.tree.tokens, &cst, out.view) {
        out.deinit()
        return Err(FmtError.VerifyFailed)
    }
    return Ok(move out)
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
//   - a bracketed comma list is a group, laid out flat or broken. Broken
//     puts each element on a line of its own one step deeper, ending in a
//     comma, and the closer back at the indent of the opener's line; an
//     array of short elements fills its lines instead. A group breaks when
//     a line it sits on overflows `max_width` and it is the outermost flat
//     group there, or when a comment or blank line sits among its elements.
//     A call's lone literal argument takes the call's overflow. Overflow is
//     found by rendering: a pass that marks a group to break is rerun until
//     a pass marks none.
//   - a `where` clause is a group the body's `{` closes, and a signature
//     holding one moves `where` to its own line before any group breaks
//   - a brace body indents one step from the line its `{` sits on, not
//     counting operator continuation; a line starting with a binary
//     operator or `.`-chain continuation indents one more step
//   - blank-line runs clamp to `max_blank_lines`
//   - a comment on its own line is indented like the code around it; a
//     comment trailing code gets exactly one space before `//`
//
// Inside an interpolated string ($"..."), authored spacing is preserved verbatim: segment text is
// token text, and hole spacing is the author's.
// ─────────────────────────────────────────────────────────────────────────

// The widest array element a broken array still fills its lines with.
const FILL_ELEMENT_WIDTH: usize = 10

// A place the current line may break: just before `and` / `or`, or after a comma of a filled group.
// `offset` indexes into the line
// buffer; `indent` is the indentation (in spaces) the split-off remainder gets, `extra` the part of
// it that is operator continuation.
type WrapPoint = struct {
    offset: usize
    indent: usize
    extra: usize
}

// What an open bracket or brace is to the layout:
//   Body  - a brace body: statements, fields, variants, arms
//   Group - a bracketed list, a `where` clause, or any other `(` / `[`
//   Sig   - a signature whose `where` clause may move to a line of its own
type CtxKind = enum {
    Body
    Group
    Sig
}

type Ctx = struct {
    kind: CtxKind
    // Indent of a line that closes it, and of a line inside it.
    base: usize
    content: usize
    // Only a breakable group is ever broken; any other bracket keeps its authored layout.
    breakable: bool
    broken: bool
    // Broken, it fills each line with elements instead of one per line.
    fill: bool
    // The opener's token index, which names the group across passes.
    key: usize
}

// A list group about to open: the next opening bracket the renderer emits is its opener.
type GroupSpec = struct {
    key: usize
    breakable: bool
    broken: bool
    fill: bool
}

// Where an overflow goes instead of breaking a call with one argument, as rustfmt's last-argument
// overflow has it: into a literal, which breaks in the call's place, or into a call's own list,
// which passes it on. Keyed like the groups, by opener token index.
type Hug = enum {
    Nothing
    Literal(usize)
    Inner(usize)
}

// The opening and closing bracket of a list, as child indices of its node.
type ListSpan = struct {
    open: usize
    close: usize
}

type Renderer = struct {
    // Completed lines. The line being built lives in `line` so it can still be split at a wrap
    // point; it flushes at every line break.
    out: StringBuilder
    line: StringBuilder
    cfg: &FmtConfig
    // The source's own line ending, written at every break. Never a post-pass: a token's text is
    // emitted verbatim, and a blanket rewrite cannot tell a break in the layout from a newline
    // inside a string literal.
    eol: String
    // Break opportunities on the current line, in order.
    wrap_points: List(WrapPoint)
    // Open brackets and braces, innermost last.
    ctx: List(Ctx)
    next_group: GroupSpec?
    // The indent the current line opened with, and the part of it that is operator continuation.
    line_indent: usize
    line_extra: usize
    // Where a comment starts on the current line; overflow measures the code before it.
    comment_col: usize?
    // Where a function's return type ends on the current line; a line ending in its body's `{`
    // measures the code before it.
    sig_end: usize?
    // The outermost flat group on the current line: the one an overflow breaks.
    line_cand: usize?
    // Per token index: a group an earlier pass broke for overflow. Shared by every pass.
    breaks: &List(bool)
    // Per token index: where an overflow of the group opened there goes first.
    hugs: &List(Hug)
    // Per token index: a `.` of a call chain the layout breaks before (`mark_chains`).
    chain_dots: &List(bool)
    // The current line opens with a chain's `.`: a brace on it indents from the line.
    line_chain: bool
    // Groups this pass newly broke. A pass that breaks any is stale and reruns.
    new_breaks: usize
    // The pending line break is the layout's and is never joined.
    force_break: bool
    // Inside a generator definition, whose layout is the author's.
    gen_depth: usize
    interp_depth: usize
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

fn render_module(cst: &CstNode, cfg: &FmtConfig, eol: String) OwnedString {
    let breaks: List(bool) = filled_list(cst.cst.tokens.len, false)
    defer breaks.deinit()
    let hugs: List(Hug) = filled_list(cst.cst.tokens.len, Hug.Nothing)
    defer hugs.deinit()
    let chain_dots: List(bool) = filled_list(cst.cst.tokens.len, false)
    defer chain_dots.deinit()
    mark_chains(cst, NodeKind.Module, &cst.cst.tokens, &chain_dots)
    loop {
        let pass = render_pass(cst, cfg, eol, &breaks, &hugs, &chain_dots)
        if pass.is_some() {
            return pass.unwrap()
        }
    }
}

// One walk under the groups broken so far. Null when the walk broke more, so its output is stale.
fn render_pass(
    cst: &CstNode,
    cfg: &FmtConfig,
    eol: String,
    breaks: &List(bool),
    hugs: &List(Hug),
    chain_dots: &List(bool),
) OwnedString? {
    let r = Renderer {
        out = string_builder(cst.end + 16),
        line = string_builder(128),
        cfg = cfg,
        eol = eol,
        wrap_points = list(0),
        ctx = list(16),
        next_group = null,
        line_indent = 0,
        line_extra = 0,
        comment_col = null,
        sig_end = null,
        line_cand = null,
        breaks = breaks,
        hugs = hugs,
        chain_dots = chain_dots,
        line_chain = false,
        new_breaks = 0,
        force_break = false,
        gen_depth = 0,
        interp_depth = 0,
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
    r.ctx.deinit()
    if r.new_breaks > 0 {
        r.out.deinit()
        return null
    }
    return Some(r.out.to_string())
}

// ─────────────────────────────────────────────────────────────────────────
// Call chains
//
// A chain where a lambda's `}` is followed by another link lays out one call per line, Kotlin
// style, when it is a whole statement or the value of a binding, an assignment or a `return`: the
// head up to the first lambda call stays, and every `.call` from there on starts a line one step
// deeper. A brace body holding one goes multiline.
//
//     const d = self.items.as_slice()
//         .filter { it > 0 }
//         .map { it * 2 }
//         .to_list()
// ─────────────────────────────────────────────────────────────────────────

// Marks the `.` of every call link of each chain that breaks, for the chains directly under
// `parent`.
fn mark_chains(node: &CstNode, parent: NodeKind, tokens: &List(Token), dots: &List(bool)) {
    if is_link(node) and holds_chain(parent) and continues_after_lambda(node) {
        mark_links(node, tokens, dots)
    }
    for i in 0..node.child_count() {
        node.child(i) match {
            NodeChild(inner) => {
                const receiver = i == 0 and is_link(node)
                mark_chains(&inner, if receiver { NodeKind.Error } else { node.kind }, tokens, dots)
            }
            TokenChild(_) => {}
        }
    }
}

// Where a chain is a value of its own: a statement, a binding's initializer, an assignment's side,
// a `return`.
fn holds_chain(kind: NodeKind) bool {
    return kind match {
        ExpressionStmt | VariableDecl | AssignmentExpr | ReturnStmt => true
        _ => false
    }
}

// A `.name` link: a member access or method call whose receiver is its first child.
fn is_link(node: &CstNode) bool {
    const kind_fits = node.kind == NodeKind.CallExpr or node.kind == NodeKind.MemberAccessExpr
    if !kind_fits or node.child_count() < 3 {
        return false
    }
    const recv_first = node.child(0) match {
        NodeChild(_) => true
        TokenChild(_) => false
    }
    const dot_second = node.child(1) match {
        TokenChild(t) => t.kind == TokenKind.Dot
        NodeChild(_) => false
    }
    return recv_first and dot_second
}

// How many links down from `node` the chain's innermost lambda call sits.
fn links_to_first_lambda(node: &CstNode) usize {
    let first = 0usize
    let depth = 0usize
    let cur = node.*
    while is_link(&cur) {
        if takes_lambda(&cur) {
            first = depth
        }
        depth = depth + 1
        cur = cur.child(0) match {
            NodeChild(inner) => inner
            TokenChild(_) => break
        }
    }
    return first
}

// Whether a chain inside `node` breaks: a marked `.` among its tokens.
fn has_chain_dot(r: &Renderer, node: &CstNode) bool {
    let i = token_index(r.tokens, node.start)
    while i < r.tokens.len and r.tokens[i].offset < node.end {
        if r.chain_dots[i] {
            return true
        }
        i = i + 1
    }
    return false
}

// Whether a link of the chain ending at `node` follows a trailing lambda's `}`: a link below the
// outermost one ends in a brace lambda.
fn continues_after_lambda(node: &CstNode) bool {
    let cur = node.*
    while is_link(&cur) {
        cur = cur.child(0) match {
            NodeChild(inner) => inner
            TokenChild(_) => return false
        }
        if is_link(&cur) and ends_with_lambda(&cur) {
            return true
        }
    }
    return false
}

fn ends_with_lambda(link: &CstNode) bool {
    return link.child(link.child_count() - 1) match {
        NodeChild(n) => n.kind == NodeKind.LambdaExpr
        TokenChild(_) => false
    }
}

fn takes_lambda(link: &CstNode) bool {
    for i in 1..link.child_count() {
        const is_lambda = link.child(i) match {
            NodeChild(n) => n.kind == NodeKind.LambdaExpr
            TokenChild(_) => false
        }
        if is_lambda {
            return true
        }
    }
    return false
}

// The chain's head - its receiver and every link before the first lambda call - stays on one line;
// each call from that first lambda call on starts a line.
fn mark_links(node: &CstNode, tokens: &List(Token), dots: &List(bool)) {
    const head = links_to_first_lambda(node)
    let cur = node.*
    let depth = 0usize
    while is_link(&cur) and depth <= head {
        depth = depth + 1
        cur.child(1) match {
            TokenChild(t) => if cur.kind == NodeKind.CallExpr {
                dots[token_index(tokens, t.offset)] = true
            }
            NodeChild(_) => {}
        }
        cur = cur.child(0) match {
            NodeChild(inner) => inner
            TokenChild(_) => break
        }
    }
}

fn flush_line(r: &Renderer) {
    note_overflow(r)
    if r.line.len > 0 {
        r.out.append(r.line.as_view())
        r.line.clear()
    }
    r.wrap_points.clear()
    r.comment_col = null
    r.sig_end = null
}

// A line past `max_width` breaks the outermost flat group on it, from the next pass on.
fn note_overflow(r: &Renderer) {
    if r.cfg.max_width == 0 or r.line_cand.is_none() {
        return
    }
    const width = line_width(r)
    if width <= r.cfg.max_width {
        return
    }
    const cand = r.line_cand.unwrap()
    const target = overflow_target(r, cand)
    const key = if r.breaks[target] { cand } else { target }
    if !r.breaks[key] {
        r.breaks[key] = true
        r.new_breaks = r.new_breaks + 1
    }
}

// The group an overflow of `key` breaks first: down through one-argument calls to the literal or
// the list it goes into.
fn overflow_target(r: &Renderer, key: usize) usize {
    let k = key
    loop {
        r.hugs[k] match {
            Nothing => return k
            Literal(inner) => return inner
            Inner(inner) => {
                k = inner
            }
        }
    }
}

fn line_width(r: &Renderer) usize {
    const code = r.comment_col ?? r.line.len
    const opens_body = r.line.as_view()[0..code].ends_with("{")
    if r.sig_end.is_some() and opens_body {
        return r.sig_end.unwrap()
    }
    return code
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
    if node.kind == NodeKind.GeneratorDef {
        r.gen_depth = r.gen_depth + 1
        render_children(r, node)
        r.gen_depth = r.gen_depth - 1
        return
    }
    if node.kind == NodeKind.FunctionDecl {
        render_fn(r, node)
        return
    }
    if node.kind == NodeKind.LambdaExpr and opens_with(node, TokenKind.OpenBrace) {
        render_brace_lambda(r, node)
        return
    }
    if is_comma_list(node.kind) {
        render_list(r, node)
        return
    }
    render_children(r, node)
}

fn render_children(r: &Renderer, node: &CstNode) {
    for i in 0..node.child_count() {
        render_child(r, node, i)
    }
}

// The `i`th child of `node`, under the separator policy when it is a token.
fn render_child(r: &Renderer, node: &CstNode, i: usize) {
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

// A bracketed comma list: one group from its opener to its closer.
fn render_list(r: &Renderer, node: &CstNode) {
    const span = list_span(node)
    if span.is_none() {
        render_children(r, node)
        return
    }
    const s = span.unwrap()
    for i in 0..node.child_count() {
        const child = node.child(i)
        child match {
            TokenChild(tok) => list_token(r, node, i, tok, s)
            NodeChild(_) => render_child(r, node, i)
        }
    }
}

// A token of a list's node: the opener opens its group, the closer closes it, and a broken group
// starts a line after each comma.
fn list_token(r: &Renderer, node: &CstNode, i: usize, tok: &Token, s: ListSpan) {
    if i == s.open {
        r.next_group = Some(group_spec(r, node, tok, s))
        render_token(r, tok, node.kind)
        if top_broken(r) {
            break_after(r)
        }
        return
    }
    if i == s.close {
        if top_broken(r) {
            break_before(r, tok)
        }
        maybe_insert_trailing_comma(r, node, tok)
        render_token(r, tok, node.kind)
        return
    }
    render_child(r, node, i)
    if tok.kind != TokenKind.Comma or i <= s.open or i >= s.close or !top_broken(r) {
        return
    }
    if top_group(r).unwrap().fill {
        record_fill_point(r)
    } else {
        break_after(r)
    }
}

// A filled group may break after this comma, starting the next line at the group's content.
fn record_fill_point(r: &Renderer) {
    const content = top_group(r).unwrap().content
    r.wrap_points.push(WrapPoint { offset = r.line.len, indent = content, extra = 0 })
}

// A function: its parameter list is a group and its `where` clause another. The signature holding a
// `where` is a group of its own around both, so an overflow moves `where` to its own line before
// either list breaks.
fn render_fn(r: &Renderer, node: &CstNode) {
    const span = list_span(node)
    if span.is_none() {
        render_children(r, node)
        return
    }
    const s = span.unwrap()
    const where_i = where_index(node, s.close)
    let in_where = false
    for i in 0..node.child_count() {
        const child = node.child(i)
        child match {
            TokenChild(tok) => {
                if i == s.open and where_i.is_some() {
                    open_sig(r, node, where_i.unwrap())
                }
                if where_i.is_some() and i == where_i.unwrap() {
                    open_where(r, tok)
                    in_where = true
                } else if in_where {
                    where_token(r, node, i, tok)
                } else {
                    list_token(r, node, i, tok, s)
                }
            }
            NodeChild(inner) => {
                if in_where and inner.kind == NodeKind.BlockExpr {
                    close_where(r, &child)
                    in_where = false
                }
                if inner.kind == NodeKind.BlockExpr {
                    r.sig_end = Some(r.line.len)
                }
                render_child(r, node, i)
            }
        }
    }
    // A foreign function's clause ends with the declaration.
    if in_where {
        close_ctx(r)
    }
}

// Opened at the parameter list and keyed by the `where` token: broken, `where` starts a line.
fn open_sig(r: &Renderer, node: &CstNode, where_i: usize) {
    const before = last_token_of(&node.child(where_i - 1)).unwrap()
    const w = first_token_of(&node.child(where_i)).unwrap()
    const key = token_index(r.tokens, w.offset)
    const breakable = can_break(r)
    const authored = spans_newline(r.source, before.offset + before.text.len, w.offset)
    const base = r.line_indent - r.line_extra
    push_ctx(r, Ctx { kind = CtxKind.Sig, base = base, content = base, breakable = breakable, broken = breakable
        and (authored and !r.cfg.join_lines or r.breaks[key]), fill = false, key = key })
}

// `where` closes the signature's group and opens the bound list's, keyed one token past it.
fn open_where(r: &Renderer, tok: &Token) {
    const sig = r.ctx.last()
    if sig.is_some() and sig.unwrap().kind == CtxKind.Sig {
        if sig.unwrap().broken {
            break_before(r, tok)
        }
        close_ctx(r)
    }
    render_token(r, tok, NodeKind.FunctionDecl)
    const key = token_index(r.tokens, tok.offset) + 1
    const breakable = can_break(r)
    const authored = spans_newline(r.source, tok.offset + tok.text.len, r.tokens[key].offset)
    push_ctx(r, Ctx { kind = CtxKind.Group, base = r.line_indent, content = r.line_indent + r.cfg.indent, breakable = breakable, broken = breakable
        and (authored and !r.cfg.join_lines or r.breaks[key]), fill = false, key = key })
    if top_broken(r) {
        break_after(r)
    }
}

// A token of the bound list: a broken list starts a line after each comma, and its last comma
// follows the trailing-comma policy.
fn where_token(r: &Renderer, node: &CstNode, i: usize, tok: &Token) {
    if tok.kind != TokenKind.Comma {
        render_child(r, node, i)
        return
    }
    if ends_bound_list(node, i) and skip_trailing(r, node, i) {
        skip_token_keep_trivia(r, tok)
        return
    }
    render_token(r, tok, node.kind)
    if top_broken(r) {
        break_after(r)
    }
}

// The body's `{` closes the bound list: on a line of its own after a broken list, which takes its
// trailing comma first.
fn close_where(r: &Renderer, block: &CstChild) {
    if top_broken(r) {
        const ends_on_comma = r.prev_kind == TokenKind.Comma
        if mode_on(r.cfg.trailing_comma) and !ends_on_comma and !r.line_has_comment {
            r.line.append(",")
        }
        const open = first_token_of(block).unwrap()
        break_before(r, &open)
    }
    close_ctx(r)
}

// Child index of a function's `where`, searched after its parameter list.
fn where_index(node: &CstNode, from: usize) usize? {
    for i in from..node.child_count() {
        const is_where = node.child(i) match {
            TokenChild(t) => t.kind == TokenKind.Identifier and t.text == "where"
            NodeChild(_) => false
        }
        if is_where {
            return Some(i)
        }
    }
    return null
}

// Whether comma `i` is the last thing in a `where` list: the body or the declaration's end follows.
fn ends_bound_list(node: &CstNode, i: usize) bool {
    if i + 1 >= node.child_count() {
        return true
    }
    return node.child(i + 1) match {
        NodeChild(n) => n.kind == NodeKind.BlockExpr
        TokenChild(_) => false
    }
}

// The opener and closer of a list node: its first opening bracket of the list's kind and the first
// matching closer after it. Null for a node written without them.
fn list_span(node: &CstNode) ListSpan? {
    const closer = list_closer(node.kind)
    const opener = if closer == TokenKind.CloseBracket {
        TokenKind.OpenBracket
    } else if closer == TokenKind.CloseBrace {
        TokenKind.OpenBrace
    } else {
        TokenKind.OpenParenthesis
    }
    let open: usize? = null
    for i in 0..node.child_count() {
        const kind = node.child(i) match {
            TokenChild(t) => t.kind
            NodeChild(_) => TokenKind.Eof
        }
        if open.is_none() and kind == opener {
            open = Some(i)
        } else if open.is_some() and kind == closer {
            return Some(ListSpan { open = open.unwrap(), close = i })
        }
    }
    return null
}

fn group_spec(r: &Renderer, node: &CstNode, tok: &Token, s: ListSpan) GroupSpec {
    const key = token_index(r.tokens, tok.offset)
    const breakable = can_break(r) and nodes_between(node, s) > 0
    r.hugs[key] = hug_of(r, node, s)
    const close_key = token_index(r.tokens, first_token_of(&node.child(s.close)).unwrap().offset)
    const pinned = if r.cfg.join_lines {
        holds_layout_trivia(r, key, close_key)
    } else {
        spans_newline(r.source, tok.offset + tok.text.len, r.tokens[key + 1].offset)
    }
    return .{ key = key, breakable = breakable, broken = breakable and (pinned
        or r.breaks[key]), fill = node.kind == NodeKind.ArrayLiteralExpr and all_short(r, node, s) }
}

// A call's lone argument that takes its overflow: a struct or array literal, or another call.
fn hug_of(r: &Renderer, node: &CstNode, s: ListSpan) Hug {
    if node.kind != NodeKind.CallExpr or nodes_between(node, s) != 1 {
        return Hug.Nothing
    }
    for i in (s.open + 1)..s.close {
        node.child(i) match {
            NodeChild(arg) => return hug_into(r, &arg)
            TokenChild(_) => {}
        }
    }
    return Hug.Nothing
}

fn hug_into(r: &Renderer, arg: &CstNode) Hug {
    const span = list_span(arg)
    if span.is_none() {
        return Hug.Nothing
    }
    const opener = first_token_of(&arg.child(span.unwrap().open)).unwrap()
    const key = token_index(r.tokens, opener.offset)
    return arg.kind match {
        StructConstructionExpr => Hug.Literal(key)
        AnonymousStructExpr => Hug.Literal(key)
        ArrayLiteralExpr => Hug.Literal(key)
        CallExpr => Hug.Inner(key)
        else => Hug.Nothing
    }
}

// Whether a comment or a blank line sits between the list's own tokens, nested brackets aside.
// Flat, the comment would swallow the code after it.
fn holds_layout_trivia(r: &Renderer, open: usize, close: usize) bool {
    let depth = 0usize
    for i in open..close {
        const tok = r.tokens[i]
        if i > open and is_opener(tok.kind) {
            depth = depth + 1
        } else if is_closer(tok.kind) {
            depth = depth - 1
        }
        const at_list = depth == 0
        if at_list
            and gap_holds_layout(r.source, tok.offset + tok.text.len, r.tokens[i + 1].offset) {
            return true
        }
    }
    return false
}

fn gap_holds_layout(source: String, from: usize, to: usize) bool {
    let newlines = 0usize
    for p in from..to {
        if source[p] == '/' {
            return true
        }
        if source[p] == '\n' {
            newlines = newlines + 1
        }
    }
    return newlines > 1
}

// Whether every element between the brackets is written on one line in at most `FILL_ELEMENT_WIDTH`
// columns, as rustfmt's short-array rule has it.
fn all_short(r: &Renderer, node: &CstNode, s: ListSpan) bool {
    for i in (s.open + 1)..s.close {
        const child = node.child(i)
        const is_node = child match {
            NodeChild(_) => true
            TokenChild(_) => false
        }
        if !is_node {
            continue
        }
        const first = first_token_of(&child).unwrap()
        const last = last_token_of(&child).unwrap()
        const end = last.offset + last.text.len
        if end - first.offset > FILL_ELEMENT_WIDTH or spans_newline(r.source, first.offset, end) {
            return false
        }
    }
    return true
}

// Groups re-flow only where layout is the formatter's: a width is set, and no generator template or
// interpolated string holds them.
fn can_break(r: &Renderer) bool {
    return r.cfg.max_width > 0 and r.gen_depth == 0 and r.interp_depth == 0
}

fn nodes_between(node: &CstNode, s: ListSpan) usize {
    let n: usize = 0
    for i in (s.open + 1)..s.close {
        node.child(i) match {
            NodeChild(_) => { n = n + 1 }
            TokenChild(_) => {}
        }
    }
    return n
}

// Index of the token at `offset`. Tokens are in source order.
fn token_index(tokens: &List(Token), offset: usize) usize {
    let lo = 0usize
    let hi = tokens.len
    while lo < hi {
        const mid = lo + (hi - lo) / 2
        if tokens[mid].offset < offset {
            lo = mid + 1
        } else {
            hi = mid
        }
    }
    return lo
}

// The pending break is the layout's: the next token starts a line.
fn break_after(r: &Renderer) {
    r.force_break = true
    if r.pending_newlines == 0 {
        r.pending_newlines = 1
    }
}

// `tok` starts a line, through its own leading newline when it has one.
fn break_before(r: &Renderer, tok: &Token) {
    r.force_break = true
    if r.pending_newlines == 0 and !leading_has_newline(r, tok) {
        r.pending_newlines = 1
    }
}

fn push_ctx(r: &Renderer, c: Ctx) {
    r.ctx.push(c)
    if c.breakable and !c.broken and r.line_cand.is_none() {
        r.line_cand = Some(c.key)
    }
}

// Leaving a brace body or a broken group puts the groups around it back on the line.
fn close_ctx(r: &Renderer) {
    const c = r.ctx.pop()
    if c.is_none() {
        return
    }
    const ends_line_structure = c.unwrap().kind == CtxKind.Body or c.unwrap().broken
    if ends_line_structure and r.line_cand.is_none() {
        r.line_cand = outermost_flat(r)
    }
}

// The outermost breakable group still flat since the innermost brace body or broken group.
fn outermost_flat(r: &Renderer) usize? {
    let from = 0usize
    for i in 0..r.ctx.len {
        if r.ctx[i].kind == CtxKind.Body or r.ctx[i].broken {
            from = i + 1
        }
    }
    for i in from..r.ctx.len {
        const c = r.ctx[i]
        if c.breakable and !c.broken {
            return Some(c.key)
        }
    }
    return null
}

// The innermost context when it is a group.
fn top_group(r: &Renderer) Ctx? {
    const top = r.ctx.last()
    if top.is_none() or top.unwrap().kind != CtxKind.Group {
        return null
    }
    return top
}

fn top_broken(r: &Renderer) bool {
    const g = top_group(r)
    return g.is_some() and g.unwrap().broken
}

fn in_flat_group(r: &Renderer) bool {
    const g = top_group(r)
    return g.is_some() and !g.unwrap().broken
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
        or has_chain_dot(r, node)
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

// `{ params => body }` (RFC-039): the body is a `BlockExpr` holding the closing `}`. A body the
// semicolon policy splits starts on the line after the `{` or `=>`.
fn render_brace_lambda(r: &Renderer, node: &CstNode) {
    const last = node.child_count() - 1
    const body = node.child(last) match {
        NodeChild(n) => n
        TokenChild(_) => {
            render_children(r, node)
            return
        }
    }
    const splits = r.cfg.remove_semicolons and block_has_semicolon(&body)
    const force = (splits or has_chain_dot(r, &body)) and element_count(&body) > 0
    for i in 0..last {
        render_child(r, node, i)
    }
    if force and r.pending_newlines == 0 {
        r.pending_newlines = 1
    }
    render_block(r, &body, force)
}

fn opens_with(node: &CstNode, kind: TokenKind) bool {
    if node.child_count() == 0 {
        return false
    }
    return node.child(0) match {
        TokenChild(t) => t.kind == kind
        NodeChild(_) => false
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
//   array literals, struct construction, type argument and parameter lists. The
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
        return skip_trailing(r, node, i)
    }

    if is_separator_body(parent) {
        // Only commas a newline makes redundant; single-line bodies keep theirs (the grammar needs
        // them there).
        return !mode_on(r.cfg.separators) and newline_after_child(node, i)
    }

    return false
}

// Whether the comma ending a list, at child `i`, goes.
fn skip_trailing(r: &Renderer, node: &CstNode, i: usize) bool {
    return r.cfg.trailing_comma match {
        No => true
        // Kept when the list is multiline, dropped on one line.
        Multiline => !list_multiline(r, node, i)
        Always => false
    }
}

// Whether the list holding comma `i` lays out one element per line: its group's mode, or for a list
// the formatter does not lay out, whether a line break follows the comma.
fn list_multiline(r: &Renderer, node: &CstNode, i: usize) bool {
    const g = top_group(r)
    if g.is_some() and g.unwrap().breakable {
        return g.unwrap().broken
    }
    return newline_after_child(node, i)
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
    // A flat group joins its closer onto the line whatever the source did.
    const g = top_group(r)
    if g.is_some() and g.unwrap().breakable and !g.unwrap().broken {
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
        or kind == NodeKind.AnonymousStructExpr or kind == NodeKind.TypeParamList
        or kind == NodeKind.ContextBindExpr
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
    const breaks_chain = tok.kind == TokenKind.Dot
        and r.chain_dots[token_index(r.tokens, tok.offset)]
    if breaks_chain and r.started {
        if r.pending_newlines == 0 {
            r.pending_newlines = 1
        }
        r.force_break = true
    }

    if r.pending_newlines > 0 and r.started and !joinable(r, tok.kind, parent) {
        emit_line_break(r, tok.kind)
    } else if r.started {
        r.pending_newlines = 0
        // A break may land right before `and` / `or`, so the opportunity is recorded before the
        // operator (and its leading space) lands.
        if (tok.kind == TokenKind.And or tok.kind == TokenKind.Or) and r.interp_depth == 0
            and parent != NodeKind.GeneratorDef {
            record_wrap_point(r)
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

// Whether the pending line break may be re-flowed into a space, leaving the layout to decide. Only
// a lone newline qualifies (blank lines and comment-carrying breaks are the author's), never a
// break the layout itself asked for, and only where the layout could put a break back:
//   - inside a group, whose mode decides its breaks, or
//   - before `and` / `or`, whose continuation style wrap reproduces, or
//   - before `-`, `(` or `[` continuing the expression above. These three are the tokens that could
//     equally open a statement of their own, so a break in front of one draws two statements where
//     the parse has one. Joining is what removes the ambiguity; `.`, `and` and the rest cannot be
//     misread at the start of a line and keep their authored break.
// A brace body is not a group, so statements inside a lambda or block passed as an argument are
// never merged.
fn joinable(r: &Renderer, next: TokenKind, parent: NodeKind) bool {
    if r.force_break {
        return false
    }
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
    if top_group(r).is_some() {
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
    r.out.append(r.eol)
    let s = wp.offset
    while s < view.len and view[s] == ' ' {
        s = s + 1
    }
    const rest = from_view(view[s..view.len])
    r.line.clear()
    for n in 0..wp.indent {
        r.line.append_byte(' ' as u8)
    }
    r.line.append(rest.view)
    r.line_indent = wp.indent
    r.line_extra = wp.extra
    const fresh = rest.len == 0
    rest.deinit()

    // Points that moved to the new line keep working, re-based onto it - a long chain may need
    // several breaks.
    let kept: List(WrapPoint) = list(0)
    for i in 0..r.wrap_points.len {
        const p = r.wrap_points[i]
        if p.offset > wp.offset and p.offset >= s {
            kept.push(WrapPoint {
                offset = wp.indent + (p.offset - s),
                indent = p.indent,
                extra = p.extra,
            })
        }
    }
    install(&r.wrap_points, kept)
    return fresh
}

// A break before `and` / `or` continues the expression one step deeper; inside a flat group the
// group's own step already shows it.
fn record_wrap_point(r: &Renderer) {
    const top = r.ctx.last()
    const content = if top.is_some() { top.unwrap().content } else { 0usize }
    const extra = if in_flat_group(r) { 0usize } else { r.cfg.indent }
    r.wrap_points.push(WrapPoint { offset = r.line.len, indent = content + extra, extra = extra })
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
        r.comment_col = Some(r.line.len)
        r.line.append(" ")
    }
    if r.comment_col.is_none() {
        r.comment_col = Some(r.line.len)
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
    r.force_break = false
    flush_line(r)
    for n in 0..(blanks + 1) {
        r.out.append(r.eol)
    }

    const extra = continuation_extra(r, next)
    r.line_indent = line_base(r, next) + extra
    r.line_extra = extra
    r.line_chain = next == TokenKind.Dot and extra > 0
    for n in 0..r.line_indent {
        r.line.append_byte(' ' as u8)
    }
    r.line_cand = outermost_flat(r)
}

// Where a line starting with `next` indents, continuation aside: a closer back at its opener's
// line, anything else inside the innermost bracket or brace.
fn line_base(r: &Renderer, next: TokenKind) usize {
    const top = r.ctx.last()
    if top.is_none() {
        return 0
    }
    if is_closer(next) {
        return top.unwrap().base
    }
    return top.unwrap().content
}

// A line opening with an operator or `.` continues the expression above, one step deeper. Inside a
// flat group the group's own step already shows it.
fn continuation_extra(r: &Renderer, next: TokenKind) usize {
    if is_closer(next) or in_flat_group(r) {
        return 0
    }
    return if is_continuation_start(next, r.prev_kind) { r.cfg.indent } else { 0usize }
}

fn is_closer(kind: TokenKind) bool {
    return kind == TokenKind.CloseBrace or kind == TokenKind.CloseParenthesis
        or kind == TokenKind.CloseBracket
}

fn is_opener(kind: TokenKind) bool {
    return kind == TokenKind.OpenBrace or kind == TokenKind.OpenParenthesis
        or kind == TokenKind.OpenBracket
}

fn update_depths(r: &Renderer, kind: TokenKind) {
    if is_opener(kind) {
        open_ctx(r, kind)
    }
    if is_closer(kind) {
        close_ctx(r)
    }
    if kind == TokenKind.InterpStringStart {
        r.interp_depth = r.interp_depth + 1
    }
    if kind == TokenKind.InterpStringEnd and r.interp_depth > 0 {
        r.interp_depth = r.interp_depth - 1
    }
}

// A list's opener opens the group announced for it. Any other brace opens a body, indented from its
// line without that line's continuation step; any other bracket a group that keeps its layout.
fn open_ctx(r: &Renderer, kind: TokenKind) {
    const spec = r.next_group
    r.next_group = null
    if spec.is_some() {
        const g = spec.unwrap()
        push_ctx(
            r,
            Ctx {
                kind = CtxKind.Group,
                base = r.line_indent,
                content = r.line_indent + r.cfg.indent,
                breakable = g.breakable,
                broken = g.broken,
                fill = g.fill,
                key = g.key,
            },
        )
        return
    }
    if kind == TokenKind.OpenBrace {
        const base = if r.line_chain { r.line_indent } else { r.line_indent - r.line_extra }
        push_ctx(
            r,
            Ctx {
                kind = CtxKind.Body,
                base = base,
                content = base + r.cfg.indent,
                breakable = false,
                broken = false,
                fill = false,
                key = 0,
            },
        )
        return
    }
    push_ctx(
        r,
        Ctx {
            kind = CtxKind.Group,
            base = r.line_indent,
            content = r.line_indent + r.cfg.indent,
            breakable = false,
            broken = false,
            fill = false,
            key = 0,
        },
    )
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
    if kind == TokenKind.OpenParenthesis or kind == TokenKind.OpenBracket or kind == TokenKind.Dot {
        return ends_expression(prev)
    }
    return kind == TokenKind.QuestionDot or kind == TokenKind.QuestionQuestion
        or kind == TokenKind.And or kind == TokenKind.Or or kind == TokenKind.Pipe
        or kind == TokenKind.Plus or kind == TokenKind.Minus or kind == TokenKind.Star
        or kind == TokenKind.Slash or kind == TokenKind.Percent or kind == TokenKind.Caret
        or kind == TokenKind.EqualsEquals or kind == TokenKind.NotEquals
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
        // `.{ ... }` anonymous struct literals glue to the dot, a lambda argument to its `(`.
        return prev != TokenKind.Dot and prev != TokenKind.OpenParenthesis
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

    if glue_after(prev, r.prev_parent) {
        return false
    }
    // An open-started range (`for i in ..a.len`) has nothing to glue its `..` to: it spaces off
    // like any prefix. With a left operand present the range glues (`0..n`).
    if (cur == TokenKind.DotDot or cur == TokenKind.DotDotEquals) and !ends_expression(prev) {
        return true
    }
    // `(` glues to what it applies to - a callee, a declared or generic name (`List(T)`,
    // `Box(Inner) { ... }`, `Some(x)`), or a `struct`/`enum`/`fn` opening a parameter list - and
    // stands off after anything else: an operator, `=`, `,`, or a keyword such as `return` or `if`,
    // where it opens a tuple or a grouping.
    if cur == TokenKind.OpenParenthesis {
        // After a closing bracket only a call glues (`f()(x)`, `xs[i](x)`); a tuple return type
        // after a parameter list (`fn f(a: i32) (i32, i32)`) stands off.
        if prev == TokenKind.CloseParenthesis or prev == TokenKind.CloseBracket
            or prev == TokenKind.CloseBrace {
            return parent != NodeKind.CallExpr
        }
        return !(ends_expression(prev) or prev == TokenKind.Struct or prev == TokenKind.Enum
            or prev == TokenKind.Contract or prev == TokenKind.Fn)
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
    // `(` is decided by the token before it (`needs_space`). `[` glues in `a[i]` and `T[]`; an
    // array literal or `[T; N]` type stands off.
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
        or kind == TokenKind.Null or kind == TokenKind.Underscore or kind == TokenKind.Context
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

// The renderer writes the file's own line ending but guarantees nothing about the last one; this
// reflows comment prose and settles the single trailing newline.
fn normalize(rendered: String, cfg: &FmtConfig, eol: String) OwnedString {
    const reflow_width = if cfg.reflow_comments { cfg.max_width } else { 0usize }
    const reflowed = reflow_comments(rendered, reflow_width, eol)
    const out = ensure_single_trailing_newline(reflowed.view, eol)
    reflowed.deinit()
    return out
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

fn reflow_comments(text: String, width: usize, eol: String) OwnedString {
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
        // A CRLF break leaves its carriage return at the end of the slice; the line's text is what
        // precedes it, and the break itself is re-emitted as `eol`.
        let stop = nl
        if stop > pos and text[stop - 1] == '\r' {
            stop = stop - 1
        }
        const line = text[pos..stop]
        const has_nl = nl < text.len

        const parsed = parse_comment_line(line)
        // Mid-paragraph: the previous line was full prose at this indent and did not introduce a
        // list. Decides whether a leading `- ` is a wrapped aside (joins) or a bullet (verbatim).
        const mid = words.len > 0 and parsed.0 == para_indent and last_len > threshold
            and !last_colon
        if parsed.2 and is_comment_prose(parsed.1, mid) {
            if words.len > 0 and (parsed.0 != para_indent or last_len <= threshold) {
                flush_paragraph(&sb, &words, para_indent, width, threshold, eol)
            }
            para_indent = parsed.0
            push_words(&words, parsed.1)
            last_len = line.len
            last_colon = parsed.1.len > 0 and parsed.1[parsed.1.len - 1] == ':'
        } else {
            flush_paragraph(&sb, &words, para_indent, width, threshold, eol)
            sb.append(line)
            if has_nl {
                sb.append(eol)
            }
            last_colon = false
        }
        pos = nl + 1
    }
    flush_paragraph(&sb, &words, para_indent, width, threshold, eol)
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
    // `//!`, `//#` and the like are markers, not prose: the harness reads `//! STDOUT:` headers.
    // Only a comment that opens with a space is text the reflow may touch.
    if content.len > 0 and content[0] != ' ' {
        return (0, "", false)
    }
    if content.len > 0 {
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
fn flush_paragraph(
    sb: &StringBuilder,
    words: &List(String),
    indent: usize,
    width: usize,
    threshold: usize,
    eol: String,
) {
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
            sb.append(eol)
            open_comment_line(sb, indent)
            col = indent + 2
        }
        sb.append(" ")
        sb.append(w)
        col = col + 1 + w.len
    }
    sb.append(eol)
    words.clear()
}

fn open_comment_line(sb: &StringBuilder, indent: usize) {
    for n in 0..indent {
        sb.append_byte(' ' as u8)
    }
    sb.append("//")
}

// The file's prevailing line ending, decided by its first newline. A file with no newline defaults
// to LF. Every break the formatter writes uses this, so no pass ever rewrites endings after the
// fact - one that did could not tell a break in the layout from a newline inside a string literal,
// and would corrupt the literal.
fn line_ending_of(source: String) String {
    let i = 0usize
    while i < source.len {
        if source[i] == '\n' {
            return if i > 0 and source[i - 1] == '\r' { "\r\n" } else { "\n" }
        }
        i = i + 1
    }
    return "\n"
}

fn ensure_single_trailing_newline(source: String, eol: String) OwnedString {
    let end = source.len
    while end > 0 and (source[end - 1] == ' ' or source[end - 1] == '	' or source[end - 1] == '\n'
        or source[end - 1] == '\r') {
            end = end - 1
        }
    let sb = string_builder(end + 2)
    sb.append(source[0..end])
    if end > 0 {
        sb.append(eol)
    }
    return sb.to_string()
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

test "a comment with no space after the slashes is a marker and passes verbatim" {
    const cfg = default_config()
    const out = format_source("//! TEST: t\n//! STDOUT: hi\n\nfn f() {}\n", &cfg).unwrap()
    defer out.deinit()
    assert_eq(out.view, "//! TEST: t\n//! STDOUT: hi\n\nfn f() {}\n", "markers untouched")
}

test "line hygiene: trailing ws stripped, final newline added" {
    const cfg = default_config()
    const r = format_source("fn main() i32 {\n    return 0  \n}", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.view == "fn main() i32 {\n    return 0\n}\n", "normalized")
}

test "crlf files stay crlf, lf files stay lf" {
    const cfg = default_config()
    const rc = format_source("fn a() {}\r\nfn b() {}", &cfg)
    let outc = rc.unwrap()
    defer outc.deinit()
    assert_true(outc.view == "fn a() {}\r\nfn b() {}\r\n", "crlf kept")

    const rl = format_source("fn a() {}\nfn b() {}\r\n", &cfg)
    let outl = rl.unwrap()
    defer outl.deinit()
    assert_true(outl.view == "fn a() {}\nfn b() {}\n", "first ending wins")
}

test "a multi-line string literal in a crlf file keeps its own endings" {
    const cfg = default_config()
    // The literal's newlines belong to the program, not to the layout. Expanding endings across the
    // whole output would write a second carriage return into it and change what it says.
    const src = "pub fn main() i32 {\r\n    const s = \"a\r\nb\"\r\n    return 0i32\r\n}\r\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.view == src, "a crlf file with a multi-line literal round-trips")
}

test "blank lines collapse to max_blank_lines" {
    const cfg = default_config()
    const r = format_source("fn a() {}\n\n\n\n\nfn b() {}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.view == "fn a() {}\n\nfn b() {}\n", "one blank kept")
}

test "already formatted input is unchanged" {
    const cfg = default_config()
    const src = "// doc\nfn main() i32 {\n    return 0\n}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.view == src, "idempotent on clean input")
}

test "spacing normalizes around punctuation and operators" {
    const cfg = default_config()
    const r = format_source("fn f(a:i32 ,b : i32) i32 {\n    return a+b\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.view == "fn f(a: i32, b: i32) i32 {\n    return a + b\n}\n", "spaced")
}

test "an open parenthesis glues to a name and stands off after a keyword or operator" {
    const cfg = default_config()
    const src = "type Box = struct(T) { v: T }\n#allow (W2004)\nfn f(a: i32) (i32, i32) {\n    let b: Box (i32) = Box (i32) { v = a }\n    let t = (a, b.v)\n    if (a + (b.v)) > 0 {\n        return (t.0, t.1)\n    }\n    return t\n}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "type Box = struct(T) { v: T }\n#allow(W2004)\nfn f(a: i32) (i32, i32) {\n    let b: Box(i32) = Box(i32) { v = a }\n    let t = (a, b.v)\n    if (a + (b.v)) > 0 {\n        return (t.0, t.1)\n    }\n    return t\n}\n",
        "names, struct literals and annotations glue; tuple, grouping and keyword parens stand off",
    )
}

test "unary and call positions glue" {
    const cfg = default_config()
    const r = format_source("fn f(p: bool) bool {\n    return ! g ( p )\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.view == "fn f(p: bool) bool {\n    return !g(p)\n}\n", "glued")
}

test "indentation recomputed from nesting" {
    const cfg = default_config()
    const r = format_source(
        "fn f() {\nlet x = 1\n        if x > 0 {\n   return\n      }\n}\n",
        &cfg,
    )
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "fn f() {\n    let x = 1\n    if x > 0 {\n        return\n    }\n}\n",
        "reindented",
    )
}

test "operator continuation lines join when they fit" {
    const cfg = default_config()
    const r = format_source("fn f(a: bool, b: bool) bool {\n    return a\n    or b\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.view == "fn f(a: bool, b: bool) bool {\n    return a or b\n}\n", "joined")
}

test "a list too long for its line breaks one element per line" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "max-width", "24"), "width set")
    const r = format_source("fn f() {\n    ggg(aaaaaaaa,\n    bbbbbbbb,\n    cccccccc)\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "fn f() {\n    ggg(\n        aaaaaaaa,\n        bbbbbbbb,\n        cccccccc,\n    )\n}\n",
        "one per line, trailing comma, closer at the opener's indent",
    )
}

test "an overflowing line breaks its outermost group first" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "max-width", "30"), "width set")
    const r = format_source("fn f() {\n    g(h(aaaaaaaa, bbbbbbbb), cccccccc)\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "fn f() {\n    g(\n        h(aaaaaaaa, bbbbbbbb),\n        cccccccc,\n    )\n}\n",
        "the inner list fits once the outer one breaks",
    )
}

test "a broken array of short elements fills its lines" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "max-width", "24"), "width set")
    const r = format_source(
        "fn f() {
    let a = [
        11,
        22,
        33, 44, 55, 66, 77]
    let b = [
        long_name_1,
        x]
}
",
        &cfg,
    )
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "fn f() {
    let a = [
        11, 22, 33, 44,
        55, 66, 77,
    ]
    let b = [
        long_name_1,
        x,
    ]
}
",
        "short elements fill, one long element puts every element on its own line",
    )
}

test "a list broken after its opener joins when it fits" {
    const cfg = default_config()
    const r = format_source("fn f(\n    a: i32,\n) i32 {\n    return g(\n        a, b)\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.view == "fn f(a: i32) i32 {\n    return g(a, b)\n}\n", "width decides")
}

test "a lone literal argument takes the call's overflow" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "max-width", "40"), "width set")
    const r = format_source(
        "fn f() {\n    xs.push(Some(Pair { left = 1, right = 2 }))\n    g(aaaa, Pair { left = 1, right = 2 })\n}\n",
        &cfg,
    )
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "fn f() {\n    xs.push(Some(Pair {\n        left = 1,\n        right = 2,\n    }))\n    g(\n        aaaa,\n        Pair { left = 1, right = 2 },\n    )\n}\n",
        "hugged through the one-argument call, not with two arguments",
    )
}

test "a leading-dot literal argument is not a chain continuation" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "max-width", "30"), "width set")
    const r = format_source("fn f() {\n    m.set(key, .{ a = 1, b = 2 }, alloc)\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "fn f() {\n    m.set(\n        key,\n        .{ a = 1, b = 2 },\n        alloc,\n    )\n}\n",
        "the argument sits at the list's indent",
    )
}

test "a signature fits when its return type does, the body brace aside" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "max-width", "16"), "width set")
    const src = "fn f(a: i32) i32 {\n    return a\n}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.view == src, "flat at 18 columns")
}

test "a call split before its argument list is joined" {
    const cfg = default_config()
    const r = format_source("fn f() i32 {\n    let b = take\n    (4)\n    return b\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "fn f() i32 {\n    let b = take(4)\n    return b\n}\n",
        "the parser reads one call, so the layout shows one",
    )
}

test "a continuing minus is joined" {
    const cfg = default_config()
    const r = format_source("fn f() i32 {\n    let a = one()\n    - 3\n    return a\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "fn f() i32 {\n    let a = one() - 3\n    return a\n}\n",
        "a leading `-` continues the line above and reads as a statement otherwise",
    )
}

test "a paren opening a statement is left alone" {
    const cfg = default_config()
    const src = "fn f() i32 {\n    if c {\n        (a ?? b).len()\n    }\n    return 0\n}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.view == src, "nothing precedes it that could end an expression")
}

test "a where clause that fits joins the signature line" {
    const cfg = default_config()
    const src = "fn f(x: $T) T where T: copyable,\n    U: Eq + Hash, {\n    return x\n}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "fn f(x: $T) T where T: copyable, U: Eq + Hash {\n    return x\n}\n",
        "joined, trailing comma dropped",
    )
}

test "an overflowing signature moves where to its own line first" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "max-width", "40"), "width set")
    const r = format_source(
        "fn f(x: $T, y: $U) T where T: copyable, U: Eq {\n    return x\n}\n",
        &cfg,
    )
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "fn f(x: $T, y: $U) T\nwhere T: copyable, U: Eq {\n    return x\n}\n",
        "where at the declaration's indent, parameters flat",
    )
}

test "an overflowing where list breaks one bound per line" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "max-width", "30"), "width set")
    const r = format_source(
        "fn f(x: $T) T where T: copyable, U: Eq + Hash {\n    return x\n}\n",
        &cfg,
    )
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "fn f(x: $T) T\nwhere\n    T: copyable,\n    U: Eq + Hash,\n{\n    return x\n}\n",
        "bounds indented with a trailing comma, the body's brace alone",
    )
}

test "join-lines false indents the continuation instead" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "join-lines", "false"), "knob set")
    const r = format_source("fn f() i32 {\n    let b = take\n    (4)\n    return b\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "fn f() i32 {\n    let b = take\n        (4)\n    return b\n}\n",
        "the break is kept, so the indent carries the parse",
    )
}

test "join-lines false keeps authored breaks" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "join-lines", "false"), "knob set")
    const r = format_source("fn f(a: bool, b: bool) bool {\n    return a\n        or b\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "fn f(a: bool, b: bool) bool {\n    return a\n        or b\n}\n",
        "kept split",
    )
}

test "a comment or a blank line inside a list keeps it broken" {
    const cfg = default_config()
    const r = format_source(
        "fn f(a: i32, b: i32) i32 {\n    g(a, // note\n        b)\n    return h(\n        a,\n\n        b,\n    )\n}\n",
        &cfg,
    )
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "fn f(a: i32, b: i32) i32 {\n    g(\n        a, // note\n        b,\n    )\n    return h(\n        a,\n\n        b,\n    )\n}\n",
        "one per line",
    )
}

test "statements inside a lambda argument never join" {
    const cfg = default_config()
    const src = "fn f() {\n    g(fn() {\n        a()\n        b()\n    })\n}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.view == src, "lambda body intact")
}

test "trailing comment gets one space, own-line comment indents" {
    const cfg = default_config()
    const r = format_source(
        "fn f() {\n    let x = 1      // note\n        // next\n    return\n}\n",
        &cfg,
    )
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "fn f() {\n    let x = 1 // note\n    // next\n    return\n}\n",
        "comments placed",
    )
}

test "interpolated strings keep authored spacing" {
    const cfg = default_config()
    const src = "fn f(a: i32) OwnedString {\n    return $\"x {a} y\"\n}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.view == src, "interp untouched")
}

test "multiline lists gain a trailing comma, single-line lists lose it" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "join-lines", "false"), "keep layout")
    const r = format_source(
        "fn f(a: i32, b: i32,) i32 {\n    return g(\n        a,\n        b\n    )\n}\n",
        &cfg,
    )
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "fn f(a: i32, b: i32) i32 {\n    return g(\n        a,\n        b,\n    )\n}\n",
        "trailing commas normalized",
    )
}

test "trailing-comma no strips multiline trailing commas" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "trailing-comma", "no"), "mode set")
    assert_true(set_option(&cfg, "join-lines", "false"), "keep layout")
    const r = format_source("fn f(a: i32) i32 {\n    return g(\n        a,\n    )\n}\n", &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.view == "fn f(a: i32) i32 {\n    return g(\n        a\n    )\n}\n", "stripped")
}

test "narrow comment prose refills to width" {
    const cfg = default_config()
    const src = "// aaa bbb ccc ddd eee fff ggg hhh iii jjj kkk lll mmm nnn ooo ppp qqq rrr sss ttt\n// uuu vvv www xxx yyy zzz aab aac aad aae aaf aag aah aai aaj aak aal aam aan aao\nfn f() {}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "// aaa bbb ccc ddd eee fff ggg hhh iii jjj kkk lll mmm nnn ooo ppp qqq rrr sss ttt uuu vvv www xxx\n// yyy zzz aab aac aad aae aaf aag aah aai aaj aak aal aam aan aao\nfn f() {}\n",
        "refilled",
    )
}

test "list and ruler comments are not reflowed" {
    const cfg = default_config()
    const src = "//   - one\n//   - two\n// 1. step\nfn f() {}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.view == src, "structure kept")
}

test "reflow-comments false keeps narrow prose" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "reflow-comments", "false"), "knob set")
    const src = "// aaa bbb ccc ddd eee fff ggg hhh iii jjj kkk lll mmm nnn ooo ppp qqq rrr sss ttt\n// uuu vvv www\nfn f() {}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.view == src, "prose untouched")
}

test "newline-separated match arm commas are stripped" {
    const cfg = default_config()
    const r = format_source(
        "fn f(a: i32) i32 {\n    return a match {\n        1 => 2,\n        else => 3,\n    }\n}\n",
        &cfg,
    )
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "fn f(a: i32) i32 {\n    return a match {\n        1 => 2\n        else => 3\n    }\n}\n",
        "arm commas dropped",
    )
}

test "single-line bodies keep their commas" {
    const cfg = default_config()
    const src = "fn f(a: i32) i32 {\n    return a match { 1 => 2, else => 3 }\n}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.view == src, "single-line arms unchanged")
}

test "an overflowing parameter list breaks one parameter per line" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "max-width", "40"), "width set")
    const r = format_source(
        "fn f(aaaaaaaa: i32, bbbbbbbb: i32, cccccccc: i32, dddddddd: i32) i32 {\n    return 0\n}\n",
        &cfg,
    )
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "fn f(\n    aaaaaaaa: i32,\n    bbbbbbbb: i32,\n    cccccccc: i32,\n    dddddddd: i32,\n) i32 {\n    return 0\n}\n",
        "the return type follows the closer",
    )
}

test "max-width 0 disables wrapping" {
    let cfg = default_config()
    assert_true(set_option(&cfg, "max-width", "0"), "width off")
    const src = "fn f(aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: i32, b: i32) i32 {\n    return 0\n}\n"
    const r = format_source(src, &cfg)
    let out = r.unwrap()
    defer out.deinit()
    assert_true(out.view == src, "long line kept")
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
    assert_true(out.view == src, "target form unchanged")
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
    assert_true(out.view == src, "prefix .. spaced, infix .. glued")
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
    assert_true(out.view == src, "splice adjacency and breaks kept")
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
    assert_true(out.view == src, "-1 stays one unit")
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
    assert_true(out.view == src, "(T,) comma kept")
}

test "semicolon chains break into one statement per line" {
    const cfg = default_config()
    const r = format_source(
        "fn f(sb: &StringBuilder) {
    g() match {
        1 => { sb.append(\"a\"); sb.append(\"b\"); sb.append(\"c\") }
        else => {}
    }
}
",
        &cfg,
    )
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "fn f(sb: &StringBuilder) {
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
        "arm body reflowed",
    )
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
    assert_true(out.view == src, "kept")
}

test "statement ifs go multiline, guards included" {
    const cfg = default_config()
    const r = format_source(
        "fn f(x: bool) i32 {
    if x { return 1 }
    if x { g() } else { h() }
    return 0
}
",
        &cfg,
    )
    let out = r.unwrap()
    defer out.deinit()
    assert_true(
        out.view == "fn f(x: bool) i32 {
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
        "stmt ifs broken",
    )
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
    assert_true(out.view == src, "expr ifs untouched")
}

test "brace lambdas space their parts and split on semicolons" {
    const cfg = default_config()
    const src = "fn f() {
    const a = xs.map {it*2}
    s.sort({a,b=>b.cmp(a)})
    xs.each { a(); b() }
}
"
    const want = "fn f() {
    const a = xs.map { it * 2 }
    s.sort({ a, b => b.cmp(a) })
    xs.each {
        a()
        b()
    }
}
"
    let out = format_source(src, &cfg).unwrap()
    defer out.deinit()
    assert_true(out.view == want, "brace lambdas normalized")
}

test "a link after a lambda breaks the chain before each call from the first lambda on" {
    const cfg = default_config()
    const src = "fn f() {
    const a = xs.map { it * 2 }.unwrap()
    const b = self.items.as_slice().filter { it > 0 }.map { x =>
        x * 2
    }.unwrap()
    const c = xs.iter().filter { it > 0 }.map { it }.to_list()
    const d = xs.iter().map { it }
    g(xs.filter { it > 0 }.map { it })
    xs.each { it.parts.filter { it > 0 }.map { it } }
}
"
    const want = "fn f() {
    const a = xs
        .map { it * 2 }
        .unwrap()
    const b = self.items.as_slice()
        .filter { it > 0 }
        .map { x =>
            x * 2
        }
        .unwrap()
    const c = xs.iter()
        .filter { it > 0 }
        .map { it }
        .to_list()
    const d = xs.iter().map { it }
    g(xs.filter { it > 0 }.map { it })
    xs.each {
        it.parts
            .filter { it > 0 }
            .map { it }
    }
}
"
    let out = format_source(src, &cfg).unwrap()
    defer out.deinit()
    assert_true(out.view == want, "chain broken before each call")
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
    assert_true(out.view == src, "guard kept")
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
    assert_true(out.view == src, "[T; N] untouched")
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
