---
status: draft
type: stdlib
created: 2026-09-01
requires: [RFC-030, RFC-028]
relates: [RFC-012, RFC-020, RFC-016]
---

# RFC-031: `Owned(T)`, one ownership wrapper

## Summary

`Owned(T)` is a generic wrapper meaning "this binding owns `T`'s buffer". Its
one `owned` field derives the non-copyable bit (RFC-028), so every implicit copy
is a compile error and every transfer is spelled `move`.

It replaces three things that each hand-roll the same idea:

| today | becomes |
| --- | --- |
| `OwnedString`, a peer type of `String` with a parallel API | `type OwnedString = Owned(String)` |
| `List.to_owned_slice() (T[], &Allocator)`, a tuple the caller frees by hand | `Owned(T[])` |
| `std/owned.f`, runtime ownership tracking through an `Option` tag | deleted, not replaced |

`to_owned(value, allocator)` constructs one. It wraps a buffer the caller
already owns and never copies; copying a view into fresh memory is boxing, a
different operation that keeps its own name.

Two consequences follow:

- `String` is the only view and `StringBuilder` the only writer. There is no
  third string type.
- `transfer()` and `is_owned()` go. Two of their three call sites never needed
  them, and the third restructures.

## When `Owned(T)`, when an `owned` field

`Owned(T)` is for a `T` that is a **view**: a `{ptr, len}` over memory it does
not free. `String` and `T[]` qualify. A view has nothing to release on its own,
so the wrapper's allocator is the only thing that knows how to free the buffer,
and wrapping adds exactly the one fact that was missing.

A type that already frees itself, such as `StringBuilder`, `List` or `Dict`,
gets its non-copyable bit from its own `owned` field and is never wrapped.
Wrapping it would add a field it does not use and a `deinit` that only
delegates.

An `i32` is neither. `Owned(i32)` says nothing about whether the value is a
file descriptor, a socket, a handle or an index, and two unrelated resources
would share a type and a `deinit`. Those keep a nominal struct with an `owned`
field, which is what `FileHandle` is and stays:

```flang
pub type FileHandle = struct {
    owned fd: i32
}
```

The rule: **`Owned(T)` when `T` is a view; an `owned` field everywhere else.**

## Design

### The type

```flang
// Owned(T) - a value whose buffer this binding owns.
//
// T is a view: it reads memory it does not free. Wrapping it says this one frees it. The
// non-copyable bit on `__value` turns every implicit copy into an error, so transfers are spelled
// `move`.
pub type Owned = struct(T) {
    owned __value: T
    __allocator: &Allocator?
}

// Reads and by-value methods of T reach through: `s.len`, `s.starts_with("x")`.
pub fn op_deref(self: &Owned($T)) &T {
    return &self.__value
}
```

Layout is 24 bytes, `{ptr, len}` inline plus the allocator: exactly
`OwnedString`'s three fields today.

### Constructing: `to_owned`

`to_owned` is generic. It takes a `T` and the allocator that owns `T`'s buffer,
and says so:

```flang
pub fn to_owned(value: $T, allocator: &Allocator? = null) Owned(T) {
    return .{ __value = value, __allocator = allocator }
}
```

That is the only body that names the fields. Every other constructor composes
through it, from inside the type that actually holds the buffer:

```flang
// std.string_builder: hand the builder's buffer over.
pub fn to_string(sb: &StringBuilder) Owned(String) {
    // ... terminate, then
    const s = to_owned(sb.as_view(), sb.allocator)
    sb.ptr = 0usize as &u8
    sb.len = 0
    sb.cap = 0
    return s
}

// std.list: hand the list's buffer over.
pub fn to_owned_slice(self: &List($T)) Owned(T[]) {
    // ... shrink to len, then
    const s = to_owned(slice_from_raw_parts(self.ptr, self.len), self.allocator)
    self.ptr = 0usize as &T
    self.len = 0
    self.cap = 0
    return s
}
```

### Owning is not boxing

`to_owned` asserts ownership of memory the caller already holds. Boxing copies
a view into fresh memory and returns the owner of the copy. That is `from_view`
for `String`; it keeps its name and ends in `to_owned` like every other
constructor:

```flang
pub fn from_view(s: String, allocator: &Allocator? = null) Owned(String) {
    const buf = allocator.or_global().alloc(s.len + 1, align_of(u8))
        .expect("OwnedString.from_view: allocation failed")
    if s.len > 0 {
        memcpy(buf.ptr, s.ptr, s.len)
    }
    const term = buf.ptr + s.len
    term.* = 0
    return to_owned(String { ptr = buf.ptr, len = s.len }, allocator)
}
```

`"literal".to_owned()` type-checks and is a lie: the caller does not own that
memory, and `deinit` will free it. That is the contract `slice_from_raw_parts`
already has and spec 3.6 states. An ownership claim is the caller's
responsibility, not the API's to police. The honest spelling of "own a copy of
this literal" is `from_view("literal")`.

### Release is per instantiation

`Owned` wraps a `T` that has no release mechanism of its own. Usually that
means no `deinit` at all; where a view does declare one, it frees nothing,
because a view has nothing to free. Either way `T` cannot release the buffer:
the wrapper holds the allocator, so the wrapper frees.

There is therefore no generic `deinit(&Owned($T))`. A generic body could only
delegate to `T.deinit`, which frees nothing, and every `Owned` would leak. Each
instantiation declares its own overload, and doing so is part of instantiating
the wrapper at all:

```flang
pub fn deinit(self: &Owned(String))
pub fn deinit(self: &Owned($T[]))
```

An instantiation without one leaks silently. Every owning type carries that
hazard today; this wrapper does not add it. RFC-028 step 7
(per-specialisation element `deinit`) is where a diagnostic for it belongs.

### The two instantiations

```flang
pub type OwnedString = Owned(String)

pub fn deinit(self: &OwnedString) {
    // Idempotent: a second call sees the nulled pointer and no-ops.
    if addr_eq(self.__value.ptr, 0usize as &u8) {
        return
    }
    self.__allocator.or_global().free(slice_from_raw_parts(self.__value.ptr, self.__value.len))
    self.__value.ptr = 0usize as &u8
    self.__value.len = 0
}

pub fn as_view(self: &OwnedString) String {
    return self.__value
}

// The slice owner. Elements are not deinited here; see open question 4.
pub fn deinit(self: &Owned($T[])) {
    if self.__value.len == 0 {
        return
    }
    self.__allocator.or_global().free(self.__value)
    self.__value = slice_from_raw_parts(0usize as &T, 0)
}
```

`op_eq` and `hash` stay hand-written on `Owned(String)`: the deref chain hands
a by-value receiver to whatever it reaches, so neither an operator nor a `&T`
function can be inherited through it. `op_eq` takes `&` per RFC-030.

## What this removes

### `OwnedString`'s parallel API

Inherited through the deref chain and deleted: `format`, `bytes(&OwnedString)`,
`chars(&OwnedString)`, and every `.as_view()` hop at a call site that only
wanted a `String` method.

Kept: `op_eq` and `hash` (unreachable through the chain), `print` and `println`
(consuming is the point), `#string_reader(OwnedString)`.

`dict.f`'s five `Dict(OwnedString, $V)` specialisations (`set`, `get`,
`get_ref`, `contains`, `remove`) stay. They exist so a lookup can pass a
`String` against an owned key, and `op_deref` runs wrapper to inner, never
inner to wrapper, so the chain cannot supply that. They retarget to
`Dict(Owned(String), $V)`.

### `std/owned.f`

Deleted. Its `Owned(T)` wraps a self-managing `T` to get `transfer()`: cleanup
on the error path through one `defer`, disarmed on the success path. It has
three call sites, all wrapping `StringBuilder`.

Two of them, in `io/file.f`, end in `sb.transfer().to_string()`. `to_string`
already nulls the builder, so a `defer sb.deinit()` is a no-op after it and
frees on a `?` bail before it. The wrapper adds nothing:

```flang
let sb = string_builder(PAGE_SIZE, allocator)
defer sb.deinit()
// ... a `?` bail frees the builder
return Ok(sb.to_string())
```

The third, in `io/fs.f`, moves the builder itself into `GlobIter.pattern`.
That is the one shape `move` cannot serve through a `defer`:

```flang
let h = H { fd = 1 }
defer h.deinit()
if fail { return Err(1) }
return Ok(Box { h = move h })
// error[E2123]: `h` was moved and cannot be used   (at the defer)
```

The pass is right. `move` leaves the bits in `h`, so the deferred `deinit` would
free a buffer now owned by `Box.h`. This is RFC-028's Defer rule (liveness is
checked where the body runs, on every exit path) and spec 4.1's ordering, not a
gap. The site restructures to handle its single fallible step explicitly:

```flang
let pat_buf = string_builder(pattern.len + 1, allocator)
pat_buf.append(pattern)
let walk = walk_dir(root_str, allocator) match {
    Ok(w) => w
    Err(e) => {
        pat_buf.deinit()
        return Err(e)
    }
}
return Ok(GlobIter { walk = walk, pattern = move pat_buf, done = false })
```

One site, so no mechanism replaces `transfer()`.

### `to_owned_slice`'s tuple

`List.to_owned_slice` returns `(T[], &Allocator)` today, and its doc comment
tells the caller to free the buffer by hand and to walk the elements deiniting
each. That is `Owned(T[])` and its `deinit` written longhand. It returns
`Owned(T[])`; its seven callers stop indexing a tuple positionally (`taken.0`,
`taken.1`) and read the slice through `op_deref`.

## Verified against the compiler

| | |
|---|---|
| `owned __value: T` derives the non-copyable bit through instantiation | works |
| `type OwnedString = Owned(String)` in every type position, including `Dict(OwnedString, V)` | works |
| `op_deref` chains field reads and by-value UFCS (`s.len`, `s.starts_with("x")`) | works |
| a `deinit` overload on one instantiation is picked over a generic `deinit(&Owned($T))` | works |
| `op_eq`, `hash`, `as_view` declared on the instantiation | works |
| `hash(&String)` reached through the deref chain | no: the chain yields a by-value receiver |
| `op_eq` reached through the deref chain | no: E2017, see RFC-030 |

## Migration

442 `OwnedString` references across 40 files, outside `dist/`, `boot/` and
`compiler/build/`. Almost all are type positions the alias covers unchanged,
including every `) OwnedString {` return signature, and `os.ptr` / `os.len`
still resolve through `op_deref` to `String`'s own fields.

**Eight struct literals** name the old fields and do not survive:

| site | shape | fate |
| --- | --- | --- |
| `std/dict.f` x4 | `{ptr = key.ptr, len = key.len, allocator = null}` | deleted with the Dict fake key, RFC-028 step 8 |
| `std/string_builder.f` x2 | `to_string` handing its own buffer over | composes through `to_owned` |
| `tests/harness/source_generators/string_reader_basic.f` x2 | a test borrowing a view as a fake owner | deleted with the fake key |

The `dict.f` literals build a borrowed key with `allocator = null` so `deinit`
skips it. A value that names itself owned but is not is a lie under this model,
and RFC-028 already removes the shape.

**173 `Dict(OwnedString, V)` and `List(OwnedString)` sites** need no edit, but
compile only once `Dict` and `List` are move-aware. That prerequisite is the
whole of the migration cost.

## Prerequisites

Both are hard gates, and both already sit on RFC-028's critical path. Neither is
caused by this ticket; both are the cost of `OwnedString` becoming non-copyable
at all, and annotating `OwnedString.ptr` in place would hit them identically.

1. **RFC-030.** `op_eq` on an owning type is unwritable until the reference form
   exists. Without it `Dict(OwnedString, V)` cannot resolve a key comparison.
2. **RFC-028 step 6, `List` and `Dict`.** `Dict.set` copies its key parameter
   into the table:

   ```
   d.set(OStr { ... }, 1usize)
   -> error[E2124]: `key` cannot be copied here - write `move key`;
      `Owned(String)` is not copyable: field `__value` is `owned`
   ```

   The stores need `move`, mirroring `list.push`.

## Sequencing

1. RFC-030 lands.
2. RFC-028 step 6 `List`/`Dict` move-awareness lands.
3. **Seed promote.** Stdlib source is about to contain a generic `owned` field
   and `move` in container stores.
4. **`std/owned.f` is deleted.** `io/file.f` drops the wrapper twice; `io/fs.f`
   restructures its error path. Needs nothing else in this ticket.
5. **`OwnedString` becomes the alias.** `from_view`, `deinit`, `as_view`,
   `op_eq` and `hash` move onto the instantiation, `from_view` returning
   through `to_owned`; `format`, `bytes` and `chars` are deleted; `to_string`
   composes through `to_owned`; the fake-key literals vanish; `dict.f`'s five
   specialisations retarget. One commit: the alias and the field change are not
   separable.
6. **`List.to_owned_slice` returns `Owned(T[])`.** Separable from step 5 and
   can land after it.

## Tests

`tests/harness/ownership/`:

- `Owned(String)` is non-copyable though `String` is not
- a field read and a by-value method reach through `op_deref`
- `Dict.deinit` reaches the `Owned(String)` overload and frees every key
- `Dict(OwnedString, V)` round-trips: `set` with a moved key, `get` by `String`
  view, `deinit` frees every key exactly once
- a second `move` of an `Owned` is E2123, replacing the old runtime panic
- `Owned(T[])` from `List.to_owned_slice`: the slice reads through `op_deref`,
  `deinit` frees the buffer, and the source list is left empty
- the `io/fs.f` shape: a builder moved into a struct after a fallible step, the
  error path freeing it, and no `defer`

Colocated in `stdlib/std/owned.f`: the existing five `std.owned` tests port to
the new shape, minus the two that pin `transfer()`'s runtime tracking.

## Open questions

1. **String interpolation.** `$"{os}"` reaching `format` through the deref chain
   is unverified. By-value UFCS chains, but interpolation may not lower that
   way. Probe before deleting `format`.
2. **Is one restructured site enough to delete `transfer()`?** Cleanup-on-error
   with hand-off-on-success through a single `defer` is E2123 by RFC-028's Defer
   rule, so `transfer()` was the only spelling of that shape, and it has one
   user. If the shape turns out to be common, the answer is a `defer` the pass
   cancels once its binding is moved, which is an RFC-028 change. This ticket
   assumes it is not needed.
3. **`s.*` yields a copyable `String` alias** silently, with the buffer's
   lifetime unchecked. Identical exposure to today's `as_view()`, but implicit
   where that is a named call. Accept?
4. **Does `Owned(T[]).deinit` walk the elements?** `to_owned_slice` explicitly
   does not, and says so. Whether the owner of a slice owns its elements is a
   semantic choice, not a mechanical one; RFC-028 step 7 is the natural home.
5. **`Owned(T)` in `core` or `std`?** `core/string.f` cannot name it today, and
   `print`/`println(OwnedString)` already live in `std` for that reason.
   `Owned(T[])` pushes on this: `core.slice` would want to name it.

## Out of scope

- Lifetime or escape analysis on the view handed out by `op_deref` or `as_view`.
- `#auto_deinit` interaction (RFC-016).
- Making `Owned(T)` the representation for `List`'s or `Dict`'s own buffers.
