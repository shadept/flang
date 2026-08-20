# 020 — `op_deref` argument coercion (deref chains at call sites)

Status: **accepted, scheduled** (2026-08-20) — implementation planned for
the next session. Supersedes the "deref-copy adaptation" sketch in
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

At an argument-unify failure, if the argument's type is settled, walk
its deref chain (`X → &Y1 → &Y2 → …`, bounded like field resolution):

1. **Borrow leg** — the parameter is `&Yk` for some chain step: insert
   the `op_deref` call(s). Zero copy. `List(Rc(Big))` elements flow
   into `fn(x: &Big)` callbacks for free; `Owned(F)` passes anywhere
   `&F` is expected.
2. **Value leg** — the parameter is `Yk` by value: insert the borrows,
   then copy through the final reference. Semantics identical to
   value-mode argument passing today (§3.2 implicit-ref copy-on-write).

Exact unification always wins; each deref hop costs in overload
scoring (mirror the receiver machinery's existing preference order).

**Direction is strictly one-way.** The chain only *peels*. `T → &T`
(auto-ref) is a separate, unrelated rule with its own
mutation-visibility question (019 §1) and is NOT part of this ticket.

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

## Sub-decisions to settle before/while implementing

1. **Owned values on the value leg.** Copying an owned value (e.g.
   `OwnedString`) *out of a smart pointer* via the value leg is a
   hidden shallow copy of shared storage — tension with the Rc design
   stance ("explicit `.clone()`, no hidden costs"). Recommended
   default: **the value leg applies only to the built-in `&T` base
   case** (which is today's semantics); copying through a *user*
   `op_deref` (Rc, Owned) stays explicit (`p.*` / `.clone()`). The
   borrow leg is unrestricted — borrowing is never a hidden cost.
2. **Scope phasing.**
   - Phase 1: sites with a single known callee signature — indirect
     calls through fn values, closure `op_call` dispatch, fn-typed
     struct fields, single-candidate direct calls. Covers the stdlib
     combinator story entirely; no overload-scoring changes.
   - Phase 2: full overload sets with per-hop cost — needs a corpus
     run (adaptable arguments can shift existing picks).
3. **`op_deref(&OwnedString) &String` layout spike** — the
   `&String → &str`-style ergonomic win (pass `OwnedString` wherever a
   `String` view is expected, no `.as_view()`). `op_deref` must return
   a reference to a real `String`, so OwnedString needs either a
   layout-compatible view prefix or a stored view field. Spike before
   promising it.
4. **Diagnostics.** When a call fails AND a deref chain would have
   matched a rejected leg (e.g. value leg through a user wrapper under
   the recommended restriction), say so: "found `Rc(Big)`, parameter
   takes `Big` by value — dereference explicitly with `.*`".

## Implementation notes (both compilers)

- **Checker:** on arg-unify failure, resolve the arg type, walk
  registered `op_deref` overloads (the receiver path's lookup,
  refactored to be position-agnostic). Record a per-argument adaptation
  list on the call node — new side table entry following the
  `ResolvedOperator.is_ref_form` precedent; overlay-scoped in the
  self-hosted checker so `$F` instantiations adapt per-instantiation.
- **Lowering:** inserted user `op_deref`s are ordinary direct calls
  (their symbols exist); the built-in `&T` base case is a scalar load
  or aggregate identity (aggregates already travel as addresses, so
  most hops are free at the FIR level).
- **Self-hosted:** extend `deref_retry`'s chain walk to argument loops
  in `indirect_call` / closure dispatch / `field_call`; adaptation
  records go in `InferenceResults` next to `lambdas`.
- Estimated ~1.5–2 days per compiler including tests (Phase 1).

## Test plan

- Harness: `Rc(T)` element → `fn(&T)` callback (borrow leg, zero
  copy); chain of two wrappers; `&T → T` value leg (base case);
  rejection + diagnostic for the restricted value leg through a user
  wrapper; exact-match-beats-deref overload test (Phase 2).
- Stdlib: a `List(Rc(Big))` combinator round-trip test.
- Self-hosted: mirrored lower.f tests + a bootstrap e2e program.
