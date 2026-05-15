// Reporter — translates `UnifyOutcome` into `Diagnostic`.
//
// The engine never builds diagnostics directly. Callers (the checker)
// hand the outcome to one of these helpers along with a `ReportCtx`
// describing where the unification was anchored (span, error code,
// optional message override). The result goes straight into the
// caller's diagnostic list.
//
// Per-call-site flavour matters: a return-statement mismatch wants a
// different code and phrasing from an assignment mismatch. Rather
// than baking those into the engine via `OverrideErrors`, the caller
// picks a `ReportCtx` and the reporter formats accordingly.

import std.allocator
import std.list
import std.option
import std.string
import std.string_builder
import flang_core.diagnostic
import flang_core.span
import flang_typer.type
import flang_typer.inference_engine
import flang_typer.error_codes

// Where the unification happened. The caller carries the span and
// chooses the error code (e.g. `E2071` for return-statement mismatch
// vs `E2002` for general type mismatch) and may supply a message
// override to weave the function name or assignment target into the
// error text.
pub type ReportCtx = struct {
    code: String
    span: SourceSpan
    // When set, used verbatim. When null, the reporter synthesises
    // a generic "expected X, got Y" message from the outcome.
    message_override: OwnedString?
}

pub fn report_ctx(code: String, span: SourceSpan) ReportCtx {
    let empty: OwnedString? = null
    return .{ code = code, span = span, message_override = empty }
}

// Emit zero or one diagnostic depending on the outcome. `Unified`
// produces nothing. Every other variant produces exactly one
// diagnostic on `out`. Caller owns the message strings appended to
// the diagnostic — they aren't reclaimed by anything in this file.
pub fn report(outcome: &UnifyOutcome, ctx: &ReportCtx, out: &List(Diagnostic), allocator: &Allocator? = null) {
    let alloc = allocator.or_global()
    outcome.* match {
        Unified(_) => {},
        UniMismatch(m) => report_mismatch(&m, ctx, out, alloc),
        UniOccursCheck(o) => report_occurs(&o, ctx, out, alloc),
        UniArityMismatch(a) => report_arity(&a, ctx, out, alloc),
        UniPrimConstraint(p) => report_prim_constraint(&p, ctx, out, alloc),
    }
}

fn report_mismatch(m: &Mismatch, ctx: &ReportCtx, out: &List(Diagnostic), alloc: &Allocator) {
    let message = ctx.message_override match {
        Some(msg) => msg,
        None => format_mismatch(m, alloc),
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

fn report_occurs(o: &OccursDetails, ctx: &ReportCtx, out: &List(Diagnostic), alloc: &Allocator) {
    let sb = string_builder(64, alloc)
    sb.append("recursive type: variable ?")
    sb.append(o.var_id)
    sb.append(" occurs inside ")
    format(&o.ty, &sb, "")
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
    let sb = string_builder(64, alloc)
    sb.append(arity_label(a.what))
    sb.append(" mismatch: expected ")
    sb.append(a.expected)
    sb.append(", got ")
    sb.append(a.actual)
    let empty_hint: OwnedString
    let diag = Diagnostic {
        severity = Severity.Error,
        code = E_ARITY_MISMATCH,
        message = sb.to_string(),
        hint = empty_hint,
        span = ctx.span,
    }
    out.push(diag)
}

fn report_prim_constraint(p: &PrimViolation, ctx: &ReportCtx, out: &List(Diagnostic), alloc: &Allocator) {
    let sb = string_builder(64, alloc)
    sb.append("type mismatch: expected one of ")
    for i in 0..p.allowed.len {
        if i > 0 { sb.append(" | ") }
        let k = p.allowed[i]
        sb.append(prim_name(k))
    }
    sb.append(", got ")
    format(&p.got, &sb, "")
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

fn format_mismatch(m: &Mismatch, alloc: &Allocator) OwnedString {
    let sb = string_builder(64, alloc)
    sb.append("type mismatch: expected `")
    format(&m.expected, &sb, "")
    sb.append("`, got `")
    format(&m.actual, &sb, "")
    sb.append("`")
    return sb.to_string()
}

fn arity_label(k: ArityKind) String {
    return k match {
        FuncParams => "function parameter count",
        TupleLength => "tuple length",
        NominalArgs => "generic argument count",
        ArrayLength => "array length",
        RecordFields => "record field count",
    }
}
