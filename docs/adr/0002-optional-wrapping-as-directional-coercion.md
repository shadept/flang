# ADR-0002: `T` -> `T?` is a directional coercion, not a unification rule

**Status:** Accepted — 2026-06-21
**Affects:** `docs/spec.md` Sec 2.7 (Option and Nullability); the self-host typer port

## Context

FLang implicitly wraps a present value into an optional: a `T` is accepted
where `T?` is expected (`fn find(...) T? { ...; return x }`). The reference
compiler implements this as a *directional* coercion (`OptionWrappingCoercionRule`)
that fires only when the target type is already a concrete `Option(C)`, applied
at sites where the expected type is known. It is, notably, **undocumented** in
the spec today.

The self-host port reached the same behavior the wrong way: by handing
`unify(T, Option(T))` to the inference engine. That makes the occurs check fire
(`variable ?X occurs inside Option(?X)`), producing a confusing diagnostic and
several spurious self-host errors (`slice.f`, `owned.f`, `rtti.f`). The error is
the type checker correctly rejecting a unification the wrapping logic should
never have asked for. It indicts *where* the wrap is applied, not the feature.

Removing the feature was considered and rejected: FLang already leans on
implicit coercions (integer widening, array -> slice, anon-struct -> named,
`String` -> `u8[]`), and the stdlib lives on `return x` into a `T?`. Singling
out optional wrapping for removal would be inconsistent and a large ergonomic
regression.

## Decision

`T` -> `T?` stays, but only as a **directional coercion at known-expected-type
positions**, never as a unification rule.

- **Fires only where the expected type is known** to be a concrete `Option(C)`:
  return value vs declared return type; annotated `let` / `const`; struct field
  init vs declared field type; argument vs declared parameter type.
- **Never inside `unify`,** and **never when the target is an unbound inference
  variable.** There is no "wrap into `Option(?unknown)`." This is the rule that
  removes the occurs-check class of errors.
- **One level only.** `T` -> `T?`. Producing a second level from a `T` (i.e.
  `T??`) requires an explicit `Some`. `T??` is a legal, distinct type — it is
  **not** flattened to `T?` — and `??` / `?.` operate one level at a time.
- **`null` / `None` -> `T?` is unchanged** (already in Sec 2.7): unambiguous,
  the literal has no other type.
- **Overload resolution prefers the no-coercion candidate** (existing
  coercion-cost ranking), so a `T` argument binds `f(T)` over `f(T?)`.

## Consequences

- Eliminates the `?X occurs inside Option(?X)` error class in the self-host run
  and preserves principal types (an expression's type no longer depends on an
  unknown target).
- Stdlib ergonomics are unchanged: `return x` into a `T?` still works.
- Predictable surface: the wrap happens only where the destination type is
  already pinned, so it is always locally explainable.
- **Implication for the self-host typer:** optional wrapping must be implemented
  as a coercion applied at expected-type sites, which requires threading the
  expected type to those sites (a coercion step), not a `unify` special-case.
  This is the shape the port should take for every coercion, not just this one.
- `T??` being distinct (not flattened) means nested optionals are
  representable (e.g. "present but null"); the spec must state that the implicit
  wrap and the `??` / `?.` operators are single-level.
- `docs/spec.md` Sec 2.7 gains an explicit bullet for the directional coercion
  and the no-inference-variable rule when this lands.

## Alternatives considered

- **Absence implicit, presence explicit** (`null` / `None` -> `T?` implicit,
  value `Some(x)` always explicit). Coherent and removes the hazard outright,
  but a real ergonomic tax (`return Some(found)` everywhere) and inconsistent
  with the stdlib's heavy `return x`. Revisit only if "minimize implicit
  coercions" becomes a stated language goal.
- **Remove optional coercion entirely** (Rust-style mandatory `Some(...)`).
  Rejected: inconsistent with FLang's coercion-heavy design.
- **Model `T <: T?` as subtyping.** Rejected: FLang inference is HM /
  unification, not subtyping. A directional coercion at expected-type sites buys
  the same ergonomics without introducing a subtyping lattice.
