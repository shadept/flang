# ADR-0001: `Type(T)` is the generic view of `TypeInfo`; erasure is implicit

**Status:** Accepted — 2026-06-21; implemented 2026-09-12 (static interned descriptors, `type_info(t) &TypeInfo`)
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
- Implicit erasure plus field access cover `Type(T)` parameters, `size_of` /
  `align_of`. `type_info(t: Type($T)) &TypeInfo` and `type_of(v: $T) &TypeInfo`
  exist beside them (2026-09-12): the address of the interned descriptor, so
  `type_of(x) == type_info(u32)` is type identity. `type_info` is intercepted at
  lowering like `size_of`; its stdlib body is a placeholder.
- Descriptors are `static_typeinfo` in `flang_driver/lower.f`: one data-segment
  global per type, memoized before its members are built so a self-citing type
  resolves to the entry under construction; the C backend declares every
  relocated global ahead of the definitions for that reason.
- `docs/spec.md` Sec 2.9 and `stdlib/core/rtti.f` reflect this.

## Alternatives considered

- **Replace the coercion with a mandatory `type_info()` accessor** (this ADR's
  original direction). Rejected: the coercion is principled phantom erasure, not
  magic; forcing an explicit call fights the `Class<T>` / `Class` model the
  design is built on. The accessor can still exist as optional sugar.
- **Collapse `Type(T)` into `TypeInfo`.** Rejected: the phantom `T` is
  load-bearing for `$T` inference (`allocator.new(Type(T)) &T`); without it the
  signature device that makes reflection generic disappears.
