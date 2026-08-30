// The module's binders, collected from the AST: function/lambda parameters and `let`/`for` names,
// each with its enclosing top-level declaration and its declared annotation's span when it has one.
// Two consumers: textDocument/inlayHint renders `: T` hints after the annotation-less `let`/`for`
// binders, and hover uses the set for bodies no checker table covers (an uninstantiated generic
// template) - a binder there hovers with its declared annotation text, and its existence suppresses
// the registry-name fallback that would otherwise show an unrelated global of the same name.
// Pattern variables are not collected; checked bodies answer them from the node tables. Sites
// inside `#define` bodies are not visited (template bodies are CST byte ranges, not AST).

import std.allocator
import std.list
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

pub fn module_binders(m: &Module, allocator: &Allocator? = null) List(Binder) {
    let out: List(Binder) = list(16, allocator)
    for d in m.decls {
        d match {
            Function(f) => {
                push_params(&out, &f.params, f.span)
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

pub fn hint_sites(m: &Module, allocator: &Allocator? = null) List(HintSite) {
    let binders = module_binders(m, allocator)
    let out: List(HintSite) = list(binders.len, allocator)
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
pub fn live_hint_sites(live_text: String, analyzed: &Module,
    allocator: &Allocator? = null) List(HintSite) {
    let doc = parse_doc(live_text, allocator)
    let live = module_binders(&doc.module, allocator)
    let anal = module_binders(analyzed, allocator)
    let out: List(HintSite) = list(anal.len, allocator)

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

fn push_params(out: &List(Binder), params: &List(FunctionParam), owner: SourceSpan) {
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
            push_params(out, &l.params, owner)
            walk_block(out, l.body, owner)
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
    const src = "fn go() {\n    let a = 1\n    let b: i32 = 2\n    for x in 0..3 {\n        let c = fn(y: i32) i32 { let d = y\n return d }\n    }\n}\n"
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
