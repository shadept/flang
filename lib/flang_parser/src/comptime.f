// Compile-time context and strict evaluation for `#if` directive
// conditions (spec §7.7).
//
// The condition language is a FLang expression subset evaluated against
// a closed, compiler-supplied context: `platform.os` / `platform.arch`
// (strings), `runtime.testing` / `runtime.release` (bools), and
// `runtime.env["KEY"]` (FLang Dict semantics: indexing yields `String?`,
// unwrapped with `??`). Semantics mirror the reference compiler's
// DirectiveConditionEvaluator:
//
//   - E2116: unknown compile-time name or member (a typo is never
//     silently false)
//   - E2117: condition did not evaluate to a bool
//   - E2118: operand misuse (optional without `??`, non-bool logic
//     operands, disallowed expression forms)
//
// Also home to `flatten_module_decls`: decl-level `#if` resolves once,
// right after projection - only the active branch's declarations survive
// into collection.

import std.allocator
import std.env
import std.list
import std.option
import std.result
import std.string
import std.string_builder
import flang_core.diagnostic
import flang_core.span
import flang_parser.ast

pub type ComptimeCtx = struct {
    os: String
    arch: String
    testing: bool
    release: bool
}

// The compiling host's context. os/arch resolve through this compiler's
// OWN #if - evaluated when the compiler binary itself was built.
pub fn host_ctx() ComptimeCtx {
    return .{
        os = host_os(),
        arch = host_arch(),
        testing = false,
        release = false,
    }
}

fn host_os() String {
    #if platform.os == "windows" {
        return "windows"
    }
    #if platform.os == "macos" {
        return "macos"
    }
    #if platform.os == "linux" {
        return "linux"
    }
    return "unknown"
}

fn host_arch() String {
    #if platform.arch == "arm64" {
        return "arm64"
    }
    #if platform.arch == "x86_64" {
        return "x86_64"
    }
    return "unknown"
}

// ─────────────────────────────────────────────────────────────────────────
// Evaluation
// ─────────────────────────────────────────────────────────────────────────

// A compile-time value. `OptStr` is what `runtime.env[key]` yields -
// FLang Dict indexing returns an optional. The `Ns*` variants are the
// intermediate namespace steps of `platform.…` / `runtime.…` paths.
pub type CtValue = enum {
    B(bool)
    S(String)
    OptStr(String?)
    NsPlatform
    NsRuntime
    NsEnv
}

pub type CtError = struct {
    code: String
    message: OwnedString
    span: SourceSpan
}

pub type CtOutcome = enum {
    Active(bool)
    Invalid(CtError)
}

// Evaluates a #if condition to its branch decision, or the diagnostic
// to report. Never guesses: any invalid condition is `Invalid`.
pub fn eval_condition(ctx: &ComptimeCtx, cond: &Expr) CtOutcome {
    return ct_eval(ctx, cond) match {
        Ok(v) => v match {
            B(b) => CtOutcome.Active(b),
            OptStr(_) => CtOutcome.Invalid(CtError {
                code = "E2118",
                message = $"optional value must be unwrapped with `??` before use as a condition",
                span = expr_span(cond),
            }),
            _ => CtOutcome.Invalid(CtError {
                code = "E2117",
                message = $"#if condition must be a bool",
                span = expr_span(cond),
            }),
        },
        Err(e) => CtOutcome.Invalid(e),
    }
}

fn ct_err(code: String, message: OwnedString, span: SourceSpan) Result(CtValue, CtError) {
    return Err(CtError { code = code, message = message, span = span })
}

fn ct_eval(ctx: &ComptimeCtx, e: &Expr) Result(CtValue, CtError) {
    return e.* match {
        Lit(l) => l.value match {
            Bool(b) => Ok(CtValue.B(b.value)),
            String(s) => Ok(CtValue.S(s.text)),
            _ => ct_err("E2118", $"literal form not allowed in #if condition", l.span),
        },
        Identifier(id) => {
            if id.name == "platform" { return Ok(CtValue.NsPlatform) }
            if id.name == "runtime" { return Ok(CtValue.NsRuntime) }
            ct_err("E2116", $"unknown compile-time name `{id.name}`", id.span)
        },
        MemberAccess(ma) => {
            const recv = ct_eval(ctx, ma.receiver)?
            recv match {
                NsPlatform => {
                    if ma.member == "os" { return Ok(CtValue.S(ctx.os)) }
                    if ma.member == "arch" { return Ok(CtValue.S(ctx.arch)) }
                    ct_err("E2116", $"unknown compile-time member `{ma.member}`", ma.span)
                },
                NsRuntime => {
                    if ma.member == "testing" { return Ok(CtValue.B(ctx.testing)) }
                    if ma.member == "release" { return Ok(CtValue.B(ctx.release)) }
                    if ma.member == "env" { return Ok(CtValue.NsEnv) }
                    ct_err("E2116", $"unknown compile-time member `{ma.member}`", ma.span)
                },
                _ => ct_err("E2118", $"cannot access member `{ma.member}` in #if condition", ma.span),
            }
        },
        Index(ix) => {
            const recv = ct_eval(ctx, ix.receiver)?
            const key = ct_eval(ctx, ix.index)?
            recv match {
                NsEnv => key match {
                    S(k) => Ok(CtValue.OptStr(env(k))),
                    _ => ct_err("E2118", $"runtime.env is indexed by a string key", ix.span),
                },
                _ => ct_err("E2118", $"expression is not indexable in #if condition", ix.span),
            }
        },
        Unary(u) => {
            const operand = ct_eval(ctx, u.operand)?
            u.op match {
                Not => operand match {
                    B(b) => Ok(CtValue.B(!b)),
                    _ => ct_err("E2118", $"`!` requires a bool operand in #if condition", u.span),
                },
                _ => ct_err("E2118", $"operator not allowed in #if condition", u.span),
            }
        },
        Coalesce(c) => {
            const lhs = ct_eval(ctx, c.lhs)?
            lhs match {
                OptStr(opt) => opt match {
                    Some(v) => Ok(CtValue.S(v)),
                    None => ct_eval(ctx, c.rhs),
                },
                _ => ct_err("E2118",
                    $"left operand of `??` must be an optional (an env lookup)", c.span),
            }
        },
        Binary(b) => ct_eval_binary(ctx, &b),
        _ => ct_err("E2118", $"expression form not allowed in #if condition", expr_span(e)),
    }
}

fn ct_eval_binary(ctx: &ComptimeCtx, b: &BinaryExpr) Result(CtValue, CtError) {
    const l = ct_eval(ctx, b.lhs)?
    const r = ct_eval(ctx, b.rhs)?

    if is_optional(&l) or is_optional(&r) {
        return ct_err("E2118",
            $"optional value must be unwrapped with `??` before comparison", b.span)
    }

    return b.op match {
        And => {
            const lb = as_bool(&l)
            const rb = as_bool(&r)
            if lb.is_some() and rb.is_some() {
                return Ok(CtValue.B(lb.unwrap() and rb.unwrap()))
            }
            ct_err("E2118", $"`and` requires bool operands in #if condition", b.span)
        },
        Or => {
            const lb = as_bool(&l)
            const rb = as_bool(&r)
            if lb.is_some() and rb.is_some() {
                return Ok(CtValue.B(lb.unwrap() or rb.unwrap()))
            }
            ct_err("E2118", $"`or` requires bool operands in #if condition", b.span)
        },
        Eq => ct_eq(&l, &r) match {
            Some(eq) => Ok(CtValue.B(eq)),
            None => ct_err("E2118", $"cannot compare these operands in #if condition", b.span),
        },
        Ne => ct_eq(&l, &r) match {
            Some(eq) => Ok(CtValue.B(!eq)),
            None => ct_err("E2118", $"cannot compare these operands in #if condition", b.span),
        },
        _ => ct_err("E2118", $"operator not allowed in #if condition", b.span),
    }
}

fn is_optional(v: &CtValue) bool {
    return v.* match {
        OptStr(_) => true,
        _ => false,
    }
}

fn as_bool(v: &CtValue) bool? {
    return v.* match {
        B(b) => Some(b),
        _ => null,
    }
}

fn ct_eq(l: &CtValue, r: &CtValue) bool? {
    l.* match {
        S(a) => {
            r.* match {
                S(b) => return Some(a == b),
                _ => {},
            }
        },
        B(a) => {
            r.* match {
                B(b) => return Some(a == b),
                _ => {},
            }
        },
        _ => {},
    }
    return null
}

// ─────────────────────────────────────────────────────────────────────────
// Decl-level flatten
// ─────────────────────────────────────────────────────────────────────────

// Resolves every decl-level #if in the module, immediately after
// projection: only the active branch's declarations survive into the
// module's decl list (nested #if resolves recursively). Invalid
// conditions produce diagnostics and drop both branches.
pub fn flatten_module_decls(m: &Module, ctx: &ComptimeCtx, diags: &List(Diagnostic), allocator: &Allocator? = null) {
    let flattened: List(Decl) = list(m.decls.len, allocator)
    splice_decls(&m.decls, ctx, diags, &flattened)
    m.set_decls(flattened)
}

fn splice_decls(decls: &List(Decl), ctx: &ComptimeCtx, diags: &List(Diagnostic), out: &List(Decl)) {
    for i in 0..decls.len {
        decls[i] match {
            IfDirective(ifd) => {
                eval_condition(ctx, &ifd.condition) match {
                    Active(active) => {
                        const branch: &List(Decl) = if active { &ifd.then_decls } else { &ifd.else_decls }
                        splice_decls(branch, ctx, diags, out)
                    },
                    Invalid(err) => {
                        let empty_hint: OwnedString
                        diags.push(Diagnostic {
                            severity = Severity.Error,
                            code = err.code,
                            message = err.message,
                            hint = empty_hint,
                            span = err.span,
                        })
                    },
                }
            },
            _ => { out.push(decls[i]) },
        }
    }
}
