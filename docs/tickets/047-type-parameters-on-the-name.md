---
type: language
created: 2026-11-17
linear: SH-111
relates: [RFC-008, RFC-035, RFC-046]
---

# RFC-047: Type parameters on the name

## Summary

A `type` declaration takes its parameters on the name, and its right-hand side uses them. This
holds for every right-hand side: a struct, an enum, a contract and any other type expression, which
gives FLang generic aliases.

```flang
type Pair(T) = struct { first: T, second: T }
type Result(T, E) = enum { Ok(T), Err(E) }
type From(T) = contract { fn from(x: T) Self }
type Vec4(T) = #simd struct { x: T, y: T, z: T, w: T }

type Grid(T) = List(List(T))        // a generic alias
type Pairs(T, U) = (T, U)[]
```

`struct`, `enum` and `contract` no longer take a parameter list. An anonymous body names the type
parameters of the scope around it, as it does today.

## Motivation

Commit `040fa32` (2026-02-17) moved parameters from the name to the keyword
(`type Result = enum(T, E) { ... }`) and RFC-008 kept that form. The reason, recorded in
`docs/plan-source-generators.md`, was anonymous types passed to source generators:
`#interface(Reader, struct(T) { ... })` has no name to carry parameters, so they went on the
keyword everywhere, keeping named and anonymous bodies alike.

That reason no longer holds:

- No generator argument in the tree is a generic anonymous body. The five `#interface` uses
  (`Encoder`, `Decoder`, `Reader`, `Writer`, one harness test) are not generic, and `#derive`
  names a declared type.
- Contracts cover what `#interface` was for, and interfaces are on the way.
- The checker already refuses a generic anonymous struct in type position.

An anonymous body does not need parameters of its own. A function introduces a type variable
wherever it writes `$T`, a field type included, and inference settles it at each call. Where
nothing pins it, the caller names it or inference reports it.

```flang
fn make(x: move $U) struct { v: U } { return .{ v = move x } }
fn first(p: struct { a: $T, b: $T }) T where T: copyable { return p.a }
```

On the name, the parameters sit where every use spells its arguments (`Pair(i32)`), and an alias
can take them, which the keyword form cannot express.

## Design

### Declarations

`type Name(P1, ..., Pn) = <type expression>`. Each parameter may carry a bound as today
(`type Box(T: copyable) = struct { ... }`). The parameters are in scope in the right-hand side,
directives included.

A struct, enum or contract declared this way is a generic nominal as before. The representation
does not change: each nominal tracks its own type parameters.

### Generic aliases

Any other right-hand side declares a transparent generic alias. Each use substitutes its arguments
for the parameters and expands the body: `Grid(i32)` is `List(List(i32))` with no new identity.
A use passes exactly as many arguments as the alias declares (E2165). There is no partial
application and no erasure: with `type Map(K, V) = Dict(K, V)`, both `Map(i32)` and a bare `Map`
are errors. The same holds for an alias body: `type Shelf = Box` is an error, and a rename of a
generic type spells its parameters (`type Shelf(T) = Box(T)`). This replaces the bare rename SH-107
added.

### Nested types

A type declared in a body names the owner's parameters (RFC-046):

```flang
type Tree(T) = struct {
    type Node = struct { value: T, children: List(Node) }
    root: Node?
}
```

### Anonymous bodies

`struct { ... }`, `enum { ... }` and `contract { ... }` without a name take no parameter list. Their
type variables come from the enclosing scope. Two anonymous structs are the same type when their
field names match and their field types agree once resolved (SH-110).

### Removed form

A parameter list on `struct`, `enum` or `contract` is a parse error: the parser expects `{` after
the keyword. E1052 (parameters on the name) is retired.

## Migration

About 174 generic declarations in 77 files under `stdlib/`, `lib/`, `compiler/`, `examples/` and
`tests/`. The seed rule fixes the order:

1. The compiler accepts both forms.
2. Promote the seed.
3. Rewrite every declaration mechanically: `type N = struct(P) {` becomes `type N(P) = struct {`,
   the same for `enum` and `contract`, directives kept in place.
4. The keyword form becomes the error above, and the bare rename of a generic type is refused.

