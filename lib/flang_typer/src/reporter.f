// Reporter - translates `UnifyOutcome` into `Diagnostic`.
//
// The engine never builds diagnostics directly. Callers (the checker) hand the outcome to one of
// these helpers along with a `ReportCtx` describing where the unification was anchored (span, error
// code, optional message override). The result goes straight into the caller's diagnostic list.
//
// Per-call-site flavour matters: a return-statement mismatch wants a different code and phrasing
// from an assignment mismatch. Rather than baking those into the engine via `OverrideErrors`, the
// caller picks a `ReportCtx` and the reporter formats accordingly.

import std.allocator
import std.dict
import std.list
import std.option
import std.string
import std.string_builder
import flang_core.diagnostic
import flang_core.span
import flang_typer.type
import flang_typer.interner
import flang_typer.inference_engine
import flang_typer.nominal_registry
import flang_typer.error_codes

// Where the unification happened. The caller carries the span and chooses the error code (e.g.
// `E2071` for return-statement mismatch vs `E2002` for general type mismatch) and may supply a
// message override to weave the function name or assignment target into the error text.
pub type ReportCtx = struct {
    code: String
    span: SourceSpan
    // When set, used verbatim. When null, the reporter synthesises a generic "expected X, got Y"
    // message from the outcome.
    message_override: OwnedString?
    // Optional: lets the reporter print a nominal by NAME instead of by registry index. Callers
    // that have the registry should pass it - "expected `i32`, got `Foo`" is the reference's
    // wording.
    nominals: &NominalRegistry?
}

pub fn report_ctx(code: String, span: SourceSpan, nominals: &NominalRegistry? = null) ReportCtx {
    let empty: OwnedString? = null
    return .{ code = code, span = span, message_override = empty, nominals = nominals }
}

// Emit zero or one diagnostic depending on the outcome. `Unified` produces nothing. Every other
// variant produces exactly one diagnostic on `out`. Caller owns the message strings appended to the
// diagnostic - they aren't reclaimed by anything in this file.
pub fn report(outcome: &UnifyOutcome, ctx: &ReportCtx, it: &TypeInterner, out: &List(Diagnostic),
    allocator: &Allocator? = null) {
    let alloc = allocator.or_global()
    outcome.* match {
        Unified(_) => {}
        UniMismatch(m) => report_mismatch(&m, ctx, it, out, alloc)
        UniOccursCheck(o) => report_occurs(&o, ctx, it, out, alloc)
        UniArityMismatch(a) => report_arity(&a, ctx, out, alloc)
        UniPrimConstraint(p) => report_prim_constraint(&p, ctx, it, out, alloc)
    }
}

fn report_mismatch(m: &Mismatch, ctx: &ReportCtx, it: &TypeInterner, out: &List(Diagnostic),
    alloc: &Allocator) {
    let message = ctx.message_override match {
        Some(msg) => msg
        None => format_mismatch(m, ctx, it, alloc)
    }
    let empty_hint: OwnedString
    let diag = Diagnostic {
        severity = Severity.Error,
        code = ctx.code,
        message = message,
        hint = empty_hint,
        span = ctx.span,
    }
    out.push(diag)
}

fn report_occurs(o: &OccursDetails, ctx: &ReportCtx, it: &TypeInterner, out: &List(Diagnostic),
    alloc: &Allocator) {
    let sb = string_builder(64, Some(alloc))
    sb.append("recursive type: variable ?")
    sb.append(o.var_id)
    sb.append(" occurs inside ")
    it.format(o.ty, &sb)
    let empty_hint: OwnedString
    let diag = Diagnostic {
        severity = Severity.Error,
        code = E_OCCURS_CHECK,
        message = sb.to_string(),
        hint = empty_hint,
        span = ctx.span,
    }
    out.push(diag)
}

fn report_arity(a: &ArityDetails, ctx: &ReportCtx, out: &List(Diagnostic), alloc: &Allocator) {
    let sb = string_builder(64, Some(alloc))
    sb.append(arity_label(a.what))
    sb.append(" mismatch: expected ")
    sb.append(a.expected)
    sb.append(", got ")
    sb.append(a.actual)
    let empty_hint: OwnedString
    // The CALLER's code, like every other outcome here: an array-length mismatch inside a `let` is
    // that `let`'s type mismatch (E2002), a parameter-count mismatch in a return is E2071.
    // `E_ARITY_MISMATCH` stays the code only when the caller asks for it.
    let diag = Diagnostic {
        severity = Severity.Error,
        code = ctx.code,
        message = sb.to_string(),
        hint = empty_hint,
        span = ctx.span,
    }
    out.push(diag)
}

fn report_prim_constraint(p: &PrimViolation, ctx: &ReportCtx, it: &TypeInterner,
    out: &List(Diagnostic), alloc: &Allocator) {
    let sb = string_builder(64, Some(alloc))
    sb.append("type mismatch: expected one of ")
    for i in 0..p.allowed.len {
        if i > 0 {
            sb.append(" | ")
        }
        let k = p.allowed[i]
        sb.append(prim_name(k))
    }
    sb.append(", got ")
    it.format(p.got, &sb)
    let empty_hint: OwnedString
    let diag = Diagnostic {
        severity = Severity.Error,
        code = E_PRIM_CONSTRAINT,
        message = sb.to_string(),
        hint = empty_hint,
        span = ctx.span,
    }
    out.push(diag)
}

fn format_mismatch(m: &Mismatch, ctx: &ReportCtx, it: &TypeInterner,
    alloc: &Allocator) OwnedString {
    let sb = string_builder(64, Some(alloc))
    sb.append("type mismatch: expected `")
    format_with_names(it, m.expected, &sb, ctx.nominals)
    sb.append("`, got `")
    format_with_names(it, m.actual, &sb, ctx.nominals)
    sb.append("`")
    return sb.to_string()
}

// The interner's `format` has no registry, so it renders a nominal as `#<id>`. With one in hand the
// SHORT name is what a reader wants ("expected `i32`, got `Foo`"), and it is what the reference
// prints - the harness matches on that text. Public: the LSP renders hover and inlay-hint types
// through the same formatting diagnostics use. `vars` optionally names free variables (a generic
// signature's `$T` bindings, see `checker.type_param_names`); an unnamed var falls back to `?N`.
pub fn format_with_names(it: &TypeInterner, t: Ty, sb: &StringBuilder, reg: &NominalRegistry?,
    vars: &Dict(VarId, String)? = null) {
    if reg.is_none() {
        it.format(t, sb)
        return
    }
    let r = reg.unwrap()
    it.node(t) match {
        NNominal(nn) => {
            sb.append(short_name(nominal_fqn(r, nn.id)))
            if nn.args.len > 0 {
                sb.append("(")
                for i in 0..nn.args.len {
                    if i > 0 {
                        sb.append(", ")
                    }
                    format_with_names(it, it.child_at(nn.args, i), sb, reg, vars)
                }
                sb.append(")")
            }
        }
        NRef(inner) => {
            sb.append("&")
            format_with_names(it, inner, sb, reg, vars)
        }
        NArray(a) => {
            sb.append("[")
            format_with_names(it, a.elem, sb, reg, vars)
            sb.append("; ")
            sb.append(a.length)
            sb.append("]")
        }
        NFunc(f) => {
            sb.append("fn(")
            for i in 0..f.params.len {
                if i > 0 {
                    sb.append(", ")
                }
                format_with_names(it, it.child_at(f.params, i), sb, reg, vars)
            }
            sb.append(") ")
            format_with_names(it, f.ret, sb, reg, vars)
        }
        NTuple(span) => {
            sb.append("(")
            for i in 0..span.len {
                if i > 0 {
                    sb.append(", ")
                }
                format_with_names(it, it.child_at(span, i), sb, reg, vars)
            }
            if span.len == 1 {
                sb.append(",")
            }
            sb.append(")")
        }
        NVar(v) => {
            const named = vars match {
                Some(m) => m.get(v.id)
                None => null
            }
            named match {
                Some(n) => sb.append(n)
                None => it.format(t, sb)
            }
        }
        _ => it.format(t, sb)
    }
}

fn nominal_fqn(reg: &NominalRegistry, id: NominalId) String {
    return reg.get(id).* match {
        NomStruct(sd) => sd.fqn
        NomEnum(ed) => ed.fqn
    }
}

// The last dot-separated segment of an FQN. Public: the LSP matches a cursor's bare identifier
// against registry FQNs through it.
pub fn short_name(fqn: String) String {
    let cut = 0usize
    for i in 0..fqn.len {
        if fqn[i] == '.' {
            cut = i + 1
        }
    }
    return fqn[cut..fqn.len]
}

fn arity_label(k: ArityKind) String {
    return k match {
        FuncParams => "function parameter count"
        TupleLength => "tuple length"
        NominalArgs => "generic argument count"
        ArrayLength => "array length"
        RecordFields => "record field count"
    }
}
