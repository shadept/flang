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
9. **A place cannot be moved and lent in the same call.** Arguments evaluate left to right, but the
   call receives them together: a binding, or any place overlapping it, passed to a `move T`
   parameter and also to a `T` or `&T` parameter of the same call is an error.

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

A capturing closure is a synthesized struct with `op_call(self: &__Closure_N, ...)`. Captures follow
what the body does with each name:

- assigned: shared, so the write reaches the outer binding;
- read: copied when the type copies, shared otherwise;
- moved out: an error.

```flang
let c: usize = 0
values.each(fn(v) { c = c + 1 })
println(c)                  // the element count
```

This retires E2112. A closure that outlives a shared capture dangles, under the same rules as a
returned `&local`.

## Moving and lending in one call

```flang
fn h(a: Route, b: move Route)
fn j(a: &Route, b: move Route)
fn k(name: OwnedString, r: move Route)

h(x, x)             // error: `x` is lent to `a` and moved into `b`
j(&x, x)            // error: same
k(x.path, x)        // error: `x.path` overlaps `x`
h(y, x)             // fine: distinct bindings
```

This is the one aliasing case that is an ownership question: the function would own and release a
value it is also reading. Other aliasing is not. `g(xs[0], &xs)` lets `g` read an element while it
may grow the list, exactly as a `const T&` into a `std::vector` does in C++. It stays the
programmer's responsibility (§3.6).

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

Unchanged in both: a generic body can be valid for one `T` and not another (`push(v)` then reading
`v`: fine for `i32`, E2123 for `Route`), reported at instantiation until RFC-029; and element
accessors that return by value keep `_ref` twins.

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
- **Aliasing that is not ownership.** `g(xs[0], &xs)`, `xs.push(xs[0])` for a copyable `T`.
- **Dangling shared captures.** A closure outliving a name it shares; the same hazard as a returned
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
2. **Lowering.** A non-copyable parameter never gets a copy-on-write shadow (rule 3 forbids the
   write, `move T` owns the value); `move T` of a copyable type lowers as `T`.
3. **Closures.** Captures by usage, `op_call(self: &Closure)`, retire E2112.
4. **Harness.** Rewrite `tests/harness/ownership/*` call sites; add tests for rule 3, rule 5, the
   lent-to-owning callback, owning rvalues, move-and-lend in one call, and closure captures. `move_param_on_copyable.f` flips to a copy.
5. **Promote.**
6. **Stdlib.** Adopt `owned` buffers with `move` on every consuming parameter (`deinit`, `push`,
   `insert`, `set`, `unwrap`, `expect`, `map`, `close`); drop the callback gates.
7. **Compiler libraries.** Sweep `lib/*`, `tools/*`, `compiler/`.
8. **Docs.** Spec §3.2, §3.6, §4.1, §7.2, §7.3 and the stdlib callback convention; RFC-028 and
   RFC-030 status and cross-references.

## Port to every branch

From `client_ownership_semantics`, not tied to either semantics:

- `d659864` MSVC toolchain record; `33e121f` parser recovery and `pub let`; `4d781a4` private
  functions reachable from a container instantiated in the same module.
- The `#error` directive (inside `f4125bc`).
- A `for` loop releasing a non-copyable iterator state on every exit (inside `4657526`).
- Stdlib: `swap` and `memswap`; `swap_remove`, `remove_at`, `take_all`, `drain`, `drain_rev` on
  lists; `drain` on dict, set, deque and stack; `find_ref`, `iter_rev_ref`; `peek_front_ref`;
  `iter_ref` on sets; `clear` on set and stack; `remove` on set; `clone` on list, dict and
  `OwnedString`; `retain` on `Rc`, `Arc` and lists; `stdlib/README.md`.
