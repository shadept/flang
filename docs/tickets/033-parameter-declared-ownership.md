---
status: draft
type: language
created: 2026-09-14
relates: [RFC-028, RFC-030, RFC-026, RFC-019, RFC-014]
---

# RFC-033: Parameter-declared ownership

## Summary

A function states ownership in its signature, never at its call sites.

- `x: &T` shares `x` with the function.
- `x: move T` moves ownership of `x` into the function.
- `x: T` gives the function read access to `x`. The caller's value is never affected. Whether the
  function may copy it follows the copy rules of `T`, as for any binding.

This replaces RFC-028's parameter rules, where `x: T` consumed whenever `T` was non-copyable and
every call site had to write `move`. It also removes the need for RFC-030's reference-form operator
dispatch.

## What RFC-028 got wrong

RFC-028 tied what a function does to the copyability of its argument. `fn f(x: T)` copied a
copyable `T` and consumed a non-copyable one: the caller's binding survived the call or died,
depending on the type. A read-only function over an owning type had to take `&T`. For concrete code
that is a nuisance. For generic code it has no answer: a generic body cannot know which spelling
reads.

The stdlib on `client_ownership_semantics` shows the cost. Every combinator that calls back picks
per element type:

```flang
#if type_info(T).copyable {
    hit = pred(s[i])
} else {
    hit = pred(s.ptr + i)
}
```

More than 50 such gates, callback signatures that change with the element type (`fn(T, T) Ord` for
`i32`, `fn(&T, &T) Ord` for anything holding a `List`), and a sort that had to be rewritten to reach
owning elements. Every author of a combinator library, a server or an engine would inherit the same
split, since any struct holding a list is non-copyable. That is function colouring by copyability,
and it comes from the language, not the library.

C++ avoids it because a reference binds with no marker at the call site. Swift, Hylo and Mojo avoid
it by putting the convention on the parameter: read by default, consume declared. This RFC takes the
second route. `move T` already parses (RFC-028, `name: move T`).

## Branches

```
                         client_ownership_semantics
                        +- 8ae1227 .. f1ec4bf   RFC-028 applied to the stdlib
                        |
... -- dad7fc5 -- e3a2970
                        |
                        +- main                  ownership in the compiler, opt-in
                        +- consumer_ownership_semantics   this RFC
```

`main` stays at `e3a2970`: the compiler knows `owned`, `move` and liveness, the stdlib does not use
them. Both semantics are completed side by side. Work that is not about ownership lands in all three
branches.

## Rules

1. **`x: &T` shares `x`.** Unchanged.
2. **`x: move T` moves ownership of `x` into the function.** A non-copyable binding passed to it is
   dead after the call. A copyable one is copied and stays live.
3. **`x: T` is read access to `x`.** The caller's value is unaffected. Inside the function, `x`
   follows the copy rules of `T` like any other binding: a copyable `x` may be copied, written
   (the function's own copy) and returned; a non-copyable `x` may be read and passed on to another
   `T` parameter; sharing it (`&x`), and anything that needs a copy or ownership, is refused.
4. **`move` is noise on a concrete copyable type.** On a type parameter it is meaningful: `push` is
   written once for every element type.
5. **`x: move &T` is an error.** A reference is copyable; owning it says nothing about the value it
   refers to.
6. **Call sites carry no ownership marker.** `move` is removed from argument position; an explicit
   `f(move x)` is an error.
7. **Rvalues need nothing.** A temporary goes straight to the parameter; nothing is marked.
8. **A non-copyable rvalue must reach an owner.** A temporary that lands where nothing takes
   ownership - a `T` parameter, a read-only receiver, an operator operand, a field read, a discarded
   result - is never released. That is an error.
9. **A place cannot be moved or shared while the same call reads it.** Arguments evaluate left to
   right, but the call receives them together: a place passed to a `move T` or `&T` parameter, and
   an overlapping place passed to any other parameter of the same call, is an error when the overlap
   holds owned state - the argument is non-copyable, or reached through an `owned` field or a
   container element.
10. **A base with a field moved out is incomplete until the field is assigned.** Moving a field out
    of a binding the function owns marks that field. Using the field, anything below it, or anything
    that encloses it - the binding itself, an enclosing field - is E2123; siblings stay usable.
    Assigning the field makes it live again; assigning it while live leaks what it holds (E2126);
    assigning the whole binding is allowed once every non-copyable field has left it.

```flang
fn push(self: &List($T), value: move T)
fn route_cmp(a: Route, b: Route) Ord
fn op_eq(a: OwnedString, b: OwnedString) bool

list.push(0)            // copyable: copied, nothing changes for the caller
list.push(handle)       // non-copyable binding: `handle` is dead after this line
list.push(rc.retain())  // rvalue: the list owns the new reference, `rc` is untouched
list.push(xs[0])        // error E2125: an element leaves through `pop`, `remove` or a drain
```

## Inside the function

A `move T` parameter is a binding the function owns. Every path out of the function hands it on or
releases it, under the same liveness rules as any binding (E2123, E2126).

A `T` parameter is a binding the function may only read, unless the type allows copies:

```flang
fn keep(s: &Server, r: Route) {
    s.routes.push(r)        // error: `r` is not owned here; declare `r: move Route`
}

fn reset(r: Route) {
    r.hits = 0              // error: writing `r` needs a copy of `Route`
}

fn pass_on(r: Route) Route {
    return r                // error: returning `r` needs a copy of `Route`
}

fn share(r: Route) {
    hit(&r)                 // error: `r` is not the function's to share
}

fn bump(n: i32) i32 {
    n = n + 1               // fine: `i32` copies, the caller's value is unaffected
    return n
}
```

## Moving a field out

Rule 10 closes the lane RFC-028 left unchecked, where a partial move marked nothing:

```flang
fn shutdown(self: move Server) Server {
    self.log.close()
    return self                     // error E2123: `self` is incomplete: field `log` was moved out
}

fn rotate(self: move Server) Server {
    self.log.close()
    self.log = open_log()           // the base is whole again
    return self
}
```

A place reached through a container's `owned` storage is not tracked: `slot.key = move
(self.entries + i).key` stays the element-store form containers use. A `deinit(self: move T)` that
moves every field out and never uses `self` whole needs nothing further.

**What `move` may take** (2026-09-16, one rule for both spellings since 2026-09-17). A binding, a
field of a binding the function owns, the value in a `&move` slot, or a place reached through an
`owned` field of a type the module declares. Anything else is E2131 for a plain field, E2125 for an
element or dereference. Handing a place to a `move` parameter is checked exactly as `move` in front
of it. Taking out of one's own `owned` storage is the read side of the element store above, and
the gate is the same scoped-mutability right. Without it, `fn take(slot: &$T) T { return move
slot.* }` in any module would turn a lent reference into ownership, which is how the first cut of
the container sweep smuggled elements out. A plain field is not storage the type releases, so rule
3 governs it in the declaring module too; `replace(&self.f, fresh)` takes one through a reference.
The chain is read syntactically, so a container writes `move (self.entries + i).key`, not a local
`&Entry` binding first.

When a field has no value to put back, the field is optional, a null object stands in for it, or
the function consumes its owner and returns a different type.

## `&move T`, the slot mode

A fourth mode, added 2026-09-16. `x: &move T` is `&T` plus the right to take the value out, against
the obligation to put one back before the function returns (E2137). The caller keeps the slot; what
is in it may differ afterwards.

It exists because nothing else can write `swap`: exchanging two owning values needs each value to
leave its storage, and `&T` shares without granting that. The first cut used a byte-level
`memswap`, which is the escape hatch this mode removes.

Restrictions, because a call site cannot see that its value is being replaced:

- **Declarable in `core` alone** (E2136). Every other module reaches it through `core.slice`'s
  `swap` and `replace`. Calling is unrestricted.
- **Parameter position only** - never a field, a return type or a binding's type - so the right to
  empty a slot cannot outlive the call that granted it, which matters in a language with no
  lifetimes.
- **No `take(slot) T`.** It would have to refill with a zeroed stand-in, and for `FileHandle { owned
  fd: i32 }` that is fd 0, standard input. `replace` makes the caller name what goes back.

What it does not claim is exclusivity: a second alias reading the slot inside the emptied window
sees dead bytes, and FLang does not track aliasing (§3.6). Rule 9 covers the case that matters,
`swap(&h, &h)`, since both arguments are claims on one place.

## Scoped mutability

The file declaring `T` gets no extra rights on a `x: T` parameter. Its field rights apply through
the other two modes:

- `x: T` - a copyable `T` writes the function's own copy, as anywhere; a non-copyable `T` can
  neither write a field (needs a copy) nor move one out (needs ownership).
- `x: &T` - fields of the shared value may be written.
- `x: move T` - fields may be written and moved out.

Outside the declaring file, field writes stay E2114 and field moves E2127 under every mode.

## `deinit`

Releasing a value needs ownership of it:

```flang
fn deinit(self: move T)
fn deinit(self: move T, allocator: &Allocator)
```

`self: T` can read the value but not release it. `self: &T` would release a value the caller still
holds. `x.deinit()` leaves `x` dead.

## Receivers and returns

The receiver follows the parameter: `h.close()` with `close(self: move FileHandle)` kills `h`, and
`xs.len()` with `len(self: List(T))` reads. RFC-028's receiver rule, the `MoveInference` seam and
`client_ownership_semantics`'s inferred receiver move have nothing left to infer. A `move self`
parameter is not reachable through a `&T` receiver or an `op_deref` hop (E2128, kept).

`return h` of a binding stays a move. The other move positions (`let b = move a`, struct literal
fields, element stores) keep `move` for now; whether they drop it too is evaluated separately.

## Callbacks and closures

Callback parameters use the same three modes. A combinator invokes `f(s[i])` once, for every
element type:

```flang
pub fn count_if(s: $T[], pred: $F) usize {
    let n: usize = 0
    for i in 0..s.len {
        if pred(s[i]) {
            n = n + 1
        }
    }
    return n
}

xs.count_if(fn(r: Route) bool { return r.hits > 0 })
```

**What stays coloured is ownership.** A function that takes ownership cannot be passed where a value
is only lent:

```flang
list.each(deinit).map(...)          // error E2125: `each` lends `s[i]`, `deinit` needs ownership
list.deinit()                       // the container releases its elements
for x in list.drain() {             // or each element is handed over
    x.deinit()
}
```

The refusal is correct on its own: `map` would run over released elements. The diagnostic points at
the argument through the instantiation site, not inside `each`. A `fn(v: move i32)` passed to `each`
over `i32` compiles, by the same copy rule that makes `let b = xs[0]` work for `i32` and fail for
`Route`.

A capturing closure is a synthesized struct with `op_call(self: &__Closure_N, ...)`. Every capture
is by reference: reads see the binding's current value, writes reach it, and moving a capture out
is an error.

```flang
let c: usize = 0
values.each(fn(v) { c = c + 1 })
println(c)                  // the element count
```

This retires E2112 and E2113: a nested closure takes its captures from the enclosing closure's
environment. A closure that outlives a captured binding dangles, under the same rules as a
returned `&local`.

## Generic bodies

A generic body is valid for every instantiation or for none. Inside it, a type that mentions one of
the function's type parameters is non-copyable - `T`, `Box(T)`, `List(T)` - because nothing says it
copies. A type that mentions none (`Point`, `i32`) keeps its own bit.

```flang
type Box = struct(T) { value: T }

fn foo(self: move Box($T)) T {
    let a = self.value              // error E2124: `Box(T)` copies only when `T` does
    return self.value
}
```

Without the rule this body compiles for `Box(i32)`, and fails at the first instantiation with a
non-copyable `T`, reported on that caller's line: the author never sees it. With the rule it fails
at any instantiation, and with RFC-029 without one.

A function that copies `T` on purpose says so with a bound (RFC-019 §2.6):

```flang
pub fn max(s: $T[]) T? where T: copyable

max([1, 2, 3, 4])                   // fine
max(handles)                        // error: `max` requires `T: copyable`
                                    //   `FileHandle` is not copyable: field `fd` is `owned`
```

Inside `max`, `T` copies. The active branch of `#if type_info(T).copyable` counts the same way, so
behaviour that really differs per element type (clone versus copy, the `deinit` cascade) needs no
bound.

The functions that return or store an element by copy take the bound: slice `get`, `first`, `last`,
`find`, `min`, `max`, `min_by`, `max_by`, `fill`, `filled_list`, dict `get` and `get_or`, and their
kind. An element leaves a container for any `T` through a `_ref` twin, a reference-returning
variant, or `pop`, `remove` and a drain.

Open:

- **Implementation.** At an instantiation the ownership pass sees substituted types, and `Box(i32)`
  does not record that `i32` came from `T`. Either the template's types reach the pass, or the pass
  runs with a non-copyable stand-in for each type parameter.
- **Error code** for an unsatisfied bound, and which candidate it names when several overloads
  compete.
- **Specificity.** Whether a bounded overload outranks an unbounded one of the same shape
  (RFC-019 §2.5).

## Moving and lending in one call

```flang
fn h(a: Route, b: move Route)
fn j(a: &Route, b: move Route)
fn k(name: OwnedString, r: move Route)

h(x, x)             // error: `x` is lent to `a` and moved into `b`
j(&x, x)            // error: same
k(x.path, x)        // error: `x.path` overlaps `x`
h(y, x)             // fine: distinct bindings
xs.concat(xs)       // error: one owned buffer, shared and read
g(xs[0], &xs)       // error: the element lives in the buffer `g` may grow
take(r.hits, r)     // fine: `hits` is plain data, the argument is a copy
```

The function would own, release or grow a value it is also reading. What stays the programmer's
responsibility (§3.6) is aliasing with no owned state in the overlap, and aliasing through a
reference, which the check does not follow.

## Owning rvalues

Rule 8 in practice:

```flang
route_count(make_server())      // error: `Server` reaches no owner
make_server()                   // error: discarded
open("f").is_ok()               // error: read-only receiver
make_a() == make_b()            // error: operands are read

let s = make_server()           // fine: `s` owns it
defer s.deinit()
route_count(s)
```

Leaking is not wrong in itself: a short-lived program may leave its resources to process exit. The
intended default is a warning that a build can promote to an error. The diagnostic system has no
per-diagnostic severity control today, so rule 8 is an error until it does (follow-up below).

## Compared with RFC-028

RFC-028 is a push model: the caller marks where ownership changes hands, at every call
(`xs.push(move h)`). RFC-033 is a pull model: a function declares that it takes ownership during
its body (`value: move T`), once. More signatures carry `move`, because more functions do take
ownership, and every call site of them is shorter.

- **Visibility.** A transfer no longer shows at the call. Use after the transfer is still E2123, and
  the LSP renders the implied `move` inline. Keeping a mandatory call-site `move` would bring back
  either the gates or a `move` on copyable arguments too.
- **Forgetting the marker.** RFC-028: a reader missing `&` consumed its argument, reported later as
  a use-after-move in the caller. RFC-033: a sink missing `move` fails inside its own body, where
  it tries to keep the value.
- **Wrappers.** A read method reaches through `op_deref` (`rc.len()`); under RFC-028 a by-value
  receiver through a hop was E2128 on owning types.
- **Inference.** RFC-028's receiver and return inference are gone; the signature decides.
- **Aliasing.** A by-value owning argument could not be aliased under RFC-028, since it was moved.
  A `T` parameter can be: rule 9 covers the ownership case, the rest is §3.6.
- **Leaks.** Readers now take `T`, so rule 8 fires on chains RFC-028 leaked silently
  (`make().len()`).

Unchanged in both until the generic-bodies rule lands: a generic body can be valid for one `T` and
not another (`push(v)` then reading `v`: fine for `i32`, E2123 for `Route`), reported at
instantiation. The rule makes it invalid for every `T` unless a `where T: copyable` bound says
otherwise. Element accessors that return by value keep `_ref` twins.

## Operators

Operands are `T` parameters. `op_eq(a: T, b: T)` and `op_cmp(a: T, b: T)` work for non-copyable
`T`, so RFC-030's reference-form rung is not needed for ownership, and its operand ownership check is
rule 3.

## Unchanged

`owned` fields and the derived copyable bit, liveness, the `move` operand table (E2125, E2127),
scoped mutability, RFC-026 for copyable types, and `#if type_info(T).copyable` where behaviour
really differs: clone versus copy, the `deinit` cascade, and functions that return an element by
value (`find`, `get`, `min`), which keep their `_ref` twins.

## Out of scope

- **The other move positions.** `let b = move a`, struct literal fields and element stores keep
  `move` until evaluated.
- **Closures that own their captures**, and storing or consuming a closure.
- **Returned borrows.** Accessors and iterators keep `&T` and `for &x`.
- **Aliasing through a reference**, and aliasing with no owned state in the overlap.
- **Dangling captures.** A closure outliving a name it captures; the same hazard as a returned
  `&local`.
- **`p.* = v` through `&T`** bypasses scoped mutability and overwrites a live owner without E2126.
  Separate known issue.

## Follow-ups

- **Per-diagnostic severity.** A build flag or `flang.toml` setting that treats a given warning as
  an error or a given error as a warning. Rule 8 then defaults to a warning.

## Plan

On `consumer_ownership_semantics`, from `e3a2970`. Seed rule applies: implement, harness-test,
promote, then use.

1. **Checker.** `move` on a parameter drives consumption; rule 3 on non-copyable `T` parameters;
   `move &T` error; `move` in argument position is an error; the receiver follows the picked
   overload's first parameter; rule 8 on non-copyable rvalues; rule 9 on overlapping arguments; the
   diagnostic for a lent-to-owning callback names the argument.

   Done. Codes: E2129 (`move` in argument position), E2130 (`move &T`), E2131 (rule 3, and a field
   moved out of a base the function does not own), E2132 (rule 8), E2133 (rule 9); E2128 narrowed
   to a `move self` reached through a reference or hop. Decided along the way:
   - `return h` of a binding moves with no marker; `return move h` is accepted with an info note
     (I2001).
   - Into a `move` parameter, an element (`xs[i]`) and a dereference (`p.*`) are E2125; a field
     moves only out of a local or a `move` parameter. Since 2026-09-17 the explicit `move` follows
     the same rule, with one exception for both: a place reached through an `owned` field of a type
     the module declares (see "What `move` may take").
   - Rule 9 fires when the overlapping argument is non-copyable, or reached through an `owned` field
     or a container element, and one side moves or shares: `take(h.fd, h)` with `owned fd`,
     `xs.concat(xs)`, `g(xs[0], &xs)`. `take(h.id, h)` with a plain `id` compiles. This narrows
     "aliasing that is not ownership" below.
   - Function types carry parameter modes: `fn(T)` and `fn(move T)` are distinct, parsed in type
     position and on lambda parameters.
   - Variant payloads (`Some(move v)`) are not argument position and keep `move`.
   - Sugar is checked as its desugar: `for x in e` as `e.iter()`, `e?` as `op_try(e)`, `a ?? b` as
     `a match { Some(v) => v, None => b }`. A `match` scrutinee owns a temporary.

   Gaps are recorded in `docs/known-issues.md` ("RFC-033 Ownership Gaps After the Checker Step").
2. **Lowering.** A non-copyable parameter never gets a copy-on-write shadow (rule 3 forbids the
   write, `move T` owns the value); `move T` of a copyable type lowers as `T`.

   Done. `lower_function` skips the prologue copy on the copyable bit; a copyable `move` parameter
   already went through the ordinary escape analysis.
3. **Closures.** Captures by usage, `op_call(self: &Closure)`, retire E2112.

   Done, with every capture by reference instead of by usage: the environment holds one `&T` per
   captured binding. E2112 and E2113 are retired. Lambda bodies get their own ownership pass
   (parameters by mode; a capture of a lent name stays lent, any other capture may be read and
   written but not moved out, E2131), and building a closure reads its captures (E2123).
4. **Harness.** Rewrite `tests/harness/ownership/*` call sites; add tests for rule 3, rule 5, the
   lent-to-owning callback, owning rvalues, move-and-lend in one call, and closure captures. `move_param_on_copyable.f` flips to a copy.

   Done: written test-first with steps 1-3, plus rule 9 through a container element, named arguments
   into `move` parameters, variant payloads keeping `move`, and rule 5 on function types and
   lambdas. `for_ref_loop` stays skipped until step 6, `container_element_deinit_runs` until
   RFC-028 step 7.
5. **Promote.**
6. **Stdlib.** Adopt `owned` buffers with `move` on every consuming parameter (`deinit`, `push`,
   `insert`, `set`, `unwrap`, `expect`, `map`, `close`); drop the callback gates.

   Split in two, because owned buffers break the compiler's build until step 7 sweeps it:
   - **6a, done.** `move` on every by-value parameter that stores its argument or takes it apart:
     container inserts, `Option`/`Result` members and `op_try`, iterator adapters and consumers
     (an adapter's own `iter` takes `move self`), `rc`/`arc`/`owned`, and the `OwnedString`
     consumers. Stores inside those bodies write `move`; the dict rehash hands entries to the
     new buffer with the same element-store `move`, since the old buffer is freed without deinit.
     `deinit` and `close_file` keep `&self`: on a copyable type a `move self` that disarms its
     argument would only write the callee's copy.
   - **6b. Generic bodies.** The rule and `where T: copyable` (the first slice of RFC-019 §2); the
     copy-returning functions take the bound. Before owned buffers, which rewrite those bodies.

     Split again. The bound is done: `where T: copyable` parses after the parameters and return
     type, is checked at each call that binds `T` (E2134, with the derivation chain, the body not
     instantiated), and a bound that is not `copyable` or not on one of the function's own type
     parameters is E2135. The body rule needs to know which types came from a type parameter, and
     an instantiation binds `T` straight to its concrete type, so it lands with RFC-029's rigid
     check of generic bodies, after 6c. The stdlib takes the bound after the next promote.
   - **6c, with step 7.** Owned buffers, `deinit(self: move T)`, `clone`, drains, one type at a
     time and green at each. `OwnedString` follows RFC-031 (an `owned view: String` read through
     `op_deref`). This branch has no callback gates to drop.

     `OwnedString` landed 2026-09-16, and with it what an owning element needs from the containers:
     a `List` and `Dict` drain, a dict that lends its entries (`for e in d` binds `&Entry`), a set
     that keeps by-value iteration and adds `iter_ref` for owning elements, `swap` through `&move`
     slots, and sorts that compare an owning element by reference. The
     `move` gate above landed with them.

     `List` and `Dict` buffers became `owned` on 2026-09-16, which makes every container
     non-copyable and reached the whole compiler at once. What the sweep changed, by shape: tables
     that used to hold a container by value now hold a reference (`Dict(NodeId, List(&Expr))`, an
     `&FnSig` from the symbol table, `&LambdaExpr` in a pending lambda); a read that used to copy a
     table entry now lends it (`get_ref`, `lookup_ref`, `Option.unwrap_ref`); a value built into a
     list is copied in bulk (`push_all(slice)`) where the arena owns the elements; and a body freed
     through a reference became one call that replaces it (`NominalRegistry.replace_body`) rather
     than a free followed by a write. Iteration over a non-copyable element is `for &x in xs`.

     The blanket `deinit(&$T)` went with them, on 2026-09-17. It was the other half of the same
     hole: a container freeing its buffer while the blanket answered for every element, so anything
     the elements owned leaked with nothing reported (docs/known-issues.md). Containers now release
     an element through `release(value: move $T)`, which is `#if !type_info(T).copyable {
     value.deinit() }` - nothing for a copyable element, the element's own `deinit` otherwise, and
     E2011 for a non-copyable type that declares none. Types whose storage is released elsewhere
     (AST nodes the arena owns, registry definitions freed by `free_body`) declare an empty
     `deinit` that names whose the storage is, so the decision reads at the type instead of
     defaulting invisibly.

     The move gate was then made one rule, on 2026-09-17. `let v = move X` and handing `X` to a
     `move` parameter had been checked by two paths that disagreed: the explicit form accepted a
     field of any type the module declares, the argument form only an owned base. So rule 3 held
     for `close(s.conn)` and not for `let c = move s.conn`. Both now read the same rule, and the
     scoped-mutability exception keys off `owned`: a place leaves through a reference only if its
     chain passes through an `owned` field of a type this module declares. A plain field follows
     rule 3 in its own module too. The sweep turned about seventy take-and-reset sites
     (`let x = move self.f` then `self.f = fresh`) into `replace(&self.f, fresh)`, made dict take
     through `(self.entries + i)` by index instead of a lent `&Entry`, and gave builders that end in
     `finish` a consuming `move self`.

     `StringBuilder` followed on 2026-09-17 (`owned ptr`). The fallout was small: the
     `#string_reader` forwarders and `format` take the builder by reference, builders move into
     `Path` and the fs walkers, and `file_name` gained a `String` form so nothing builds a
     temporary `Path` to read one component. Its `deinit` then became consuming like every other,
     and with it the types that hold a builder: `Path` (non-copyable through `__sb`, nothing else
     to change) and the CSV decoder, reader and table.

     `RawDir` then took `owned handle` with a consuming `deinit`, which makes `Dir`, the walk frames
     and the walk and glob iterators non-copyable. A walk frame declares its own `deinit`, so the
     walker closes a finished directory by popping it and releasing it, and `WalkIter.deinit` is
     the stack's own release. `Command` was already non-copyable through its argument lists and
     already consumed in `deinit`; a harness test now pins both it and `Dir`.

     `Child` owns its process handle the way `FileHandle` owns its descriptor (`owned __handle`),
     and the pipes taken from it own theirs (`owned __fd`). `Child.deinit` and each pipe's `close`
     consume: a copy used to keep the descriptor numbers after one copy closed them, so a second
     release could close an unrelated, reused descriptor.

     `Rc` and `Arc` hold `owned __inner` (no longer optional: a consuming `deinit` never leaves a
     released handle behind, so `is_released` is gone). The count bump is `retain`, as the spec's
     ownership vocabulary names it, and `rc.clone()` now peels through `op_deref` to the value's
     own `clone`. `UnmanagedDeque` holds `owned ptr`, the last raw container buffer; the other
     collections are built on `List` and `Dict`.

     `ArenaAllocator` owns its page chain (`owned first_page`; `current_page` is a cursor) and its
     `deinit` consumes. It owns the pages, not the allocations inside them, which stay plain
     references. The sweep caught a regression from the container change: `Module.append_decls`
     had become `install(&self.decls, merged)`, which releases the old list through the allocator
     it was built with - a view of the projection's stack-local arena, dead by then. The old list
     is now swapped out with `replace` and left for the arena, as the code did before.
7. **Compiler libraries.** Sweep `lib/*`, `tools/*`, `compiler/`.

   Done 2026-10-10. Most of it landed with 6c, since owned buffers reached the compiler at once.
   What was left: `close_file` consumes its `File`, as a pipe's `close` does, so a closed file is
   no longer reachable; the two call sites that only re-raised `open_file`'s error use `?`; the
   diagnostic moves drain instead of copying out a slice and freeing it; and the remaining
   `deinit(self: &T)` became `move self` on the non-copyable types (`BlockExpr`, `PendingSpec`,
   `FunctionScheme`, FIR's `Instr` and `Terminator`) and went away on the copyable ones, which
   `release` never calls. `Instr` and `Terminator` had freed payload lists bound out of a lent
   `self.*`, the pattern-binding gap in docs/known-issues.md.
8. **Docs.** Spec §3.2, §3.6, §4.1, §7.2, §7.3 and the stdlib callback convention; RFC-028 and
   RFC-030 status and cross-references.

## Port to every branch

From `client_ownership_semantics`, not tied to either semantics:

- `d659864` MSVC toolchain record; `33e121f` parser recovery and `pub let`; `4d781a4` private
  functions reachable from a container instantiated in the same module.
- The `#error` directive (inside `f4125bc`).
- A `for` loop releasing a non-copyable iterator state on every exit (inside `4657526`).
- Stdlib: `swap_remove`, `remove_at`, `take_all`, `drain`, `drain_rev` on
  lists; `drain` on dict, set, deque and stack; `find_ref`, `iter_rev_ref`; `peek_front_ref`;
  `iter_ref` on sets; `clear` on set and stack; `remove` on set; `clone` on list, dict and
  `OwnedString`; `retain` on `Rc`, `Arc` and lists; `stdlib/README.md`.
