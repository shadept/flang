# RFC-027: `owned` fields, non-copyable types, and `move`

**Type:** Language feature (field modifier + expression form) + compiler check
**Status:** Draft
**Depends on:** None
**Relates to:** spec §3.1 (assignment), §3.2 (function arguments), §3.4.1 (place
expressions), §7.5 (match binding mode), §4.1 (allocator pattern); RFC-026
(copy-on-write parameters); RFC-020 (`op_deref` argument coercion); RFC-016
(`#auto_deinit`)

## Summary

Copyable is the default and stays the default. A type that is responsible for
releasing a resource cannot be copied, because a copy duplicates the release
responsibility with no way to say which value holds it.

Three pieces:

1. **`owned`** — a field modifier declaring that the field holds a resource the
   value must release. A claim, not a verified fact, like `#foreign`.
2. **A derived per-type bit** — a type is **non-copyable** if any field is
   declared `owned`, or if any field's own type is non-copyable. Derived, never
   authored.
3. **`move`** — the expression form that says a use is a transfer, not a copy.
   Emits nothing. Marks the source dead.

The check is: **a copy of a non-copyable value is an error unless it is a
move.** Nothing else. Use-after-free, leaks, double-release and aliasing remain
the programmer's responsibility (§3.6).

## `owned`

```flang
type FileHandle = struct { owned fd: u32 }
type Buffer     = struct { owned ptr: &u8, len: usize }
```

`owned` is a contextual keyword in struct field position: a modifier when
followed by an identifier, a field name when followed by `:`.

Ownership originates on struct fields only. An enum variant payload propagates
the bit but cannot declare it — wrap a scalar resource in a struct.

`owned` is part of the type's identity: two structs differing only in `owned`
are different types and participate in the canonical rendering used by the type
interner (RFC-024).

## The derived bit

A type is non-copyable if any field is declared `owned`, or if any field's type
is non-copyable. Enum variant payloads count as fields.

**Leaves** (do not recurse): `&T`, slices `T[]`, function types.
**Recurse:** struct fields, enum variant payloads, tuple elements, fixed arrays.

Because pointers and slices are leaves, the walk is post-order with no fixpoint:
a by-value field cycle cannot exist (infinite size), and every other cycle
passes through a leaf.

The bit is a property of the *type*. A field declared `owned` whose type is
itself copyable reads as copyable through field access: given
`type Buffer = struct { owned ptr: &u8 }`, `b.ptr` is a `&u8` and copying it is
unchecked. `Buffer { ptr = other.ptr }` is likewise unchecked.

Exposed as `T.copyable` on `TypeInfo` alongside `T.fields`, plus the first field
that cleared it, for diagnostics.

## What counts as a copy

A copy is reading an **lvalue** into a second location (§3.4.1). The original
keeps its storage and the result gets its own, so both are usable afterwards —
which for a non-copyable type means two values responsible for one resource.

An **rvalue** has no storage of its own. Nothing is duplicated when it is bound,
passed or stored, so an rvalue is never a copy and never needs `move`:
`close(open("f"))` is a transfer with nothing left behind.

Copies of a non-copyable type — the lvalue sites:

| site | example |
|---|---|
| rebinding | `let b = a`, `b = a` |
| by-value argument | `close(h)`, `xs.push(s)` |
| by-value return of a local | `return h` |
| struct literal field | `Wrapper { h = h }` |
| element store | `xs[i] = h` |

Not copies:

- Every rvalue — call results, literals, struct literals, `match` and `if`
  results.
- An lvalue whose own type is copyable — `h.fd`, `&cfg.name`.
- Aggregate pattern bindings. Per §7.5 they name the scrutinee's storage, so
  `opt match { Some(v) => ... }` binds `v` to an existing lvalue rather than
  producing a second one.
- Anything reached through `&T`: a borrow reads the lvalue without duplicating
  it.

**By-value arguments are copies.** Copy-on-write (§3.2, RFC-026) is an
implementation guarantee, not a semantic one: a callee's change cannot affect
the caller regardless of whether a shadow is materialised.

## `move`

`move` is a prefix operator over an lvalue. It marks that lvalue's binding moved
from that point on and emits no code. An rvalue operand is `E2124`: there is no
storage to take, and nothing would be left behind to mark.

```flang
let b = move a          // rebinding
close(move h)           // by-value argument
(move h).close()        // UFCS receiver
Wrapper { h = move h }  // struct literal field
xs[i] = move h          // element store
return move h           // by-value return of a local
move h.fd               // error: partial moves are out in v1
```

**Any lvalue is a valid operand.** If you can assign to it, you can move from
it — the operand grammar of `move` is the grammar of an assignment target
(§3.4.1). What differs between the four lvalue forms is what the move marks:

| operand | marks |
|---|---|
| `x` — a binding | `x` moved |
| `p.*` — a dereference | nothing |
| `base[i]` — an index | nothing |
| `base.field` — a field | nothing; requires scoped-mutability rights |

`p.*` marks nothing because a pointer carries no ownership: references are how
FLang shares a value, and they are leaves of the derivation. There is no binding
behind the dereference to put in the moved state, so the move is unchecked — the
same lane as reading an `owned` field whose own type is copyable.

`base[i]` is not a special form. Indexing desugars to the ref-form operator
(§5.2), so `xs[i]` is `op_index_ref(xs, i)`: `xs` and `i` are ordinary
arguments checked by the ordinary rules, and the move applies to the `&T` it
returns. That is the `p.*` case, and it is unchecked for the same reason.

`base.field` carries one rule and no tracking: **moving a field requires the same
rights as writing one** — the module that declares the type (§scoped mutability,
`E2114`). Outside it, the move is `E2126`. Inside it, nothing further is checked
in v1: the base is not marked, the field is not tracked, and the base stays
usable.

This is what lets a type disassemble itself. A field whose own type is
non-copyable can only be reached from `deinit` and the type's other methods, and
those are in the declaring module by definition:

```flang
type Session = struct {
    conn: HandleBundle
    log: HandleBundle
}

fn deinit(self: Session) {
    (move self.conn).deinit()
    (move self.log).deinit()        // both fine: same module, nothing marked
}
```

The rule is a permission, not an analysis. It stops a consuming library from
taking a resource out of someone else's type, and leaves the declaring module
free to do what it needs — including getting it wrong. A double release built
out of partial moves inside the declaring module is the author's to avoid, the
same lane as `p.*`.

Most owned fields never reach this rule at all. `owned` marks the *field* while
the bit is on the *type*, so a resource held as a handle or a view has a copyable
field type and reads freely:

```flang
type HandleBundle = struct {
    owned a: u32
    owned b: u32
}

fn deinit(self: HandleBundle) {
    close(self.a)                   // `self.a` is a u32: an ordinary read
    close(self.b)
}
```

Reassembly needs no rule of its own: `self.conn = make()` is a field write, so it
is already governed by scoped mutability and already permitted in the same
places.

A site **consumes** when its destination is a by-value slot of a non-copyable
type, or a parameter declared `move`. The two rules are symmetric:

- `move` missing at a consuming site is `E2123`.
- `move` written at a site that does not consume is `W2004`. It does nothing —
  a warning, not an error, so a `move` that survives a type changing from
  non-copyable to copyable does not break the build.

A `move` parameter therefore consumes a copyable type, and its call sites are
required to say so — the keyword is doing work there, not describing the type.

The exception to `W2004` is a **type parameter**: in a generic body, `move value`
where `value: T` is written once and serves every instantiation. It is diagnosed
against the type as written, so a `T` that resolves to `i32` at one
instantiation is not an error there.

```flang
fn push(self: &List($T), value: T) {
    // ...
    data[self.len - 1] = move value     // `T` is a type parameter: accepted
}

let n = 3
let m = move n                          // warning W2004: `i32` is copyable
```

### Where it is required

**`move` is required at every site that would otherwise be a copy** — rebinding,
by-value argument, UFCS receiver, struct literal field, element store, by-value
return of a local. A copy of a non-copyable value without it is `E2123`.

A later phase makes the keyword omittable where a signature already states the
transfer — a by-value parameter and a `return` type. Relaxing a requirement
never invalidates existing source; the strict form comes first for that reason.

**Always accepted where a move happens.** The set of positions the LSP renders
a ghost `move` on and the set the parser accepts an explicit `move` in are the
same set. The UFCS receiver is written `(move h).close()`, which is therefore
the ordinary spelling for a consuming method.

### Parameter side

`move` on a parameter is legal and additive: it makes a by-value parameter
consuming for a **copyable** type. It is never required, and it is redundant on
a parameter whose type is already non-copyable.

> A by-value parameter consumes if its type is non-copyable **or** it is
> declared `move`.

Generic sinks need no annotation: `fn push(self: &List($T), value: T)` consumes
`value` at instantiations where `T` is non-copyable and copies it elsewhere.

## Liveness

A binding of a non-copyable type is in one of two states: **live** or **moved**.
It starts live at its initializer, `move` takes it to moved, and an assignment
takes it back to live.

- Use of a moved binding is `E2122`.
- Assignment over a **live** binding is `E2125`: the old value is overwritten
  and whatever it held is leaked.
- Assignment over a **moved** binding reinitializes it.

```flang
let h = open("a")
h = open("b")           // error E2125: `h` is live
close(move h)
h.fd                    // error E2122: `h` was moved
h = open("b")           // ok: reinitializes a moved binding
h.fd                    // ok
```

The check runs over a CFG. Merge points are not tracked with drop flags: a
value moved on some paths into a merge is moved at the merge.

```flang
if c { close(move h) }
h.fd                    // error E2122: `h` moved on one path
```

### Defer

A `defer` body is an ordinary statement whose **effects happen at scope exit**.
Spec §4.1 fixes the order: *a `return expr` evaluates `expr` first, then fires
the active defers in LIFO order, then transfers control.* Liveness is therefore
checked **at the point the body runs**, not where it is written, and on every
path that exits the scope — `return`, `break`, `continue`, and falling off the
end.

That one rule covers everything a defer can hold; the consequences follow from
it rather than from anything specific to `deinit`.

**A return expression that moves the value the defer touches.** The return runs
first, so the deferred statement sees a moved binding. This holds whether the
body moves it again or only reads it:

```flang
let h = open("f")
defer (move h).deinit()
return move h
//     ^^^^^^ `h` is moved here, before the defer runs
// error E2122: `h` was moved and cannot be used
//   moved at line 3 by the return expression
//   the deferred call on line 2 runs after it
```

```flang
let h = open("f")
defer log(h.fd)                 // reads `h` at scope exit
return move h                   // error E2122: same reason
```

This is spec §4.1's prose warning ("don't defer-deinit a value you're returning
by value") turned into a diagnostic, and it now covers the reading case the
prose did not. Read the field into a local first if the defer needs it:

```flang
let h = open("f")
let fd = h.fd                   // `fd` is an i32
defer log(fd)
return move h                   // ok: the defer no longer names `h`
```

**A return expression that does not move it.** The common stdlib shapes are
unaffected, because they borrow:

```flang
let sb = string_builder(64)
defer (move sb).deinit()
return sb.to_string()           // `to_string` takes `&StringBuilder`
```

**Several defers.** They fire LIFO, so the last registered runs first and the
earlier ones see its effects:

```flang
defer (move h).deinit()         // runs second — error E2122
defer (move h).deinit()         // runs first
```

**A defer registered after a move.** The binding is already moved when the body
runs, so the body is checked against that state:

```flang
close(move h)
defer (move h).deinit()         // error E2122
```

**Block scope.** A defer fires at the end of its own block, not the function's,
so a move in a nested block's defer is confined to that block:

```flang
{
    let h = open("f")
    defer (move h).deinit()     // fires here
}
```

**Loops.** A defer in a loop body fires each iteration, so one that moves a
binding declared outside the loop moves it more than once:

```flang
let h = open("f")
for _i in 0..2 {
    defer (move h).deinit()     // error E2122 on the second iteration
}
```

**Exit paths must all be valid.** A defer that moves a binding is checked
against every path that leaves the scope, including `break` and `continue`
unwinds. If any path has already moved it, the defer is an error on that path.

**Bodies that name nothing owned** — a counter bump, a log of an unrelated
value, a call taking `&T` — are unaffected. Most defers are in this class or in
the `deinit` class; the rule is the same one for both.

`?` is already forbidden inside a defer body (E2091), so a defer has no early
exit of its own to reason about.

## Deinit

`deinit` takes its receiver by value and consumes it. Releasing a resource makes
the value unusable, and the by-value parameter is what states that.

```flang
fn deinit(self: FileHandle)

(move h).deinit()               // moves `h`
defer (move h).deinit()        // the move happens at scope end
```

`defer (move h).deinit()` is therefore the terminal move of `h`, which makes the
discipline in spec §4.1 ("don't defer-deinit a value you're returning by
value") a diagnostic rather than a comment. See Liveness below for the rule.

A container's element loop deinits through a pointer:

```flang
for i in 0..self.len {
    const elem: &T = self.ptr + i
    (move elem.*).deinit()
}
```

`elem` is a `&T` and `deinit` takes `T` by value, so the call moves through the
dereference. This is the value leg of RFC-020 into a consuming parameter, and it
is unchecked for the reason above — there is no binding to kill.

The element loop is gated on whether the element type has a `deinit`, resolved
per specialization, not on the non-copyable bit. This is the fix recorded in
`docs/known-issues.md` under "The Blanket `deinit(&$T)` Silently Wins Over an
Element's Own", and it retires the blanket `deinit(&$T)`.

`deinit` needs no `move` on its parameter: for a non-copyable type the by-value
parameter already consumes, and for a copyable type there is nothing to
invalidate.

Two consequences for RFC-016:

- A `deinit` that disarms itself by writing through `&self` (`Rc.__inner = null`)
  no longer reaches the caller. It does not need to: a second `deinit` on a live
  binding is a compile error. Invariants 1 and 3 hold only for the unchecked
  lanes.
- `#auto_deinit`'s inserted `defer (move x).deinit()` is a move. The follow-up must
  define the insertion so that the consuming call does not itself schedule a
  deinit of its own parameter.

## Diagnostics

The error on use after move names the move site and the derivation chain:

```
error[E2122]: `h` was moved and cannot be used
  moved at line 12: `close(move h)`
  `FileHandle` is not copyable: field `fd` is `owned`
```

```
error[E2123]: `h` cannot be copied here — use `move h`
  `FileHandle` is not copyable: field `fd` is `owned`
```

New codes:

- `E2122` — use of a moved value.
- `E2123` — a consuming site requires `move`.
- `E2124` — `move` operand is not an lvalue.
- `E2125` — assignment over a live non-copyable binding.
- `E2126` — partial move outside the module declaring the type.
- `W2004` — `move` at a site that does not consume (warning).

The derivation chain is required on `E2123` as well: virality is unreadable
without it. For a type that is non-copyable transitively, the chain names every
hop:

```
  `Config` is not copyable: field `paths` is `List(OwnedString)`
    `List(OwnedString)` is not copyable: field `ptr` is `owned`
```

A copy rejected inside a generic body is reported at the instantiation site, not
at the generic's source. `xs.get(0)` on a `List(FileHandle)` names the call, with
the stdlib frame as a note.

## LSP

- Ghost `move` inlay at every derived move position, rendered distinctly from a
  written one.
- Ghost `owned` on fields whose type is non-copyable, rendered distinctly from a
  declared one, plus the bit on the struct header.

## Out of scope

- Tracking which fields of a base have been moved. Inside the declaring module a
  partial move is unchecked; outside it is refused.
- Use-after-deinit, double-release, leak detection, escape analysis.
- Aliasing: a `&` taken before a move is not tracked.
- `arena.reset()` — accepted as unchecked.
- Consuming a copyable type by any route other than an explicit `move`
  parameter.

## Sequencing

1. **Convert read-only by-value signatures to `&`.** `Dict.len/is_empty/get/`
   `get_ref/contains/get_or/get_or_else`, `List.as_slice/get/get_ref/op_index/`
   `first/last/contains/index_of`, `Set.len/is_empty/contains`,
   `Stack.len/is_empty/peek/as_slice`, `Deque.is_empty/peek_front/peek_back`,
   `OwnedString.as_view/op_eq/hash/bytes/chars`, `test.assert_seq_eq/`
   `assert_set_eq`. ~44 signatures. Independently justified by RFC-026; no
   semantic change.
2. **Lazy `$"..."`** producing a struct implementing `format`; delete
   `print`/`println(OwnedString)`. An rvalue argument carries no move
   obligation, so a consuming function called on a temporary is otherwise
   unchecked.
3. **Seed promote:** parse `owned` and `move`, derive the bit, expose
   `T.copyable`. No enforcement.
4. **Enforcement**, warning first, then error.
5. **Annotate leaf resource types** — `File.fd`, `OwnedString.ptr`. `List` and
   `Dict` last.
6. **Per-specialization element `deinit` resolution**; retire the blanket.
7. **Remove what the check rejects for non-copyable `T`:** `get`, `first`,
   `last`, `peek`, `peek_front`, `peek_back`, `get_or`, `get_or_else` — the
   element stays in the container, so the return is a second owner.
   `pop`, `pop_front`, `pop_back`, `remove`, `take_last`, `to_owned_slice`
   stay: the element left the container.
   Also removed: `filled_list`, the `list(source)` memcpy constructor, the Dict
   fake-key.

Adding `copyable` to `core.rtti.TypeInfo` changes its layout and is its own
promote commit. `TypeInfo` is materialised at lowering with a depth cap that
nulls nested `type_info` pointers, so the bit is computed from the compiler's
`Ty` and filled at every level, never derived by walking the materialised
record.

## Tests

`tests/harness/ownership/`, each self-contained with a local
`type FileHandle = struct { owned fd: i32 }`. Written first as
`//! SKIP: RFC-027 not implemented`.

### E2123 — a consuming site requires `move`

`copy_let_binding`, `copy_assignment_after_move`, `copy_call_argument`,
`copy_ufcs_receiver`, `copy_struct_literal_field`, `copy_element_store`,
`copy_array_literal_element`, `copy_tuple_element`, `copy_return_local`,
`copy_via_list_get`, `copy_via_by_value_loop`, `copy_transitive_chain`.

The last two pin diagnostic attribution: the copy happens inside `list.f`, and
the error must name the caller's line.

### E2122 — use of a moved value

Straight line: `use_after_move_let`, `use_after_move_arg`,
`use_after_move_receiver`, `use_after_move_deinit`, `move_twice_one_call`,
`move_then_address_of`, `move_then_ref_param`.

Control flow: `use_after_move_if_branch`, `use_after_move_if_else_both`,
`use_after_move_match_arm`, `use_after_move_while_body`,
`use_after_move_loop_body`, `use_after_move_for_body`,
`use_after_move_nested_block`, `use_after_move_after_break`.

Expression positions: `move_in_if_expression_value`, `move_in_match_result`,
`move_in_block_expression`, `move_in_short_circuit`,
`move_in_question_operator`.

Evaluation order (§5.1.1, left to right): `move_then_read_in_arg_list`
(`f(move h, h.fd)` fails) and `read_then_move_in_arg_list`
(`f(h.fd, move h)` compiles).

Defer, all following from "the body runs at scope exit":
`defer_move_then_return`, `defer_read_after_return_move`,
`defer_read_captured_before_return`, `defer_move_twice`,
`defer_registered_after_move`, `defer_in_loop_body_moves`,
`defer_nested_block_scope`, `defer_unrelated_value`,
`defer_move_on_break_path`, `defer_borrowing_return`.

### E2124 — `move` operand is not an lvalue

`move_call_result`, `move_literal`, `move_arithmetic`, `move_match_result`.

### E2126 — partial move outside the declaring module

`move_field_outside_module`, `move_field_inside_module` (positive),
`move_field_two_owned_fields` (positive — the `Session` shape),
`move_field_through_reference` (also E2126 outside the module).

Index operands are lvalues and unchecked: `move_index_element`.

### E2125 — assignment over a live binding

`assign_over_live_binding`, `assign_over_moved_binding_ok`,
`assign_over_live_in_loop`.

### W2004 — `move` at a site that does not consume

`move_on_copyable`, `move_copyable_field`, `move_copyable_struct`.

### Positives

`copyable_field_read`, `borrow_stays_live`, `rvalue_argument`,
`move_param_on_copyable`, `pattern_binding_borrows`,
`for_ref_loop`, `move_deref`, `move_index_element`, `receiver_paren_form`,
`derived_bit_leaves`, `derived_bit_transitive`, `owned_fields_copyable_types`,
`move_in_both_branches_unused_after`, `reinit_after_move`.

### Runtime behaviour

`move_arg_runtime`, `deinit_runs_once`, `container_element_deinit_runs`.

### Harness

`//! COMPILE-ERROR: <CODE> <substring>` asserts the rendered output contains the
substring, so message content is testable without a new directive. The
attribution tests assert their own filename appears in the diagnostic, which is
what distinguishes a copy reported at the call site from one reported inside
`stdlib/std/list.f`.
