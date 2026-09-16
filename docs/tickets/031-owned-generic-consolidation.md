---
status: implemented
type: stdlib
created: 2026-09-01
implemented: 2026-09-16
requires: [RFC-033]
relates: [RFC-028, RFC-019, RFC-016]
---

# RFC-031: `OwnedString`, a `String` that owns its buffer

## Summary

`OwnedString` is a `String` plus the two facts a view lacks: this value frees the buffer, and
which allocator frees it. Everything it reads, it reads as the `String` it holds.

```flang
pub type OwnedString = struct {
    owned view: String
    allocator: &Allocator?
}

pub fn op_deref(self: &OwnedString) &String {
    return &self.view
}
```

The type keeps construction, release and nothing else. `s.len`, `s.starts_with("x")`, `s == t`
and `$"{s}"` resolve on `String` through `op_deref`; `hash` alone is declared, since the catch-all
`hash(val: $T)` takes the receiver as written. The parallel API goes, and so
does `fake_owned`, the `OwnedString` built around a borrowed `String` so string-keyed dicts could
look up by view.

It has no mutators. Growing a string is `StringBuilder`'s business, and mutability and lifetimes
stay out of scope: the type owns, it does not promise immutability, and the views it hands out are
unchecked (spec 3.6).

This supersedes the earlier draft of this RFC, a generic `Owned(T)` wrapper with
`type OwnedString = Owned(String)`.

## Why not the alternatives

- **`Owned(T)`, generic.** It needs the same `op_deref` reach as this design, with a `deinit` per
  instantiation that leaks silently when forgotten, and a type that means nothing for most `T`
  (`Owned(i32)`). One concrete type states its meaning in its own declaration.
- **Merging into `StringBuilder`** (one owning string, Rust's `String` model). Owning a buffer
  would imply being able to grow it: a mutability decision this language does not make.
- **`owned T` as a type modifier**, accepted wherever `T` is read. It would be the only construct
  of its kind, and whether a plain `T` may stand in for `owned T` would depend on the parameter
  mode rather than on anything a reader sees in the type.

## Design

### Reads

Under RFC-033 a read never needs ownership, so every function that only reads a `String` is valid
on the `String` an `OwnedString` holds. `op_deref` is how the checker gets there: field reads,
by-value methods, `&String` methods, operators, and interpolation holes all peel the hop. Where a
`String` value itself is wanted, it is `s.view`, a field read of a copyable type.

### Construction

```flang
// An owned copy of a view.
pub fn from_view(s: String, allocator: &Allocator? = null) OwnedString

// StringBuilder hands its buffer over; the builder is left empty.
pub fn to_string(sb: &StringBuilder) OwnedString
```

`$"..."` returns `OwnedString`, as today.

### Release and copies

```flang
pub fn deinit(self: move OwnedString)
pub fn deinit(self: move OwnedString, allocator: &Allocator)   // the element form; ignores `allocator`
pub fn clone(self: &OwnedString, allocator: &Allocator? = null) OwnedString
```

`owned view` makes the type non-copyable (RFC-028), so a second release is E2123 rather than a
nulled pointer checked at run time, and a copy is E2124. `clone` is the explicit deep copy.

### Keys

A dict or set keyed by `OwnedString` is looked up by `String`. Lookups become generic over the
probe's type:

```flang
pub fn get_ref(self: &UnmanagedDict($K, $V), key: $Q) &V?
pub fn contains(self: &UnmanagedDict($K, $V), key: $Q) bool
pub fn remove(self: &UnmanagedDict($K, $V), key: $Q) V?
```

The probe hashes `key` and compares `entry.key == key`. With `K = OwnedString` and `Q = String`,
`==` resolves on `String` through the key's `op_deref` and `hash` forwards to it; with `Q = K` the existing overloads rank
first. Any key type with a view gets the same lookup. The one requirement a key type carries is
that `k.hash()` and the view's `hash()` agree, which holds by construction when the key's reads are
its view's.

Inserts by view stay specific to `OwnedString` (`add`, `set` taking a `String`), because they build
the owned key with `from_view`. `fake_owned` and the lookup overloads are deleted.

A concrete key type that needs a lookup form is the cost this design keeps: compatibility with
`String` lives in the generic probe rather than in the type system.

## Prerequisites

Both make `op_deref` behave the same everywhere; neither adds a construct.

1. **Operator dispatch peels `op_deref`.** `a == "hello"` and `a == b` on `OwnedString` are E2017
   today; method calls and indexing already peel. Binary operators resolve through the same
   receiver shapes.
2. **Receiver tiers.** `x.f()` resolves as `f(x)` would: the receiver as written, then adapted to
   `&x`, then through `op_deref`, each tier tried only when nothing matched the one before. A
   catch-all taking the receiver as written therefore wins over a concrete overload through a hop.
   A reader that must not fall to a catch-all is declared for the type itself: `OwnedString`
   keeps `hash(s: OwnedString)` so `Dict(OwnedString, V)` hashes the text, not the struct bytes.

Both landed 2026-09-15. Tiers disable `std.iter` until RFC-019 can bound its `$I`.

### Verified on `consumer_ownership_semantics`

| | |
| --- | --- |
| a field read through `op_deref` (`s.len`) | works |
| a by-value `String` method through `op_deref` (`s.starts_with("he")`) | works |
| `s.hash()` reaching `String`'s `hash` | needs `hash(s: OwnedString)` (prerequisite 2) |
| `s == "hello"`, `"hello" == s`, `s == t` | works (prerequisite 1) |
| `$"{s}"` through `op_deref` | works; consumes a named `s` (open question 1) |

## Migration

- **`OwnedString`'s own API.** `hash` stays, forwarding to the view. `as_view`, `bytes`, `chars`, `format` and `op_eq` are deleted.
  `path_from_owned(s: &OwnedString)` takes the view. `#string_reader(OwnedString)` retargets to
  `String` through the hop or is deleted if the generator reads the view already.
- **`s.as_view()` call sites** (~990 across the tree) become `s.view`. Dropping the call where a
  `String` method follows is left to taste: `.view` resolves as written, while the peel is the last
  receiver tier and a catch-all can take the receiver first.
- **Struct literals naming the old fields** (`ptr`, `len`, `allocator`): `from_view`,
  `StringBuilder.to_string` and the `fake_owned` sites in `dict.f`.
- **The ~40 types holding an `OwnedString`** become non-copyable and follow RFC-033: `deinit(self:
  move T)` plus the element form, `move` in struct literals, `clone` where a copy was meant, `for
  &x` and `get_ref` where elements were read by value.

## `std/owned.f`

Deleted, independent of the rest. Its runtime `Owned(T)` tracks a transfer through an `Option` tag
so a `defer` can free on the error path and do nothing after a hand-off. Ownership is static now:
a moved binding is dead, and a `defer` that would release it is E2123 on the path that moved it.
Its three users are `std.io` sites around a `StringBuilder`; two end in `to_string()`, which leaves
the builder empty so a plain `defer sb.deinit()` is correct, and one moves the builder into
`GlobIter` and now builds it after the fallible step, so no error path holds it.

## Sequencing

1. Operator dispatch peels `op_deref`. Done.
2. Receiver tiers. Done.
3. Seed promote. Done.
4. `std/owned.f` deleted, its three users restructured. Done.
5. `OwnedString` becomes the struct above, the key lookups become generic, the parallel API and
   `fake_owned` go, and the tree is swept until green. One commit per green state:
   - 5a. `{ view, allocator }` plus `op_deref`, still copyable. Done.
   - 5b. `$Q` lookups on `UnmanagedDict` and `UnmanagedSet`; `fake_owned` and the `String` lookup
     overloads deleted. The `K` overloads stay, so a literal probe still types from the key. Done.
   - 5c. `as_view`, `format`, `op_eq`, `bytes`, `chars` and `#string_reader(OwnedString)` deleted;
     call sites read `.view`. Done.
   - 5d. `owned view`: non-copyable, `deinit(self: move OwnedString)` plus the element form,
     `clone`, and the ~40 types holding one. Done, with what an owning element needs from the
     containers: `List`/`Dict` drains, a dict that lends its entries, a set that keeps by-value
     iteration and gains `iter_ref`, `swap` through `&move` slots, and sorts that compare by
     reference.
     RFC-033's `move` gate landed here too: taking out of a reference is the declaring module's
     right, not everyone's.

## Tests

`tests/harness/ownership/`:

- `OwnedString` is non-copyable though `String` is copyable
- a field, a by-value method, `==` against a `String` and against an `OwnedString`, `hash`, and an
  interpolation hole all reach `String` through `op_deref`
- `Dict(OwnedString, V)`: `set` moves the key, `get_ref` and `contains` by `String`, `remove` by
  `String` returns the value, and `deinit` releases every key once
- a second `deinit` is E2123
- `clone` gives an independent buffer

`tests/harness/op_deref/`: operator dispatch through a hop; a concrete overload through a hop
loses to a catch-all as written.

## Settled while implementing

1. **Interpolating a named `OwnedString`.** A hole that names a place is read - the desugar emits
   `place.format(sb.writer(), spec)` - and only a temporary goes to the consuming `append`. Without
   it `$"{s}"` would kill `s`.
2. **Ranking.** Answered by receiver tiers rather than by a hop-versus-catch-all tie-break: an
   overload taking the receiver as written wins, so `OwnedString` declares its own `hash`.
3. **Arguments.** RFC-020 landed with it, so `lexer(source, alloc)` takes an `OwnedString` where a
   `String` is wanted; the owner decays to the view it holds.

## Still open elsewhere

- **`List.to_owned_slice`** returns a `(T[], &Allocator)` tuple the caller frees by hand. The `List`
  increment of RFC-033 step 6c replaces it with the drains this RFC added and `take_all`.

## Out of scope

- Mutability of an owned string, and immutability of any owner.
- Lifetimes of the views `op_deref` hands out.
- `#auto_deinit` (RFC-016).
