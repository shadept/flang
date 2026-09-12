# The FLang standard library

Two libraries:

- `core/`, the prelude: strings, options, ranges, hashing, panics, runtime type info. In scope in
  every program.
- `std/`: collections, allocators, IO, formatting, JSON, paths, processes. Imported by name,
  `import std.collections.list`.

The compiler is written against both, so this is the API it runs on.

Stdlib source is compiled by the seed compiler in `boot/`. A language feature is usable here once it
has landed in the compiler, has a harness test and has been promoted (`CLAUDE.md`, Seed rule).

The rest of this page describes how the code is organised and written.

## File layout

A file is organised around its main type. The type and its doc comment come first, followed by
everything that belongs to it. Supporting types (an iterator, an entry, a control block) are placed
after the type they serve. The file reads top to bottom, most important part first.

The functions of a type are grouped in this order:

1. constructors (`list`, `from_view`)
2. destructor (`deinit`)
3. copies (`clone`, `retain`)
4. queries (`len`, `get_ref`, `contains`)
5. mutations (`push`, `insert`, `pop`)
6. transformations and other operations (`map`, `join`, `format`)
7. operators (`op_index`, `op_deref`, `op_eq`)
8. iterators: the iterator type, then `iter`, `iter_ref`, `next`

Public types come before private ones, each directly followed by its own functions. Tests are at the
end of the file, in the order of the types they cover.

Older files are being brought to this layout as they are edited.

## Style

**Receiver name.** A function designed to be called as `x.f()` names its first parameter `self`,
whether it takes `T` or `&T`.

**Reference for reading, value for consuming.** Read-only functions take `&self`. A by-value `self`
consumes the value (RFC-028); this is the shape of `unwrap`, `expect` and `map` on `Option` and
`Result`.

**Allocator last.** The allocator is the final parameter: `push(self, value, allocator)`,
`list(capacity, allocator)`. Managed types default it to null, meaning the global allocator;
unmanaged types require it. An `&Allocator?` is passed down as is and resolved with `or_global()`
in the function that allocates.

**Inference.** Types are written where inference has nothing to work from and left out elsewhere.
Tests are the exception: they pin their types so that a failure describes the behaviour under test.

**Doc comments.** A doc comment states the contract the signature leaves open: ownership, panics,
how long a returned reference stays valid, what null means. One imperative summary line, then as
much as the contract needs.

**ASCII.** Hyphens, plain quotes, `->` in diagrams.

## Conventions

**Expected functions.** Generic code calls a fixed set of functions by name, so a type that provides
them under these signatures works everywhere the stdlib does (spec §9.4):

- `deinit(self: &T)` releases what the value owns and leaves it zeroed, so a second call is a no-op.
  Every type that owns something has one; containers call it on their elements. The unmanaged form
  is `deinit(self: &T, allocator: &Allocator)`.
- `clone(self: &T, allocator: &Allocator? = null) T` is the canonical deep copy. Containers call it
  to duplicate their elements. The unmanaged form requires the allocator.
- `hash(self: &T) usize` and `op_eq` make a type usable as a `Dict` key or `Set` element.
- `format(self: &T, w: Writer, spec: String)` makes a type printable through `$"..."` and `append`.
- `iter(self: &T)` returning a type with `next(self: &I) E?` makes a type usable in `for`;
  `iter_ref`, returning references, is the `for &x` form.

**Copyable and owning elements.** A container selects per element type with
`#if type_info(T).copyable`: copyable elements are copied bitwise and skipped on `deinit`; owning
elements go through their own `clone` and `deinit`.

**Reference counting.** `Rc` and `Arc` use `retain` for the reference-count bump, so that
`rc.clone()` keeps its meaning: through `op_deref`, a clone of the `T` inside.

**Managed and unmanaged pairs.** `UnmanagedList` is the buffer and takes the allocator at every
allocating call. `List` carries the allocator, reaches the buffer through `op_deref`, and gets its
wrappers from one `#define` template shared with `ListRef`. `Dict`, `Set`, `Stack` and `Deque`
follow the same shape.

**Zero is empty.** A zero-initialised value is valid and empty: `let xs: List(i32)` is an empty list
on the global allocator, and a zeroed `OwnedString` is safe to `deinit`. Every `deinit` returns its
value to that state.

**Lookups by view.** `Dict(OwnedString, V)` and `Set(OwnedString)` accept a `String` view for `get`,
`contains` and `remove`. Only an insert copies the key.

**Two iteration forms.** `for x in xs` copies each element and is the form for copyable element
types. `for &x in xs` yields references and is the form for owning element types. Dict entries are
always yielded by reference.

## Idioms

**Loops.** A loop uses the iterator, `for x in xs` or `for &x in xs`. The compiler lowers both to
the index loop, so `for i in 0..xs.len` is written only when the index itself is needed.

**Element access.** Elements are reached through the container's API: `self.get_ref(i)`,
`&self[i]`, `self.pop()`. Arithmetic on `self.ptr` appears only in the handful of functions that
own the buffer layout (`reserve`, `insert`, `to_owned_slice`).

**Field access.** Struct fields are addressed by name, `&inner.value`, never through an offset
computed from `size_of`. The compiler knows the layout, including padding and alignment.

**In-place updates.** A stored value is modified through `get_ref` or `op_index_ref`. Reading it
out, changing the copy and writing it back with `set` leaves two owners of whatever it holds.

**Cleanup.** The `defer` is registered when the value is created:
`let sb = string_builder(64); defer sb.deinit()`. A function that hands the storage on uses
`to_owned_slice` or `transfer` on the success path, and the deferred `deinit` becomes a no-op.

**Transfers.** A transfer of ownership is spelled `move`: `xs.push(move v)`, `return move out`,
`Wrapper { inner = move x }`, `unwrap(move r)`. The checker reports each site that needs one
(E2124, E2128), so a missing `move` is a compile error, never a silent copy.

## Tests

Tests are colocated `test "name" { ... }` blocks at the end of each file, named after what they
prove. `flang check` type-checks them and `flang test` runs them; `flang build` skips them, so a
change is complete when `flang check` passes.

Each stdlib project runs its tests against the source tree, from `stdlib/core` or `stdlib/std`:

```bash
../../dist/darwin-arm64/flang test -s "$(pwd)/.."
```

Changed files are formatted with `flang fmt <files>` before a change is finished.
