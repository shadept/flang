# RFC-009: `op_try` Early-Return Operator

**Type:** Language feature (operator + stdlib)
**Status:** Implemented (optimization phase deferred)
**Depends on:** RFC-007 (Option as enum)

## Implementation notes

Phases 1–5 and 7 from the original plan landed; the optimization phase (phase 6) is deliberately out of scope for v1.

- **Resolved open questions:**
  1. `TryResult` lives in `core.try`, re-exported via [stdlib/core/predule.f](../../stdlib/core/predule.f). Auto-imported through the prelude.
  2. Bare `expr?` as a statement is **not** allowed yet — it must currently appear in a context where its `T` is consumed (e.g. RHS of `let`, argument, return). Will be revisited.
  3. `?` inside a closure returns from the **lambda**, not the enclosing function. The type checker peeks the top of `FunctionStack`, which lambdas push.
  4. `?` inside `defer` is forbidden (E2091). Tracked via `InferenceContext.DeferDepth`. Can be revisited if a clean semantics emerges.

- **Code map:**
  - AST: [TryExpressionNode.cs](../../src/FLang.Frontend/Ast/Expressions/TryExpressionNode.cs) — carries the operand and the synthesized desugar.
  - Parser: postfix `?` in `ParsePostfixOperators` ([Parser.cs](../../src/FLang.Frontend/Parser.cs)). `?.` is still a single `QuestionDot` token, so the bare `Question` branch is unambiguous.
  - Type checker: `InferTry` in [HmTypeChecker.Expressions.cs](../../src/FLang.Semantics/HmTypeChecker.Expressions.cs) — builds `op_try(operand) match { Continue(v) => v, Return(r) => return r }`, runs inference on it, then explicitly checks the `R` slot against the enclosing function's return type (see "Type-checker quirk" below).
  - Lowering: [HmAstLowering.cs](../../src/FLang.Semantics/HmAstLowering.cs) just dispatches `TryExpressionNode` to its `DesugaredMatch`.
  - Stdlib impls: `op_try` for `Option` in [core/option.f](../../stdlib/core/option.f); for `Result` in [std/result.f](../../stdlib/std/result.f).

- **Diagnostics:**
  - `E2090`: `?` outside a function.
  - `E2091`: `?` inside a `defer` body.
  - `E2092`: no `op_try` overload accepts the operand type.
  - `E2071` (reused): `?` early-returns a type incompatible with the enclosing function's return type.

- **R-type compatibility check:** unification flows naturally through the synthesized `return r` arm body.

- **Stdlib `op_try` signatures:** both `Option` and `Result` use the same `T` for input and `R`'s payload — i.e. `?` on `Option(i32)` requires the enclosing fn to return `Option(i32)` exactly, not `Option(U)` for arbitrary `U`. The RFC's "`Option(?)`" sketch (cross-T early returns) would require unbound generics inferred purely from call-site context; deferred until there's a concrete user need.

- **Optimization phase deferred:** the desugar produces a real `TryResult` allocation and match. The C compiler will inline the small functions, but FLang itself does no special-casing for known stdlib types yet. Real-world impact: extra struct copy and a tag dispatch per `?`. Revisit when profiling demands it.

## Summary

Add `expr?` as a postfix early-return operator. Unlike Rust's hard-coded `?`, FLang's version desugars to a user-extensible `op_try` function that returns a `TryResult(T, R)` discriminating "continue with `T`" from "early-return `R`". The compiler emits the control-flow primitive (`return r`); the user type decides what counts as "absent" and what value to propagate.

Stdlib provides `op_try` for `Option(T)` and `Result(T, E)`. User types can opt in by implementing the function.

## Motivation

Without `?`, every fallible call requires a `match` or `if is_err` ladder. From [examples/fq/src/main.f:99-103](../../examples/fq/src/main.f:99):

```
const parsed = parse(stdin.reader())
if parsed.is_err() {
    print("fq: failed to parse JSON: ")
    println(parsed.unwrap_err().to_string())
    return 1
}
```

With `?` (when the enclosing function returns a compatible type):

```
const parsed = parse(stdin.reader())?
```

This pattern repeats across every fallible call in real code. It pays for itself instantly.

The user-extensibility piece matters because FLang's stated philosophy is "every operator desugars to a function call." Hard-coding `?` for `Option`/`Result` only would be the only operator in the language without a user-extension hook.

## Design

### `TryResult` — the desugar target

A two-variant built-in enum the compiler recognizes:

```
pub type TryResult = enum(T, R) {
    Continue(T),
    Return(R),
}
```

`T` is the value to keep when not short-circuiting. `R` is the value to propagate via early `return`.

### `op_try` signature shape

```
fn op_try(self: Self) TryResult(T, R)
```

`Self`, `T`, and `R` are determined by the implementing type. For `Option(T)`:

```
fn op_try(self: Option(T)) TryResult(T, Option(?)) {
    self match {
        Some(v) => { TryResult.Continue(v) }
        None => { TryResult.Return(None) }
    }
}
```

For `Result(T, E)`:

```
fn op_try(self: Result(T, E)) TryResult(T, Result(?, E)) {
    self match {
        Ok(v) => { TryResult.Continue(v) }
        Err(e) => { TryResult.Return(Err(e)) }
    }
}
```

### Desugar

`let x = expr?` becomes:

```
let __t = op_try(expr) match {
    Continue(v) => { v }
    Return(r) => { return r }
}
let x = __t
```

The `return r` is the only piece the compiler emits unconditionally — everything else is a regular function call and a regular match.

### Constraint on enclosing function's return type

`op_try`'s `Return` type must be assignable to the enclosing function's declared return type. If `op_try` returns `TryResult(T, Option(?))`, the function must return `Option(?)` for compatible `?`.

No automatic `From`-style coercion across error types (Rust's approach). If the user wants to convert error types, they do it explicitly inside the body or via a wrapping `op_try` impl on a custom error type. Keeps the rule simple: `?`'s `Return` type unifies with the function's return type, period.

### Optimization

The straightforward desugar produces a `TryResult` allocation followed by a match. Both the `Continue` and `Return` paths are short. A targeted optimization pass should:

1. Inline `op_try` for known stdlib types (`Option`, `Result`).
2. Collapse the `TryResult` wrapper when the result is consumed inline by the `?` desugar — no actual `TryResult` value is materialized; the match becomes a direct branch on the source value's discriminant.

After optimization, `expr?` on `Option(T)` produces code equivalent to:

```
if expr.is_none() { return None }
let __t = expr.unwrap()
```

Identical to a hand-coded check.

### Lexer / parser interaction with `?.`

- `?.` remains a single token (single-symbol per Q18: lifts and flattens for `Option(T)`).
- `?` standalone is the new `op_try` operator.
- `expr?.field` lexes as `?.` (safe access). Always.
- `(expr?).field` is the explicit form for "early-return then access."
- `expr? .field` (with whitespace) — under the rule "lexer is whitespace-insensitive," this is `expr` followed by `?.`, which is also safe access. To get early-return-then-access, the parens form is required.
- `expr?` standalone (followed by anything that isn't `.`) is `op_try`.

### Precedence

`?` is postfix at high precedence — same level as `as` (top of binary table) and method calls. Binds tighter than every binary operator. `a + b?` parses as `a + (b?)`.

## Rejected variants

- **Hard-coded `?` for Option/Result only.** Considered. Rejected: violates FLang's "operators are functions" philosophy. User types can't tap in.
- **Restrict `?` to call expressions only (`foo()?`).** Considered. Rejected: fussy, saves nothing real.
- **Drop `?` entirely.** Considered. Rejected: too high-traffic an idiom to leave on the floor.

## Migration

No migration — this is a new feature. Existing manual `match`/`if is_err` code keeps working; users can opt in incrementally.

## Implementation phases

1. Add `TryResult` to stdlib (auto-imported).
2. Implement `op_try` for `Option` and `Result` in stdlib (depends on RFC-007 landing first).
3. Parser: recognize postfix `?` at high precedence; distinguish from `?.`.
4. Type checker: resolve `op_try` overload on the operand's type; check `Return` type against enclosing function's return type.
5. Lowering: emit the desugar (TryResult match + early return).
6. Optimization pass: inline `op_try` for known types and collapse the `TryResult` wrapper.
7. Diagnostics:
   - E20XX: `?` in a function whose return type is incompatible with `op_try`'s `Return`.
   - E20XX: `?` on a type that doesn't implement `op_try`.
   - E20XX: `?` outside a function (e.g., at module top level).

## Open questions

1. **Where does `TryResult` live?** Probably `core.try` or directly in the prelude. Auto-imported either way.
2. **Bare `expr?` as a statement.** `parse(input)?` with no binding — drops the value, just runs the early-return. Allowed? Recommendation: yes; common idiom for "I don't care about the value, just propagate the error."
3. **`?` inside a closure.** Lambdas can't capture, but they have their own return. Does `?` inside a lambda body return from the lambda or from the enclosing function? Recommendation: from the lambda. Same as `return` inside a lambda. Document explicitly.
4. **`?` inside `defer`.** Defer runs at scope exit; using `?` inside a deferred expression would early-return from... what? Recommendation: forbid `?` inside defer bodies. Diagnostic clear about why.
