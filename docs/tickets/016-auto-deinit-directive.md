# RFC-016: `#auto_deinit` directive and the managed-lifecycle contract

**Type:** Language feature (declarative; auto-defer behavior deferred to a follow-up)
**Status:** Draft
**Depends on:** RFC-012 (Owned transfer tracking) — background only; not load-bearing

## Summary

Introduce `#auto_deinit`, a type-level directive that marks a struct as a candidate for compiler-inserted scope-end cleanup. This RFC defines **only** the directive, its contract, and the initial set of stdlib types that adopt it.

The compiler behavior that actually inserts `defer x.deinit()` at `let` sites is a separate follow-up. Sequencing the pieces separately keeps each one reviewable in isolation: types that satisfy the contract can be marked today; the auto-defer mechanism builds on top of a stable, declarative foundation.

## Motivation

FLang is C-style by default: the developer controls allocation, transfer, and cleanup. Manual `defer x.deinit()` works, but with `Rc(T)` / `Arc(T)` it adds no information — it always means "decrement at scope end" — and forgetting it leaks. The cost is paid at every binding.

The end goal is opt-in, type-level auto-cleanup: a type marks itself, the compiler emits the `defer` for every binding. From that primitive, higher-level constructs follow (user-space cycle collectors, lifetime-tied resource handles, source-generated tracers).

Reaching the goal needs three pieces in sequence:

1. **A contract** for what it means for a type to be safely auto-cleaned. *(this RFC)*
2. **Stdlib types compliant with the contract**, so step 3 has something to operate on. *(this RFC: `Rc`, `Arc`)*
3. **Compiler insertion** of `defer x.deinit()` at the `let` site. *(follow-up RFC)*

This RFC delivers (1) and (2). It is intentionally narrow: no codegen change, no auto-defer, no NRVO. The directive is purely declarative — a marker the compiler can read later.

## Why not call it `#managed`?

Considered and rejected. In C++ and C#, "managed" already means GC-tracked memory. FLang's eventual goal *is* user-space GC, but it gets there by composing primitives: idempotent cleanup, scope-bound defer, refcounted handles, source-generated tracers. Each primitive is independently usable and independently checkable. `#auto_deinit` names what the directive does (auto-fire deinit at scope end), not what the type accomplishes (which varies by use case).

## Design

### The directive

`#auto_deinit` is a type-level directive placed above a `struct` declaration:

```
#auto_deinit
pub type Rc = struct(T) {
    __inner: &RcInner(T)?
    __allocator: &Allocator?
}
```

Placement matches `#deprecated` (detached, above the declaration) rather than `#foreign` / `#simd` (inline after `=`), because it describes lifecycle semantics, not memory layout.

In this RFC the directive has **no compiler-emitted behavior**. It is parsed, recorded in the symbol table, and otherwise inert. The follow-up RFC consumes the marker.

### The three invariants

A type marked `#auto_deinit` must satisfy this contract. The compiler does not fully verify it — invariants are documented per-type and tested.

**1. Idempotent.** `deinit(&self)` on a value that has already been deinit'd is a no-op. No panic, no double-free, no observable side effects beyond a fast early-return.

Mechanism: the type carries a sentinel field (e.g., `__inner: &RcInner(T)?`); `deinit` checks the sentinel and returns early if disarmed, then transitions the sentinel to disarmed before returning.

**2. Zero-is-deinit'd.** The all-bits-zero pattern of `T` must satisfy invariant 1 — calling `deinit` on a zero-initialized `T` is a no-op.

This unlocks future `mem.forget` semantics by zero-poking the bits, without each type writing a custom disarm path. For `Rc`/`Arc`: all-zero gives `__inner = null` (Option niche), which already early-returns.

**3. Alias-safe.** Two values aliasing the same backing state must not silently corrupt under multiple `deinit`s. They must panic.

For `Rc`/`Arc`: aliased handles (created by structural copy without `.clone()`) decrement the same `RcInner.ref_count`; the type detects underflow and panics. For other managed types added later: analogous check at the choke point.

### `deinit` stays the single cleanup name

`#auto_deinit` does not introduce a new function name. Cleanup remains `deinit(self: &T)` — the same name used throughout the stdlib, with the universal no-op fallback in `stdlib/core/deinit.f`. Consequences:

- Generic containers (`List(T)`, `Dict(K, V)`) iterate `elem.deinit()` and the call resolves correctly whether `T` is `#auto_deinit` or not. No fallback indirection, no naming split.
- The directive carries the *auto-fire* semantics; the function carries the cleanup *logic*. Orthogonal.

A type with `#auto_deinit` must have a `pub fn deinit(self: &T)` resolvable in its module's visibility. Compile error otherwise.

### What is enforced now vs deferred

**Enforced in this RFC**:
- Parser recognizes `#auto_deinit` on `struct` type declarations.
- Symbol table records the marker for the type.
- Compile error if the marked type has no `pub fn deinit(self: &T)` in scope.

**Not enforced (contractual, tested per type)**:
- The three invariants.

**Deferred to follow-up RFC**:
- Auto-insert `defer x.deinit()` at `let` sites of `#auto_deinit`-typed bindings.
- Reassignment emits eager `deinit` on the old value before overwrite.
- `return r` (bare identifier of an `#auto_deinit` binding) suppresses the inserted defer — move-on-return.

## Stdlib changes

Two types adopt `#auto_deinit` in this RFC:

### `Rc(T)` (`stdlib/std/rc.f`)

1. Add `#auto_deinit` above the type declaration.
2. Add refcount underflow panic to satisfy invariant 3:

   ```
   pub fn deinit(self: &Rc($T)) {
       let inner = self.__inner match {
           Some(p) => p,
           None => return                      // invariant 1
       }
       if inner.ref_count == 0 {
           panic("Rc.deinit: refcount underflow — aliased without clone")
       }                                       // invariant 3
       inner.ref_count = inner.ref_count - 1
       if inner.ref_count == 0 {
           let val_ptr: &T = (inner as &u8 + size_of(usize)) as &T
           val_ptr.deinit()
           self.__allocator.or_global().free(inner)
       }
       self.__inner = null
   }
   ```

3. Invariants 1 and 2 are already satisfied (`__inner: ...?` sentinel with early-return; zero pattern gives `null`).

### `Arc(T)` (same file)

Same shape. The underflow check uses the result of `__flang_atomic_sub` — if the pre-decrement value is `0`, panic. (Alternative: an atomic load before subtract; first option avoids the extra atomic op.)

### Types deliberately *not* marked

`Owned(T)`, `StringBuilder`, `List(T)`, `Dict(K, V)`, `OwnedString`. These use structural-copy single-owner semantics and would silently double-free under auto-defer (see RFC-012 §motivation and the survey in this RFC's design discussion). They keep manual `defer x.deinit()` and existing transfer patterns. They become candidates for `#auto_deinit` later, only after compiler-tracked transfer support is designed.

## Tests

Embedded in `stdlib/std/rc.f`:
- `test "rc deinit underflow panics"` — construct two Rc bit-aliases without clone, deinit both, expect panic on the second.
- `test "arc deinit underflow panics"` — same for `Arc`.

Under `tests/FLang.Tests/Harness/directives/`:
- `auto_deinit_parses.f` — directive parses on a type declaration; binary compiles.
- `auto_deinit_requires_deinit.f` — type with `#auto_deinit` but no `deinit` in scope is a compile error.

## Out of scope

- Compiler insertion of `defer x.deinit()` — separate RFC.
- NRVO / move-on-return.
- Reassignment-emits-deinit.
- `mem.forget` sugar.
- `Owned(T)` migration to `#auto_deinit`.
- Per-field auto-deinit (managed fields inside a non-managed struct).
- Cycle collection / tracing GC.

## Open questions

1. **Error code** for "type marked `#auto_deinit` has no `deinit(&T)`" — new entry in `docs/error-codes.md`. Assign next available `E2NNN`.
2. **Documentation home in `docs/spec.md`** — new `§4.4 Managed lifecycle` under "Memory Model", or `§3.7` under "Value Semantics"? The contract is about lifecycle, not allocator interaction → leaning §3.7, but §4.3 (Rc/Arc) is the natural cross-reference, which argues for §4.4.
3. **Should the directive accept arguments** (e.g., `#auto_deinit(idempotent, zero_safe, alias_safe)` as machine-checked promises)? Recommend no — simpler now, extensible later.
4. **`Owned(T)` future**: it satisfies all three invariants structurally. Mark it now (and accept that step-3 auto-defer will fire on it), or hold until the auto-defer RFC lands and the implication is concrete? Recommend hold.
