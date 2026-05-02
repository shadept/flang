# RFC-007: Option as Enum, `null` as `Option.None`

**Type:** Language semantics + stdlib migration
**Status:** Proposed
**Depends on:** None
**Blocks:** RFC-009 (`op_try`), RFC-010 (smart casting on Option, `?.` flattening generalization), Q20 (`is`/`matches!` shorthand)

## Summary

Convert `Option(T)` from its current struct representation to a proper enum. Define `null` as a polymorphic literal that desugars to `Option.None`, with `T` filled by inference. `null` is rejected on raw references — only `Option(T)` (including `&T?`) accepts it.

## Motivation

`Option` is currently defined as `struct(T) { has_value: bool, value: T }` ([spec.md:156](../spec.md:156)) — a leftover from when FLang did not yet support enums with payloads. Now that enums are first-class, the struct form is a misfit:

1. **Pattern matching is awkward.** Today `opt match { ... }` requires field-based predicates; with an enum, `opt match { Some(v) => { ... }, None => { ... } }` reads naturally.
2. **Constructing `None` requires a struct literal.** `Option { has_value = false, value = ??? }` — what `value` field to put? Today's solution involves zero-init defaults; an enum has no such issue.
3. **`null` semantics are unclear.** Today `null` exists but its type and desugar are unstated. As `Option.None` it has a precise meaning.
4. **Niche-optimized layout for `&T?` already works as if `Option` were an enum** ([spec.md:166-169](../spec.md:166)). The struct representation is fiction — the optimization treats it as a sum type internally.

## Design

### New `Option` definition

```
pub type Option = enum(T) {
    Some(T),
    None,
}
```

Replaces `pub type Option = struct(T) { has_value: bool, value: T }` in `std`.

### `null` as polymorphic literal

`null` is sugar for `Option.None`, with `T` filled by type inference from context. Same mechanism as untyped integer literals.

- `null` in expression position is treated as a placeholder of type `Option(?)`.
- Inference unifies `?` with the surrounding context's expected `T`.
- If context provides no constraint → error E20XX ("type of `null` cannot be inferred; add a type annotation").
- No default `T`. Unlike integer literals defaulting to `i32`, `null` has no sensible default.

### `null` is not a pointer value

- `&T` is non-null by type. `let p: &i32 = null` errors with E20XX ("`null` is `Option.None`; use `&T?` for a nullable reference").
- `&T?` is `Option(&T)`. The niche optimization (a 0 pointer encodes `None`) is unchanged — same wire format, new spec wording.

### Methods preserved

`is_some()`, `is_none()`, `unwrap_or(fb)`, `expect(msg)`, `map(f)` keep working. They become methods on the enum rather than the struct. `Some` and `None` are the canonical constructors.

### Niche optimization scope

- `Option(&T)`: 0-pointer encodes `None`. Unchanged.
- `Option(BareEnum)` (planned, [spec.md:171](../spec.md:171)): becomes a special case of "niche-optimize an enum-of-enum with spare discriminants." Spec wording updated; no implementation change required for this RFC.

## Migration

This is a sweeping change. Every file that touches `Option` is affected.

### Compiler

1. Replace `Option` definition in stdlib (`std/option.f` or wherever it lives).
2. Update layout logic: `Option(&T)` keeps the nullable-pointer niche; other `Option(T)` becomes a tagged enum with `Some` and `None` variants. Existing struct-layout code for Option goes away.
3. Update `null` parsing: produce a sentinel AST node representing "polymorphic None" and resolve via inference.
4. Update `?.` chaining ([spec.md:387](../spec.md:387)) to dispatch through `Some`/`None` variants instead of `has_value`/`value` fields.
5. Update `??` coalesce similarly.
6. Update interpolation of error messages that reference `has_value`.
7. Remove the special check for `has_value` writes ([HmAstLowering.cs:4567](../../src/FLang.Semantics/HmAstLowering.cs:4567), E3005). The field no longer exists; the check is dead code after migration.

### Stdlib

1. Rewrite `Option` methods to use enum dispatch (`match self { Some(v) => ..., None => ... }`).
2. Audit every `pub` function returning `Option(T)` — call sites that construct `Option { has_value = true, value = v }` become `Some(v)`; `Option { has_value = false, value = ... }` becomes `None`.
3. Iterator protocol ([spec.md:447](../spec.md:447)): `next()` returns `Element?` — already abstract over Option's representation, no change at the protocol level. Implementations may need rewrites.

### Examples

Every example using `Option` (`fq`, `playground`, others) needs sweep:
- `opt.is_some()` / `opt.is_none()` keep working.
- `opt.value` (direct field access) is invalid — must use `match`, `unwrap()`, or `?.`.
- `Option { has_value = true, value = v }` literal forms (none observed in current examples) become `Some(v)`.

### Spec docs

- §2.7 rewritten around the enum definition.
- §2.5 (enums) cross-references Option as the canonical Option-shaped enum.
- Niche-layout paragraph (§2.7) keeps the `&T` case; restate the bare-enum niche as a future "discriminant-shift" optimization on `Option(E)` where `E` is a bare enum.

## Open questions

1. **`Option` location.** Currently part of `std` and presumably auto-imported via prelude (since `T?` sugar must always work). Confirm the auto-import setup survives the rewrite.
2. **Iterator's `Element?`.** When `Option` becomes an enum, `next()` returning `Element?` is `Element` wrapped in the new enum form. Confirm lowering treats it the same way.
3. **Error message phrasing.** "`null` is `Option.None`" is precise; users may prefer "for nullable references use `&T?`" depending on the surface message.

## Implementation phases

1. Land `Option` enum definition behind a flag; old struct definition still active.
2. Migrate stdlib internals to use the enum form.
3. Migrate examples.
4. Flip the flag; remove the struct definition.
5. Remove dead code (E3005 check, struct-specific Option layout paths).

## Out of scope

- `op_try` early-return — RFC-009. Lands after this RFC because its desugar relies on `Some`/`None` variants.
- `?.` chaining generalization — RFC-010. Lands after this RFC.
- `is`/`matches!` shorthand — parked separately; revisit after this lands.
