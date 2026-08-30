// Source-generator template bodies (RFC-021): the body parser and the text engine. A `#define` body
// is a run of verbatim source text with
// `#(expr)` interpolations, `#for x in list { … }` loops and
// `#if cond { … } #elif … #else { … }` conditionals. Every expression is
// evaluated by the one compile-time evaluator (comptime.f) with the template's bindings layered
// over the closed context.
//
// Offsets: the body is lexed once; every token offset and Expr span is relative to the BODY text.
// `base` (the body's start in its file) is added when a diagnostic is reported, so spans reach the
// real source.

import std.allocator
import std.dict
import std.list
import std.option
import std.result
import std.string
import std.string_builder
import std.test
import flang_core.diagnostic
import flang_core.span
import flang_parser.ast
import flang_parser.comptime
import flang_parser.cst
import flang_parser.lexer
import flang_parser.parser
import flang_parser.projector
import flang_parser.token

pub type TemplateNode = enum {
    Verbatim(String)
    Interp(TemplateInterp)
    Loop(TemplateFor)
    Cond(TemplateIf)
}

// `#(expr)`; `in_string` marks a hole inside a string literal, whose value is pasted escaped so the
// literal stays valid.
pub type TemplateInterp = struct {
    expr: Expr
    in_string: bool
}

pub type TemplateFor = struct {
    var_name: String
    iterable: Expr
    body: List(TemplateNode)
}

// `else_body` is empty when there is no `#else`; an `#elif` chain nests a single `Cond` node there.
pub type TemplateIf = struct {
    cond: Expr
    body: List(TemplateNode)
    else_body: List(TemplateNode)
}

// ─────────────────────────────────────────────────────────────────────────
// Body parser
// ─────────────────────────────────────────────────────────────────────────

type TemplateParser = struct {
    body: String
    base: usize
    file_id: i32
    tokens: List(Token)
    parser: Parser
    alloc: &Allocator
    diags: &List(Diagnostic)
    cursor: usize
}

// Parse a template body. `body` is the text between the `#define`'s braces, starting at byte `base`
// of file `file_id`. Everything produced borrows `body` and is allocated from `alloc`, which must
// outlive the nodes. Parse errors are pushed to `diags` with file-absolute spans.
pub fn parse_template_body(body: String, base: usize, file_id: i32, alloc: &Allocator,
    diags: &List(Diagnostic)) List(TemplateNode) {
    let lx = lexer(body, Some(alloc))
    const tokens = lx.tokenize()
    let p = parser(tokens, body, Some(alloc))
    p.set_file_id(file_id)
    let tp: TemplateParser = .{
        body = body,
        base = base,
        file_id = file_id,
        tokens = tokens,
        parser = p,
        alloc = alloc,
        diags = diags,
        cursor = 0,
    }
    let out: List(TemplateNode) = list(0, Some(alloc))
    const stop = tp.parse_nodes(0, &out)
    if stop < tp.tokens.len and tp.tokens[stop].kind == TokenKind.CloseBrace {
        tp.error_at(stop, "E1002", $"unbalanced closing brace in template body")
    }
    tp.flush_verbatim(body.len, &out)
    tp.shift_diags(&tp.parser.diagnostics)
    return out
}

fn error_at(self: &TemplateParser, index: usize, code: String, message: OwnedString) {
    let start: usize = self.body.len
    let length: usize = 0
    if index < self.tokens.len {
        start = self.tokens[index].offset
        length = self.tokens[index].text.len
    }
    self.diags.push(error(code, message, .{ file_id = self.file_id, start = self.base + start,
        length = length }))
}

// Move body-relative parser diagnostics out, shifted to file offsets.
fn shift_diags(self: &TemplateParser, from: &List(Diagnostic)) {
    const taken = from.to_owned_slice()
    for &d in taken.0 {
        const sp: SourceSpan = .{ file_id = self.file_id, start = self.base + d.span.start,
            length = d.span.length }
        self.diags.push(error(d.code, d.message, sp))
    }
    taken.1.free(taken.0)
}

fn flush_verbatim(self: &TemplateParser, end: usize, out: &List(TemplateNode)) {
    if self.cursor >= end {
        return
    }
    out.push(TemplateNode.Verbatim(self.body[self.cursor..end]))
    self.cursor = end
}

fn kind_at(self: &TemplateParser, index: usize) TokenKind {
    if index < self.tokens.len {
        return self.tokens[index].kind
    }
    return TokenKind.Eof
}

fn is_elif(self: &TemplateParser, index: usize) bool {
    return self.kind_at(index) == TokenKind.Identifier and self.tokens[index].text == "elif"
}

// Walks tokens from `start`, appending nodes; returns the index of the `}` that closes the
// enclosing body (depth 0), or of Eof.
fn parse_nodes(self: &TemplateParser, start: usize, out: &List(TemplateNode)) usize {
    let i = start
    let depth: usize = 0
    loop {
        const k = self.kind_at(i)
        if k == TokenKind.Eof {
            return i
        }
        if k == TokenKind.Hash {
            const next = self.kind_at(i + 1)
            if next == TokenKind.OpenParenthesis {
                i = self.parse_interpolation(i, out)
                continue
            }
            if next == TokenKind.For {
                i = self.parse_for(i, out)
                continue
            }
            if next == TokenKind.If {
                i = self.parse_if(i, out)
                continue
            }
        }
        if k == TokenKind.StringLiteral and self.tokens[i].text.contains("#(") {
            self.flush_verbatim(self.tokens[i].offset, out)
            self.parse_string_holes(self.tokens[i], out)
            i = i + 1
            continue
        }
        if k == TokenKind.OpenBrace {
            depth = depth + 1
        }
        if k == TokenKind.CloseBrace {
            if depth == 0 {
                return i
            }
            depth = depth - 1
        }
        i = i + 1
    }
    return i
}

// `#(expr)` at token `i`. Returns the index after the closing `)`.
fn parse_interpolation(self: &TemplateParser, i: usize, out: &List(TemplateNode)) usize {
    self.flush_verbatim(self.tokens[i].offset, out)
    self.parser.seek(i + 2)
    const cst = self.parser.tree.node_at(self.parser.parse_expression())
    const e = project_expression(cst, self.file_id, self.alloc)
    let j = self.parser.token_index()
    if self.kind_at(j) != TokenKind.CloseParenthesis {
        self.error_at(j, "E1002", $"expected `)` to close `#(`")
        self.cursor = cst.end
        return j
    }
    self.cursor = self.tokens[j].offset + 1
    out.push(TemplateNode.Interp(TemplateInterp { expr = e, in_string = false }))
    return j + 1
}

// `#for name in expr { body }` at token `i`. Returns the index after `}`.
fn parse_for(self: &TemplateParser, i: usize, out: &List(TemplateNode)) usize {
    self.flush_verbatim(self.tokens[i].offset, out)
    if self.kind_at(i + 2) != TokenKind.Identifier {
        self.error_at(i + 2, "E1002", $"expected a loop variable after `#for`")
        return i + 2
    }
    const var_name = self.tokens[i + 2].text
    if self.kind_at(i + 3) != TokenKind.In {
        self.error_at(i + 3, "E1002", $"expected `in` in `#for`")
        return i + 3
    }
    self.parser.seek(i + 4)
    const cst = self.parser.tree.node_at(self.parser.parse_condition_expression())
    const iterable = project_expression(cst, self.file_id, self.alloc)
    let body: List(TemplateNode) = list(0, Some(self.alloc))
    const after = self.parse_braced_body(self.parser.token_index(), &body)
    out.push(TemplateNode.Loop(TemplateFor { var_name = var_name, iterable = iterable,
        body = body }))
    return after
}

// `#if expr { body } [#elif expr { body }]* [#else { body }]` at token `i`.
fn parse_if(self: &TemplateParser, i: usize, out: &List(TemplateNode)) usize {
    self.flush_verbatim(self.tokens[i].offset, out)
    self.parser.seek(i + 2)
    const cst = self.parser.tree.node_at(self.parser.parse_condition_expression())
    const cond = project_expression(cst, self.file_id, self.alloc)
    let body: List(TemplateNode) = list(0, Some(self.alloc))
    let after = self.parse_braced_body(self.parser.token_index(), &body)
    let else_body: List(TemplateNode) = list(0, Some(self.alloc))
    if self.kind_at(after) == TokenKind.Hash and self.is_elif(after + 1) {
        // Parse the `#elif` exactly like `#if`; it nests as the sole else node.
        self.cursor = self.tokens[after].offset
        after = self.parse_if(after, &else_body)
    } else if self.kind_at(after) == TokenKind.Hash and self.kind_at(after + 1) == TokenKind.Else {
        self.cursor = self.tokens[after].offset
        after = self.parse_braced_body(after + 2, &else_body)
    }
    out.push(TemplateNode.Cond(TemplateIf { cond = cond, body = body, else_body = else_body }))
    return after
}

// `{ nodes }` starting at token `open`. Returns the index after `}`.
fn parse_braced_body(self: &TemplateParser, open: usize, body: &List(TemplateNode)) usize {
    if self.kind_at(open) != TokenKind.OpenBrace {
        self.error_at(open, "E1002", $"expected an opening brace for the template block")
        return open
    }
    self.cursor = self.tokens[open].offset + 1
    const close = self.parse_nodes(open + 1, body)
    if self.kind_at(close) != TokenKind.CloseBrace {
        self.error_at(close, "E1002", $"expected a closing brace for the template block")
        return close
    }
    self.flush_verbatim(self.tokens[close].offset, body)
    self.cursor = self.tokens[close].offset + 1
    return close + 1
}

// A string literal token containing `#(expr)` holes: split it into verbatim runs and escaped
// interpolations. Each hole's expression is lexed from its absolute offset in the body, so spans
// stay real.
fn parse_string_holes(self: &TemplateParser, tok: Token, out: &List(TemplateNode)) {
    const text = tok.text
    let local: usize = 0
    loop {
        const rel = text[local..text.len].find("#(")
        const hole: usize = rel match {
            Some(r) => local + r
            None => break
        }
        if hole > local {
            out.push(TemplateNode.Verbatim(text[local..hole]))
        }
        let lx = lexer(self.body, Some(self.alloc), tok.offset + hole + 2)
        const toks = lx.tokenize()
        let p = parser(toks, self.body, Some(self.alloc))
        p.set_file_id(self.file_id)
        const cst = p.tree.node_at(p.parse_expression())
        const e = project_expression(cst, self.file_id, self.alloc)
        let close_end = cst.end
        if p.token_index() < toks.len and toks[p.token_index()].kind == TokenKind.CloseParenthesis {
            close_end = (toks[p.token_index()].offset + 1) as u32
        } else {
            self.diags.push(error("E1002", $"expected `)` to close `#(` inside a string literal",
                    .{ file_id = self.file_id, start = self.base + cst.end, length = 0 }))
        }
        self.shift_diags(&p.diagnostics)
        out.push(TemplateNode.Interp(TemplateInterp { expr = e, in_string = true }))
        local = close_end - tok.offset
    }
    if local < text.len {
        out.push(TemplateNode.Verbatim(text[local..text.len]))
    }
    self.cursor = tok.offset + text.len
}

// ─────────────────────────────────────────────────────────────────────────
// Text engine
// ─────────────────────────────────────────────────────────────────────────

// Expand `nodes` into `sb`. The first evaluation error stops expansion and is returned (its span is
// body-relative; the caller adds `base`).
pub fn expand_template(env: &CtEnv, nodes: &List(TemplateNode), sb: &StringBuilder) Result((),
    CtError) {
    for &node in nodes {
        expand_node(env, node, sb)?
    }
    return Ok(())
}

fn expand_node(env: &CtEnv, node: &TemplateNode, sb: &StringBuilder) Result((), CtError) {
    node.* match {
        Verbatim(text) => { sb.append(text) }
        Interp(it) => {
            const v = ct_eval(env, &it.expr)?
            if it.in_string {
                let tmp = string_builder(16, Some(env.alloc))
                ct_stringify(&v, &tmp)
                append_string_escaped(sb, tmp.as_view())
            } else {
                ct_stringify(&v, sb)
            }
        }
        Loop(lp) => {
            const iterable = ct_eval(env, &lp.iterable)?
            const items: List(CtValue) = iterable match {
                List(l) => l
                _ => return Err(CtError {
                    code = "E2118",
                    message = $"`#for` requires a list to iterate",
                    span = expr_span(&lp.iterable),
                })
            }
            const shadowed = env.bindings[lp.var_name]
            for item in items {
                env.bindings[lp.var_name] = item
                expand_template(env, &lp.body, sb)?
            }
            shadowed match {
                Some(prev) => { env.bindings[lp.var_name] = prev }
                None => { let _dropped = env.bindings.remove(lp.var_name) }
            }
        }
        Cond(cd) => {
            if ct_eval_condition(env, &cd.cond)? {
                expand_template(env, &cd.body, sb)?
            } else {
                expand_template(env, &cd.else_body, sb)?
            }
        }
    }
    return Ok(())
}

// Escape a value pasted inside a string literal.
fn append_string_escaped(sb: &StringBuilder, text: String) {
    for c in text.as_raw_bytes() {
        if c == '"' as u8 {
            sb.append("\\\"")
        }
        else if c == '\\' as u8 {
            sb.append("\\\\")
        }
        else if c == '\n' as u8 {
            sb.append("\\n")
        }
        else {
            sb.append_byte(c)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────

fn test_env(arena: &Allocator) CtEnv {
    const ctx: ComptimeCtx = .{ os = "testos", arch = "testarch", testing = false, release = false }
    const boxed = box(arena, ctx)
    const lookup: CtLookup = .{ ctx = 0usize as &u8, resolve = test_no_lookup }
    return ct_env(boxed, arena, lookup)
}

fn test_no_lookup(ctx: &u8, name: String) &TypeDecl? {
    return null
}

fn expand_for_test(body: String, env: &CtEnv, alloc: &Allocator) OwnedString {
    let diags: List(Diagnostic) = list(0, Some(alloc))
    const nodes = parse_template_body(body, 0, 0, alloc, &diags)
    assert_true(diags.len == 0, "template parse error")
    let sb = string_builder(64, Some(alloc))
    expand_template(env, &nodes, &sb) match {
        Ok(_) => {}
        Err(e) => assert_true(false, e.code)
    }
    return sb.to_string()
}

test "template: #for over a bound list with #(x) and \"#(x)\"" {
    let backing = arena_allocator(or_global(null))
    let a = backing.allocator()
    let env = test_env(&a)
    let names: List(CtValue) = list(3, Some(&a))
    names.push(CtValue.S("x"))
    names.push(CtValue.S("y"))
    names.push(CtValue.S("z"))
    env.bindings["names"] = CtValue.List(names)
    env.bindings["fType"] = CtValue.Ident("f32")
    const out = expand_for_test("type P = struct {\n#for f in names {\n  #(f): #(fType), \"#(f)\"\n}\n}",
        &env, &a)
    defer out.deinit()
    assert_true(out.as_view() == "type P = struct {\n\n  x: f32, \"x\"\n\n  y: f32, \"y\"\n\n  z: f32, \"z\"\n\n}",
        "expansion text")
}

test "template: #if / #elif / #else on the closed context and bindings" {
    let backing = arena_allocator(or_global(null))
    let a = backing.allocator()
    let env = test_env(&a)
    env.bindings["n"] = CtValue.I(2)
    const out = expand_for_test("#if platform.os == \"windows\" {A} #elif n == 2 {B} #else {C}",
        &env, &a)
    defer out.deinit()
    assert_true(out.as_view() == "B", "expansion text")
}

test "template: string-literal hole escapes its value" {
    let backing = arena_allocator(or_global(null))
    let a = backing.allocator()
    let env = test_env(&a)
    env.bindings["q"] = CtValue.S("say \"hi\"")
    const out = expand_for_test("let s = \"#(q)!\"", &env, &a)
    defer out.deinit()
    assert_true(out.as_view() == "let s = \"say \\\"hi\\\"!\"", "expansion text")
}
