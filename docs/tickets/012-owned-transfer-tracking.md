# RFC-012: `Owned(T)` — transfer-aware cleanup helper

**Type:** Stdlib addition
**Status:** Implemented
**Depends on:** RFC-009 (op_try) — composes with `?` but doesn't require it

## Summary

Add `std.owned.Owned(T)`, a small stdlib type that wraps a value plus a cleanup
function and tracks whether ownership has been transferred. `defer
buf.deinit()` paired with `buf.transfer()` gives correct cleanup-on-error
semantics for code that builds resources fallibly and hands them off on
success.

## Motivation

A recurring pattern in code that uses `?`:

```
let buf = alloc(...)
let inner = build_inner(buf)?       // ? exit: buf leaks
let outer = build_outer(inner)?     // ? exit: buf leaks, inner may leak
return Ok(.{ buf = buf, inner = inner, outer = outer })
```

Manual fix:

```
let buf = alloc(...)
let inner = build_inner(buf) match {
    Ok(v)  => v,
    Err(e) => { free(buf); return Err(e) },
}
let outer = build_outer(inner) match {
    Ok(v)  => v,
    Err(e) => { free(buf); /* inner cleanup */; return Err(e) },
}
return Ok(.{ buf, inner, outer })
```

Verbose, repetitive, and the cleanup duplication grows quadratically with the
number of fallible steps.

Alternatives considered (and rejected):

- **`defer_try`** (a defer that fires only on `?` exit) — looks clean but the
  ownership state is hidden in compiler bookkeeping, making transfer-mid-block
  bugs invisible to readers. Discussed and dropped before this RFC.
- **`try { ... }` blocks** — bigger language change, doesn't fully solve the
  ownership-transfer-on-success problem either.

`Owned(T)` solves the same problem at the library level with the ownership
state encoded in the value (`Option(T)`), where it's visible at every line.

## Design

### Type

```
pub type Owned = struct(T) {
    __value: &T?,
    __cleanup: fn(&T) void,
}
```

`Owned(T)` wraps a heap pointer. `__value: &T?` niche-optimizes to a single
nullable pointer (per spec.md §2.7) — the same wire size as `&T`. `Some(p)`
means we own the pointer; `None` means we transferred. `cleanup` runs on
`deinit` if we still own.

**Implementation note (deviation from original draft):** the first draft
spec'd `value: T?` (T by-value). That doesn't fit FLang's ownership model:
stack values are owned by the frame, so wrapping them in `Owned` is
redundant; container types like `StringBuilder` / `List` / `Dict` already
own their internal heap via the header. `Owned` is specifically for raw
heap pointers from an allocator, where the cleanup contract is "free this
pointer once." Storing `&T?` makes the type's purpose explicit and avoids
the language gap around extracting `&T` from inline `Option(T)` storage.

### API

```
pub fn owned(value: &$T, cleanup: fn(&T) void) Owned(T)

// Take ownership out. The Owned becomes empty; deinit becomes a no-op.
// Panics if the Owned is already empty.
pub fn transfer(self: &Owned($T)) &T

// Run cleanup if still owned, otherwise no-op. Idempotent.
pub fn deinit(self: &Owned($T))

// True if we still own a pointer.
pub fn is_owned(self: &Owned($T)) bool

// Transparent access to the inner T. Panics if the Owned is empty.
pub fn op_deref(self: &Owned($T)) &T
```

### Cleanup signature: `fn(&T)`, not `fn(T)`

The cleanup takes `&T`. Even though stdlib `deinit` functions today are
written `fn deinit(self: OwnedString)` (by value), this is a soundness gap
masked by the optimizer: the value is consumed by-name, but the language
provides no guarantee against the caller using it afterwards. `Owned`
deliberately uses `&T` so the cleanup contract is honest about not requiring
ownership-by-value.

User cleanups that want to call existing `deinit(self: T)` functions wrap:
`|v| { (&v).deinit() }` — until that pattern is sorted out at the language
level.

### Usage with `?`

```
fn build_thing() Result(Thing, Err) {
    let buf = owned(alloc(...), free)
    defer buf.deinit()                       // fires on every exit

    let parsed = parse(buf)?                  // ? exit: deinit frees buf
    let validated = validate(parsed)?         // ? exit: deinit frees buf

    return Ok(.{ buf = buf.transfer(), parsed = validated })
    //         ^ ownership moves; deinit becomes a no-op; caller owns buf
}
```

Every `?` gets cleanup-on-error for free. The success path's `transfer()`
disarms the defer.

### `op_deref` semantics

Mirrors `Rc.op_deref`: panics if called on an empty Owned, with a clear
message. The user discipline ("after `transfer`, the Owned is dead") matches
existing `Rc` conventions.

## Rejected variants

- **`fn(T)` cleanup** — see above; would propagate the existing soundness
  gap.
- **A separate `borrow()` method** — `op_deref` covers the ergonomic case;
  adding `borrow()` is redundant API surface.
- **`discard()` (drop ownership without cleanup)** — niche; defer until a
  real use case appears.
- **Multiple constructor overloads (`owned_alloc`, etc.)** — premature.
  Single constructor is enough; specializations can land if patterns emerge.

## Edge cases

### Multi-argument transfer

```
let a = owned(alloc(...), free)
let b = owned(alloc(...), free)
defer a.deinit()
defer b.deinit()

let combined = combine(a.transfer(), b.transfer())?
```

Argument evaluation is left-to-right, so `a.transfer()` runs first, then
`b.transfer()`, then `combine`. If `combine` errors via `?`, both deinits
are no-ops (correct). If `combine` panics or errors mid-execution after
consuming one but not the other, that's `combine`'s responsibility — not
something `Owned` can fix.

### Transfer in a struct constructor

```
let result = .{ thing = build()?, buf = buf.transfer() }
```

Safe: if `build()` errors, `buf.transfer()` never runs, defer fires,
`buf` is freed.

```
let result = .{ buf = buf.transfer(), thing = build()? }
```

**Footgun**: `buf.transfer()` runs first, then `build()?` errors,
`result` is never constructed, `buf`'s contents leak. Document the
discipline: transfer at the absolute end, after all fallible operations.

### Double transfer / double deinit

`transfer` after empty: panics. `deinit` after empty: no-op. Both are
intentional.

## Where it lives

`stdlib/std/owned.f`. Not auto-imported via the prelude — opt-in via
`import std.owned`.

## Tests

Under `tests/FLang.Tests/Harness/owned/`:

- `owned_basic.f` — construct, deinit fires.
- `owned_transfer.f` — transfer, then deinit is a no-op.
- `owned_double_deinit.f` — second deinit is a no-op.
- `owned_with_question.f` — `defer deinit + ?` shape; ? exit frees, success
  transfers.
- `owned_op_deref.f` — pass `Owned(T)` to a function expecting `&T`.
- `owned_after_transfer_panics.f` — calling `transfer` twice panics.
- `owned_op_deref_after_transfer_panics.f` — using `buf.field` after
  transfer panics.

Plus embedded `test "..." { ... }` blocks inside `std/owned.f` for the
cheap invariants.

## Out of scope

- Language-level support for `defer_try` or `try { ... }` blocks. Revisit
  only if `Owned(T)` proves insufficient in real code.
- Soundness fix for the `fn deinit(self: T)` pattern in existing stdlib.
  Tracked separately.

## Open questions

1. **Bikeshed: `Owned` vs `Guard` vs `ScopeGuard`.** `Owned` reads naturally
   and matches the concept (ownership tracking, not just "scope").
2. **Should `op_deref` be on `&Owned(T)` or also on `Owned(T)` by-value?**
   Defer to whatever convention the rest of the stdlib uses (Rc has both?).
3. **Helper constructors** like `owned_alloc(size) Owned(u8[])` that bundle
   common allocation + cleanup pairs. Not in v1.
