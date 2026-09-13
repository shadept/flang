---
status: accepted
type: language
created: 2026-09-13
requires: [RFC-028]
supersedes: [RFC-016]
relates: [RFC-031]
---

# RFC-032: Consuming iteration

## Summary

RFC-028 made a copy of a non-copyable value an error and left one shape open:
how a container hands its elements over. Today that is `to_owned_slice`, which
transfers the buffer and leaves the elements' release to whoever holds the
slice, and `move x.*` through an element reference, which leaves stale bits in
the container for its `deinit` to release a second time
(`docs/known-issues.md`, "Related hazard, element deinit").

This RFC closes the shape with four decisions and one rule change:

1. **Slices own nothing.** A slice function either copies an element out, or
   lends a reference to it. The copying forms refuse an owning element type at
   compile time and name the reference or drain form to use instead.
   `to_owned_slice` is removed.
2. **`swap` exchanges two values in place.** It needs no gate, so `reverse`
   works on owning elements as it is.
3. **Every container drains.** `xs.drain()` is an iterator that moves each
   element out and hands the untaken tail back to the container when it is
   released. `for x in xs.drain()` is the consuming loop.
4. **A `for` loop releases its iterator.** When the iterator state is
   non-copyable, the loop deinits it on every exit path.

And the rule change: **`move` takes a binding, a field path, or an element of
an `owned` field inside the declaring module.** `move p.*` and `move xs[i]`
through anything else are `E2125`.

By-value `deinit`, the last step of RFC-028, lands on top of this. Its shape is
recorded here because the drain is what makes it writable.

## Slices: copy or lend

A slice is a view: `struct { ptr: &T, len: usize }`, and copying it is
unchecked because it releases nothing. Its element functions came in one form,
by value, which for an owning `T` is the copy RFC-028 forbids, reported inside
`core/slice.f` at the instantiation. The rule now:

**A slice function that copies an element out gates on
`#if !type_info(T).copyable { #error(...) }`** and names the form to use
instead. `copy_to` already does this. The gated functions:

| function | the message points at |
|---|---|
| `get`, `op_index(idx)`, `first`, `last` | `get_ref`, `&s[i]`, `first_ref`, `last_ref` |
| `find`, `min`, `max`, `min_by`, `max_by` | `find_ref`, `min_ref`, `max_ref` |
| `iter`, `iter_rev` | `for &x`, `iter_ref`, `iter_rev_ref`, or `.drain()` on the container |
| `op_set_index`, `fill`, `replace` | `swap`, or the container's `set` |
| `reinterpret` | nothing: two views over one owner |

`find_ref`, `min_ref`, `max_ref` and `iter_rev_ref` are added: the reference
twins of the gated searches, so an owning element type keeps the vocabulary.

**Callbacks receive owning elements by reference.** `each`, `any`, `all`,
`count_if`, `find_index`, `fold` and `fold_right` call `f(s[i])` for a copyable
`T` and `f(&s[i])` otherwise, selected by `#if type_info(T).copyable` in the
body. `min_by`, `max_by` and `sort_by` keep the by-value call: the first two
return the element and are gated, and `sort_by` is reached through `sort`,
which an owning `T` does not reach either. A callback written for an owning
element type takes `&T`; the same callback over a copyable type takes `T`.
This is the one place the element type shows through the API, and it is the
cheaper of the two conventions: the by-value form stays copy-free for the
types it is used on (spec §3.2), and the reference form is the only one that
can exist for the other.

`contains`, `index_of`, `last_index_of`, `count`, `starts_with`, `ends_with`,
`binary_search`, `lower_bound`, `upper_bound` compare with `==` against a
by-value argument; they stay by value and are reachable for an owning `T` once
RFC-030 gives `op_eq` its reference form. Until then they are unreachable for
such a `T`, which is the state they are in today.

The container forwarders (`List.get`, `List.first`, `List.find`, ...) forward
to the gated slice function and inherit the gate: `xs.get(0)` on a
`List(FileHandle)` is the `#error`, reported at the caller's line (spec §7.7).
`List.set(index, value)` deinits the element it overwrites; the unmanaged
`xs[i] = v` on an owning element type is the `op_set_index` gate.

## `swap`

```flang
pub fn swap(a: &$T, b: &T)
```

`swap` exchanges the two values. No value is duplicated and no value is
released, so there is nothing to gate: exactly the same set of owners exists
before and after. A copyable element goes through a local temporary, which the
C compiler turns into register moves; an owning one cannot be read into a
temporary at all, so its bytes are exchanged in place through a runtime
`memswap(a, b, size)` beside `memcpy`, selected by `#if type_info(T).copyable`.

`reverse` is built on `swap` and works on owning elements as it is. `sort` is
not: powersort merges through a scratch buffer, assigning elements into it, so
it stays unreachable for an owning `T` until that merge is written in terms of
moves.

## Drain

Every container gets a `drain`. The list's:

```flang
pub type Drain = struct(T) {
    owned __list: &UnmanagedList(T)
    taken: usize
    count: usize
    from_back: bool
}

pub fn drain(self: &UnmanagedList($T)) Drain(T)     // count = len; len = 0
pub fn drain_rev(self: &UnmanagedList($T)) Drain(T) // the same, taken from the back
pub fn iter(self: Drain($T)) Drain(T)               // { return move self }
pub fn next(self: &Drain($T)) T?                    // Some(move (self.__list.ptr + at).*)
pub fn deinit(self: Drain($T))                      // the untaken tail moves to the front; len = count - taken
```

`drain_rev` takes from the back, the order `pop` yields, which is what a stack
drains in; its untaken elements are already at the front, so releasing it moves
nothing. `swap_remove(index)` and `remove_at(index)` are added beside `pop` as
the single-element forms E2125 names.

`drain` records the length and zeroes it, so the list reads as empty while the
drain is live and no path through the list's API reaches an element that is
about to be moved. `next` moves the element at `taken` out and advances.
`deinit` memmoves the untaken elements to the front and restores the length as
the number left. A forgotten `deinit` leaks the tail and never double-frees:
the list's own `deinit` walks a length of zero.

`Drain` is non-copyable because `__list` is `owned`: the value is responsible
for handing the tail back, and two copies would hand it back twice. `owned` on
a reference-typed field is accepted and does exactly that: it sets the derived
bit and nothing else (the reference is still a leaf of the walk).

`iter` takes `self` by value and returns it, so `for x in xs.drain()` consumes
the rvalue and `for x in d` on a binding is the inferred move of `d` (spec
§7.2). The loop owns the drain from then on and releases it (below).

The same shape, each in its own file:

| container | type | yields | `deinit` restores |
|---|---|---|---|
| `UnmanagedList` | `Drain(T)` | `T` | the tail, memmoved to the front |
| `UnmanagedDict` | `DictDrain(K, V)` | `(K, V)` | `length` (taken entries are tombstones) |
| `UnmanagedDeque` | `DequeDrain(T)` | `T` | `head` advanced by `taken`, `len` |
| `UnmanagedStack` | `Drain(T)` | `T`, top first | forwards to the list's `drain_rev` |
| `UnmanagedSet` | `SetDrain(T)` | `T` | forwards to the dict |

`List`, `Dict`, `Deque`, `Stack` and `Set` forward `drain` through the managed
template. Since a container reads as empty while drained, `drain` composes with
the container's own `deinit`: `deinit` is `for x in self.drain() { deinit(x,
allocator) }` followed by the free, and a `clear` or `truncate` is a drain over
the dropped range.

What `drain` replaces:

- `to_owned_slice`: removed. Its callers were moving elements out of one list
  into another (`for x in src.drain() { dst.push(move x) }`) or releasing a
  buffer whose elements had already been moved out, which the drain makes a
  plain `deinit`.
- `list(source: T[])` and `unmanaged_list(source)`: removed. They copied a
  slice's elements into fresh storage, which for an owning `T` is a clone per
  element; write `push_all`, which clones, or the loop.
- `filled_list` / `filled_unmanaged_list`: gated on a copyable `T`. `count`
  copies of one owning value are `count` owners.
- `filter`, `remove`, `drop_first`, `take_last`, `reversed`, `zip`,
  `partition`, `uniq`: each returns a new list and leaves the receiver alone,
  so an owning element is cloned into the result under `#if`, the way
  `push_all` does.

## The loop releases its iterator

`for x in xs` resolves `iter` on the iterable as a method call, so a by-value
`iter(self: I) I` is picked for an rvalue or a moved iterable by the receiver
rules already in place. What is new: **when the iterator state's type is
non-copyable, the loop deinits it on every path that leaves the loop.**

The checker resolves `deinit` on the state type beside `iter` and `next`, by
value first and by reference second (reference parity with `next`), and
records the pick on the loop variable's name node. Lowering registers the
call as a defer at loop entry, in a defer scope that wraps the loop, so the
existing unwind machinery fires it once: on fallthrough and `break` at the
exit block, and on `return` and `?` from inside the body as part of the flush
those already do. `continue` does not fire it: the loop is still running.

```flang
for x in xs.drain() {
    if x.fd == 0 { break }         // the drain is released at the exit; the tail is back in `xs`
    if x.fd < 0 { return -1 }      // the drain is released on the way out
    close(move x)
}
```

A `for` variable is bound anew on every iteration, so moving it in the body
says nothing about the next one: the ownership pass clears it from the state it
carries around the loop, which is what makes
`for x in xs.drain() { ys.push(move x) }` the idiom rather than an error.

A copyable iterator state, which is every iterator in tree before this RFC, is
unaffected: there is nothing to release. Nothing here is a consuming `for`,
and nothing dispatches on the element type: `for x in list` over an owning
element type is the `iter` gate above, pointing at `for &x` and `.drain()`.

## `move` operands

RFC-028 admitted every assignment target as a `move` operand and marked
nothing for `p.*` and `base[i]`. That was the lane the known-issues hazard
lives in: a move through an element reference is accepted, and the container
does not know. The rule now:

**The operand of `move` is one of:**

- a binding: `move h`, marking the binding;
- a field path: `move s.h`, `move e.value`, taking the declaring module's
  rights (`E2127` elsewhere), marking nothing;
- an index or a dereference of an `owned` field, optionally followed by a field
  path: `move (self.ptr + i).*`, `move self.__inner.*`, `move (self.ptr + i).*.name`,
  inside the module declaring that field, marking nothing.

Anything else is `E2125`: `move p.*` through a local reference, `move xs[i]`
through a container's `op_index_ref`, `move arr[i]` on a local array. The
element belongs to the container, and only the container can take it out.
`pop` is `Some(move (self.ptr + self.len).*)`; a caller that wants an element out
of the middle writes `swap_remove`, `remove`, or a drain.

The receiver of a consuming call follows the same table (spec §7.2):
`xs[0].close()` is refused where `move xs[0]` is. `E2128` is unchanged: a
by-value non-copyable first parameter reached through a `&T` receiver or an
`op_deref` hop.

## By-value `deinit`

Sequenced after the drain, because the drain is what lets a container release
its elements without reaching through a reference:

```flang
pub fn deinit(self: T)                          // a type that carries its allocator
pub fn deinit(self: T, allocator: &Allocator)   // the element form
```

Both take the value. A second `deinit` on a binding is `E2123`; there is no
disarm write and no idempotence claim, and a value's zero pattern stays safe
to release (an empty list frees nothing) so that a zero-initialised binding
still has a `deinit`. Bodies change shape accordingly: `self.* match` becomes
`self match`, `self.__inner = null` and `self.* = None` go.
`Owned(T).__cleanup` becomes `fn(T) void`.

Callers keep `x.deinit()` and `defer x.deinit()`: the receiver is the inferred
move. A site that released through a `&T` or an index restructures through
`pop`, `swap_remove`, `set` or a drain, never through `move p.*`.

## Diagnostics

`E2125` is reworded from "not an lvalue" to "not a place `move` can take
from", with the operand table above. `E2127` and `E2128` are unchanged.

## Tests

`tests/harness/ownership/`:

- `move_deref` and `move_index_element` flip to `E2125`; `move_owned_index_inside_module`
  and `move_owned_deref_inside_module` are the positives, `move_owned_index_outside_module`
  the `E2125` through a public `owned` field from another module.
- `receiver_index_element` flips to `E2125`.
- `drain_loop_break_keeps_tail`: a `break` in a drain loop leaves the untaken elements in the list.
- `drain_loop_return_releases`: a `return` from inside a drain loop deinits the drain.
- `for_over_owning_elements`: `for x in list` over an owning `T` is the `iter` gate.
- `swap_owning_elements`: `swap` and `reverse` over owning elements.
- `forgotten_drain_leaks`: a drain never released leaks the tail and releases nothing twice.
- `owned_reference_field`: `owned` on a `&T` field makes the struct non-copyable.

## Sequencing

1. This document; spec §7.2, §7.4, §9.4; `docs/error-codes.md` E2125; RFC-028
   step 8 becomes gates rather than deletion; RFC-016 superseded.
2. Compiler: the `move` operand rule in `check_move` and `own_receiver`; the
   `deinit` pick in `resolve_for_protocol` and the wrapped defer scope in
   `lower_for_iter`. Harness tests. Seed promote: the stdlib is about to lean
   on the loop release and the `#error` gates.
3. Stdlib: `memswap`; the slice gates and `_ref` twins; `Drain` on every
   container; `to_owned_slice`, `list(source)` and the copying constructors
   go; `clear`/`truncate` through the drain; the cloning transformations.
4. By-value `deinit`, stdlib first, then each library in dependency order,
   driven by the checker.
5. RFC-028 implemented; `docs/known-issues.md`; promote.

## Open

Two follow-ups RFC-028 already names, not taken here: lambda captures are
by-value copies of the captured bindings, which the ownership pass does not
see; and the two scope-exit leak warnings (a non-copyable binding live at
exit, never moved; a discarded owning rvalue).
