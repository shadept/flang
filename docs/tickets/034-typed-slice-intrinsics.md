---
status: implemented
type: language
created: 2026-10-10
implemented: 2026-10-10
requires: [RFC-033]
relates: [RFC-019, RFC-029]
---

# RFC-034: Typed slice intrinsics

## Summary

Bulk memory operations become compiler intrinsics over typed slices, so FLang source never turns a
`&T` into a `&u8` to call `memcpy`, `memmove` or `memset`:

```flang
pub fn copy_to(src: $T[], dst: T[]) where T: copyable   // duplicate
pub fn move_to(src: $T[], dst: T[])                       // relocate
pub fn as_bytes(s: $T[]) u8[] where T: copyable          // read a value's bytes
```

Each lowers to the C call with `n * sizeof(T)`; the reinterpretation lives in codegen, where the
types are known. `fill(s, v)` stays the function it is, and slice `==` is element-wise, lowered to
`memcmp` where bytes and values agree. The raw byte functions become private to `core`.

## Motivation

A cast to `&u8` is where the type, and with it ownership, leaves the checker. `push_all` copied a
slice of owning elements with one `memcpy` and nothing objected: two lists owned every element
(RFC-033 log, 2026-10-10). The fix there was a `where T: copyable` bound on four functions, applied
by hand once the hole had been found.

The stdlib makes 36 raw `memcpy` / `memmove` / `memset` calls, 14 of them through `as &u8` on a
typed pointer: the container grow paths, `insert` and `remove_at` shifts, the drain compaction, the
sort merge, deque growth, `push_all` and the copying constructors. Every one is either a duplicate,
which needs `T: copyable` to be sound, or a relocation, which leaves its source slots dead. The two
read the same in source, and the checker cannot tell them apart.

## Design

### `copy_to(src: $T[], dst: T[]) where T: copyable`

Copies `src` into the front of `dst`. The bound is the soundness argument: a bitwise duplicate of a
copyable value is a copy. Overlap is allowed (it lowers to `memmove`), as in C#'s `Span.CopyTo` and
Java's `System.arraycopy`. `dst.len < src.len` panics; exactly `src.len` elements are copied.

Today's `copy_to` copies the shorter length and returns it. Its two callers (`std.conv`) check
`dst`'s length first and return `BufferTooSmall`.

### `move_to(src: $T[], dst: T[])`

Relocates `src` into the front of `dst`: the ownership of every element moves, and the source slots
are dead afterwards. For a copyable `T` it is `copy_to`, as a `move` parameter is a copy for a
copyable type (RFC-033 rule 2). For a non-copyable `T`, `src` follows the rule `move` follows (spec
3.2, "What `move` may take"): it is formed in the call from storage reached through an `owned` field
of a type this module declares. The module is trusted inside that storage, as it is for
`move (s.ptr + i).*`: the dead slots are not tracked, and reading one again is the module's own
error to avoid.

Underneath it is `memmove` and nothing else. The source is not zeroed: ownership is the checker's
model, and the bytes left behind are what the module's own bookkeeping (`len`, `head`) already
excludes.

`src` and `dst` may overlap, since that is what a shift is (`insert` moves `[i..len)` to
`[i+1..len+1)`). Rule 9 (E2133) exempts the two arguments of `move_to` from each other; anything
else in the call that overlaps them is still refused.

**Provenance through a slice.** The `move` rule reads a chain of fields and pointer arithmetic
where it is written. A slice of owned storage is formed by `slice_from_raw_parts(chain, n)` or by
ranging an existing slice (`s[a..b]`); both keep the chain's provenance when written inline in the
`move_to` call. A slice held in a binding does not, as a reference held in a binding does not today.

### `as_bytes(s: $T[]) u8[] where T: copyable`

The bytes of `s`, read-only by convention. It replaces `&val as &u8` in `core.hash` and the
allocator's typed `free` helpers. The bound keeps an owner's bytes out of reach, so no copy of a
buffer pointer escapes through a byte view.

### `fill(s: $T[], value: T) where T: copyable`

Stays a function: it is a typed loop with no cast. It takes the bound its body already needs
(storing a read-only `value` is a copy), so a non-copyable `T` is refused at the call rather than
inside the body. The backend may lower a `u8` fill to `memset`.

### Slice equality

`a == b` on slices is element-wise wherever `T` has `op_eq`, a generic in `core`. The compiler may
lower it to `memcmp` when bitwise equality is value equality: integers, `bool`, `char`, `u8`, so
`String`. Never floats (`NaN != NaN`, `-0.0 == +0.0`). Structs only while zero-init fixes their
padding (spec 4.2); if zero-init goes, they lose the shortcut, and so does the byte-wise `hash`.

### The raw functions

`memcpy`, `memmove` and `memset` move from `std.mem` into `core` as private `#foreign` declarations,
reachable only by the intrinsics' lowering. Byte buffers (`StringBuilder`, readers, writers, CSV,
readline, `realloc`) call `copy_to` on `u8` slices.

### Zeroing

There is no zeroing intrinsic: it would bake in the default spec 4.2 may drop. The two places that
zero on purpose say what they mean instead:

- `Dict` marks a slot empty by its hash (`hash == 0`). A fresh table writes that hash into each
  entry rather than zeroing the whole table, which leaves key and value bytes as they are - unused
  in an empty slot.
- `rc_alloc` zero-initializes for in-place fill through `op_deref` (spec 4.3). It keeps its `memset`
  until the zero-init decision; dropping zero-init changes that contract, not this one.

### What stays a cast

Of the 36 `as &u8` lines in the stdlib, 14 feed the raw calls and go with them. The rest:

| Kind | Sites | Disposition |
|---|---|---|
| Null reference, `0usize as &u8` | 3 | Stays: docs/known-issues.md, "`0 as &T` is how a null reference is spelled". |
| Type erasure: allocator `impl`, interface `_ctx` | 6 | Stays: a vtable's context pointer has no type to keep. |
| Allocator page arithmetic | 4 | Stays: the allocator is the boundary between bytes and types. |
| Typed `free` helpers, `core.hash`, list buffer frees | 5 | `as_bytes`, or the existing typed `free(T[])`. |
| A byte read into a 1-slice (`&b as &u8` on `b: u8`) | 3 | The cast is a no-op; removed. |
| FFI (`ioctl`) | 1 | Stays. |

After the sweep a pointer cast outside `core`, `std.allocator` and `#foreign` declarations could
become a warning, so a new one is deliberate.

## Plan

Seed rule: implement, harness-test, promote, then use.

1. **Checker.** `copy_to` and `as_bytes` are ordinary generics under their bounds. `move_to` checks
   `src` against the `move` place rule through `slice_from_raw_parts` and ranges, and is exempt
   from E2133 between its own two arguments.
2. **Lowering.** The three intrinsics lower to `memmove` / a pointer view with the element size of
   the instantiation, plus the length check.
3. **Harness.** Duplicate under the bound and refused without it, relocation within a module's own
   storage and refused outside it, overlapping shifts, the short-`dst` panic, slice `==` on integers
   and floats.
4. **Promote.**
5. **Stdlib.** Replace the 36 raw calls and the casts the table above retires; `fill` takes its
   bound; `Dict` writes empty hashes; the raw functions become private to `core`.
6. **Docs.** Spec 3.2 (`move_to` beside `move`), 4.2 (what still zeroes), 7.7's copyable bit,
   9.4; known issues; the error-code entries the checker step adds.

## Open questions

- **Provenance through `slice_from_raw_parts`**, or a range on an owned pointer (`self.ptr[a..b]`)
  as new syntax? The first needs no grammar and matches how the stdlib already forms slices.
- **The pointer-cast warning**: worth adding once the sweep lands, and at what scope?
- **`rc_alloc`**: keep zero-filling, or construct in place some other way, once spec 4.2 is decided?

## Implementation notes (2026-10-10)

The open questions were taken as recommended: provenance reads through `slice_from_raw_parts` and
ranges, the pointer-cast warning waits, and `rc_alloc` keeps zero-filling (now `fill` over the
allocation's bytes). No promote was needed: to the seed `move_to` is an ordinary function, and its
provenance check only refuses.

`copy_to`, `move_to` and `as_bytes` are `core.slice` functions whose bodies make the one byte call,
so the cast lives in `core` rather than in codegen. `move_to` carries `#intrinsic`; the ownership
pass recognises it as `core.slice.move_to` and checks its source.

The sort merge was not a `move_to` site after all: `s` is the caller's slice, so a module-local
relocation is refused, correctly. An owning element now sorts by sorting indices with the same
stable powersort and applying the permutation in place with `swap`; a copyable one keeps the staged
merge, written with `copy_to` and assignment under `where T: copyable`.

