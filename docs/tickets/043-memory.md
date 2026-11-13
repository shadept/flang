---
status: implemented
type: language
created: 2026-10-25
implemented: 2026-10-26
relates: [RFC-016, RFC-028, RFC-033, RFC-034]
---

# RFC-043: Heap memory as an owned resource

## Summary

An allocator hands out a `Memory` and takes it back; a slice only ever borrows one. `leak` ends an
ownership chain where its resource leaves the language. The release check (W2006) then sees every
container's release as a move, and the allocator boundary is checked like any other.

```flang
// core.memory
pub type Memory = struct {
    owned ptr: &u8
    len: usize      // bytes
}

#intrinsic
pub fn leak(value: move $T) {}
pub fn from_raw(ptr: &u8, len: usize) Memory
pub fn unallocated() Memory
pub fn is_allocated(m: &Memory) bool
pub fn as_slice(m: &Memory) $T[]
```

## Motivation

- **Two questions had one answer.** What introduces an owned value: constructing a non-copyable
  type. What removes it: nothing. A leaf type (`owned ptr: &u8`) released its resource through a
  raw free, an OS call or a count, none of them a move, so W2006 fired inside every `deinit`.
- **A slice served two ideas.** It was both a view of elements and the handle storage was freed and
  moved through. Nothing tracked an allocation between `alloc` and the struct literal that wrapped
  it, nor between taking the pointer out and `free`.
- **Every memory-owning container was its own leaf**, each with an `owned` raw pointer and a free
  the checker could not see.

## Design

### `Memory`

`len` bytes at `ptr`. `unallocated()`, the zero value, owns nothing. Only an allocator creates
one (`alloc`), and only an allocator ends one (`dealloc`):

```flang
pub type AllocatorVTable = struct {
    alloc: fn(&u8, size: usize, alignment: usize) Memory?
    realloc: fn(&u8, memory: &Memory, new_size: usize) bool
    dealloc: fn(&u8, move Memory) void
}
```

- The block does not carry its alignment: the address is the record. A block that moves keeps the
  alignment its address meets, up to `MAX_ALIGN`. Carrying it cost a word per container and
  per string, and was read only by a panic.
- `realloc` resizes the block in place of `memory`: true with `memory` now the resized block, false
  with it untouched. On failure the caller still owns the original.
- `unallocated()` is never allocated: `dealloc` of it is a no-op, `realloc` of it is false.

### `leak`

Takes ownership and releases nothing: the end of every chain. It is an intrinsic, so its own body
is the one place W2006 does not look. The bottoms:

- the global allocator: read `memory.ptr`, `leak(memory)`, `free(ptr)`;
- a region (arena, fixed buffer): `leak` a block it reclaims with its pages;
- an OS handle (`File`, `Child`, a directory): `leak(self)` after the syscall;
- `Rc`/`Arc`: `leak(self)` once the count is given back;
- `NoCopy`: `leak(self)`.

### `as_slice` and element moves

`as_slice` borrows a block as `m.len / size_of(T)` elements of any `T`, chosen by the annotation:
`const entries: Entry(K, V)[] = self.mem.as_slice()`. The slice is mutable, which is why it is
not called a view. A `Memory` field grants the module that declares
its type what an `owned` field does (RFC-034): taking non-copyable elements out of the storage it
reaches, by `move` or through `move_to`. `copy_to` is unchanged: it copies copyable values
between slices.

### Containers

`UnmanagedList`, `UnmanagedDeque`, `UnmanagedDict`, the `OrderedDict` index, `StringBuilder` and
`OwnedString` hold a `Memory`. Capacity is derived (`mem.len / size_of(T)`), and `deinit` moves the
block into `dealloc`, so the container is released by a visible move. `OwnedString` holds exactly its
text and terminator, and `view()` is the text as a `String`; `to_string` shrinks the builder's block
to fit, which an allocator may do by moving it. `new`, `box` and `free(&T)` remain for a single raw slot.

## Transition

The seed checks the stdlib, and it does not know that a `Memory` field grants element moves, nor
that `m.as_slice()` reaches the storage of `m`. Until the next promote, `UnmanagedList`,
`UnmanagedDeque` and `UnmanagedDict` declare their field `owned mem: Memory`, and a `move_to`
source is still spelled `slice_from_raw_parts(s.mem.ptr as &T, n)`; both checkers accept that.
After the promote the `owned` goes and those sources become `s.mem.as_slice()[a..b]`.

### Arena

The arena owns its first page's block, and each page header owns the next page's, so `deinit`
moves every block into `dealloc` and needs no `from_raw`. Allocation walks on to the pages a
`reset` kept before taking a new one; it used to link a new page over the rest of the chain and
lose it. Both bump allocators align the address they hand out, not their offset into the buffer.

## Open questions

- Typed storage: a typed `Memory(T)` instead of casts at every element access.
- `to_owned_slice` hands a block over as a raw slice (`leak` plus `free(items)`); return the
  `Memory` instead?
- Restricting `from_raw` to allocator implementations and FFI modules.
- Identical specializations (`as_slice` for types of one size) are not folded; emission could dedup
  them by body.

## Supersedes

The `owned` raw-pointer storage of RFC-028 §containers and spec 4.1 rule 4. RFC-016 (`#auto_deinit`)
is under review against this and W2006.
