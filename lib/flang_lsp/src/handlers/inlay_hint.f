// The module's binders, collected from the AST: function/lambda parameters and `let`/`for` names,
// each with its enclosing top-level declaration and its declared annotation's span when it has one.
// Two consumers: textDocument/inlayHint renders `: T` hints after the annotation-less `let`/`for`
// binders, and hover uses the set for bodies no checker table covers (an uninstantiated generic
// template) - a binder there hovers with its declared annotation text, and its existence suppresses
// the registry-name fallback that would otherwise show an unrelated global of the same name.
// Pattern variables are not collected; checked bodies answer them from the node tables. Sites
// inside `#define` bodies are not visited (template bodies are CST byte ranges, not AST).

import std.allocator
import std.char
import std.collections.list
import std.option
import std.test

import flang_core.span
import flang_parser.ast
import flang_typer.node_id

import flang_lsp.handlers.syntax_diagnostics

pub type Binder = struct {
    name: String
    // The name token's span for `let`/`for`; the whole param slot for parameters.
    name_span: SourceSpan
    // The enclosing top-level declaration's span.
    owner: SourceSpan
    // The declared type annotation's span, null when the binder has none.
    annotation: SourceSpan?
    // Annotation-less `let`/`for` binder - the kind an inlay type hint attaches to.
    hintable: bool
    // What brings the binding into scope - `let`, `const`, `param`, `for` - the hover prefix.
    intro: String
}

pub fn module_binders(m: &Module) List(Binder) {
    let out: List(Binder) = list(16)
    for &d in m.decls {
        d.* match {
            Function(f) => {
                push_params(&out, f.params, f.span)
                f.body match {
                    Some(b) => walk_block(&out, b, f.span)
                    None => {}
                }
            }
            Test(t) => walk_block(&out, t.body, t.span)
            _ => {}
        }
    }
    return out
}

// One place a type hint can render: right after the binder name ending at `offset`. `node` is the
// name node the checker recorded the binder's type on.
pub type HintSite = struct {
    offset: usize
    node: NodeId
}

pub fn hint_sites(m: &Module) List(HintSite) {
    let binders = module_binders(m)
    let out: List(HintSite) = list(binders.len)
    for &b in binders {
        if b.hintable {
            out.push(.{
                offset = b.name_span.start + b.name_span.length,
                node = node_id_of(b.name_span),
            })
        }
    }
    binders.deinit()
    return out
}

// Hint sites for a buffer that has drifted from the analyzed text: positions come from a fresh
// parse of the LIVE text (a parse is milliseconds and runs per keystroke anyway), types stay under
// the ANALYZED module's node ids. The two binder sequences pair positionally by name; pairing stops
// at the first mismatch (a binder added, removed or renamed), so hints below that divergence wait
// for the next analysis while everything above keeps rendering at live offsets.
pub fn live_hint_sites(live_text: String, analyzed: &Module) List(HintSite) {
    let doc = parse_doc(live_text)
    let live = module_binders(&doc.module)
    let anal = module_binders(analyzed)
    let out: List(HintSite) = list(anal.len)

    let i: usize = 0
    let j: usize = 0
    loop {
        while i < live.len and !live[i].hintable {
            i = i + 1
        }
        while j < anal.len and !anal[j].hintable {
            j = j + 1
        }
        if i >= live.len or j >= anal.len {
            break
        }
        if live[i].name != anal[j].name {
            break
        }
        out.push(.{
            offset = live[i].name_span.start + live[i].name_span.length,
            node = node_id_of(anal[j].name_span),
        })
        i = i + 1
        j = j + 1
    }

    anal.deinit()
    live.deinit()
    doc.deinit()
    return out
}

// Where an implied-bound hint renders: `offset` in the displayed text, and the analyzed declaration
// it reads - a function (`name`, `decl` its span) or a generic alias's parameter (`decl` the
// parameter's span). A function site with a `param` sits before the first `where` entry that
// projects through it (`I.Item: ...`) and shows the bounds on that parameter; one without sits
// after the signature and shows the rest. `lead` and `tail` join the hint to the text.
pub type BoundSite = struct {
    offset: usize
    decl: SourceSpan
    name: String
    is_fn: bool
    param: String
    lead: String
    tail: String
}

// Bound hint sites at positions in `text`, paired by name with the analyzed module's declarations
// as `live_hint_sites` pairs binders: pairing stops at the first declaration added, removed or
// renamed. `analyzed_text` is the text `analyzed` was parsed from.
pub fn bound_sites(text: String, analyzed_text: String, analyzed: &Module) List(BoundSite) {
    let anal = bound_anchors(analyzed_text, analyzed)
    if text == analyzed_text {
        return anal
    }
    let doc = parse_doc(text)
    let live = bound_anchors(text, &doc.module)
    let out: List(BoundSite) = list(anal.len)
    const n = if live.len < anal.len { live.len } else { anal.len }
    for i in 0..n {
        const same = live[i].name == anal[i].name and live[i].is_fn == anal[i].is_fn
            and live[i].param == anal[i].param
        if !same {
            break
        }
        out.push(.{
            offset = live[i].offset,
            decl = anal[i].decl,
            name = anal[i].name,
            is_fn = anal[i].is_fn,
            param = anal[i].param,
            lead = live[i].lead,
            tail = live[i].tail,
        })
    }
    live.deinit()
    doc.deinit()
    anal.deinit()
    return out
}

fn bound_anchors(text: String, m: &Module) List(BoundSite) {
    let out: List(BoundSite) = list(0)
    for &d in m.decls {
        d.* match {
            Function(f) => push_fn_anchor(&out, text, &f)
            Type(t) => push_alias_anchors(&out, &t)
            _ => {}
        }
    }
    return out
}

fn push_fn_anchor(out: &List(BoundSite), text: String, f: &FunctionDecl) {
    const body = f.body ?? return
    for i in 0..f.bounds.len {
        if first_projection(f.bounds, i) {
            out.push(.{
                offset = f.bounds[i].subject_spans[0].start,
                decl = f.span,
                name = f.name,
                is_fn = true,
                param = f.bounds[i].param,
                lead = "",
                tail = ", ",
            })
        }
    }
    out.push(.{
        offset = trim_back(text, body.span.start),
        decl = f.span,
        name = f.name,
        is_fn = true,
        param = "",
        lead = if f.bounds.len > 0 { ", " } else { " where " },
        tail = "",
    })
}

// Whether `bounds[i]` is the first entry projecting through its parameter.
fn first_projection(bounds: TypeBound[], i: usize) bool {
    if bounds[i].path.len == 0 or bounds[i].subject_spans.len == 0 {
        return false
    }
    for j in 0..i {
        if bounds[j].path.len > 0 and bounds[j].param == bounds[i].param {
            return false
        }
    }
    return true
}

// The offset just past the last non-blank byte before `end`.
fn trim_back(text: String, end: usize) usize {
    let i = end
    while i > 0 and is_whitespace(text[i - 1]) {
        i = i - 1
    }
    return i
}

fn push_alias_anchors(out: &List(BoundSite), t: &TypeDecl) {
    const nominal = t.body.* match {
        AnonStruct(_) => true
        AnonEnum(_) => true
        Contract(_) => true
        _ => false
    }
    if nominal {
        return
    }
    for &g in t.generics {
        const end = g.bound match {
            Some(b) => type_expr_span(b)
            None => g.span
        }
        out.push(.{
            offset = end.start + end.length,
            decl = g.span,
            name = g.name,
            is_fn = false,
            param = "",
            lead = if g.bound.is_some() { " + " } else { ": " },
            tail = "",
        })
    }
}

fn push_params(out: &List(Binder), params: FunctionParam[], owner: SourceSpan) {
    for &p in params {
        out.push(.{
            name = p.name,
            name_span = p.span,
            owner = owner,
            annotation = Some(type_expr_span(p.type_expr)),
            hintable = false,
            intro = "param",
        })
    }
}

fn push_let(out: &List(Binder), ls: &LetStmt, owner: SourceSpan) {
    // Error recovery leaves the name span equal to the statement span - nothing to bind.
    if ls.name.len == 0 {
        return
    }
    const ann = ls.type_annotation match {
        Some(t) => Some(type_expr_span(t))
        None => null
    }
    out.push(.{
        name = ls.name,
        name_span = ls.name_span,
        owner = owner,
        annotation = ann,
        hintable = ann.is_none(),
        intro = if ls.is_const { "const" } else { "let" },
    })
}

fn push_for(out: &List(Binder), fs: &ForStmt, owner: SourceSpan) {
    if fs.var_name.len == 0 {
        return
    }
    out.push(.{
        name = fs.var_name,
        name_span = fs.var_span,
        owner = owner,
        annotation = null,
        hintable = true,
        intro = "for",
    })
}

fn walk_block(out: &List(Binder), b: &BlockExpr, owner: SourceSpan) {
    for &s in b.stmts {
        walk_stmt(out, s, owner)
    }
    b.trailing match {
        Some(t) => walk_expr(out, t, owner)
        None => {}
    }
}

fn walk_stmt(out: &List(Binder), s: &Stmt, owner: SourceSpan) {
    s.* match {
        Let(ls) => {
            push_let(out, &ls, owner)
            ls.init match {
                Some(i) => walk_expr(out, i, owner)
                None => {}
            }
        }
        Expression(es) => walk_expr(out, es.expr, owner)
        Return(rs) => rs.value match {
            Some(v) => walk_expr(out, v, owner)
            None => {}
        }
        Defer(ds) => walk_expr(out, ds.expr, owner)
        For(fs) => {
            push_for(out, &fs, owner)
            walk_expr(out, fs.iterable, owner)
            walk_block(out, fs.body, owner)
        }
        While(ws) => {
            walk_expr(out, ws.condition, owner)
            walk_block(out, ws.body, owner)
        }
        Loop(l) => walk_block(out, l.body, owner)
        IfDirective(ifd) => {
            for &t in ifd.then_stmts {
                walk_stmt(out, t, owner)
            }
            for &e in ifd.else_stmts {
                walk_stmt(out, e, owner)
            }
        }
        _ => {}
    }
}

fn walk_opt(out: &List(Binder), e: &Expr?, owner: SourceSpan) {
    e match {
        Some(x) => walk_expr(out, x, owner)
        None => {}
    }
}

fn walk_expr(out: &List(Binder), e: &Expr, owner: SourceSpan) {
    e.* match {
        Lit(_) => {}
        InterpolatedString(is) => {
            is.target match {
                NewString(args) => {
                    for &a in args {
                        walk_expr(out, a, owner)
                    }
                }
                IntoBuilder(b) => walk_expr(out, b, owner)
            }
            for &p in is.parts {
                p.* match {
                    Hole(h) => walk_expr(out, h.expr, owner)
                    _ => {}
                }
            }
        }
        ArrayLit(al) => al.kind match {
            Elements(els) => {
                for &el in els {
                    walk_expr(out, el, owner)
                }
            }
            Repeat(r) => {
                walk_expr(out, r.value, owner)
                walk_expr(out, r.count, owner)
            }
        }
        TupleLit(tl) => {
            for &el in tl.elements {
                walk_expr(out, el, owner)
            }
        }
        StructLit(sl) => {
            for &f in sl.fields {
                f.value match {
                    Some(v) => walk_expr(out, v, owner)
                    None => {}
                }
            }
        }
        Identifier(_) => {}
        MemberAccess(ma) => walk_expr(out, ma.receiver, owner)
        AddressOf(ao) => walk_expr(out, ao.operand, owner)
        Move(m) => walk_expr(out, m.operand, owner)
        Dereference(de) => walk_expr(out, de.operand, owner)
        NullPropagation(np) => walk_expr(out, np.receiver, owner)
        Index(ix) => {
            walk_expr(out, ix.receiver, owner)
            walk_expr(out, ix.index, owner)
        }
        Call(c) => {
            walk_expr(out, c.callee, owner)
            for &a in c.args {
                a.* match {
                    Positional(p) => walk_expr(out, p, owner)
                    Named(n) => walk_expr(out, n.value, owner)
                }
            }
        }
        Cast(cs) => walk_expr(out, cs.operand, owner)
        Binary(b) => {
            walk_expr(out, b.lhs, owner)
            walk_expr(out, b.rhs, owner)
        }
        Unary(u) => walk_expr(out, u.operand, owner)
        Range(r) => {
            walk_opt(out, r.start, owner)
            walk_opt(out, r.end, owner)
        }
        Coalesce(c) => {
            walk_expr(out, c.lhs, owner)
            walk_expr(out, c.rhs, owner)
        }
        Try(t) => walk_expr(out, t.operand, owner)
        Assignment(a) => {
            walk_expr(out, a.lhs, owner)
            walk_expr(out, a.rhs, owner)
        }
        Block(b) => walk_block(out, &b, owner)
        If(i) => walk_if(out, &i, owner)
        Match(m) => {
            walk_expr(out, m.scrutinee, owner)
            for &arm in m.arms {
                arm.guard match {
                    Some(g) => walk_expr(out, g, owner)
                    None => {}
                }
                walk_expr(out, arm.body, owner)
            }
        }
        Lambda(l) => {
            push_params(out, l.params, owner)
            walk_block(out, l.body, owner)
        }
        Context(_) => {}
        ContextBind(cb) => {
            for &a in cb.args {
                a.* match {
                    Positional(p) => walk_expr(out, p, owner)
                    Named(n) => walk_expr(out, n.value, owner)
                }
            }
            walk_block(out, cb.body, owner)
        }
        Error(_) => {}
    }
}

fn walk_if(out: &List(Binder), i: &IfExpr, owner: SourceSpan) {
    walk_expr(out, i.condition, owner)
    walk_block(out, i.then_branch, owner)
    i.else_branch match {
        Block(b) => walk_block(out, b, owner)
        If(next) => walk_if(out, next, owner)
        NoElse => {}
    }
}

// Tests

test "hint sites cover annotation-less lets and for binders, nested included" {
    const src = "fn go() {\n    let a = 1\n    let b: i32 = 2\n    for x in 0..3 {\n        let c = { y: i32 => let d = y\n d }\n    }\n}\n"
    let doc = parse_doc(src)
    defer doc.deinit()
    let sites = hint_sites(&doc.module)
    defer sites.deinit()
    // a, x, c, d - b is annotated.
    assert_eq(sites.len, 4 as usize, "annotation-less binders only")
}

test "module_binders carries params with annotations and owners" {
    const src = "fn go(k: i32) {\n    let a = k\n}\n"
    let doc = parse_doc(src)
    defer doc.deinit()
    let bs = module_binders(&doc.module)
    defer bs.deinit()
    assert_eq(bs.len, 2 as usize, "param and let")
    assert_eq(bs[0].name, "k", "param first")
    assert_true(bs[0].annotation.is_some(), "param annotation span present")
    assert_true(!bs[0].hintable, "params get no inlay hint")
    assert_eq(bs[1].name, "a", "let second")
    assert_true(bs[1].annotation.is_none(), "unannotated let")
    assert_true(bs[1].hintable, "unannotated let is hintable")
    assert_true(bs[1].owner.start == bs[0].owner.start, "same enclosing declaration")
}

test "bound sites follow a shifted live buffer and stop at a renamed declaration" {
    const src = "type S(T) = B(T)\nfn f(b: B($T)) i32 { return 0 }\nfn g(b: B($T)) i32 { return 0 }\n"
    let doc = parse_doc(src)
    defer doc.deinit()
    let same = bound_sites(src, src, &doc.module)
    defer same.deinit()
    assert_eq(same.len, 3 as usize, "alias parameter and two functions")
    assert_eq(same[0].lead, ": ", "unbounded parameter")
    assert_eq(same[1].lead, " where ", "no where clause")

    const padded = "// pad\ntype S(T) = B(T)\nfn f(b: B($T)) i32 { return 0 }\nfn g(b: B($T)) i32 { return 0 }\n"
    let shifted = bound_sites(padded, src, &doc.module)
    defer shifted.deinit()
    assert_eq(shifted.len, 3 as usize, "every declaration pairs")
    assert_eq(shifted[1].offset, same[1].offset + 7, "positions move with the text")

    let renamed = bound_sites(
        "type S(T) = B(T)\nfn h(b: B($T)) i32 { return 0 }\n",
        src,
        &doc.module,
    )
    defer renamed.deinit()
    assert_eq(renamed.len, 1 as usize, "pairing stops at the rename")
}
