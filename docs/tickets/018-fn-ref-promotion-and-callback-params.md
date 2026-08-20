# 018 — `fn(T)` → `fn(&T)` promotion, and `&T` callback parameters in the stdlib

Status: **resolved by redesign** (2026-08-20). The session that took this
up landed a different — better — shape; the surviving open threads moved
to docs/tickets/019.

## Outcome

Neither the promotion rule nor the `&T` signature sweep shipped, on
purpose:

1. **Stdlib combinators went duck-typed instead** (`f: $F`), the C++
   template convention. That dissolved both halves of this ticket:
   capturing closures (which can never fill a concrete `fn` slot, E2111)
   compose with every combinator, and the copy-vs-ref choice moved to
   the *callback author's* parameter list instead of the library
   signature. See spec §7.3 "Stdlib callback convention".
2. **The promotion thunk was dropped** — with `$F` slots there is no
   concrete target type to promote into; instantiation-time unification
   does the adapting for value-mode callables.
3. **`&T` callbacks turned out to chase a phantom cost**: spec §3.2's
   implicit-reference copy-on-write ABI already passes every argument by
   address and copies only on first write, so value-mode `fn(T)`
   predicates never copy. References stay what they were — mutability
   intent, not efficiency.

## What moved to 019

- Argument adaptation (auto-ref vs deref-copy) — the one rule that would
  let a single combinator body accept both `fn(T)` and `fn(&T)` shapes.
- Overloaded names as first-class values (`.map(deinit)`) via
  instantiation-time resolution.
- Generic constraints, higher-kinded type params, iterator `flat_map`,
  template-eager-check limits.
