---
status: implemented
type: language
created: 2026-10-18
implemented: 2026-10-18
relates: [RFC-007, RFC-009]
---

# RFC-040: `??` through `op_try`

## Summary

`a ?? b` is defined by the protocol `?` already uses, and its right side is a match-arm body, so
it can leave the function or the loop:

```
a ?? b           :=  op_try(a) match { Continue(v) => v, Return(_) => b }
a ?? return      :=  op_try(a) match { Continue(v) => v, Return(_) => return }
a ?? return b    :=  op_try(a) match { Continue(v) => v, Return(_) => return b }
a ?? break       :=  op_try(a) match { Continue(v) => v, Return(_) => break }
a ?? continue    :=  op_try(a) match { Continue(v) => v, Return(_) => continue }
a?               :=  op_try(a) match { Continue(v) => v, Return(r) => return r }
```

`?` keeps the residual and returns it; `??` releases it and evaluates `b` (the release is left
out above, see Ownership). Any type with an `op_try`
gets both: `Result` gains `r ?? 0` and `r ?? return`.

## Motivation

- **Early exit without a matching return type.** `?` needs the enclosing function to return the
  operand's family. A function returning `Ty` that looks up an `Option` writes
  `if x.is_none() { return TY_ERROR }` and then `x.unwrap()`. With this RFC:
  `let id = map.get(k) ?? return TY_ERROR`.
- **The same in loops.** `let v = it.get(k) ?? continue`.
- **`op_coalesce` cannot express `??`.** As a function, its fallback is evaluated before the
  call, which breaks the short-circuit rule (spec §5.1.1). A lazy fallback would need a lambda,
  and `return` inside a lambda is E1054. The compiler already ignores `op_coalesce`: `??` is built
  in and Option-only, and the two stdlib definitions are dead code that documents eager semantics.

## Design

### Forms

- **Unwrap form.** `a ?? b` where `op_try(a)` is `TryResult(T, R)` and `b: T`. The result is `T`.
  `b` is evaluated only on the `Return` path.
- **Chain form.** `a ?? b` where `a, b: Option(T)`. The result is `Option(T)`: `a` when present,
  else `b`. Option only; a `Result ?? Result` chain is a type error. Chains such as
  `function_named(..) ?? nominal_named(..) ?? local_named(..)` depend on it.
- **Diverging right side.** The right side parses as a match-arm body: `return [expr]`, `break`,
  `continue`, or an expression. `return`, `break` and `continue` there have type `never`, so the
  result is `T`. Each follows the rules it has as a statement in that position: `break` and
  `continue` need an enclosing loop (E1006 / E1007), and `return` inside a lambda is E1054.

### Parsing

- Precedence and associativity are unchanged (level 1, right-associative).
- `return` takes the rest of the expression: `a ?? return x + 1` returns `x + 1`;
  `a ?? return b ?? c` returns `b ?? c`.
- `break` and `continue` take nothing: `a ?? break + 1` is `(a ?? break) + 1`.

### Ownership

- **Option is read in place.** A kept result consumes `a`; a result only read (`(a ?? b).len`)
  leaves `a` live (spec §5, unchanged).
- **Every other `op_try` type consumes `a`**, as `a?` does: `a` flows into `op_try`'s `move self`.
  A result only read is read out of the temporary, and `a` is dead afterwards.
- **`??` owns the residual it drops.** On the `Return` path the residual is released
  (`release`, core.deinit) before `b` is evaluated, as a `for` loop releases its state on every
  exit (spec §7.4). The desugar is:

  ```
  op_try(a) match {
      Continue(v) => v
      Return(r) => {
          release(r)
          b
      }
  }
  ```

  A copyable residual releases to nothing. `parse(s) ?? return default` with an owned error frees
  the error; without the release it would leak or be E2132 (a discarded non-copyable temporary).
- **`b` is moved on one path only.** `a ?? move b` leaves `b` moved afterwards, as an `if` branch
  does.

### Errors

- A left side with no `op_try` is E2092, as for `?`: "`??` needs an Option, a Result, or a type
  with `op_try`". This replaces "left operand of `??` must be an Option".
- `op_try` not returning `TryResult(T, R)` is E2092, as for `?`.
- `b` not fitting `T` (or `Option(T)` in the chain form) is a type mismatch, as today.

### Lowering

- `a` is not an Option: call `op_try(a)`, branch on the tag, yield the `Continue` payload or
  lower `b`. The `?` lowering with the `Return` arm replaced.
- `a` is an Option: the inline tag (or null-pointer) test `??` uses today. It is observably the
  same as calling core's `op_try` for Option, keeps the niche form a pointer compare, and is the
  only path the chain form has.
- A residual type variable `??` leaves unsolved (`U` in `Result($U, E)`) unifies with the
  operand's type, so `TryResult` has a layout: `?` pins it with the function's return type, and
  `??` has nothing else. A residual unrelated to the operand is left as `op_try` declares it.

### Removed

`op_coalesce`: both definitions in `stdlib/std/option.f`, and its entry in the operator overloading
list (`docs/syntax.md`). `??` is not overloadable on its own; a type opts in through `op_try`.

## Implementation

1. Parser: the right side of `??` through `parse_arm_body`.
2. Projector: a statement right side wraps in a single-statement block, as a match-arm body does.
3. Checker: `check_coalesce` resolves `op_try` for a non-Option left side, unifies the residual
   with the operand's type, records the residual's `deinit` pick on the `??` token; E2092. The ownership pass treats the
   protocol path as `own_protocol`.
4. Lowering: `lower_coalesce` gains the `op_try` path, releasing the residual on the `Return`
   path; the Option path is unchanged.
5. Formatter: the statement right side.
6. Harness tests: `?? return`, `?? return v`, `?? break`, `?? continue`, Result unwrap,
   short-circuit, ownership of a kept result, a released owned error, E2092, E1006 / E1054
   positions.
7. Docs: spec §5 and §7, syntax operator list, `op_coalesce` removed from the stdlib.

## Decisions

- Option keeps its inline lowering: observably the same as core's `op_try`, a pointer compare for
  the niche form, and the only path the chain form has.
- An unsolved residual unifies with the operand's type. Binding it to `never` was the first
  choice (its copyability would be the error's alone), but a generic body instantiated with
  `never` leaves unbound every variable it meets (`never` unifies as the bottom without binding),
  and layout refuses them. The cost: a `Result(T, E)` residual with a non-copyable `T` is released
  through `Result`'s `deinit` although it holds an `Err`, which releases only the `E`.
- `??` releases the residual (above), rather than refusing a non-copyable one.

## Related

- `Result` gains `deinit` (releases whichever payload it holds, as `Option`'s does), so a
  non-copyable residual has one.

- `release` skips the `deinit` of a copyable type (`docs/known-issues.md`). `??` inherits it: a
  copyable error type with a `deinit` is not released.
