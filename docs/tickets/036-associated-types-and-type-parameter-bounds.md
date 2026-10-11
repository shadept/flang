---
status: provisional
type: language
created: 2026-10-11
implemented: 2026-10-11
relates: [RFC-035]
---

# RFC-036: Associated types, projection, and bounds on type parameters

## Summary

A contract's output types become associated types the bound solves, reachable from the bounded
parameter by projection; struct, enum and contract parameters take bounds inline; and a type's
bounds hold wherever the type does:

```flang
pub type Iterator = contract {
    type Item
    fn next(self: &Self) Item?
}

type FilterIter = struct(I: Iterator, F: fn(I.Item) bool) {
    it: I
    f: F
}

pub fn filter(it: move $I, f: move $F) FilterIter(I, F)
pub fn to_set(it: move $I) Set(I.Item) where I: Iterator(Item: Hash + Eq)
pub fn total(it: move $I) i32 where I: Iterator(Item = i32)
```

This supersedes three parts of RFC-035: the element type as a contract parameter (`Iterator(T)`),
`where` on a contract's own parameters (`contract(T) where T: copyable`), and the restriction of
bounds to functions. Everything else in RFC-035 stands.

## Motivation

- **Every adapter restates its bounds.** `FilterIter(I, F)` is only meaningful when `I` is an
  iterator and `F` takes its elements, yet the struct cannot say so, and each of its functions
  repeats `where I: Iterator($T), F: fn(T) bool`. A type documenting its requirements in a comment
  (`UnmanagedSet`: "`T` is `Hash + Eq`") is the same gap.
- **The element type is an output, modelled as an input.** An iterator type yields exactly one
  element type; RFC-035 already makes a `next` that resolves two ways an error. `Iterator(T)` still
  makes every user name `T` up front, solved per call, as if it were chosen.
- **`$` in bounds mixes two ways of declaring a name.** A function introduces `T` with `$` inside a
  parameter; a type declares its parameters in a list, without `$`. A bound that needs the element
  type of `I` on a struct (`struct(I: Iterator($T), ...)`) has no good spelling under RFC-035. With
  projection it needs none: `I.Item` names it.

## Design

### A contract is the type of a type parameter

RFC-035 made a contract a type in name and declaration. Projection makes it one in use: a contract
is to a type parameter what a type is to a value, and each form below is its value-level
counterpart one level up.

| Value level | Type level |
|---|---|
| `x: Point` - `x` has type `Point` | `I: Iterator` - `I` has contract `Iterator` |
| `x.field` - a member of `x`'s type | `I.Item` - a member of `I`'s contract |
| `Point { x = 1 }` - a member set | `Iterator(Item = i32)` - a member pinned |
| `fn f(x: Point)` - a parameter annotated | `struct(I: Iterator)` - a type parameter annotated |

So a bound is an annotation, and `I.Item` resolves as `x.f` does: look the name up, read what it is
annotated with, find the member there. That decides the rest of this design rather than leaving
each part to taste:

- **Bounds go on the parameter list** of a type, as a function's parameters carry their types.
- **`:` annotates and `=` sets**, at both levels.
- **A contract's members are its fields**: RFC-035's TypeInfo already lists requirements and
  associated types in `fields`.
- **RFC-035's value-position sugar** reads as the same annotation applied once more: `src: Reader`
  is a value whose type's contract is `Reader`.

**The implementation follows the model.** Today the checker keeps bounds in a side table keyed by
function (`fn_bounds`), which projection would have to search backwards from a name. Instead, a
type parameter's binding carries its contract, as a value binding carries its type: the binding
holds the parameter's lowered bound atoms and its associated types' variables. `I.Item` is then a
member lookup on `I`'s binding; a struct's parameter and a function's `$T` are bound the same way;
and implied bounds are what a parameter's binding already carries when a function binds it through
`FilterIter($I, $F)`. The call-site check (probing, pinning, the drain's E2134) reads the same atoms
it reads today.

**The analogy stops at the type level.** A contract has no values (`dyn C`, RFC-035's future, is
the separate case), and a type parameter is not a value: there is no passing `I` at run time, no
storing it, no computing a type from data. `I.Item` is resolved during checking and is gone before
lowering, as every type is.

### Associated types

A contract member `type Name` is an associated type: a type the bound solves from the requirements
rather than takes as an argument. Three forms:

| Member | Meaning |
|---|---|
| `type Item` | solved from the requirements |
| `type Item: Bound` | solved, then held to `Bound` |
| `type Item = TypeExpr` | derived: an alias inside the contract, over `Self`, parameters, other associated types |

`type Item: Bound` is RFC-035's `type S: Bound`, unchanged. The derived form is new and is what
makes chained element types readable:

```flang
pub type Iterable = contract {
    type Iter: Iterator
    type Item = Iter.Item
    fn iter(self: &Self) Iter
}
```

**When an associated type is known.** Exactly when the bounded type is: an associated type is a
function of it. Satisfying `I: Iterator` with `I = Counter` resolves `next(&Counter)`, whose return
`i32?` solves `Item = i32` at the same moment RFC-035 solves `$T` today, when the call commits. A
type application `FilterIter(Counter, G)` solves it as soon as `Counter` is concrete. Inside a
generic body, with `I` still open, `I.Item` is a type known by name and by its bounds only: two
uses of `I.Item` are the same type, nothing else about it is decided until an instantiation. An `I`
nothing pins leaves its `Item` unsolved, as an unpinned `$T` is (E2001).

Contract parameters remain, for inputs a type is not determined by (`contract(T) { fn from(x: T)
Self }`). An output stays an associated type.

### Projection

`X.Item` names the associated type `Item` of the contract bounding `X`. It is valid in any type
position where `X` is:

- a type parameter whose bounds (the function's `where`, its parameter list's, or a type's implied
  bounds, below) include a contract that declares `Item`, directly or through `+` or a name;
- `Self`, inside a contract;
- itself a projection, so `C.Iter.Item` reads through `Iterable` to its `Iterator`.

Type positions have no dotted names today (`Color.Red` is a value), so the form is free. Two
contracts in `X`'s bounds that both declare `Item` name one type, since each is a function of `X`:
they unify, and a type that would solve them differently fails the bound (E2134). A projection on a
concrete type (`Counter.Item`) is not a form; the concrete type is written instead.

### Pinning and bounding an associated type

A contract applied with a named argument constrains one of its associated types:

```flang
where I: Iterator(Item = i32)               // Item is exactly i32
where I: Iterator(Item: copyable + Hash)    // Item is some type satisfying the bound
where I: Iterator, J: Iterator(Item = I.Item)
```

`=` pins and `:` bounds, as in `let x = ...` against `x: T`. `Item = Eq` is not the bound form:
with a contract on the right it would read as "the element is the contract", and a contract has no
values. Both forms are sugar for a constraint on the projection, `I: Iterator, I.Item: copyable +
Hash`, which may also be written that way in a `where`. Named arguments follow positional ones, as
in a call; a positional argument still fills a contract parameter.

### Bounds on type parameters

A struct, enum or contract declares its parameters in a list, and a parameter's bound sits on it
there:

```flang
type FilterIter = struct(I: Iterator, F: fn(I.Item) bool) { it: I, f: F }
type UnmanagedSet = struct(T: Hash + Eq) { __inner: UnmanagedDict(T, u8) }
type Tree = enum(T: Ordered) { Leaf, Node(&Self, T, &Self) }
pub type Into = contract(T: copyable) { fn into(self: Self) T }
```

A function has no parameter list: its type parameters are introduced by `$` inside value
parameters, so its bounds stay in `where`. One rule covers both: **a bound sits where its parameter
is declared.** `where` on a type declaration, RFC-035's `contract(T) where T: ...` included, is
removed: each position has exactly one spelling.

A later parameter's bound may name an earlier parameter and its projections (`F: fn(I.Item)`), not
a later one.

### Where a type's bounds hold

- **At application.** A type written with concrete arguments, `Set(Point)` anywhere a type is
  written, is checked against its parameters' bounds there, and an unsatisfied one is E2134 at that
  type expression. An application whose arguments are still open is checked when they settle, at
  the instantiation that settles them.
- **Implied on functions.** A function that takes a bounded type assumes its bounds: in
  `fn next(self: &FilterIter($I, $F)) I.Item?`, `I: Iterator` and `F: fn(I.Item) bool` hold, and
  `I.Item` is in scope. The function's own `where` adds to them. RFC-035's `std.iter` signatures
  lose their restated clauses.
- **Construction** needs nothing further: a literal `FilterIter { it, f }` is an application whose
  arguments its fields settle.

A call site of such a function needs no separate check: the argument's type was already checked
where it was formed.

### Errors

E2134 (a bound is not satisfied) and E2135 (a malformed bound) widen to type applications. New,
numbered from E2142 when the checker step lands:

- a projection `X.Item` where no contract bounding `X` declares `Item`;
- `Name(Item = T)` or `Name(Item: B)` naming an associated type the contract does not declare, or
  the same one twice;
- a bound naming a later parameter of the same list;
- `where` on a type declaration.

## The standard library

```flang
pub type Iterator = contract {
    type Item
    fn next(self: &Self) Item?
}

pub type Iterable = contract {
    type Iter: Iterator
    type Item = Iter.Item
    fn iter(self: &Self) Iter
}

type FilterIter = struct(I: Iterator, F: fn(I.Item) bool) { it: I, f: F }

pub fn next(self: &FilterIter($I, $F)) I.Item?
pub fn filter(it: move $I, f: move $F) FilterIter(I, F)
pub fn fold(it: move $I, init: move $A, f: move $F) A where I: Iterator, F: fn(A, I.Item) A
pub fn to_set(it: move $I, allocator: &Allocator? = null) Set(I.Item)
    where I: Iterator(Item: Hash + Eq)
pub fn chain(a: move $I, b: move $J) ChainIter(I, J) where I: Iterator, J: Iterator(Item = I.Item)
```

`UnmanagedSet`, `UnmanagedDict`, `MultiMap` and the managed wrappers move their `Hash + Eq` from
each function onto the type's parameter; the functions keep nothing but what they add.

## Plan

New syntax, so the seed rule applies: implement, harness-test, promote, then use.

1. **Parser.** A real type-parameter list on `struct(...)`, `enum(...)` and `contract(...)`: `Name`
   or `Name: Bound`, replacing the balanced-token skip. `X.Item` in type position. Named arguments
   `Name = T` and `Name: B` in a contract application. `type Item = T` as a contract member.
   `where` on a type declaration parsed and refused.
2. **Checker: bounds on the binding.** A type parameter's binding carries its lowered bound atoms
   and its associated types' variables, replacing the per-function `fn_bounds` table as the source
   of truth. Derived members; `X.Item` as a member lookup on `X`'s binding; the `=` and `:`
   arguments lowered to projection constraints; agreement between two contracts declaring one name.
3. **Checker: type-parameter bounds.** A struct's or enum's parameters bound like a function's, and
   stored on the definition; checked at applications with concrete arguments and at the
   instantiation that settles open ones; implied on a function by the bindings its signature's
   `FilterIter($I, $F)` creates.
4. **Harness**, then **promote**.
5. **Stdlib.** `Iterator`, `Iterable` and `std.collections.iter` migrated; container bounds moved
   onto the types.
6. **Docs.** Spec 2.3.2, 2.4, 2.5; syntax; RFC-035's superseded sections marked; the error
   registry.

## Implementation status (2026-10-11)

Landed (Plan steps 1-4, and 6): the syntax (type-parameter lists with bounds on `struct`, `enum`
and `contract`, `X.Item` projections, `Name = T` / `Name: B` contract arguments, derived
`type Item = T` members, `where I.Item: B` entries, `where` on a type declaration refused at
parse, E2145), associated types solved at the call, projection, pinning and bounding, two contracts
on one parameter sharing a member, struct, enum and contract parameter bounds, implied bounds on
functions through every type their signature names (nesting included), the application check in
bodies and at instantiation, projections in struct fields and enum payloads, and E2142-E2145. Not
yet: promote and the stdlib migration (steps 4-5), which wait on approval of the promote commit.

How it differs from the Design text:

- **Bounds stay in `fn_bounds`.** The per-function atom list is still what the call checks, with a
  signature's implied atoms appended. What a type parameter's binding carries is its associated
  types: each is a type binding named by its path (`I.Item`), joining the template's type
  parameters as a `$T` does, so instantiations and the rigid check bind projections with no
  mechanism of their own.
- **A field's associated type is solved per instance.** A definition lists the associated
  variables its fields name; the checker solves them for each ground instance and records the
  result in the nominal registry, which every field substitution (checker, copyability, layout,
  lowering) reads.
- **Where written bounds are checked.** In a body a bounded type is checked at the type
  expression; in a signature its bounds are implied and checked at each call; a field's type, and a
  literal against no written type, are checked only through their uses (docs/known-issues.md).

Answers taken on the open questions: implied bounds hold transitively, through every bounded type a
signature names at any depth; a projection on a concrete type stays not a form (E2142).

## Alternatives considered

- **`where` on type declarations** (`struct(I, F) where I: Iterator($T), F: fn(T) bool`). One bound
  syntax everywhere, and `$` introduces as in functions. Rejected for the projection route: with
  `I.Item` nothing needs introducing, and the bound reads best on the parameter it constrains.
- **`$` inside a type's parameter list** (`struct(I: Iterator($T), ...)`). Mixes the two ways of
  declaring a name.
- **The element type declared as a parameter** (`struct(T, I: Iterator(T), F: fn(T) bool)`). `T`
  becomes a real parameter every use spells out, `FilterIter(i32, X, Y)`, or a new kind of
  "solved, not passed" parameter.
- **A parameter aliased as an associated type** (`contract(T) { type Item = T }`). `I.Item` is then
  just `T`, which still has to be supplied: it moves the problem instead of removing it.

## Open questions

- **Implied bounds on enums and nested types.** A function taking `Option(Set(T))` assumes
  `T: Hash + Eq` through two levels: implied transitively, or only from the outermost type?
- **Projection on a concrete type** (`Counter.Item`): never, or once something needs it?
- **Associated types with parameters** (RFC-035, "Future"): `type Mapped(U)` would build on the
  projection here.
