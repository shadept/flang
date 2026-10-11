---
status: provisional
type: language
created: 2026-10-11
implemented: 2026-10-11
relates: [RFC-019, RFC-029, RFC-033, RFC-014, RFC-036]
---

# RFC-035: Contracts

## Summary

A contract is a type that names a set of functions other types must have. It bounds a type
parameter the way `copyable` does today, and it is declared the way every other named type is:

```flang
pub type Iterator = contract(T) {
    fn next(self: &Self) T?
}

fn filter(it: move $I, f: move $F) FilterIter(I, F) where I: Iterator($T), F: fn(T) bool
```

A bound is checked at the call and feeds inference: `F: fn(T) bool` gives a lambda argument its
parameter type before its body is checked. Contracts combine with `+`, `copyable` is one of them,
and a contract-typed parameter is sugar for a bounded type parameter. This RFC replaces the design
notes of RFC-019 §2 and is what `std.collections.iter` waits on.

RFC-036 supersedes three parts of this design: the element type as a contract parameter
(`Iterator(T)` becomes `Iterator` with `type Item`, read as `I.Item`), `where` on a contract's own
parameters, and the restriction of bounds to functions. The rest stands.

## Motivation

- **`std.iter` is disabled.** Every adapter takes an unbounded `it: $I`. Under spec 7.2's receiver
  tiers a catch-all that takes the receiver as written beats a specific overload reached by
  adapting it, so `xs.last()` on a `List` resolved to `last(it: move $I)` and failed inside it,
  and `d.any(f)` on a `Dict` handed `f` one entry instead of `(key, value)`. Nothing can say that
  `I` must be an iterator (docs/known-issues.md).
- **A wrong callable fails deep.** `filter(it, f)` accepts any `f`; one of the wrong shape errors
  inside `next` at the instantiation, far from the call.
- **A lambda in a `$F` slot infers from its own body.** Its parameter type is decided by whichever
  call in the body resolves first, and inference stops when that call has more than one candidate.
  A bound that says `F: fn(T) bool` is the context the lambda lacks.
- **Overload ranking is a heuristic.** `scheme_specificity` counts concrete type constructors; the
  spec calls it "a tuned heuristic standing in for a real constraint system". Bounds give ranking a
  rule: a stricter bound is more specific.

## Design

### Declaring a contract

A contract is declared as a type, with `type`, beside `struct` and `enum`, and takes type
parameters on the keyword as they do (what being a type means for it is below):

```flang
pub type Iterator = contract(T) {
    fn next(self: &Self) T?
}

pub type Iterable = contract(T) {
    type S: Iterator(T)
    fn iter(self: &Self) S
}

pub type Eq = contract {
    fn op_eq(a: Self, b: Self) bool
}
```

A body holds two kinds of member:

- **A requirement** is a function declaration without a body, in lockstep with how functions are
  declared: name, parameters with their modes (`&T`, `move T`, read-only `T`), return type.
- **An associated type**, `type S` or `type S: Bound`, is a type the contract solves rather than
  takes: `Iterable(T)` does not say what `iter` returns, only that it is an `Iterator(T)`.

`Self` is the type being constrained: the `I` in `where I: Iterator(T)`. There are no receivers or
methods. A requirement says that a function of that name and shape is callable on `Self`, and UFCS
makes it callable as `x.next()`.

An anonymous contract is written where it is used, as `struct { ... }` is:

```flang
fn sum(it: move $I) T where I: contract { fn next(self: &Self) $T? }, T: copyable
```

### `Self`

`Self` is a predeclared type name, as `Option`, `String` and `List` are, not a keyword: the
language has no uppercase keywords, and the predeclared types are where a PascalCase built-in
name belongs. It is contextual. Inside a `struct`, `enum` or `contract` body it names the type
being declared; anywhere else it is an unknown type.

- **In a contract** it is the type being constrained, the `I` in `where I: Iterator(T)`.
- **In a named struct or enum** it is the type applied to its own parameters, which spares a
  recursive generic type from repeating them:

  ```flang
  type Node = struct(T) {
      value: T
      next: &Self?                      // Node(T)
  }

  type Expr = enum {
      Lit(i32)
      Add(&Self, &Self)
  }
  ```

  `Self(U)` is not a form: a different instantiation is written by name. `Self` by value
  (`next: Self`) is the infinite-size error it would be by name (E2035).
- **In an anonymous struct or enum** it is refused for now. `struct { next: &Self? }` would be a
  recursive structural type, and comparing two of them needs an equality that follows cycles,
  which the type interner does not have.

Nothing may be declared with the name `Self` - a type, a type parameter (`$Self`), a binding - so it
cannot be shadowed, and it means the same thing wherever it is valid. That gives it what a keyword
would, without adding the first uppercase one. The `#managed_list` and `#managed_dict` generators
name their parameter `Self` today and are renamed with it.

### Combining contracts

`+` combines contracts. A type satisfies the combination when it satisfies every part. A
combination can be named like any type, and a contract that extends another is that contract plus
its own members:

```flang
pub type Ordered = Eq + contract {
    fn op_cmp(a: Self, b: Self) Ord
}

pub type Key = copyable + Hash + Eq

fn dedup(it: move $I) List(T) where I: Iterator($T), T: Key
```

`+` combines contracts only; a struct or enum operand is an error.

### `copyable` is a built-in contract

`copyable` is satisfied by RFC-028's derived bit, not by a function: it is the one contract whose
members the language supplies. It is lowercase like the built-in types (`i32`, `bool`); declared
contracts are PascalCase by convention. `where T: copyable` keeps its meaning and its codes.

### Callable bounds

A function type in bound position is a contract: `where F: fn(T, U) R` means "callable with a `T`
and a `U`, returning an `R`", by a function pointer or by anything with a matching `op_call`, a
capturing closure included. Parameter modes are part of it: `fn(move T) R` is a different bound
from `fn(T) R`. There are no `Fn` contracts and contracts do not overload by arity: the function
type already is the shape, for any arity.

One callable kind is enough. Closures capture by reference (RFC-033) and are called through
`op_call(self: &__Closure_N, ...)`, so a closure that writes its captures and one that does not are
called the same way. Rust's `FnMut`/`FnOnce` split returns only with closures that own their
captures.

### Callable modes

A `fn(...)` bound calls its callable through `&Self`: a combinator calls `f` as often as it likes
and never consumes it. A callable whose `op_call` takes `move self` can be called once and does not
satisfy a `fn(...)` bound; a function that wants one says so with the contract spelled out,
`F: contract { fn op_call(self: move Self, x: T) R }`.

Where Rust's callable kinds differ in what the call does to the closure, ours differ in what it
does to the argument. Each parameter mode is a different promise:

| Bound | The callable may | The caller afterwards |
|---|---|---|
| `fn(T) R` | read the argument | still owns it, unchanged |
| `fn(&T) R` | read and write it | still owns it, possibly changed |
| `fn(move T) R` | own it: store it, release it | no longer has it |

A callable fits a bound that asks no more of it than its own signature does, as Rust's `Fn` fits
where `FnOnce` is accepted:

- **`fn(T)` where `fn(&T)` is bound: accepted.** A callable that only reads demands less than one
  allowed to write, and the call is the same: a read-only parameter already crosses by pointer
  (spec 3.2).
- **`fn(T)` where `fn(move T)` is bound: accepted.** The combinator hands the argument over and
  the callable only reads it, so the compiler releases it after the call, as a `for` loop releases
  the iterator it owns.
- **`fn(move T)` where `fn(T)` or `fn(&T)` is bound: refused** (E2125). The caller keeps the
  argument, so the callable would be its second owner.
- **`fn(&T)` where `fn(T)` is bound: refused.** The caller was promised the argument does not
  change.

For a copyable `T` the first and last modes coincide: `move` of a copyable value is a copy
(RFC-033 rule 4), so `fn(i32)` and `fn(move i32)` are interchangeable. The distinction holds
where it matters, on a generic `T`.

**Pinning carries modes.** An unannotated lambda in a bounded slot takes its parameter modes from
the bound along with its types: in `F: fn(move A, T) A`, `fn(acc, x) { ... }` gets `acc: move A`,
the strongest mode the slot offers, so its body may keep, release or return `acc`. That closes the
known issue that unannotated callbacks never take ownership (docs/known-issues.md, "RFC-033
Ownership Gaps"): `xs.fold(list(0), fn(acc, x) { acc.push(x)  acc })` needs no annotation.

### Using a bound

A bound goes in a `where` clause, after the parameters and return type:

```flang
fn filter(it: move $I, f: move $F) FilterIter(I, F) where I: Iterator($T), F: fn(T) bool
```

At the use site the sigil does what it does in a signature: `Iterator($T)` introduces `T` and the
contract solves it; `Iterator(String)` requires it to be `String`. A variable the contract does
not bind otherwise is solved by unification, so outputs need no syntax of their own: `U` in
`F: fn(T) U` is whatever `f` returns.

A contract can also stand in a type position, as sugar for a bounded type parameter; see below.

### A contract as a type

A contract is a type in name and declaration - declared with `type`, exported and imported like one,
described by a TypeInfo - but it has no values. Nothing has a contract as its run-time type: where
a contract stands in a type position it means some concrete type that satisfies it, or the
position is an error.

| Where | Allowed | Meaning |
|---|---|---|
| `where X: C`, `type S: C`, an operand of `+` | yes | a bound |
| `type K = A + B` | yes | a name for a contract |
| a parameter's type, `src: Reader` | yes | a fresh type parameter bounded by `Reader` |
| inside a parameter's type, `src: &Reader`, `xs: Reader[]` | yes | the same, for that occurrence |
| a local annotation, `let r: Reader = make()` | yes | the inferred type, checked against `Reader` |
| a return type, `fn make() Reader` | yes | a fresh type parameter bounded by `Reader` |
| `type_info(C)` | yes | the contract's descriptor |
| a struct field, an enum payload | no | needs a value of the contract: `dyn C` |
| a type argument, `List(Reader)`, `Reader?`, `(Reader, i32)`, `[Reader; 4]` | no | the same: `dyn C` |
| `size_of(C)`, `align_of(C)` | no | no layout |
| a construction (`C { }`, `.{ }` against `C`), `as C` | no | no values, no conversion |
| `C` without its arguments (`Iterator` for `Iterator(T)`) | no | a contract is used applied, as a generic struct is |
| a contract as a contract's argument (`Iterable(Iterator(i32))`) | no | contract parameters are types |

**A contract in a type position is sugar for a bounded type parameter**, wherever it stands. These
are the same function:

```flang
fn copy_all(src: Reader)
fn copy_all(src: $R) where R: Reader
```

Every occurrence introduces its own type parameter and refers to no other, so `fn eq(a: Eq, b: Eq)`
takes two possibly different types, and `src: &Reader` or `xs: Reader[]` binds a parameter nothing
else in the signature can name. That is allowed and rarely what is meant: a function whose types
must agree names the parameter, `fn eq(a: $T, b: T) where T: Eq`.

**Solving a type parameter.** Every type parameter - written `$T` or introduced by a contract, in a
parameter or in the return type - is solved the same way:

- **Whoever pins it first decides**: an argument, the type the call site expects or later uses
  (`let l = list(3)` then `l.push(3i32)` pins `list`'s `T`), or the body. Today the body never
  does: a generic waits to be instantiated until the call site has pinned every parameter it
  mentions. When nothing at the call site pins one, the instantiation proceeds with it open, and
  what the body produces binds it. A body generic in a parameter - `list` in `T` - leaves it to
  the caller.
- **While it is open, it is used through its bounds.** `R: Iterator(i32)` says a `next(&R) i32?`
  exists, so a call to `next` on an `R` types as `i32?` before `R` is known - the same pinning a
  lambda gets from `F: fn(T) bool`, applied to every use of a value of that type.

So `fn evens(xs: i32[]) Iterator(i32)` is `fn evens(xs: i32[]) $R where R: Iterator(i32)`: the
body pins `R`, the caller sees the concrete type, and nothing is opaque. The cost against an opaque
type is encapsulation: callers can depend on the concrete type, so a body that changes what it
returns can break them.

A concrete type never becomes its contract and is never converted to one; a bound checks and binds,
nothing more. Two contracts are equal when their requirement sets are (see Identity), and
`type_info(A) == type_info(B)` agrees. A contract's own parameters are bounded as a function's are,
`contract(T) where T: copyable { ... }`. *(Superseded by RFC-036: the bound sits on the parameter,
`contract(T: copyable)`, and `where` on a type declaration is refused.)*

`dyn C` (see the last section) is the one form that gives a contract values, and with them the
rows marked `dyn C` above. Everything else in the table holds for it unchanged.

### What satisfies a requirement

A requirement is satisfied when **the call resolves**: `op_eq(a, b)` with `a, b: X` type-checks,
with everything a call allows - overload ranking, `op_deref` peeling, generic overloads and their
bounds. This is how every protocol already works (`for` resolves `iter` and `next` as calls), and
it decides two cases on its own:

- `OwnedString` has no `op_eq`; `s == t` peels to `String`'s. It is `Eq`.
- `Option(T)` gets `==` from the generic `op_eq(a: Option($T), b: Option(T))`. Bounded
  `where T: Eq`, that overload makes `Option(X)` an `Eq` exactly when `X` is: conditional
  conformance with no syntax of its own.

The call resolves in the call site's visibility unioned with the generic's defining module, the
loaded-context rule spec 2.3 already applies inside a specialization. A satisfaction that resolves
two ways - a type with two `next` overloads returning different types, solving `$T` - is an error
at the use, never a pick.

### Identity

A contract is its set of requirements. Two contracts with the same members (in any order, `+`
flattened, associated types equal when their bounds are) are the same contract, and a contract's
name is a transparent alias in the sense of spec 2.3.1. `Ordered` and
`contract { fn op_eq(a: Self, b: Self) bool  fn op_cmp(a: Self, b: Self) Ord }` are equal.

The cost: a contract cannot mean something by its name alone. `contract {}` is satisfied by every
type, so a marker contract carries no promise; only built-in ones (`copyable`) do.

### Checking a call

A bound is checked where the call binds its type parameters, after inference settles them, and an
unsatisfied one is E2134 with the requirement that failed and, for `copyable`, the derivation
chain. The body is not instantiated for a call that fails a bound.

**A bound pins, not only checks.** When an argument is a lambda in a `$F` slot bounded by
`fn(T) U`, the lambda's parameter types unify with `T` before its body is checked, and its return
type with `U`. That is the inference a lambda in a duck-typed slot lacks today, and the reason a
check-only design (C++ concepts) would not do.

### Overload ranking

A bounded overload is more specific than an unbounded one of the same shape, and of two bounds on
the same position the one whose requirement set is a superset is more specific: `T: Ordered`
beats `T: Eq`. That is what lets `any(&Dict($K, $V), $F)` and `any(it: $I) where I: Iterator($T)`
coexist: the dict's receiver no longer satisfies the iterator's bound, so the catch-all stops
capturing it.

It can also invert the lazy-fallback pick of spec 7.3. `unwrap_or(self, fallback: T)` and
`unwrap_or_else(self, make: $F)` have different names, so they never compete; but any eager/lazy
pair that shares a name and relies on `T` tying with `$F` would see `$F where F: fn() T` win once
bounds count. The rule: a bound adds specificity only against an unbounded type parameter, never
against a concrete type.

### Generic bodies

A bound does not restrict the body. Inside it, `T` is used as today and dispatch waits for the
instantiation; RFC-029's rigid check keeps checking ownership against `T` as non-copyable unless a
bound says `copyable` (or a contract that includes it). Checking a body against its bounds alone -
a call on `T` that no bound provides is an error - is the follow-up the rigid check makes possible.

### TypeInfo

`type_info(Iterator(i32))` describes the contract: `kind = TypeKind.Contract`, its `name`, its
arguments in `params`, and its members in `fields`, a requirement with its function type and an
associated type with its bound. A contract has no `size` or `align`: there is no value of one, so
reading either is a compile-time error, never zero. `type_info(I)` for a bounded type parameter still describes the concrete type at each
instantiation. A comptime `satisfies(T, C)` is deferred; when it lands, `type_info(T).copyable` is
`satisfies(T, copyable)`.

### Errors

- E2134 (a bound is not satisfied) and E2135 (a malformed bound) keep their codes and widen to
  contracts.
- New: a requirement that does not mention `Self`; `Self` outside a struct, enum or contract body,
  or in an anonymous one; a declaration named `Self`; a contract where a value of it is needed (a
  field, a payload, a type argument, `size_of`, a construction); a contract used unapplied or as a
  contract's argument; `+` with a non-contract operand; an ambiguous satisfaction. Numbered from E2138 when the checker step
  lands.

## The standard library

`Iterator(T)` and `Iterable(T)` above go in `core`, beside the `for` protocol they describe. `for`
keeps resolving `iter` and `next` as calls; the contracts state what it already requires.
`Iterable` describes what a collection offers (`iter(&self)` leaves it in place); an iterator that
`for` consumes (`iter(self: move Drain)`, the adapters) is bounded by `Iterator`, which is what the
adapters take.
`std.collections.iter` comes back with every `$I` bounded:

```flang
pub fn filter(it: move $I, f: move $F) FilterIter(I, F) where I: Iterator($T), F: fn(T) bool
pub fn map(it: move $I, f: move $F) MapIter(I, F) where I: Iterator($T), F: fn(T) $U
pub fn fold(it: move $I, init: move $A, f: move $F) A where I: Iterator($T), F: fn(move A, T) A
pub fn any(it: move $I, pred: $F) bool where I: Iterator($T), F: fn(T) bool
```

The prelude re-exports it again, and `stdlib/dict_iter_chain.f` and
`ownership/stdlib_iter_adapters_own.f` come off the skip list.

## Plan

New syntax, so the seed rule applies: implement, harness-test, promote, then use.

1. **Parser.** `contract(...) { ... }` in type position, requirement and associated-type members,
   `+` in bound position, a function type in bound position, a contract type in parameter
   position. `Self` as a predeclared, reserved type name; the `#managed_list` and `#managed_dict`
   parameter renamed off it first, since a promoted seed would reject it.
2. **Checker: `Self`.** Resolution inside struct, enum and contract bodies, the instantiation it
   names in a generic type, the refusals.
3. **Checker: declarations.** A contract registers as a type, its identity as its requirement set;
   TypeInfo; the declaration errors.
4. **Checker: bounds.** Satisfaction at the call by resolving each requirement; E2134 with the
   failing requirement; the type-position sugar; a call on a value of an open type parameter
   resolved through its bounds; a type parameter the call site leaves open, bound by the body.
5. **Checker: pinning.** A callable bound types a lambda argument, modes included, before its
   body is checked; the callable-mode subsumption, with the release after a read-only callable
   that was handed ownership.
6. **Ranking.** Bounded over unbounded, superset over subset; a harness test for an eager/lazy
   pair sharing a name.
7. **Harness**, then **promote**.
8. **Stdlib.** `Iterator`, `Iterable`, `Eq`, `Hash`, `Ordered` in `core`; `std.collections.iter`
   restored and re-exported; `where F: fn(...)` on the callbacks that take one.
9. **Docs.** Spec 2.3 (bounds), 2.4 and 2.5 (`Self` in structs and enums), 7.3 (callback
   convention), 7.4 (`for` and the contracts); RFC-019
   §2 marked superseded by this RFC.

## Implementation status (2026-10-11)

Landed: the syntax (`contract`, requirements, associated types, `+`, function types and anonymous
contracts in bound position), `Self` in contracts and named structs and enums with its refusals,
contract declarations checked on their own (E2141), bounds lowered once per signature to
requirement atoms, satisfaction by resolving each requirement as a method call, overload probing
that drops a candidate whose bound fails (and reports it, E2134, when nothing else fits), commit-time
pinning of `$T` and of lambda parameter types, the callable-mode subsumption, ranking by the
number of atoms that held, E2138-E2141, `Iterator` and `Iterable` in `std.collections.iter` (not
`core`: nothing in `core` uses them, and `for` resolves its calls without them), and
`std.collections.iter` restored with every `$I` bounded. `Eq` and `Ordered` (core.cmp) and `Hash`
(core.hash), with every primitive's operator functions declared in `core.ops` so `op_eq` is a
function on `i32` as `==` is an operator; `Dict`, `Set`, `MultiMap` keys bounded `Hash + Eq`, the
by-value searches `Eq`, what orders values `Ordered`.

Not yet, tracked in docs/known-issues.md ("RFC-035 Contracts: What the First Cut Leaves Out"): the
type-position sugar in a return type or local annotation (the parameter form landed with RFC-036's
follow-up), a body using an open parameter through its bounds, mode pinning and the release
after a read-only callable handed ownership, the two-way-satisfaction error, superset ranking,
TypeInfo and identity.

Answers taken on the open questions below: parameter names in requirements are optional, as in
function types; satisfaction resolves as the instantiated body will - the defining module, with the
call site's visible set unioned in (the loaded-context rule), so the caller's private functions do
not count; partially overlapping bounds rank by how many requirements held.

## Open questions


- **Parameter names in requirements:** optional, as function types allow (`fn next(&Self) T?`),
  or required, for copy-paste lockstep with declarations?
- **Naming an associated type from outside:** `Iterable`'s `S` is not reachable from a function
  bounded by it. A projection (`I.S`) when something needs it? *(Answered by RFC-036: `I.Item`.)*
- **Satisfaction visibility:** the loaded-context union, or the call site alone?
- **Ranking of two partially overlapping bounds** (neither a superset): ambiguous, or declaration
  order?

## Future: interfaces and `dyn`

Out of scope here; written down so the static design does not close the door.

A contract is a type, so it can also be the type of a value: a data pointer and a vtable, built
from the same structural check, dispatching at run time. The stdlib builds this by hand today:
`#interface(Reader, struct { read: fn(...) })` generates a vtable struct, a wrapper and
forwarding functions, and `#implement(File, Reader)` writes shims and a `file.reader()`
conversion per type. A contract replaces both generators.

The keyword is `dyn`, usable in both forms:

```flang
fn copy_all(src: dyn Reader)              // one function, dispatch through a vtable
fn copy_all(src: $R) where R: dyn Reader  // the same: R is compiled once, as the erased type
```

`dyn` in a bound makes the dispatch strategy a property of the bound: a function changes strategy
without changing its body.

Directions, each to be decided then:

- **A `dyn C` value borrows**, like a slice: copyable, owning nothing. `&File` decays to
  `dyn Reader` at a `dyn Reader` slot as an array decays to a slice. An owning form needs `deinit`
  in the vtable and an allocator.
- **Dispatchability.** Only a contract whose every requirement takes `Self` exactly once, as a
  `&Self` first parameter, can be `dyn`. `Reader` and `Iterator(T)` can; `Eq` cannot (two `Self`
  values); `Iterable(T)` cannot unless its `S` is fixed. `dyn` on any other is an error naming the
  member.
- **TypeInfo:** a `dyn C` has a layout (two pointers), so `size` and `align` exist for it.
- **Overloads.** `dyn C` is a concrete type, so `f(x: dyn Reader)` and `f(x: $R) where R: Reader`
  can both accept a `&File`: one by decay, one by binding `R`. Ranking needs a rule for which wins,
  and whether a static and a dynamic overload of the same shape may coexist at all.

## Future: associated types with parameters

Contracts here are first-order: `Self` is the instantiated type, so a contract cannot say that
`map` returns the same kind of container over another element. Associated types that take
parameters would, solved from the type's own signatures as plain associated types are:

```flang
pub type Mappable = contract(T) {
    type Mapped(U)
    fn map(self: &Self, f: fn(T) $U) Mapped(U)
}
```

`List`'s `map` returns `List(U)`, so `Mapped(U)` is `List(U)`; a dict mapping its values gives
`Dict(K, U)`. This needs requirements that introduce their own `$` variables, and satisfaction
that is coinductive - a goal met again while it is being checked holds - with a depth limit for
goals that keep growing.
