# ADR-0005: Remove the implicit `T` -> `T?` coercion

**Status:** Accepted — 2026-08-18. Supersedes [ADR-0002](0002-optional-wrapping-as-directional-coercion.md).
**Affects:** `docs/spec.md` §2.7; both type checkers; `stdlib/`, `tests/harness/`, `examples/`, `tools/`, the self-host compiler sources

## Context

ADR-0002 kept the implicit wrap as a directional coercion at known-expected-type
positions, arguing consistency with FLang's other coercions. Living with that
decision showed the wrap is not like the other coercions: it cannot be applied
at one place in the unifier. It has to happen *during* unification — `bool` in
one match arm and `null` in another only meet if the Option payload is chosen
while the two are being unified — so every new piece of type logic had to
independently know about it:

- The C# checker needed `PreBindOptionTypeVar` at three join sites plus a
  symmetric `UnifyJoin` mode.
- The self-hosted checker re-grew the same shape (`prebind_option_payload`,
  a payload special case in `unify_expected`, an unbound-payload guard in the
  engine's coercion ladder).
- A `UnifyInternal` branch for constrained literals silently bypassed the
  `[lang].implicit_option_wrap` migration flag the same day it was added.

Each site is a place the feature can be forgotten, and the failure mode is
silence — a program that compiles under one checker and not the other, or a
flag that under-reports its own migration worklist. Three stdlib failures in
one session (`core/range.f`, `std/dict.f`, `std/allocator.f`) traced to the
unbound-payload guard interacting with generic returns, each surfacing as an
unrelated-looking `E2071` occurs-check error.

## Decision

Remove the coercion entirely. A present value is always wrapped explicitly:

- `return Some(v)` against `T?`; `Some(v)` for arguments, annotated bindings,
  struct fields, and match arms / if-else branches that join a `null` arm.
- `null` / `None` -> `T?` stays implicit — the literal has no other type.
- The `[lang].implicit_option_wrap` flag is removed with the feature (the
  `[lang]` manifest section went with it; it had no other knob).
- Sugar that *constructs* the wrap on the user's behalf spells it out: the
  string-interpolation desugar wraps an `&alloc` builder argument in
  `Some(...)` itself.

## Consequences

- One unification mode fewer in both checkers; no pre-binding, no payload
  special cases, no rule-registered-or-not state to consult.
- `Some(ptr)` for a niche-optimized `Option(&T)` is now written in source, so
  lowering recognizes it as variant construction (a retype, not an enum build)
  — previously unreachable syntax for the niche form.
- The stdlib's `#enum_utils` template generates `Some(...)` in `from_string`.
- Migration was mechanical and total: ~800 sites across stdlib, the self-host
  compiler, harness tests, examples, and tools; the compiler with the rule
  removed is the worklist.
- ADR-0002's ergonomic argument (stdlib leaned on `return x`) is retired by
  doing the migration once, everywhere.
