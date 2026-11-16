---
type: language
created: 2026-11-16
linear: P-SH-9
relates: [RFC-005, RFC-022, RFC-035, RFC-036]
---

# RFC-046: Lexical scopes for type declarations

## Summary

A `type` declaration is valid in every scope: a module, a type, a function, a block. A type is
visible throughout the scope that declares it and every scope nested in it, never in an enclosing
one. An inner scope may shadow any name from an outer one. Within one scope, order does not
matter: each scope is checked in two passes, declarations first.

```flang
pub fn main() i32 {
    const e = Event.Accepted(7)          // used above its declaration: same scope

    type Event = enum {
        Accepted(i32)
        Stop
    }

    return e match {
        Accepted(n) => n
        Stop => 0
    }
}

type Tree = struct(T) {
    type Node = struct {                 // a type in a type scope; names the outer `T`
        value: T
        children: List(Node)
    }
    root: Node?
}

fn count(t: &Tree(i32)) usize { ... }   // `Tree(i32).Node` from outside
```

## Motivation

- **Local types are parsed and dropped** (SH-89). `type` in a function body parses, the projector
  discards it, and every use reports an unknown type.
- **Small types belong to one function.** A value-based `select` (RFC-005 D9) maps its arms onto a
  small enum that only that function needs. Declaring it at module level leaks a name into the
  whole module.
- **The checker has no type scopes.** Every named type lives in one program-wide registry keyed
  by its full path. A bare name resolves to the current module's type of that name, then to a
  type of that name in an imported module, then (a fallback, bug SH-102) to any registered type
  at all. Nothing can be private to a function, and a local type registered there would be
  reachable from everywhere.
- **Contracts already declare named types** (`type Item`, RFC-036). A struct or enum cannot, and
  a function or block cannot. One rule for every scope removes the special cases, and is the
  structure inner functions will need.

## Design

### Scopes

| Scope | Opened by | Declares types today |
| --- | --- | --- |
| Module | a file | yes |
| Type | a `struct`, `enum` or `contract` body | contracts only (associated types) |
| Function | a function's parameters and body | no |
| Block | `{ }` in a body: `if`/`match` arms, loop bodies, plain blocks, lambda bodies | no |

Every scope may declare types with the module-level form, `type Name = TypeExpr`. What a scope
can declare is the same everywhere; only what it can see differs.

### Visibility and shadowing

- A type is visible throughout its own scope, above and below its declaration, and in every scope
  nested in it. It is never visible in an enclosing or sibling scope.
- A name resolves by walking from the innermost scope outward: block, enclosing blocks, function,
  enclosing types, module. At the module scope the existing rules apply: the module's own types,
  then imports and the prelude.
- An inner declaration shadows an outer one of the same name, whatever the scopes. Two
  declarations of one name in the same scope are an error (E_DUP_TYPE_DECL, as at module level).
- A type declared in a function or block scope has no path from outside: it cannot be named
  outside the function. A type declared in a type scope is reached from outside through its owner:
  `Tree(i32).Node`, wherever `Tree` is visible.
- `pub` is valid on a module-level type and on a type nested in a `pub` type. It is an error inside
  a private type and in a function or block scope.
- Directives (`#foreign`, `#simd`, `#derive`, ...) apply to a type in any scope.

### Two passes per scope

Modules already collect their declarations before checking anything else. Every scope does the
same: a function or block first collects the `type` declarations among its statements, then
checks its statements in order. A type can therefore be used above its declaration and two local
types can refer to each other. Bindings (`let`, `const`) keep their order: a binding is visible
from its declaration on.

### Generics

- A local type may be generic: `type Pair = struct(A, B) { first: A, second: B }` inside a
  function is used as `Pair(i32, bool)`.
- A local type may name the type parameters of every enclosing scope: a function's `$T`, an outer
  type's parameters. Calls are monomorphized, so each instantiation of the enclosing function has
  its own copy of the local type with the parameters filled in. `Tree(i32).Node` and
  `Tree(u8).Node` are distinct types.

### Identity and names

- Each `struct` or `enum` declaration is its own nominal type: two functions declaring `Event` declare two types,
  and so do two sibling blocks.
- Diagnostics, hover and `type_info(T).name` show the declared name (`Event`, `Tree.Node`).
- A value of a local type may leave its scope only where no name is needed: through a generic
  parameter, or inside a value whose type is visible. A return type or a field outside the scope
  cannot name the type.

- `type Name = OtherType` in any scope is an alias, as at module level. A struct declaring
  `type Item = T` gives the contract's associated type `Item` its answer, as `type Item` does in
  a Rust iterator: inference reads it to type the iterator and its `next`.

### Enums

Variants of a nested enum follow the enum's visibility: `Event.Accepted(7)` and the bare
`Accepted(7)` resolve exactly where `Event` does. `match` arms resolve the variant from the matched
value, as today.

### Functions on nested types

A function of a nested type must see it. Module-level functions see types declared in type
scopes (`fn len(self: &Tree(T).Node) usize`), but not types declared in functions or blocks. Those
take no UFCS functions until inner functions exist; operators built into the language (`==` on a
payload-less enum, `match`) work.

## Implementation

1. **Parser and projector** (`flang_parser`). `Stmt` gains a type declaration variant; the
   projector stops dropping it. Struct, enum and contract bodies accept `type` declarations
   beside their fields, variants and requirements.
2. **Scope tree in the checker** (`flang_typer`). Type lookup walks scopes outward and consults
   the registry only at the module scope. Nested types get a path that names their scope; the
   program-wide short-name scan and the hidden fallback never return a nested type. The same
   scopes resolve variant names, `enum_receiver` and `type_instantiation_call`.
3. **Two-pass bodies.** `check_block` collects the block's type declarations (placeholder, then
   body, as `collect_nominal_names` and `resolve_nominal_bodies` do for modules) before checking
   its statements.
4. **Re-checks and incremental demand** (RFC-022). A body is checked once rigidly and once per
   instantiation, and re-demanded after edits. A nested type follows what closures already do: a
   per-check identity, retirement at the end of `check_all`, a fact in the body and
   specialization caches, and replay with its counter burned.
5. **Every exhaustive `Stmt` match** gains an arm: the ownership pass, lowering, `param_escape`,
   the LSP's inlay hints, comptime. Lowering needs nothing else: layouts are computed from the
   registry on demand, as for closures.
6. **Docs, tests, promote.** Spec §2 (where declarations go, lookup), error codes, harness tests
   for every rule above. Compiler and stdlib code use nested types only after a promote.

Phases: 1. the scope tree, function and block scopes (SH-89); 2. type scopes for structs and
enums (`Tree(T).Node`). Inner functions are a later RFC built on the same tree.

## Decisions

### Decided (2026-11-16, by the owner)

| # | Decision |
| --- | --- |
| 1 | Every scope (module, type, function, block) may declare types; a declaration valid in one is valid in all. |
| 2 | An inner scope may shadow any outer name. |
| 3 | Order within a scope does not matter: two passes per scope, declarations first. |
| 4 | Nested types may be generic. |
| 5 | Nested types may name the type parameters of enclosing scopes, including a function's `$T`; monomorphization gives each instantiation its own type. |
| 6 | Module-level type names follow import visibility like identifiers: a transitive import is visible to the importing module's code (its monomorphized bodies included), not to its importers. The program-wide fallback is bug SH-102, fixed separately; nested types are never reachable through it. |
| 7 | `pub` is valid at module level and in a `pub` type; an error in a private type and in function and block scopes. |
| 8 | `type Item = T` in a struct is an alias that answers the contract's associated type; inference uses it to type the iterator. |
| 9 | Directives apply to types in every scope. |
