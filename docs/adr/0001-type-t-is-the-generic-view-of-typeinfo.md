# ADR-0001: `Type(T)` is the generic view of `TypeInfo`; erasure is implicit

**Status:** Proposed — 2026-06-21 (awaiting confirmation of the model below)
**Affects:** `docs/spec.md` Sec 2.9; `stdlib/core/rtti.f`; the self-host typer port

## Context

FLang reflection is two faces of one type, mirroring Java's `Class<T>` /
`Class` (and C#'s reflection split):

- **`TypeInfo`** is the raw runtime metadata struct — name, size, align, kind,
  fields, params. This is the value that actually exists at runtime.
- **`Type(T)`** is that same value with a phantom type parameter. It exists only
  at compile time, as a signature device: `fn new(ty: Type($T)) &T` says "this
  argument is a type; bind it to `T`," which is what lets the body return `&T`
  and lets `size_of` / `align_of` / `type_of` recover the metadata.
  Representationally `Type(T)` *is* a `TypeInfo`; the phantom `T` is carried for
  `$T` inference only and cannot be collapsed away.

So `Type(T) -> TypeInfo` is **phantom erasure** — forgetting `T`, exactly like
`Class<T> -> Class`. It is implicit and principled, not a disguised intrinsic.
(This corrects an earlier framing of this ADR that treated the coercion as the
problem.)

What *is* a wart is how the checker implements the relationship: a hard-coded
field-access redirect (`nominal.Name == "core.rtti.Type"` resolves fields
against `TypeInfo`) plus a standalone coercion rule. That one-off makes the
relationship invisible and is part of what the self-host port chokes on (the
`Type(T)`->`TypeInfo` mismatch, and the `size_of(ArenaPage)` / `align_of(u8)`
type-argument failures).

## Decision

Model the generic/raw relationship in the type system instead of special-casing
it.

- **`Type(T)` is a phantom-parameterized view of `TypeInfo`** — same
  representation, `T` carried only at compile time for `$T` binding. Keep both:
  `Type(T)` for signatures and for carrying a type as a value
  (`allocator.new(Type(T))`); `TypeInfo` as the raw runtime struct.
- **`Type(T) -> TypeInfo` stays implicit**, modeled as erasure of the known
  phantom (cf. `Class<T> -> Class`), so `type_of(t) TypeInfo { return t }` stays
  clean. It is not a bespoke coercion entry.
- **Remove the hard-coded `core.rtti.Type` field-access special-case.** Field
  access on a `Type(T)` resolves against `TypeInfo` because it *is* a
  `TypeInfo` — this follows from the view relationship, not a name check.
- **Materialization is a compile-time lookup.** A type name in value position
  (`size_of(i32)`, `Type(T)`) lowers to a reference to a statically emitted
  `TypeInfo` descriptor for the monomorphized type — the "global type metadata
  table" the spec already posits, via the same lowering interception
  `project_info()` uses.
- **Descriptors are interned:** one per monomorphized type, deduplicated per
  binary. Reflection references `&TypeInfo` into that table, so pointer equality
  is type identity. (`type_of` returning `TypeInfo` by value is a convenience
  copy over the interned descriptor.)
- **Cyclic types** emit in two phases: reserve descriptor addresses, then
  populate the `&TypeInfo` fields.

## Consequences

- The relationship is expressed once, in the type system, instead of a checker
  name-check plus a coercion rule — fewer seams, and a far easier thing to port
  to the self-host compiler (erasure of a known phantom vs a hard-coded branch).
- `&TypeInfo` pointer identity gives O(1) type comparison and a stable map key.
- No new user-facing surface is required: implicit erasure plus field access
  already cover `type_of` / `size_of` / `align_of`. An explicit
  `type_info(t) &TypeInfo` accessor would be optional sugar for "give me the raw
  view," not a replacement for the coercion — deferred unless wanted.
- `docs/spec.md` Sec 2.9 and `stdlib/core/rtti.f` are updated when this lands;
  until then this ADR is the decision of record.

## Alternatives considered

- **Replace the coercion with a mandatory `type_info()` accessor** (this ADR's
  original direction). Rejected: the coercion is principled phantom erasure, not
  magic; forcing an explicit call fights the `Class<T>` / `Class` model the
  design is built on. The accessor can still exist as optional sugar.
- **Collapse `Type(T)` into `TypeInfo`.** Rejected: the phantom `T` is
  load-bearing for `$T` inference (`allocator.new(Type(T)) &T`); without it the
  signature device that makes reflection generic disappears.
