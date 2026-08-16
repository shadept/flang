# ADR 0003 — Place expressions are a distinct lowering mode

**Status:** Accepted
**Date:** 2026-08-16
**Affects:** `docs/spec.md` §3.4.1; `src/FLang.Semantics/HmAstLowering.cs`; `lib/flang_driver/src/lower.f`

## Context

FLang has always had lvalues in practice — assignment targets, `&x`, `&self`
receivers — but never defined them. The C# lowering grew a `LowerLValue`
alongside `LowerExpression`, and callers picked between them case by case. The
choice was never stated as a rule, so it was made inconsistently, and the
inconsistency was invisible: lowering a place as a value compiles cleanly and
emits working code for the shallow cases everyone writes.

An audit of `HmAstLowering` (5324 lines, 11 GEP sites, 5 `LowerLValue` calls)
found the same defect at four independent sites, each written separately, each
correct at depth one and wrong at depth two:

| Site | Symptom |
|---|---|
| UFCS receiver | `outer.mid.c.incr()` mutates a temporary; write lost |
| `&base.field` | `&outer.mid.inner` returns a pointer into dead stack |
| `LowerLValue` index base | `outer.h.arr[0] = 1` store discarded |
| `&base[i]` | same shape as above |

Three were confirmed by running programs; all produced no diagnostic. Notably
the third was inside `LowerLValue` itself — the helper meant to be the correct
path had the bug it exists to prevent. That is the signature of a missing
specification rather than a coding mistake: four authors independently reached
for `LowerExpression` on a base, because nothing said not to.

The bug survived because depth one is the common case and works by accident:
for `self.field`, the base `self` is an identifier already held as a pointer,
so lowering it "as a value" happens to yield an address. Only at depth two does
the intermediate get spilled to an alloca and copied.

## Decision

**Place expressions are a first-class concept in the language specification,
and place lowering is a separate entry point from value lowering in every
implementation.**

1. `docs/spec.md` §3.4.1 normatively defines the place forms, the place
   contexts, and the propagation rule: place-ness propagates leftward through a
   path, so a path in a place context is addressed end to end.

2. Each compiler exposes two lowering entry points with distinct contracts —
   value (`LowerExpression` / `lower_expr`) and place (`LowerLValue` /
   `lower_place`). A place context calling the value entry point is a defect by
   definition, reviewable without reasoning about whether it currently
   miscompiles.

3. Every place context obtains its base through **one shared helper**
   (`LowerBaseAddress` in C#), so the rule lives in a single place. Four
   independent implementations of the same rule was the actual failure.

4. Rvalue materialization — spilling to a stack slot to take an address — is
   permitted **only** for expressions that are not places (`&f()`). It is never
   a fallback for a place.

## Consequences

**Good.** The four bugs are fixed by construction rather than individually, and
`tests/harness/places/` pins the depth-2 behaviour of all three forms so they
cannot silently diverge again. New place contexts (compound assignment,
`op_index_ref`, pattern bindings that bind by reference) have a rule to follow
instead of a precedent to copy. Review has something to check against.

**Cost.** Two entry points must be kept in sync per compiler, and the self-hosted
lowering has to carry the same split even though most of its place forms are
still milestone-gated. That cost is accepted deliberately: the self-hosted
`lower_expr` currently stubs `Assignment`, `Index`, and `AddressOf` as
placeholders, so introducing `lower_place` **now**, before M3 and M5 build on
them, is far cheaper than the retrofit this ADR documents on the C# side. The
whole point is to not repeat the archaeology in the second implementation.

**Known sharp edge.** The recursion must stop at identifiers. `_locals` stores a
local's *slot address*, so the value path already yields the pointer, and
recursing further hands back one level too many (`&&T`). The first attempt at
the C# fix did exactly this and broke the depth-1 case plus the whole stdlib
with `Allocator**` vs `Allocator*` errors. `LowerBaseAddress` encodes the stop
condition; nothing else should re-derive it.

**Not addressed.** Two sites lower an index base as a value under a genuine
conditional — on whether the callee's first parameter is a pointer, and on
whether the base is already a reference type. Those discriminate correctly and
are left alone. They are noted here so a future audit does not re-flag them.
