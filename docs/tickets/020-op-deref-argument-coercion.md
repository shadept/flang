---
status: implemented
type: language
created: 2026-08-20
implemented: 2026-08-23
---

# 020 — `op_deref` argument coercion (deref chains at call sites)

Status: **accepted** (2026-08-20), rule pinned 2026-09-06 to the borrow leg
only - see "The rule". Supersedes the "deref-copy adaptation" sketch in
ticket 019 §1 as the mechanism of record.

## Summary

Generalize the existing `op_deref` chain — already used for field
access, UFCS receiver resolution (`TryUfcsOpDerefCall` /
`deref_retry`), and `op_call` dispatch — to **argument positions**.
This is Rust-style deref coercion: opt-in per type, one semantic family
("this wraps a T"), per-hop overload cost. Not C++'s open-ended
conversion operators.

`&T` becomes the degenerate base case: spec-wise, a reference has the
built-in primitive `op_deref`, so the rule needs no special-casing and
the spec gets simpler, not bigger.

## The rule

`op_deref` turns a reference into another reference, and that is all it
does. At an argument-unify failure, if the argument's type is settled and
is a reference `&X`, walk `X`'s deref chain (`&X → &Y1 → &Y2 → …`, bounded
like field resolution) and, when some `&Yk` is the parameter's type,
insert the `op_deref` call(s). Zero copy. `List(Rc(Big))` elements flow
into `fn(x: &Big)` callbacks for free; `Owned(F)` passes anywhere `&F` is
expected. Every reference-typed argument position, resolved left to right.

Exact unification always wins; each deref hop costs in overload scoring
(mirror the receiver machinery's existing preference order).

**Both directions across the reference boundary stay closed:**

- No value leg. A `&Yk` never satisfies a parameter that takes `Yk` by
  value; the caller spells the copy (`p.*`). The first draft of this ticket
  allowed it, restricted to the built-in `&T → T` case - dropped: it is an
  implicit copy, a hidden shallow copy of shared storage out of a smart
  pointer, and under RFC-028 a copy the compiler would have to invent a
  `move` for. This is exactly how implicit conversions get in.
- No auto-ref. `f(x, y)` where `f` wants `&x` is an error. The one place
  the compiler adds a reference is the UFCS sugar: `x.f(y)` is `f(x, y)`,
  else `f(&x, y)` (spec §7.2). With the borrow leg in argument position
  those two spellings resolve identically, which restores `x.f(y) ≡ f(x, y)`
  for wrappers - today `w.value_of()` resolves through `op_deref` and
  `value_of(&w)` is E2011.

## `op_ref` — considered and rejected

A user-overloadable "referencing" operator (the reverse direction) is
rejected outright:

- It manufactures aliasing/mutation channels invisibly at call sites —
  the reader of `f(x)` can no longer tell whether `x` escapes by
  reference. Deref coercion has no such problem: peeling a wrapper
  never grants access the caller didn't already hand over.
- The reverse direction cannot chain meaningfully (which wrapper would
  it build? with whose allocator?), so it degenerates into arbitrary
  implicit conversion — exactly the C++ `operator&`/conversion-operator
  swamp the Rc design already declined once ("no assignment operator
  overloading, learning from C++").
- If a built-in auto-ref rule is ever wanted (019 §1), it will be a
  compiler rule for places, never a user hook.

## Sub-decisions

1. **One phase, corpus-gated.** The rule is universal (every reference
   argument, every call), so the mechanism lands as one change with a
   full-tree build, the harness and the stage-3 fixpoint as the gate:
   adaptable arguments can shift existing overload picks, and the fixpoint
   is what catches a silent shift in the compiler itself.
2. **`op_deref(&OwnedString) &String` layout spike** — the
   `&String → &str`-style ergonomic win (pass `OwnedString` wherever a
   `String` view is expected, no `.as_view()`). `op_deref` must return
   a reference to a real `String`, so OwnedString needs either a
   layout-compatible view prefix or a stored view field. Spike before
   promising it.
3. **Diagnostics.** When a call fails AND a hop would have reached the
   parameter's type by value, say so: "found `&Rc(Big)`, parameter takes
   `Big` by value — dereference explicitly with `.*`".

## Implementation notes

- **Checker:** on arg-unify failure with a reference-typed argument,
  walk `op_deref` overloads the way `member_deref_retry_at` does (already
  position-agnostic: it records a chain on any span). Record a
  per-argument adaptation list on the call node, overlay-scoped so `$F`
  instantiations adapt per instantiation.
- **Lowering:** inserted `op_deref`s are ordinary direct calls;
  `follow_deref_hops` (lower.f) already runs a recorded chain from a
  wrapper's address, and `deref_hop_base` already loads a reference
  receiver down to that address. Argument adaptation is the same two
  steps on the argument operand.

## Test plan

- Harness: `Rc(T)` element → `fn(&T)` callback (zero copy); chain of
  two wrappers; the free-call spelling `value_of(&w)` and a second-argument
  position both resolving; `weigh(&shared)` against a by-value parameter
  rejected with the diagnostic; `f(x)` against `f(&x)` rejected;
  exact-match-beats-deref overload test.
- Stdlib: a `List(Rc(Big))` combinator round-trip test.
- lower.f: a colocated test that the adaptation calls the hop on the argument, not on its slot.
