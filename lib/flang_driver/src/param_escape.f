// Copy-on-write parameters (RFC-026): decide, before a single instruction is emitted, whether a
// by-value aggregate parameter needs its shadow copy.
//
// Every aggregate crosses a call boundary by pointer, so a parameter is really a borrow of the
// caller's value. spec §3.2 says the copy that turns it back into a value appears on first write,
// not on entry. This answers "does this body ever write to it, or let its address outlive the
// expression it appears in" from the checked AST, and `lower_function_body` binds the parameter to
// the caller's pointer when the answer is no.
//
// Deciding here rather than deleting the copy afterwards is what makes the by-pointer parameter a
// real borrow rather than an optimized-away copy: there is no point in the pipeline where a
// read-only parameter has bytes of its own. RFC-028's `move` lands on the same seam - a moved
// argument is one more reason not to emit the copy, not a second mechanism.
//
// ── the rule ───────────────────────────────────────────────────────────
//
// ALLOWED, the parameter keeps the caller's pointer:
//
//   p                     read the whole value
//   p.field               read a field (only when the checker recorded no `op_deref` hops - a hop
//                         is a call taking `&p`)
//   f(p)                  hand the whole value to a callee. The callee is a by-value aggregate
//                         parameter in its own right, so it ran this same analysis and made its own
//                         copy if it needed one. Nothing is assumed about its body.
//   p match { ... }       every arm; a pattern binding out of `p` ALIASES `p`, so the bound names
//                         join the set and are held to the same rule
//   return p              copies out through the caller's sret buffer
//
// Anything else that so much as mentions the parameter forces the copy. The classification is a
// whitelist on purpose: an AST form nobody considered, and every implicit `&` the checker records
// (user operators, `op_index`, `op_try`, the iterator protocol, UFCS receivers), lands in the
// default and copies. Missing a case costs a memcpy, never correctness. The matches over `Expr`,
// `Stmt` and `Pattern` are total, so a new variant is a build error here rather than a silent
// miscompile.

import std.allocator
import std.dict
import std.list
import std.option
import std.string
import std.test
import flang_core.span
import flang_parser.ast
import flang_typer.node_id
import flang_typer.result
import flang_typer.inference_results

// The names that alias the parameter's storage: the parameter, plus whatever a pattern bound out of
// it. Scope is ignored - a name kept live past its arm only ever costs an extra copy.
type Aliases = struct {
    names: List(String)
}

// Whether each of `decl`'s parameters needs a shadow copy, parallel to `decl.params`. A parameter
// that is not a by-value aggregate is irrelevant here and answers `true`, which its caller ignores.
pub fn shadowed_params(decl: &FunctionDecl, result: &TypeCheckResult,
    overlay: &InferenceResults?, allocator: &Allocator? = null) List(bool) {
    let out: List(bool) = list(decl.params.len, allocator)
    const body = decl.body
    for i in 0..decl.params.len {
        if body.is_none() {
            out.push(true)
            continue
        }
        out.push(needs_shadow(decl.params[i].name, &body.unwrap(), result, overlay, allocator))
    }
    return out
}

// One parameter. True means the body writes through it or lets its address escape.
pub fn needs_shadow(name: String, body: &BlockExpr, result: &TypeCheckResult,
    overlay: &InferenceResults?, allocator: &Allocator? = null) bool {
    // A `_`-named parameter is unreachable from the body by convention, but the name is still a
    // name; nothing special is done for it.
    let aliases: Aliases = .{ names = list(4, allocator) }
    defer aliases.names.deinit()
    aliases.names.push(name)
    return block_escapes(body, &aliases, result, overlay)
}

// ── the walk ───────────────────────────────────────────────────────────

fn block_escapes(b: &BlockExpr, al: &Aliases, r: &TypeCheckResult,
    ov: &InferenceResults?) bool {
    for i in 0..b.stmts.len {
        if stmt_escapes(&b.stmts[i], al, r, ov) {
            return true
        }
    }
    b.trailing match {
        Some(e) => return expr_escapes(e, al, r, ov)
        None => {}
    }
    return false
}

fn stmt_escapes(s: &Stmt, al: &Aliases, r: &TypeCheckResult, ov: &InferenceResults?) bool {
    return s.* match {
        // Re-binding a name we track loses the thread; from here on `name` could be either value.
        Let(l) => {
            if contains_name(al, l.name) {
                true
            } else {
                l.init match {
                    Some(e) => expr_escapes(&e, al, r, ov)
                    None => false
                }
            }
        }
        Expression(e) => expr_escapes(&e.expr, al, r, ov)
        // The value is copied into the caller's buffer, so the address does not travel with it.
        Return(rt) => rt.value match {
            Some(e) => expr_escapes(&e, al, r, ov)
            None => false
        }
        Defer(d) => expr_escapes(d.expr, al, r, ov)
        Break(_) => false
        Continue(_) => false
        // The loop variable of `for x in p` names into `p`'s storage.
        For(f) => {
            if roots_in(f.iterable, al, r, ov) {
                al.names.push(f.var_name)
            }
            expr_escapes(f.iterable, al, r, ov) or block_escapes(&f.body, al, r, ov)
        }
        While(w) => expr_escapes(w.condition, al, r, ov) or block_escapes(&w.body, al, r, ov)
        Loop(l) => block_escapes(&l.body, al, r, ov)
        // Both arms are projected away before lowering; whichever survives is walked as itself.
        IfDirective(d) => block_escapes(&d.then_body, al, r, ov)
            or d.else_body match {
                Some(b) => block_escapes(&b, al, r, ov)
                None => false
            }
    }
}

fn expr_escapes(e: &Expr, al: &Aliases, r: &TypeCheckResult, ov: &InferenceResults?) bool {
    return e.* match {
        // A bare read.
        Identifier(_) => false
        Lit(_) => false

        // A field read is a gep into the parameter - unless the checker resolved the receiver
        // through `op_deref`, which is a call taking its address.
        MemberAccess(ma) => {
            if roots_in(ma.receiver, al, r, ov) and has_deref_hops(ma.span, r, ov) {
                true
            } else {
                expr_escapes(ma.receiver, al, r, ov)
            }
        }

        // The address itself leaves.
        AddressOf(a) => roots_in(a.operand, al, r, ov) or expr_escapes(a.operand, al, r, ov)

        // A write through the parameter, or through anything aliasing it.
        Assignment(a) => roots_in(a.lhs, al, r, ov) or expr_escapes(a.lhs, al, r, ov)
            or expr_escapes(a.rhs, al, r, ov)

        // `p.f(x)` hands `&p` to the callee. A plain `f(p)` does not, and is walked as ordinary
        // arguments below.
        Call(c) => call_escapes(&c, al, r, ov)

        // Arms bind INTO the scrutinee, so their names join the alias set.
        Match(m) => match_escapes(&m, al, r, ov)

        // Structure.
        Block(b) => block_escapes(&b, al, r, ov)
        If(f) => if_escapes(&f, al, r, ov)

        // Everything below either takes an address the checker recorded rather than the source
        // showing it, or is a form this analysis has not been taught. Mentioning an alias is
        // enough to keep the copy.
        InterpolatedString(s) => mentions_any_expr_list(&s.parts, al)
        ArrayLit(a) => mentions_any_expr_list(&a.elements, al)
            or a.repeat_count match {
                Some(x) => mentions(&x, al)
                None => false
            }
        TupleLit(t) => mentions_any_expr_list(&t.elements, al)
        StructLit(s) => {
            let hit = false
            for i in 0..s.fields.len {
                if mentions(s.fields[i].value, al) {
                    hit = true
                }
            }
            hit
        }
        Dereference(d) => mentions(d.operand, al)
        NullPropagation(n) => mentions(n.receiver, al)
        Index(i) => mentions(i.receiver, al) or mentions(i.index, al)
        Cast(c) => mentions(c.operand, al)
        Binary(b) => mentions(b.lhs, al) or mentions(b.rhs, al)
        Unary(u) => mentions(u.operand, al)
        Range(g) => g.start match { Some(x) => mentions(&x, al), None => false }
            or g.end match { Some(x) => mentions(&x, al), None => false }
        Coalesce(c) => mentions(c.lhs, al) or mentions(c.rhs, al)
        Try(t) => mentions(t.operand, al)
        Lambda(l) => mentions_block(&l.body, al)
        Error(_) => false
    }
}

fn call_escapes(c: &CallExpr, al: &Aliases, r: &TypeCheckResult, ov: &InferenceResults?) bool {
    // A member-access callee is a UFCS call: the receiver crosses as the first argument, adapted to
    // `&T` when that is what the winner declared, and the source never spells the `&`.
    const ufcs = c.callee.* match {
        MemberAccess(ma) => roots_in(ma.receiver, al, r, ov)
        _ => false
    }
    if ufcs {
        return true
    }
    if expr_escapes(c.callee, al, r, ov) {
        return true
    }
    for i in 0..c.args.len {
        const arg = c.args[i] match {
            Positional(e) => e
            Named(n) => n.value
        }
        // A whole-value argument lands in a by-value parameter, which protects itself. Anything
        // else about the argument is judged on its own.
        if expr_escapes(arg, al, r, ov) {
            return true
        }
    }
    return false
}

fn match_escapes(m: &MatchExpr, al: &Aliases, r: &TypeCheckResult, ov: &InferenceResults?) bool {
    if expr_escapes(m.scrutinee, al, r, ov) {
        return true
    }
    const from_alias = roots_in(m.scrutinee, al, r, ov)
    for i in 0..m.arms.len {
        const arm = &m.arms[i]
        if from_alias {
            collect_bindings(&arm.pattern, al)
        }
        arm.guard match {
            Some(g) => {
                if expr_escapes(g, al, r, ov) {
                    return true
                }
            }
            None => {}
        }
        if expr_escapes(arm.body, al, r, ov) {
            return true
        }
    }
    return false
}

fn if_escapes(f: &IfExpr, al: &Aliases, r: &TypeCheckResult, ov: &InferenceResults?) bool {
    if expr_escapes(f.condition, al, r, ov) {
        return true
    }
    if block_escapes(&f.then_branch, al, r, ov) {
        return true
    }
    return f.else_branch match {
        Some(e) => expr_escapes(&e, al, r, ov)
        None => false
    }
}

// Every name a pattern introduces, added to the alias set: a payload binding names the scrutinee's
// storage rather than a copy of it.
fn collect_bindings(p: &Pattern, al: &Aliases) {
    p.* match {
        Variable(v) => al.names.push(v.name)
        EnumVariant(e) => {
            for i in 0..e.payloads.len {
                collect_bindings(&e.payloads[i], al)
            }
        }
        Struct(s) => {
            for i in 0..s.fields.len {
                s.fields[i].binding match {
                    Some(b) => collect_bindings(b, al)
                    // `Point { x }` binds `x` to the field of that name.
                    None => al.names.push(s.fields[i].name)
                }
            }
        }
        Tuple(t) => {
            for i in 0..t.elements.len {
                collect_bindings(&t.elements[i], al)
            }
        }
        Or(o) => {
            for i in 0..o.alternatives.len {
                collect_bindings(&o.alternatives[i], al)
            }
        }
        Wildcard(_) => {}
        Literal(_) => {}
        Range(_) => {}
        Error(_) => {}
    }
}

// ── place roots ────────────────────────────────────────────────────────

// Whether `e` is a place rooted at a tracked name: `p`, `p.x`, `p[i]`, `p.*`, `p?.x`. A member hop
// the checker resolved through `op_deref` is NOT part of the same storage - it is a call - so the
// chain stops there and the answer is false.
fn roots_in(e: &Expr, al: &Aliases, r: &TypeCheckResult, ov: &InferenceResults?) bool {
    return e.* match {
        Identifier(id) => contains_name(al, id.name)
        MemberAccess(ma) => !has_deref_hops(ma.span, r, ov) and roots_in(ma.receiver, al, r, ov)
        Index(i) => roots_in(i.receiver, al, r, ov)
        Dereference(d) => roots_in(d.operand, al, r, ov)
        NullPropagation(n) => roots_in(n.receiver, al, r, ov)
        _ => false
    }
}

// Whether the checker recorded `op_deref` hops for the node at `span`. Read through the active
// overlay first, the way every table read in lowering is.
fn has_deref_hops(span: SourceSpan, r: &TypeCheckResult, ov: &InferenceResults?) bool {
    const id = node_id_of(span)
    ov match {
        Some(o) => {
            if o.receiver_derefs.get_ref(id).is_some() {
                return true
            }
        }
        None => {}
    }
    return r.get_receiver_deref(id).is_some()
}

fn contains_name(al: &Aliases, name: String) bool {
    for i in 0..al.names.len {
        if al.names[i] == name {
            return true
        }
    }
    return false
}

// ── the conservative fallback ──────────────────────────────────────────

// Whether any tracked name appears anywhere inside. Used by the forms the walk does not classify:
// if the parameter is in there at all, keep the copy.
fn mentions(e: &Expr, al: &Aliases) bool {
    return e.* match {
        Identifier(id) => contains_name(al, id.name)
        Lit(_) => false
        InterpolatedString(s) => mentions_any_expr_list(&s.parts, al)
        ArrayLit(a) => mentions_any_expr_list(&a.elements, al)
            or a.repeat_count match {
                Some(x) => mentions(&x, al)
                None => false
            }
        TupleLit(t) => mentions_any_expr_list(&t.elements, al)
        StructLit(s) => {
            let hit = false
            for i in 0..s.fields.len {
                if mentions(s.fields[i].value, al) {
                    hit = true
                }
            }
            hit
        }
        MemberAccess(ma) => mentions(ma.receiver, al)
        AddressOf(a) => mentions(a.operand, al)
        Dereference(d) => mentions(d.operand, al)
        NullPropagation(n) => mentions(n.receiver, al)
        Index(i) => mentions(i.receiver, al) or mentions(i.index, al)
        Call(c) => {
            let hit = mentions(c.callee, al)
            for i in 0..c.args.len {
                const arg = c.args[i] match {
                    Positional(e2) => e2
                    Named(n) => n.value
                }
                if mentions(arg, al) {
                    hit = true
                }
            }
            hit
        }
        Cast(c) => mentions(c.operand, al)
        Binary(b) => mentions(b.lhs, al) or mentions(b.rhs, al)
        Unary(u) => mentions(u.operand, al)
        Range(g) => g.start match { Some(x) => mentions(&x, al), None => false }
            or g.end match { Some(x) => mentions(&x, al), None => false }
        Coalesce(c) => mentions(c.lhs, al) or mentions(c.rhs, al)
        Try(t) => mentions(t.operand, al)
        Assignment(a) => mentions(a.lhs, al) or mentions(a.rhs, al)
        Block(b) => mentions_block(&b, al)
        If(f) => mentions(f.condition, al) or mentions_block(&f.then_branch, al)
            or f.else_branch match {
                Some(e2) => mentions(&e2, al)
                None => false
            }
        Match(m) => {
            let hit = mentions(m.scrutinee, al)
            for i in 0..m.arms.len {
                if mentions(m.arms[i].body, al) {
                    hit = true
                }
                m.arms[i].guard match {
                    Some(g) => {
                        if mentions(g, al) {
                            hit = true
                        }
                    }
                    None => {}
                }
            }
            hit
        }
        Lambda(l) => mentions_block(&l.body, al)
        Error(_) => false
    }
}

fn mentions_block(b: &BlockExpr, al: &Aliases) bool {
    for i in 0..b.stmts.len {
        if mentions_stmt(&b.stmts[i], al) {
            return true
        }
    }
    return b.trailing match {
        Some(e) => mentions(&e, al)
        None => false
    }
}

fn mentions_stmt(s: &Stmt, al: &Aliases) bool {
    return s.* match {
        Let(l) => l.init match {
            Some(e) => mentions(&e, al)
            None => false
        }
        Expression(e) => mentions(&e.expr, al)
        Return(rt) => rt.value match {
            Some(e) => mentions(&e, al)
            None => false
        }
        Defer(d) => mentions(d.expr, al)
        Break(_) => false
        Continue(_) => false
        For(f) => mentions(f.iterable, al) or mentions_block(&f.body, al)
        While(w) => mentions(w.condition, al) or mentions_block(&w.body, al)
        Loop(l) => mentions_block(&l.body, al)
        IfDirective(d) => mentions_block(&d.then_body, al)
            or d.else_body match {
                Some(b) => mentions_block(&b, al)
                None => false
            }
    }
}

fn mentions_any_expr_list(xs: &List(Expr), al: &Aliases) bool {
    for i in 0..xs.len {
        if mentions(&xs[i], al) {
            return true
        }
    }
    return false
}
