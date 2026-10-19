# FLang Language Specification

## Table of Contents

1. [Philosophy](#1-philosophy)
2. [Type System](#2-type-system)
3. [Value Semantics](#3-value-semantics)
4. [Memory Model](#4-memory-model)
5. [Operators](#5-operators)
6. [Modules and Visibility](#6-modules-and-visibility)
7. [Compilation Model](#7-compilation-model)
8. [Defined Behaviors](#8-defined-behaviors)
9. [Conventions](#9-conventions)

---

## 1. Philosophy

FLang is a statically-typed compiled language designed for explicit control, strong inference, and ergonomic syntax.

- No garbage collector — deterministic memory management with allocators and `defer`.
- Multi-phase Hindley-Milner type inference and unification.
- Nominal typing for structs and enums. Tuples are structural (anonymous structs).
- Small core language extended through the standard library and source generators.
- All operators desugar to function calls — the language is fundamentally extensible.

---

## 2. Type System

### 2.1 Primitives

`i8` `i16` `i32` `i64` `isize` — signed integers
`u8` `u16` `u32` `u64` `usize` — unsigned integers
`f32` `f64` — floating point
`bool` — boolean
`char` — 4-byte unsigned Unicode scalar (distinct type, same representation as `u32`)
`void` — absence of value
`never` — bottom type, unifies with all types (diverging computations)

### 2.2 Composite Types

| Syntax         | Meaning                                               |
| -------------- | ----------------------------------------------------- |
| `[T; N]`       | Fixed-size array                                      |
| `T[]`          | Slice — fat pointer `{ ptr: &T, len: usize }`         |
| `&T`           | Non-null reference                                    |
| `T?`           | Optional — sugar for `Option(T)`                      |
| `&T?`          | Nullable reference — sugar for `Option(&T)`           |
| `(A, B)`       | Tuple — sugar for anonymous struct `{ _0: A, _1: B }` |
| `()`           | Unit (empty tuple)                                    |
| `fn(T1, T2) R` | Function type: a `{ code, env }` pair (§7.3)          |
| `#foreign fn(T1) R` | C function type: one C code pointer (§7.6)       |
| `Type(T)`      | Runtime type descriptor                               |

**Tuples** desugar to anonymous structs with a double-underscore prefix to avoid collisions with user fields: `(A, B)` → `{ __0: A, __1: B }`, access via `t.0` → `t.__0`. User-defined fields named `_0`, `_1`, etc. remain valid. Trailing comma distinguishes single-element tuple `(x,)` from grouped expression `(x)`.

**Anonymous type expressions**: `struct { ... }` and `enum { ... }` are valid anywhere a type appears — parameters, return types, variable annotations, function fields, and the right-hand side of a `type` alias. Anonymous struct *values* (`.{ ... }`) require a target type from context — context-less `.{}` errors with a hint to add a type annotation.

**Structural typing**: FLang is nominally typed for named structs and enums. However, tuples and anonymous structs are structurally typed — compatibility is determined by field names and types, not by declaration identity. A function accepting `{ _0: i32, _1: i32 }` will accept a tuple `(i32, i32)`. This is the foundation for planned broader structural typing: anonymous structs will serve as the entry point for TypeScript-style structural compatibility, where any value with matching fields satisfies an anonymous struct type constraint.

### 2.3 Generics

`$T` introduces a type parameter. After binding, `T` (without `$`) refers to it. Type parameters can appear in any position.

```
fn identity(x: $T) T { return x }
```

Generic structs and enums use parentheses on the `struct` / `enum` keyword. A parameter may carry a bound there, on the parameter it constrains (§2.3.2):

```
type Pair = struct(T) { first: T, second: T }
type Result = enum(T, E) { Ok(T), Err(E) }
type UnmanagedSet = struct(T: Hash + Eq) { __inner: UnmanagedDict(T, u8) }
```

**Instantiation uses parentheses**: `Option(i32)`, `List(String)`, `Result(Value, JsonError)`.

Inference is multi-phase: constraints flow bidirectionally from return positions, parameter annotations, and assignment targets. Untyped integer and float literals are placeholders that must unify with a concrete type before compilation completes.

A type parameter in scope **shadows** any nominal of the same name: inside `fn wrap(e: $E) Result(T, E)`, `E` is the parameter even if a type named `E` is visible.

**Bounds.** A `where` clause after the parameters (and return type) bounds a function's type parameters by contracts (§2.3.2): `fn max(s: $T[]) T? where T: copyable`, `fn min_by(it: move $I, key: fn(I.Item) $K) I.Item? where I: Iterator, K: Ordered`. An entry may bound an associated type by its path: `where I: Iterator, I.Item: Hash`. A bound is checked at each call that binds its parameter, reported there with the requirement that failed (E2134; for `copyable`, with the derivation chain), and the body is not instantiated for a call that fails it. A bound on something other than one of the function's own type parameters, or one that is not a contract, is E2135. `where` is contextual: it opens a clause only as `where Name :` or `where Name.Item :`.

**A bound sits where its parameter is declared** (RFC-036). A function introduces its type parameters with `$` inside value parameters, so its bounds go in `where`; a struct, enum or contract declares its parameters in a list, so their bounds go on the list: `struct(I: Iterator, F: fn(I.Item) bool)`. A later parameter's bound may name an earlier parameter and its associated types, never a later one (E2144). `where` on a type declaration is refused (E2145).

**Where a type's bounds hold.** A struct's or enum's parameter bounds hold wherever the type does:

- *Written in a body*, a bounded type applied to settled arguments (`let s: Set(Point)`) is checked at the type expression (E2134). One whose arguments are still type parameters is checked at the instantiation that settles them, and reported at the call that chose them.
- *Named in a signature*, its bounds are **implied**: a function that takes or returns `FilterIter($I)` assumes `I: Iterator`, and `I.Item` is in scope. This holds through nesting (`Holder(Source($I))` implies `Source`'s bounds on `I`). The function's own `where` adds to them. A call checks what the return type implies, as it checks a `where` entry, so `fn skip(it: move $I, n: usize) SkipIter(I)` needs no `where` of its own; what a parameter's type implies solves and filters overloads but is not reported again at the call - the argument's type met it where it was formed - unless nothing has been reported yet.
- *A literal* (`FilterIter { it, f }`) is checked through the type it is written against: the annotation, the parameter or the return type it lands in.

**A generic body copies a type parameter only under the bound.** Each generic function is checked once against its own type parameters, each a rigid type that unifies with nothing else and is non-copyable unless `where T: copyable` says otherwise (RFC-029, RFC-033 6b): `T`, `Box(T)`, `(T, T)` copy only when `T` does. A copy, a move out of storage the body does not own, or a call to a function that requires `T: copyable`, is refused at the declaration, with no instantiation anywhere (E2124, E2131, E2134). Only the ownership findings come from this check: whatever is dispatched on `T` - a member call, an operator, an overload pick - waits for an instantiation, as does the liveness of a value handed to a call the check could not resolve. `#if type_info(T).copyable` reads the rigid `T` as not copyable, so the copyable branch is checked at the instantiations that take it. A template the check refused skips the ownership pass at its instantiations, so each error is reported once.

#### 2.3.2 Contracts

A contract (RFC-035) names a set of functions a type must have. It is declared as a type, takes parameters on its keyword as `struct` does (bounded the same way, `contract(T: copyable)`), and holds requirements (function declarations without a body) and associated types:

```
pub type Iterator = contract {
    type Item
    fn next(self: &Self) Item?
}

pub type Iterable = contract {
    type Iter: Iterator
    type Item = Iter.Item
    fn iter(self: &Self) Iter
}

pub type Key = copyable + Hash + Eq
```

- **`Self`** is the type being constrained, the `I` in `where I: Iterator`. Every requirement mentions it (E2141).
- **A requirement is satisfied when the call it describes resolves**, as a method call on its first parameter - overload ranking, `op_deref` peeling and a reference receiver read as its value included - and returns exactly the declared type. A by-value receiver is never adapted to a reference: `hash(self: Self)` is not met by a `hash(&T)`. The call resolves as the instantiated body would (§2.3.0): in the generic's defining module, with what the calling module makes visible unioned in - so a private `op_cmp` in the caller does not satisfy `Ordered` on `core`'s `max`, whose body could not call it. `OwnedString` is `Eq` through `String`'s `op_eq`; a payload-less enum is `Eq` through its built-in `==`, and a type with only `op_cmp` through the derived one (§5.2).
- **An associated type** is a type the bound solves rather than takes (RFC-036): `type Item` is solved from the requirements, `type Item: Bound` is solved and then held to its bound, and `type Item = TypeExpr` is derived, an alias inside the contract over `Self`, its parameters and its other associated types. An associated type is a function of the bounded type: it is known exactly when that type is, solved when the call commits. An output belongs in an associated type; a contract parameter is for an input the type is not determined by (`contract(T) { fn from(x: T) Self }`).
- **Projection.** `X.Item` names the associated type `Item` of the contract bounding `X`, in any type position where `X` is a type parameter bounded by a contract that declares `Item` (directly, through `+`, or through a name), `Self` inside a contract, or itself a projection: `C.Iter.Item` reads through `Iterable` to its `Iterator`. Inside a generic body `I.Item` is a type known by name and by its bounds alone: two uses are the same type, copyable only under `I.Item: copyable`. Two contracts on one parameter that both declare `Item` name one type. A projection no bound declares, or on a concrete type (`Counter.Item`: write the type itself), is E2142.
- **Pinning and bounding an associated type.** A contract applied with a named argument constrains one: `I: Iterator(Item = i32)` pins it, `I: Iterator(Item: Hash + Eq)` bounds it - sugar for `I: Iterator, I.Item: Hash + Eq`. `=` pins and `:` bounds, as `let x = ...` against `x: T`. Named arguments follow positional ones; one the contract does not declare, the same one twice, or one outside a bound (`List(Item = i32)`) is E2143.
- **`+`** combines contracts; a type satisfies the combination when it satisfies every part. `copyable` is the built-in contract RFC-028's derived bit satisfies.
- **A called type parameter needs a callable bound.** A generic body that calls a value of type `F` must bound `F` by a function type or a contract requiring `op_call`, or the call is E2146.
- **A function type in bound position is a contract**: `F: fn(T, U) R` holds for a function value, a closure, or a type with a matching `op_call`. A callable fits a bound that asks no more of it than its own signature does: a reading parameter fits a `&T` or a `move T` slot; a `move` parameter fits only a `move` slot, and a `&T` parameter only a `&T` slot (E2134).
- **At the use site the sigil does what it does in a signature**: `Iterator($T)` introduces `T` and the contract solves it (a name only a bound introduces may name the return type); `Iterator(String)` requires it. An anonymous contract is written in place: `where B: contract { fn get(self: &Self) $T }`.
- **A bound pins, not only checks.** Once a call picks a bounded overload, what its bounds solve is kept: `$T` from `next`'s return, a lambda argument's parameter types from `F: fn(T) bool`.
- **Overloads.** A candidate whose bound fails is dropped from the call's overload set; when no other candidate fits, the bounded one is reported with its failing requirement. Between candidates of the same shape, the one with more requirements seen to hold wins: a bound adds specificity against an unbounded type parameter, never against a concrete type.
- **A contract in a parameter's type is a bounded type parameter.** `fn copy_all(src: Reader)` is `fn copy_all(src: $R) where R: Reader`, and `it: move Iterator(Item: Hash)` is `it: move $I where I: Iterator(Item: Hash)`. The same holds behind a reference or a slice (`src: &Reader`, `xs: Reader[]`). Each occurrence introduces its own type parameter, so `fn eq(a: Eq, b: Eq)` takes two possibly different types; a function whose types must agree, or that names the parameter's associated types, writes the `$T` form.
- **A contract has no values.** Anywhere else a type is needed - a field, a payload, a type argument, `Reader?`, a tuple or array element, a return type, a local annotation - it is E2138; bound a type parameter instead.

`core` declares `Eq` (`fn op_eq(a: Self, b: Self) bool`), `Hash` (`fn hash(self: Self) usize`) and `Ordered` (`Eq` plus `fn op_cmp(a: Self, b: Self) Ord`), which `core`'s own slice, hash and math functions use; `std.collections.iter` declares `Iterator` and `Iterable` in the associated-type form above. The hashed containers bound their keys on the type, `struct(K: Hash + Eq, V)` (`UnmanagedDict`, `Dict`, `DictRef`, `UnmanagedSet`, `Set`, `MultiMap`), the searches by value (`contains`, `index_of`, `last_index_of` on slices and lists, slice `==`) bound their element `Eq`, and what orders values (`min`, `max`, `clamp`, the binary searches, `std.iter`'s `min`/`max`/`min_by`/`max_by`) bounds it `Ordered`, so a key without `==` or `hash` is refused where the container type is written or constructed, naming the contract (E2134).

Not yet: a contract in a return type or a local annotation (RFC-035 lets the body or the initializer bind it), a call on a value of an open type parameter typed through its bounds inside the generic body, the ambiguity check for a requirement that resolves two ways, mode pinning (a lambda taking `move` from a `fn(move T)` bound), `type_info` of a contract, and `dyn` (docs/known-issues.md).

#### 2.3.0 Monomorphization

Generic functions are **monomorphized at their call sites**:

- A generic function's body is validated **only when instantiated**. Each call site whose instantiated signature settles to concrete types produces (or reuses) one specialization; the body is re-checked with the type parameters bound to those concrete types, and body errors are reported per instantiation. A generic function nothing ever calls is never validated.
- Each function is instantiated **once per concrete signature** (parameter types plus return type). Two call sites with the same concrete signature share one specialization, and one emitted symbol.
- A call site whose type arguments cannot be inferred (nothing pins them) is an error (E2001) at that call site.
- **Loaded-context resolution (deliberate, and deliberately sharp):** while a specialization's body is checked, *function* overload lookups see the defining module's imports unioned with the instantiating call site's — this is what lets a generic container call a `hash()` or `deinit()` overload that only the caller imports. Because specializations dedup by signature, the **first** instantiation of a signature fixes the winning overloads for every later same-signature call site, regardless of what those sites import. Code that depends on different call sites resolving the same instantiation differently is undefined. The union applies to function lookups only; type and enum-variant names resolve against the defining module's own visibility.

### 2.3.1 Transparent type aliases

```
type VarId = u32
type NodeId = usize
type Buf = [u8; 4]
pub type Pair = (i32, i32)
```

`type Name = <type-expression>` where the RHS is anything other than a `struct(...) { ... }` or `enum(...) { ... }` builder declares a **transparent alias**: `Name` resolves to the RHS type everywhere it appears. No nominal identity is introduced and no conversion is required at use sites — `let v: VarId = 7u32` and `let n: u32 = v` are both valid without any cast.

Aliases participate in module visibility like struct/enum declarations (`pub type` is exported, bare `type` is module-private). Cyclic aliases — `type A = B; type B = A` — are rejected with **E2036**. Generic aliases (`type Pair(T, U) = (T, U)`) are not yet supported; use a `struct` or `enum` wrapper if you need a polymorphic named type.

### 2.4 Structs

```
type Point = struct { x: i32, y: i32 }
type Vec2 = struct { x: f32, y: f32 }
```

Structs are always declared as a `type` alias whose RHS is a `struct(...) { ... }` builder. The legacy `struct Name { ... }` form has been removed (RFC-008, error E1050).

- All fields public (readable from any file).
- Field writes restricted to the defining file — see §8 *Scoped mutability* (E2114).
- **Layout is the compiler's, not the declaration's** — see *Memory layout* below.
- Construction: `Point { x = 10, y = 20 }` (uses `=`, not `:`).
- Anonymous construction: `.{ x = 10, y = 20 }` (type from context).
- Field shorthand: `.{ x, y = 20 }` equivalent to `.{ x = x, y = 20 }`.
- **Strict construction**: every field must be assigned. `Point { x = 10 }` errors with E2050 ("struct literal missing field `<name>`") if `Point` has more fields. `Marker { }` is valid only when `Marker` has zero fields. Context-less `.{}` is invalid.
- **Bounded parameters**: `struct(I: Iterator, F: fn(I.Item) bool)` - see §2.3, *Where a type's bounds hold*. A field may name a parameter's associated type: `type Peekable = struct(I: Iterator) { it: I, peeked: I.Item? }` stores an `i64?` in `Peekable(Counter)` when `Counter` yields `i64`. Each instance's associated types are solved from its arguments, as a call solves a function's.
- **`Self`** inside a named struct or enum body is the type applied to its own parameters: in `type Node = struct(T) { value: T, next: &Self? }`, `Self` is `Node(T)`. By value it is the infinite-size error a by-value self-reference is (E2035). `Self` is a predeclared type name, not a keyword: valid only inside a named struct, enum or contract body (E2139), and nothing may be declared with it - a type, a `$Self`, a generic parameter (E2140).

#### Memory layout

**A struct's memory layout is unspecified.** Declaration order is not memory order, and the compiler reserves the right to change how any struct is laid out, at any time, without notice. The only guarantees are the ones the language itself gives: every field is present, correctly aligned, and reachable by name.

The compiler **reorders fields to minimise the type's memory footprint** — in practice by descending alignment, so padding falls at the end rather than between fields:

```
type Wasteful = struct { a: u8, big: u64, b: u8 }
```

In declaration order that is 24 bytes: `a`, seven bytes of padding, `big`, `b`, seven more. Reordered it is 16 — `big`, `a`, `b`, six bytes of tail padding. Nothing in the language lets a program observe the difference, which is exactly what makes the freedom safe to take.

Two consequences follow, and both matter at an FFI boundary:

1. **Field offsets are not stable across compilers or versions.** `size_of` and `offset_of` are answers about *this* build, not properties of the declaration.
2. **A plain struct cannot be passed to or returned from a C function by value.** Its bytes are laid out to suit FLang, so they match no C declaration of the same members. Use `#foreign` (§10) — that is what it is for. A compiler that cannot honour the C layout of an aggregate crossing the boundary must reject the signature rather than pass bytes C will read differently.

### 2.5 Enums (Tagged Unions)

```
type Color = enum { Red, Green, Blue }
type Result = enum(T, E) { Ok(T), Err(E) }
type JsonError = enum { UnexpectedChar, UnexpectedEnd }
```

Enums are always declared as a `type` alias whose RHS is an `enum(...) { ... }` builder. The legacy `enum Name { ... }` form has been removed (RFC-008, error E1051).

Variants can carry zero or more payload types. Tags assigned sequentially starting at 0 (first variant = 0, next = 1, ...). Parameters take bounds as a struct's do: `type Tree = enum(T: Ordered) { Leaf, Node(&Self, T, &Self) }` (§2.3).

**Naked enums** (C-style): when any variant has `= value`, all variants are integer-tagged with no payloads. Tags auto-increment from previous value.

```
type Ord = enum { Less = -1, Equal = 0, Greater = 1 }
```

**Enum ↔ integer casts:**
- `e as i32` extracts the tag. Valid for any enum.
- `(n as MyEnum)` constructs a variant by tag value. **Only allowed for bare enums** — enums where every variant is payload-less. Allowing this on a payload-carrying enum would leave payload bytes uninitialized; the type checker rejects it with E2020.
- An unsuffixed literal operand takes the tag type `i32`: `12 as Month` is `12i32 as Month`. An integer literal that no variant carries (`13 as Month`) is E2020; a runtime value is not checked.

Useful for FFI where a C shim returns an error code that matches the FLang discriminant layout. If a niche optimization later shifts bare-enum discriminants (see §2.7), both sides of the FFI boundary must update together — keep the C constants and the FLang enum declaration in the same file or adjacent files.

**Variant construction**: `Color.Red` (qualified), `Result.Ok(42)` (with payload), `Ok(42)` (short form when unambiguous).

### 2.6 String Types

Three types with explicit ownership. All share layout `{ ptr: &u8, len: usize }` and guarantee null-termination for C FFI.

**String** — non-owning view. No `deinit`. Used for literals, parameters, temporary references. Same binary layout as `u8[]`.

**Containers own their buffers.** `UnmanagedList.ptr` and `UnmanagedDict.entries` are `owned`, so every container - `List`, `Dict`, `Set`, `Deque`, `Stack` and anything holding one by value - is non-copyable (RFC-028's derived bit). A container reaches a second place through `move`, a `&T` parameter, or `clone`; reading one out of a table is `get_ref` / `lookup_ref`, and a loop over a non-copyable element is `for &x in xs`.

**Container iteration and ownership.** The iterator protocol is defined for copyable elements; an owning element type moves through a container's `drain` (`for x in xs.drain()` hands each element over; a drain is not copyable, and the loop releases it on exit, which puts the untaken tail back, §7.4). A dict lends each entry (`for e in d` binds `&Entry`), since an entry may hold owning keys or values; a set iterates by value and adds `iter_ref`, the split `List` already has. `swap` exchanges two values in place through `&move` slots (§3.2), so an owning `T` moves between two places with no copy, and the sorts compare an owning element in read mode where it lies (`fn(T, T) Ord`, §3.2). What is deliberately not settled yet: relocating owning elements through an adapter chain (docs/known-issues.md).

**OwnedString** — owns its buffer: `struct { view: String, allocator: &Allocator? }`. Must be freed via `deinit()`. Follows allocator pattern. Produced by `StringBuilder.to_string()`, `from_view()`. Every `String` read reaches `view` through `op_deref` (`s.len`, `s.starts_with(p)`, `s == t`); `hash` is declared, since the catch-all `hash($T)` would take it as written. A dict or set keyed by `OwnedString` is looked up by `String` (RFC-031).

**StringBuilder** — owning, mutable, growable buffer (`owned ptr`, so non-copyable: a builder reaches a struct with `move` and a function through `&StringBuilder`). `append()` adds content. `to_string()` transfers buffer to OwnedString (move semantics — builder resets). `as_view()` returns non-owning String view.

| From            | To            | Method                    | Cost                  |
| --------------- | ------------- | ------------------------- | --------------------- |
| `OwnedString`   | `String`      | `.view`                   | Zero-copy             |
| `String`        | `OwnedString` | `from_view(s, allocator)` | Allocates + copies    |
| `StringBuilder` | `OwnedString` | `.to_string()`            | Zero-copy (move)      |
| `StringBuilder` | `String`      | `.as_view()`              | Zero-copy (temporary) |

Conversions are always explicit — no implicit coercions between string types.

**Formattable protocol**: `fn format(self: T, w: Writer, spec: String)` writes a value's text to a sink — printf's job with the printing taken out. The sink is any `Writer`: a socket, a file, a `StringBuilder`. Building a string is one use of `format`, not the shape of it.

Every type has one, builtins included, so a generic body can format whatever it was handed. A type declares itself formattable by declaring the function, and it belongs in the file that declares the type — the same rule `deinit` follows. `std.format` holds the two sets with nowhere else to live: the primitives, which have no declaring file, and `String`, declared in `core` where `Writer` cannot be named.

A `format` body writes literals with `w.write_str(...)` and delegates values to their own `format`. `StringBuilder.append(value)` and `append(value, spec)` are the string-building front door and forward to `format` through the builder's own `writer()`.

What reaches the sink is the value's *text*: `42i32.format(w, "")` writes the bytes `4` and `2`, not the four bytes of the integer. Serializing a value's representation is a different job with a different protocol (`std.encoding.codec`).

Text reaches a sink as UTF-8, matching `String`'s in-memory encoding. A destination needing other bytes on the wire transcodes in its own writer; nothing above the sink knows or cares.

**String interpolation** (RFC-004): `$"..."`, `$(args)"..."`, and `$sb"..."` are pure syntactic sugar over `StringBuilder.append` and `to_string`. The forms desugar as follows:

- `$"seg0{e1}seg1{e2}seg2"` becomes (roughly):
  ```
  ({ let __sb = string_builder(); defer __sb.deinit();
     __sb.append("seg0"); __sb.append(e1);
     __sb.append("seg1"); __sb.append(e2);
     __sb.append("seg2"); __sb.to_string() })
  ```
  — yields an `OwnedString`. Empty segments are skipped. Because `to_string()` transfers ownership and zeroes the builder, the deferred `deinit` is a no-op on success but still frees on panic.
- `$(args)"..."` forwards `args` to `string_builder(capacity: usize = 0, allocator: &Allocator? = null)`. A lone `&alloc` argument routes to the `allocator` slot; any other single positional arg lands in `capacity`. An `&alloc` allocator argument (lone, positional, or `allocator=&alloc`) is wrapped in `Some(...)` by the desugar — the sugar owes its user the explicit wrap now that there is no implicit `T -> Option(T)` coercion.
- `$sb"seg0{e1}seg1"` becomes `({ sb.append("seg0"); sb.append(e1); sb.append("seg1") })` — type `void`. Works with any receiver that has a matching `append` overload (including a `Writer`).
- A hole `{expr:spec}` desugars to `sb.append(expr, "spec")`, dispatching to the primitive or generic `append` overload for `expr`'s type.

**Format specs**: the text after a hole's `:` is passed verbatim as the `spec` argument. Three grammars share a fill/align/width prefix, where `align` is `<` (left), `>` (right, the default) or `^` (centered), a leading `0` selects zero as the fill, and `width` is a minimum measured in bytes:

| Family | Grammar |
|---|---|
| Integers | `[fill][align][0][width][type]`, `type` one of `x` `X` `b` `o` |
| Floats | `[fill][align][0][width][.precision][type]`, `type` one of `e` `E` `a` |
| Text - `String`, `OwnedString`, `StringBuilder`, `char` | `[fill][align][0][width]` |

Content at least as wide as `width` is emitted whole; the spec never truncates. A type char has no meaning for text and is ignored. A user type receives the spec unparsed and decides what it means.

### 2.7 Option and Nullability

```
pub type Option = enum(T) {
    None,
    Some(T),
}
```

- `T?` is sugar for `Option(T)`.
- `null` is sugar for `Option.None`. The inner `T` is filled by inference from context; with no constraint the compiler reports a type-mismatch error.
- There is **no implicit `T -> Option(T)` coercion**: a present value must be wrapped explicitly with `Some(v)` wherever `T?` is expected (return value, annotated binding, struct field, argument, match arm / branch joining a `null` arm). Only `null` / `None` is implicit — the literal has no other possible type. See [ADR-0005](adr/0005-remove-implicit-option-wrapping.md), which supersedes ADR-0002.
- `null` is **not** a pointer value. `&T` is non-null by type; `let p: &i32 = null` errors. Use `&T?` for a nullable reference.
- `&T?` is `Option(&T)`. The niche optimization (a 0-pointer encodes `None`) is unchanged — same wire format.
- Variant constructors: `Some(v)` and `None` work as canonical constructors.
- Methods: `is_some()`, `is_none()`, `unwrap()`, `unwrap_or(fallback)`, `expect(msg)`, `map(fn(T) U)`.
- Pattern-match with `match opt { Some(v) => …, None => … }`. The compiler knows about Option's representation and lowers Some/None match arms through both the niche-pointer and tagged-enum forms.

**Variant order matters:** `None` is declared first so it gets discriminant tag `0`. Struct fields of type `Option(T)` and zero-initialized memory therefore default to `None`, which is what every existing call site expects.

The legacy field-access shims (`opt.has_value` / `opt.value`) have been removed; access the payload through `match`, `is_some()` / `is_none()`, `unwrap()` / `unwrap_or(...)`, or `?.`.

**Layout:**

| Inner type       | Representation                                           | Rationale                                                       |
| ---------------- | -------------------------------------------------------- | --------------------------------------------------------------- |
| `&T` (reference) | `IrPointer(T, IsNullable: true)` — a nullable pointer    | Niche: `None` encoded as 0 pointer. Zero overhead vs. raw `&T`. |
| Anything else    | Tagged enum with `None` (tag `0`) and `Some(T)` variants | Generic enum layout.                                            |

**Planned niche for bare enums (not yet implemented):** when `T` is a payload-less enum, shifting discriminants to start at 1 lets `Option(E)` encode `None` as tag 0 in a single-word representation — matching the nullable-pointer trick. This would change discriminant values, which is why FFI code must never hard-code them (see §2.5).

### 2.8 Result

```
pub type Result = enum(T, E) { Ok(T), Err(E) }
```

Methods: `is_ok()`, `is_err()`, `unwrap()`, `unwrap_err()`, `unwrap_or(default)`, `expect(msg)`.

### 2.9 Type Literals and RTTI

```
let t: Type(i32) = i32
let s = size_of(i32)        // from core.rtti
let a = align_of(Point)
```

`Type(T)` is a built-in generic struct carrying runtime metadata. Type names used as values become `Type(T)` instances. The compiler emits one static `TypeInfo` descriptor per type into the data segment, minted on first use and cited by every later one: a `Type(T)` value, a `type_info` / `type_of` result, a field's `type_info`, a `type_args` entry all point into that table. Introspection is a pointer read, and a descriptor cites itself where the type does (`Tree { kids: List(Tree) }`).

> `Type(T)` is the generic (phantom-`T`) view of the raw `TypeInfo`, à la Java `Class<T>` / `Class`; `Type(T)` -> `TypeInfo` is implicit phantom erasure. Descriptors are interned, so `&TypeInfo` pointer identity is type identity. See [ADR-0001](adr/0001-type-t-is-the-generic-view-of-typeinfo.md).

`TypeInfo` (`core.rtti`) carries `name`, `size`, `align`, `kind: TypeKind`, `copyable` (the derived bit of RFC-028: false when the type or anything it holds by value declares an `owned` field), `fields: FieldInfo[]` (structs), `variants: VariantInfo[]` (enums), `params: ParamInfo[]` and `return_type` (function types). `type_info(T) &TypeInfo` is the descriptor of a type (`type_info(Point)`, `type_info(T)` in a generic body) and `type_of(v) &TypeInfo` the descriptor of a value's type. Both return the table entry, so `type_of(x) == type_info(u32)` is type identity; `type_info` is folded to the entry's address at the call site, as `size_of` is to a constant. It is also the introspection surface of source generators (§7.8): the same struct, the same members, so compile-time generation and runtime reflection never diverge. `TypeInfo` grows only for a demonstrated need — no convenience flags (`is_struct` is `kind == TypeKind.Struct`).

**Project metadata**: `core.rtti` also exposes `ProjectInfo { name: String, version: String }` and `project_info() ProjectInfo`. The compiler substitutes each call with the metadata of the project that *lexically owns* the call site — sourced from that project's `flang.toml`. A library calling `project_info()` inside its own module sees its own name and version; the same call inside a consumer returns the consumer's. Call sites in stdlib modules fall back to `("stdlib", "")`. See `docs/architecture.md` for implementation details.

### 2.10 Char and Byte Literals

- `'x'` — char literal (type `char`, 4 bytes). Supports `\n`, `\t`, `\r`, `\\`, `\'`, `\0`, `\uXXXX` (1-6 hex digits).
- `b'x'` — byte literal (type `u8`). Same escapes except `\u`.

### 2.11 Integer and Float Literals

- **Closed suffix list** — exactly the primitive integer/float type names: `i8 i16 i32 i64 isize u8 u16 u32 u64 usize f32 f64`. No others are recognized.
- `_` is a separator anywhere inside a number (between digits, before a suffix). Leading `_` is not allowed (would be an identifier).
- A digit-led identifier is a lexer error — `42_pixels` is not a number with a `pixels` suffix; it is an invalid identifier.
- Hex: `0xff`, `0xDEAD_BEEF`.
- Underscore separators: `1_000_000`, `0xff_ff`.
- Scientific notation: `1.5e10`, `3e-4`.
- A suffixed literal **is** its suffix's type: `0u32` is a `u32` value, and unifying it against an incompatible expected type is an error.
- Unsuffixed integers and floats are inferred from context. A bare literal as a cast operand takes the cast's target type (`0xFFFF_FFFF as u64` is a `u64` constant, not an `i32` converted), or `i32` when the target is an enum (§2.5). A literal that no context ever pins is an error (**E2001**).
- **An unsuffixed numeric literal never defaults to a concrete type.** It carries a candidate set, not a type, and nothing settles it but the program: an annotation, a suffix, a cast target, or a parameter it is passed to. Where the candidate set holds more than one type and nothing chooses, that is **E2011**, not a silent pick - `sb.append(3)` is an error and `sb.append(3i32)` is how it is written. This is a deliberate and permanent rule, not a gap awaiting a default: a defaulted literal decides a type the program never states, and the signed/unsigned reading of the same bits is exactly what the program must say out loud. A char literal is the one case with a preferred type (`char` over `u8`), because `'a'` already names it.

### 2.12 Trailing Commas

Comma-separated lists accept a trailing comma uniformly: function-call arguments, struct/enum literal fields, parameter lists, `where` bound lists, generic type parameters, enum variant declarations, match arms (when commas are used as separators inside a single arm body), array literals, etc. The single-element tuple `(x,)` keeps its distinct meaning — the trailing comma is what makes `(x,)` a 1-tuple rather than a grouped expression.

### 2.13 Comments

`// line comment to end of line` is the only comment form. There is no `/* */` block comment, no `///` doc comment. Editor tooling handles "comment out a block" by inserting `//` per line.

**Docstrings.** A run of `//` lines directly above a declaration is its docstring: each line holds nothing but indentation before the `//`, and no blank line sits between the run and the declaration's first token (`pub`, a `#directive`, a field or variant name). The rule is positional, not lexical - there is no `///`. It applies to every declaration: functions, types, fields, enum variants, consts. The run a file opens with is the module's docstring when a blank line (or the end of the file) separates it from what follows; glued to the first declaration, it documents that declaration instead. Read as prose, a docstring drops each line's `//` and one following space; what remains is structured the way Go doc comments are: a blank line (`//` alone) separates paragraphs and wrapped prose lines flow together; a line opening with `- `, `* `, `+ ` or `1. `, indented or not, is a list item and indented lines under it continue the item; any other run of indented lines is a code block, shown verbatim; backtick spans are inline code. Nothing else is syntax, though tooling renders the text as markdown so its other constructs work where a client supports them. Docstrings have no semantic effect; tooling (the LSP hover) surfaces them.

---

## 3. Value Semantics

### 3.1 Storage and Assignment

Every named binding has a memory location. `let x = expr` performs a shallow byte-copy. Pointers inside are copied as-is (aliasing possible). No hidden reference counting.

### 3.2 Function Arguments

**Implicit reference, copy-on-write:**

- Caller passes address of each argument (implicit reference).
- Callee reads through pointer (no copy for read-only access).
- The compiler inserts a shadow copy (alloca + memcpy) when the body **writes** to a parameter or lets its **address escape**. All accesses then use the shadow.
- Escape means: passed as an argument to any call, stored somewhere outliving the expression, or returned as an address. Reading a field, indexing, matching, operating on a scalar read out of the parameter (`p.n + 1`, `n as i64`, `-n`), and returning the value by copy are not escapes.
- The caller's value is never mutated by the callee.
- A non-copyable parameter is never shadowed (§3.2 parameter modes): without `move` it cannot be written, and with `move` the caller no longer holds the value.

This is transparent — source code reads as pass-by-value, but large structs avoid unnecessary copies.

`&` in a signature communicates intent to mutate or retain. `fn f(s: S)` and `fn f(s: &S)` emit the same code for a read-only body, because everything already crosses by pointer.

The guarantee is value semantics: a parameter reads as a value, and the callee never mutates the caller's. Crossing by address and eliding the copy is how the compiler meets it, not part of it. Whether a read-only parameter shares the caller's storage is unspecified, and how an argument crosses is the backend's choice (RFC-041 passes small aggregates in registers). Section 5.4 refuses the one cast that could break the copy-on-write analysis: a reference fabricated from an integer could write through a laundered parameter address.

**Parameter modes (RFC-033).** A function states ownership in its signature, never at its call sites:

- `x: &T` shares `x` with the function.
- `x: move T` moves ownership into the function. A non-copyable binding passed to it is dead after the call; a copyable one is copied. `move &T` is an error (E2130).
- `x: &move T` is a **slot**: everything `&T` allows, plus taking the value out (`let v = move x.*`), on the obligation of putting one back before the function returns (E2137). The caller keeps the slot; the value in it may be a different one afterwards. It is the only mode that empties storage its caller keeps, so it is declared in `core` alone (E2136) - `core.slice`'s `swap` and `replace` are how every other module reaches it - and it is a parameter mode only, never a field, return or binding type.
- `x: T` reads. A copyable `x` may be copied and written (the function's own copy). A non-copyable `x` may be read and passed on to another `T` parameter; writing, sharing, binding, returning or moving it is refused (E2131).

**What `move` may take.** A binding, a field of a binding the function owns, the value in a `&move` slot, or a place reached through an `owned` field of a type the current module declares (E2131 for a plain field, E2125 for an element or dereference, E2127 for a field declared elsewhere). The last case is the scoped-mutability right a type's own module has over the storage it releases: `std.collections.list` takes an element back out of `owned ptr` the same way it stores one into it, and `std.collections.dict` takes a key out of `(self.entries + i).key`. A plain field is not storage the type releases, so rule 3 decides it everywhere: `s.conn` through `s: &Session`, or from a read-only `s: Session`, stays with its owner even in `Session`'s module. The chain is read where the move is written, so a local reference binding (`let at = s.ptr + i` then `move at.*`, or `const entry = self.entries + i` then `move entry.value`) loses the provenance and is refused. A place handed to a `move` parameter or a `move self` receiver follows exactly this rule, since the call site carries no `move` (E2129): `release((s.ptr + i).*)` is what `let v = move (s.ptr + i).*` is. Inside `owned` storage the module is trusted rather than tracked: the move does not mark the slot dead, so reading it again is the module's own error to avoid. A plain field taken through a reference is `replace(&self.f, fresh)`.

**Bulk moves** go through `core.slice` (RFC-034), never through byte calls: `copy_to(src, dst) where T: copyable` duplicates, and `move_to(src, dst)` relocates, leaving the source slots dead. Both allow overlap and panic when `dst` is shorter than `src`. `move_to` of a non-copyable `T` holds `src` to the rule above, the chain read through `slice_from_raw_parts(p, n)` and ranges written in the call (E2125); its two arguments are exempt from each other under E2133, since a shift overlaps by design. `as_bytes(s) where T: copyable` views a slice's bytes. Outside `core` FLang source does not call `memcpy`, `memmove` or `memset`; the casts that remain are the allocator boundary, type erasure, the null spelling and FFI.

The receiver follows the first parameter. A call site carries no ownership marker (`f(move x)` is E2129). A non-copyable temporary must reach an owner: one passed to a `T` parameter, a read-only receiver or an operator, read for a field, or discarded, is E2132. A call cannot move or share a place that another of its arguments reaches through owned state (E2133): one argument containing another, or the same place twice. Two DIFFERENT elements of one container are not that - `swap(&s[i], &s[j])` is fine, `swap(&h, &h)` is not - and an index the check cannot read as written counts as a different one, leaving run-time aliasing where §3.6 leaves it. A function type carries its parameters' modes: `fn(T)` and `fn(move T)` are distinct types.

### 3.3 Return Values

| Return type                    | Mechanism                                                                                               |
| ------------------------------ | ------------------------------------------------------------------------------------------------------- |
| Small values (≤ register size) | Returned in registers                                                                                   |
| Large structs                  | Caller allocates slot, passes hidden `__ret` pointer as first argument. Callee writes directly to slot. |

This is transparent to the programmer — `return expr` works uniformly.

### 3.4 References

- `&x` takes address of a variable.
- `ptr.*` explicit dereference (produces a copy).
- `ptr.field` auto-dereference (reads/writes through pointer, no copy). Recursive through `&&T`.

### 3.4.1 Place Expressions

A **place expression**, or **lvalue**, denotes a storage location: it names memory that exists independently of the expression, and can be read from, written to, and addressed. A **value expression**, or **rvalue**, denotes a value with no location of its own; it exists only as the result of evaluating the expression.

Both names are used throughout this spec and in diagnostics. *Place* and *lvalue* are the same thing, as are *value expression* and *rvalue*.

Every expression is lowered in exactly one of these two modes, and which mode applies is a property of the *context*, not of the expression.

**The place forms.** These, and only these, denote places:

| Form         | Place when                                    |
| ------------ | --------------------------------------------- |
| `x`          | `x` is a local, parameter, or global          |
| `p.*`        | always — the pointer already is the address   |
| `base.field` | `base` is a place, or is a reference          |
| `base[i]`    | `base` is a place, or is a reference or slice |

Everything else — call results, literals, arithmetic, struct literals, `match` results — is an rvalue. An lvalue is also usable as a value, by loading it; an rvalue is not usable as a place.

**Place contexts.** An expression must be lowered as a place when it appears as:

1. the target of an assignment — `place = v`, and the base of a compound target
2. the operand of `&` — `&place`
3. the receiver of a call whose corresponding parameter is `&T`, including UFCS — `place.method()`
4. the base of a field or element access that is itself in a place context

Rule 4 is the recursive one, and it is the rule that matters: **place-ness propagates leftward through a path.** In `a.b.c = v`, the assignment target `a.b.c` is a place, so its base `a.b` must be a place, so its base `a` must be a place. A path of any depth is addressed end to end; no intermediate is ever materialized.

**The invariant.** *Lowering a base in a place context must never copy the aggregate.* Copying an intermediate produces a temporary, and everything derived from it is then wrong in a way that compiles silently:

```flang
outer.mid.inner.incr()   // mutation lands in the temporary and is lost
let p = &outer.mid.inner // pointer into dead stack
outer.mid.arr[0] = 1     // store discarded
```

**Value contexts** are the complement: reading `a.b.c` for its value, passing by value, arithmetic operands. There a copy is correct and expected — FLang is a value-semantics language (§3.1).

**Rvalue materialization.** When a value expression appears where an address is required — `&f()`, or a by-value call result used as a `&T` receiver — it is materialized into a fresh temporary whose address is taken. The temporary lives to the end of the enclosing statement. This is the *only* case in which a place context operates on a temporary, and it applies exclusively to expressions that were never places; a genuine place is never materialized.

**Diagnostic.** Using a value expression where a place is required is an error (`E3005`, "expression is not assignable"). An assignment target is never silently materialized instead.

### 3.5 Scope and Lifetime

Variables are valid from declaration to end of enclosing block. A binding of a copyable type is always usable while in scope (C-like). A binding of a non-copyable type (RFC-028) is live or moved: passing it to a `move` parameter, returning it, or `let b = move a` moves it, using it afterwards is E2123, and assigning to it makes it live again (assigning over a live one is E2126). The same holds per field: moving a field out of a binding the function owns leaves the binding incomplete, so using the field or anything enclosing it is E2123 until the field is assigned; siblings stay usable.

### 3.6 Safety Model

The compiler enforces two things: scoped mutability (§8) and the ownership of non-copyable values (§3.2, §3.5). For a non-copyable value, a moved binding is not used again (E2123), a live one is not overwritten (E2126), so a consuming `deinit` or `close` cannot run twice; a temporary reaches an owner (E2132); and one call cannot release or grow a value that another of its arguments reads (E2133). The following are the programmer's responsibility:

- Double-free and use-after-free of copyable data, and of storage reached through a reference (`&T` is not tracked)
- Aliased mutation with no owned state in the overlap
- Data races
- Dangling references (String views and `&T` must not outlive the storage they point into; a closure must not outlive its captures, §7.3)
- Inside a module's own `owned` storage, reading a slot again after moving out of it (§3.2)

---

## 4. Memory Model

No intrinsic allocator. No heap management guarantees. All memory management is explicit.

### 4.1 Allocator Pattern

All stdlib types that perform heap allocation use a vtable-based allocator:

```
pub type Allocator = struct {
    impl: &u8
    vtable: &AllocatorVTable
}

pub type AllocatorVTable = struct {
    alloc: fn(&u8, size: usize, alignment: usize) u8[]?
    realloc: fn(&u8, memory: u8[], alignment: usize, new_size: usize) u8[]?
    dealloc: fn(&u8, memory: u8[], alignment: usize) void
}
```

**Rules:**

1. Types that allocate have an `allocator: &Allocator` field.
2. **The default allocator is the context's** (§4.4). `std.allocator` declares two context fields, both defaulting to the global (malloc) allocator: `allocator`, the default for everything, and `temp_allocator`, for memory nothing frees on its own, reclaimed all at once by the scope that rebinds it (a request, a frame, a test). An allocator parameter defaults to the current one: `allocator: &Allocator = context.allocator`, evaluated at the call. A null `&Allocator`, which only zero-initialization produces, resolves at the leaf (`alloc`, `realloc`, `dealloc`) to the current context's allocator, so a zero-initialised container (`let xs: List(i32)`) works with no constructor; grown and freed under different contexts it reaches different allocators, which is the programmer's to avoid. A method that defaults to its receiver's own allocator keeps `allocator: &Allocator? = null` (`allocator ?? self.allocator`): a default value cannot name another parameter.
3. All allocation/realloc/free go through the allocator — never raw `malloc`/`free`.
3a. **Every entry point carries the alignment**, next to the `memory` it finishes describing and ahead of any new size, and `realloc`/`dealloc` must be given the one the matching `alloc` was: an allocator cannot recover it from a pointer, a block that moves has to land on it, and a platform whose over-aligned blocks need their own release path has to know which kind it holds. The typed helpers (`free(&T)`, `free(T[])`) derive `align_of(T)`; raw byte-slice callers pass it explicitly.
3b. **`MAX_ALIGN` (16) is the global allocator's ceiling, not the interface's.** It is what `malloc`/`realloc`/`free` guarantee. An allocator built on them declines a request above it — returning null, never memory that does not meet it — and satisfying one means `aligned_alloc`/`_aligned_malloc` with a matching release path. The bump allocators (arena, fixed buffer) align their own cursor and have no such limit.
4. Types that allocate hold their storage in an `owned` field, which makes them non-copyable, and provide `deinit(self: move T)` for deterministic cleanup.
5. Callers use `defer x.deinit()` for scope-based cleanup, registered right after the value is created.
6. **`deinit` consumes its value.** The binding is dead after the call, so a second `deinit` is E2123 at compile time, never a run-time double free. No released value is left behind, so there is no released state to test for.
7. **Containers cascade**: `List.deinit`, `Dict.deinit`, `Option.deinit`, etc. release their live elements (keys and values for dicts) through `release` (§Ownership vocabulary) before freeing their storage, so an owning element type must declare a `deinit` and it must be `pub` - the container instantiates where the type is not in scope. Do not hand-loop element deinits before a container deinit. An element leaves its container only through `pop`, `remove` or a drain; handing a stored element to a `move` parameter is E2125. Read and mutate stored values in place through `for &x in xs`, `get_ref` or `op_index_ref`.
8. **`Dict.set` on an existing key releases the value it replaces**, and the new key too, since the entry keeps the one it has.

```
let sb = string_builder(64)
defer sb.deinit()
```

This enables arena-based bulk deallocation: allocate many objects into an arena, free them all by resetting the arena.

**Defer ordering on `return`.** A `return expr` evaluates `expr` first, then fires the active defers in LIFO order, then transfers control. This lets `defer x.deinit()` coexist with a return expression that reads `x` (`return x.as_view().len`, `return sb.to_string()`, etc.) — the read observes `x`'s pre-deinit state, and the deferred call sees whatever state the return expression left behind (e.g. `to_string` zeroes the builder so the deferred `deinit` is a no-op). Returning `x` itself moves it, so a `defer x.deinit()` still active would release a moved value: that is E2123 at the defer. Drop the defer for a value you return.

### 4.2 Zero Initialization

All memory is zero-initialized by default. Variables declared without an initializer are memset to zero. The compiler may optimize this away when provably written before read.

Zero initialization covers the whole allocation, not just the named fields: aggregate construction (struct literals, enum variants, tuples, closures) zero-fills its storage before storing fields, so padding bytes, the tag-to-payload gap in tagged enums, and the unused space of smaller variants all read as zero. Byte-wise consumers rely on this — the generic `hash` in `core.hash` folds every byte of a value, and equal values must produce equal hashes.

### 4.3 Reference Counting (Rc and Arc)

`Rc(T)` provides shared ownership of a heap-allocated value. `Arc(T)` is the thread-safe variant using atomic operations on the reference count. Both live in `std.rc`.

**Control block layout**: `RcInner(T) = { ref_count: usize, value: T }`. Single heap allocation — no separate allocation for the control block.

**Construction**:
- `rc(value, allocator?)` / `arc(value, allocator?)` — moves value into a new heap allocation.
- `rc_alloc(allocator?)` / `arc_alloc(allocator?)` — zero-initializes for in-place fill via `op_deref`.

**Operations**:
- `.retain()` — explicit refcount bump. Returns a new handle to the same value. A handle holds one count, so it is not copyable (`owned __inner`): `let r2 = r` is E2124.
- `.clone()` — not a bump: it peels through `op_deref` to `T`'s own `clone` and yields an independent `T`.
- `.deinit()` — consumes the handle and gives its count back. At zero, releases the value (`release`, statically dispatched via monomorphization — no function pointer in the control block) then frees the allocation.
- `.op_deref()` — returns `&T`, enabling transparent field access: `rc.field` instead of `rc.borrow().field`.

**Arc atomics**: `Arc.retain()` uses `atomic_fetch_add`, `Arc.deinit()` uses `atomic_fetch_sub`. Backed by C11 `<stdatomic.h>` via `std.atomic`.

**Conventions**: Internal fields use `__` prefix (`__inner`, `__allocator`). No `Weak` references yet — `RcInner` stays opaque for future addition.

### 4.4 Runtime Context

Every FLang function runs under one current **context** (RFC-038): a value of the compiler-provided type `Context` (declared in `core.runtime`, so the prelude makes it visible everywhere), whose fields are the program's `context` declarations. Code reads it, copies it and rebinds it for a scope; it never mutates it.

```
pub context logger: &Logger = &stderr_logger
context span_depth: u32 = 0             // module-private

fn handle(req: &Request) {
    context.logger.info("start")
    let saved = context                 // a copy, type `Context`
    context(logger = &req.log) { run(req) }
}
```

**Declaration.** `[pub] context <name>: <Type> = <default>`, top level only. The type and the default are both required; there is no zero-init.

- The type is copyable (E2147): a context is copied by `let c = context`, by a rebind, and by `defer`. Shared or owned state goes in by reference (`&T`), owned by the scope that rebinds.
- The default is a constant initializer (E2148): a literal, a negated number literal, a function name, a payload-less variant, the address of a module constant, a pointer cast of such an address, or a struct literal of those. The root context is a static, so it exists before any constant initializer runs.
- Visibility is `pub` or module-private and covers both reading and rebinding. Two declarations of one name in one module are E2005.

**Use.**

- `context.<name>` reads a field. The name resolves among the fields visible from the module: its own, private or not, and the `pub` fields of the modules it sees (§6). None is E2150; two visible fields of one name are ambiguous (E2152).
- `context` alone is a copy of the current context, of type `Context`. `ctx.<name>` reads a saved copy the same way, through a reference too (`c: &Context`).
- The current context has no address (`&context`, `&context.f`: E2149) and is never assigned into (`context.f = v`: E2149). A by-value field passed to a `&T` receiver (`context.deadline.check()`) lends a copy. A `Context` is made only by `context`; a struct literal of it is E2153.

**Rebinding.** `context(args) { body }` runs `body` under a new context. It is a block construct like `for` and `match`, not a call: `return`, `?`, `break`, `continue` and `defer` in the body act as in any block, and the construct is an expression whose value is the body's.

- The arguments follow the call rule: an optional positional `Context` is the base (the current context when omitted), then named fields override it. The base comes first and only once (E2153); a field is named at most once (E2151); a named field is a visible one (E2150), typed by its declaration.
- The arguments evaluate under the outer context, left to right. The change lasts exactly as long as the body; there is no form without one.
- One token after `context` decides the form: `(` a rebind, `.` a field read, anything else a copy.

**Semantics.**

1. **Dynamic scope.** A callee runs under its caller's context at the time of the call.
2. **Closures do not capture the context.** A closure runs under whoever calls it. To run under the creator's context, capture a copy and rebind to it inside the body: `const saved = context; fn() { context(saved) { work() } }`.
3. **`defer` keeps its own context**: the deferred expression runs under the context current where it was written, wherever the scope is left from.
4. **Generics are unaffected.** The context is not part of an instantiation.
5. **Entry.** `main`, the constant initializers and every `test {}` block run under the root context: every field at its default.

**ABI.** Every FLang function, closure body and test block takes two hidden parameters after its own, and after the result buffer of an aggregate return: the address of the current context (`const Context *`), then `env`, the state of the function being called (RFC-037). Every call passes both; a direct call passes a null `env`, which only a closure body reads. `#foreign` functions take neither, a body declared `#foreign` included: it runs under the root context. A `fn` value calls through the same convention; a `#foreign fn` value is one C code pointer called with the arguments alone (§7.6). A rebind builds the new context in the caller's frame and passes its address within the body; leaving the body needs no code. The layout of `Context` holds every field of the program, ordered by module FQN then declaration order.

---

## 5. Operators

### 5.1 Precedence (highest to lowest)

| Level | Operators                 |
| ----- | ------------------------- |
| 13    | `as` (postfix typed cast) |
| 12    | `*` `/` `%`               |
| 11    | `+` `-`                   |
| 10    | `<<` `>>` `>>>`           |
| 9     | `&` (bitwise AND)         |
| 8     | `^` (XOR)                 |
| 7     | `\|` (OR)                 |
| 6     | `..`                      |
| 5     | `<` `>` `<=` `>=`         |
| 4     | `==` `!=`                 |
| 3     | `and`                     |
| 2     | `or`                      |
| 1     | `??` (right-assoc)        |
| 0     | `match` (postfix, lowest) |

- `as` is a postfix typed operator that binds tighter than every binary operator: `a + b as i32` parses as `a + (b as i32)`.
- Postfix `match` binds looser than every binary operator: `a + b match { ... }` parses as `(a + b) match { ... }`.
- `and`/`or` are keywords, short-circuit, bool operands only.
- `!expr` logical NOT, `&expr` address-of (prefix unary).
- `>>` arithmetic right shift (sign-preserving). `>>>` logical right shift (zero-fills).
- A shift's result has the left operand's type. A shift count written as an
  integer literal must be in `0..width-1` of that type (E2121); `isize`/`usize`
  are checked against their widest (64-bit) layout. A runtime count is not
  checked and must satisfy the same bound.

### 5.1.1 Evaluation order

**Operands evaluate left to right, and each is fully evaluated before the next
begins.** This holds for function-call arguments, binary operator operands,
struct-literal field initializers, array- and tuple-literal elements, and index
expressions. It is a guarantee, not an artifact: code may rely on it.

```
let n: i32 = 0
f(tick(&n), tick(&n))       // f receives 1, then 2 - never 2, then 1
check(syscall(&err), err)   // `err` is read after the call has written it
```

The call target itself is evaluated before its arguments. Short-circuiting
operators (`and`, `or`, `??`) evaluate their right operand only when the left
does not already decide the result; the left-to-right rule is what makes
"already decide" meaningful.

Assignment is left to right like everything else: the place is evaluated
before the value stored into it, so in `dst[i()] = v()` the index call runs
first.

**This is deliberately stronger than C.** C99 §6.5.2.2p10 leaves the order of
evaluation of function arguments *unspecified*, and C++17 sequenced arguments
without ordering them. C# and Java both guarantee left to right, and so does
FLang: targeting C99 means matching its capabilities and operator semantics,
not adopting the places where it declined to decide.

The guarantee is therefore enforced by the backend, which lowers every operand
to its own temporary in source order:

```c
int32_t call_5 = __flang_fs_open(p, mode, &fd, &err);   /* argument 1 */
int32_t load_6 = *(int32_t*)&err;                       /* argument 2 */
result_t  call_7 = check(call_5, load_6);
```

Any future backend must preserve this. A backend that emitted arguments as C
sub-expressions would inherit C's unspecified order and silently break code
this spec says is correct - the guarantee is a compiler obligation, not a
property of the target.

Regression tests: `tests/harness/eval_order/`.

### 5.2 Operator Functions

An operator and its `op_*` function below are one thing: `a == b` is `op_eq(a, b)`. A user type enables an operator by defining the function; the checker records the pick on the node and lowering emits an ordinary call. The primitive types have theirs too, declared in `core.ops` with the built-in operation as body and `#inline`, so `op_add(a, b)` on `i32` can be called, passed as a function value and bound by a contract like any user type's; the operator expression on primitives emits the built-in directly, so no user `op_add(i32, i32)` captures integer addition. The set follows the type: every primitive has the six comparisons; every number `+ - * / %`; signed numbers unary `-`; integers `& | ^ << >> >>>` and `~`; `bool` `& | ^` and `!`. A payload-less enum's `==` is the built-in tag compare, and `!=`, `<`, `>`, `<=`, `>=`, `==` derive from `op_ne` or `op_cmp` when a type defines those instead (§5.2 ladder); a contract requirement named after an operator function holds wherever the operator applies, derivations included (§2.3.2).

| Operator                                          | Function                                        |
| ------------------------------------------------- | ----------------------------------------------- |
| `+` `-` `*` `/` `%`                               | `op_add` `op_sub` `op_mul` `op_div` `op_mod`    |
| `==` `!=` `<` `>` `<=` `>=`                       | `op_eq` `op_ne` `op_lt` `op_gt` `op_le` `op_ge` |
| `&` `\|` `^`                                      | `op_band` `op_bor` `op_bxor`                    |
| `[]` (ref-form)                                   | `op_index_ref`                                  |
| `[]` read (value-form) / `[]=` write (value-form) | `op_index` / `op_set_index`                     |
| `??` (§5.3)                                       | `op_try`                                        |
| postfix `?`                                       | `op_try`                                        |
| `=`                                               | `op_assign`                                     |
| `+=`                                              | `op_add_assign`                                 |
| unary `-` / `!` / `~`                             | `op_neg` / `op_not` / `op_bnot`                 |
| `.field` (fallback)                               | `op_deref`                                      |
| `t(args)` (callable types)                        | `op_call`                                       |

**`op_call`** (RFC-014): when `t(args)` is invoked and `t`'s type defines `fn op_call(self: T, ...)` or `fn op_call(self: &T, ...)`, the call rewrites to `op_call(t, args...)` (or `op_call(&t, args...)`). Any type can become callable — comparators with state, function objects, iterator-like wrappers, and (Phase 2) capturing closures. Multiple `op_call` overloads on the same type are resolved by the existing overload mechanism. `op_call` resolution chains through `op_deref`: a wrapper is callable when the type it derefs to is, no special-casing required. `op_call` dispatch also applies in field position: `h.f(args)` where field `f`'s type defines `op_call` (e.g. a capturing closure stored in a struct field) rewrites to `op_call(&h.f, args...)`, calling in place through the field — no local copy needed.

**`op_deref`**: When `x.field` fails to resolve on type `X`, the compiler looks for `fn op_deref(self: &X) &T`. If found, resolution retries on `T`. Chains through multiple layers: `Rc(Wrapper(Point)).x` resolves through two `op_deref` calls. Own fields on `X` always take priority — for field access `op_deref` is only consulted when direct resolution fails. For a UFCS call `x.method()` the peel is the last receiver tier of overload ranking (§Imports): it is tried only when no overload takes `x` as written or adapted to `&x`, and then the fewest hops win. An overload matching `X` itself, a catch-all `$T` included, always wins over one reached through a hop, so a wrapper that wants the inner type's reader under a catch-all declares that reader itself. Binary operators peel the same way: when no operator function matches the operands as written, each operand is tried through its `op_deref` chain, fewest hops first and the left side first at a tie, so `owned == "text"` reaches `String`'s `op_eq`. Only nominal operand pairs dispatch, peeled or not: a wrapped primitive never reaches an operator function or a builtin operation. Indexing and `for` are that same resolution, since they are method calls in disguise: `xs[i]` resolves `op_index_ref`/`op_index`, `xs[i] = v` resolves `op_set_index`, and `for x in xs` resolves `iter` (or `iter_ref` for `for &x`) exactly as `xs.iter()` would, so `for` over a wrapper compiles to the same code as its desugaring. This is a general-purpose language feature, not specific to smart pointers: `List` reaches its `UnmanagedList` storage through it (§9.4), indexing and iteration included.

`op_deref` itself only ever turns a reference into another reference, `&W → &I`. It applies to the receiver and, per RFC-020, to every argument of a call, spelled either way (`w.f()` and `f(&w)` resolve the same). An argument that does not fit its parameter as written is retried through the chain and takes the first shape that fits: `&I`, or `I` by value when `I` is copyable - the decay of an owner to the view it holds (`OwnedString → String`). `List(T)` does not decay to `T[]`: its chain ends at `&UnmanagedList(T)`, which holds no slice; pass `xs.as_slice()`. Peeling to a non-copyable value is refused, since it would hand one resource to two owners, and nothing yields a reference from a value outside the UFCS sugar (§7.2). Each hop costs in ranking, so an overload taking the argument as written always wins.

**Indexing (`[]`)** — two mutually exclusive patterns for user-defined types:

| Pattern                          | Signature                                                                 | Enabled syntax                                    |
| -------------------------------- | ------------------------------------------------------------------------- | ------------------------------------------------- |
| **Ref-form** (lvalue storage)    | `fn op_index_ref(self: &Self, idx: Idx) &T`                               | `x[i]` read, `x[i] = v` write, `&x[i]` address-of |
| **Value-form** (computed read)   | `fn op_index(self, idx: Idx) T` (any return shape: `T`, `T?`, `T[]`, ...) | `x[i]` read only                                  |
| **Value-form** (optional setter) | `fn op_set_index(self: &Self, idx: Idx, v: V)`                            | `x[i] = v` write                                  |

*Dispatch rules:*

- `x[i]` (read): ref-form if declared, else value-form `op_index`.
- `x[i] = v` (write): ref-form if declared (store through returned pointer), else value-form `op_set_index`.
- `&x[i]` (address-of): ref-form required. Rejected on value-form with E2040 — computed results have no stable storage.

*Ambiguity:* for any given `(Self, Idx)` pair, declaring **both** `op_index_ref` and any value-form operator (`op_index` / `op_set_index`) is rejected with **E2077**. The two patterns are mutually exclusive. Different `Idx` types are independent overloads — `List` legally declares ref-form `op_index_ref(&List, usize) &T` alongside value-form `op_index(List, Range) T[]`.

*Choosing a pattern:* use **ref-form** for containers backed by real storage (`List`, `Slice`, custom vectors) — one function covers all three contexts, and reads/writes hit the underlying memory without temporary copies. Use **value-form** when the indexed result is genuinely computed (`Dict` returning `Option(V)`, `String` returning `u8`, `Range` returning `T?`, slicing into a new slice). Built-in arrays `[T; N]` and slices `T[]` use compiler-provided ref-form semantics automatically — no operator declaration needed.

**Auto-derivation:**
- `op_eq` auto-derives `op_ne` (and vice versa) by negation.
- `op_cmp(a, b) Ord` auto-derives all six comparison operators. Explicitly defined operators take priority.
- **Primitive short-circuit**: `==`, `!=`, `<`, `>`, `<=`, `>=` on two values of the same primitive type (`i32`, `u64`, `f64`, `bool`, `char`, etc.) always use the hardware comparison. User-defined `op_cmp` on primitives is still callable as a regular function (required for generic algorithms like `std.sort`), but it never intercepts the built-in operators. This prevents recursion (an `op_cmp` body that uses `<` would otherwise call itself) and keeps comparisons on the hot path inlinable.
- **Bare-enum equality**: `==` and `!=` on two values of the same bare enum type (every variant payload-less) compile to a tag compare without requiring a user-defined `op_eq`. Ordering operators stay off — tag values aren't a meaningful total order without the author's intent; define `op_cmp(E, E)` if you want `<`/`>` on an enum. Tagged-union enums (any variant carries a payload) still require a user-defined `op_eq`/`op_cmp`, because tag-alone comparison would silently ignore payload contents.

`Ord` lives in `core.cmp` (auto-imported via the prelude) with `op_cmp` overloads for all primitive types and `String`. Tuple `op_cmp` is not provided yet — define it on your concrete tuple type if you need ordered tuples.

### 5.3 Null Operators

**Coalescing `??`** (RFC-040): `a ?? b` yields `a`'s happy-path value, else `b`, through the protocol `?` uses:

```
a ?? b   :=   op_try(a) match { Continue(v) => v, Return(r) => { release(r); b } }
```

`b` is evaluated only when `a` does not continue. The right side is a match-arm body: any expression - a block or `if` may yield `T` or leave (`o ?? { log(); return Err(e) }`) - or a bare `return [expr]`, `break` or `continue` (`let id = map.get(k) ?? return TY_ERROR`, `let v = o ?? continue`), with their statement rules (E1006 / E1007, E1054); `return` takes the rest of the expression. Right-associative: `a ?? b ?? c`. Where `?` returns the residual, `??` owns it and releases it before `b` - an owned error is freed, a copyable one costs nothing. A left side with no `op_try` is E2092.

- **Option** is read in place: a result that is kept - bound, stored, passed to a `move` parameter, returned - consumes `a` with no marker, as an argument to a `move` parameter is consumed; a result only read (`(a ?? b).len`) leaves `a` in place. A non-copyable `a` the function does not own cannot be consumed (E2131).
- **Option chain**: `Option(T) ?? Option(T)` yields `Option(T)`, `a` when present, else `b`. Option only.
- **Every other `op_try` type** consumes `a`, as `a?` does: `r ?? 0` on a `Result` hands `r` to `op_try`.

**Why.** `?` leaves when the function returns the operand's family; `??` covers every other way out of "the value is missing", in one expression and without restating the test:

```
let id = map[k] ?? return TY_ERROR                     // early exit, any return type
let user = cache[id] ?? db.load(id) ?? return Err(NotFound)
for line in lines {
    return parse(line) ?? continue                     // the first parseable line
}
loop {
    let job = queue.pop() ?? break
    run(job)
}
```

An error type's `deinit` runs exactly when `??` drops it, so a type can report its own swallowing (log, count, assert) while `?` still hands it on untouched.

**Limits.** `op_try` is for a value that may be absent or have failed: `Continue` carries the payload the caller wants. A type whose `Continue` payload is always discarded - a deadline check, a budget token - is a condition dressed as a value, and `let _ = deadline.check() ?? return Timeout` is an `if` written backwards. Write the `if`.

**Safe member access `?.`**: `opt?.field` yields `Option(field_type)` — the field value if present, `null` otherwise. Chainable: `a?.b?.c`.

**Early return `?`** (RFC-009): `expr?` desugars to

```
op_try(expr) match {
    Continue(v) => v,
    Return(r)   => return r,
}
```

`op_try(self) TryResult(T, R)` is a user-extensible operator. The expression evaluates to `T` (the `Continue` payload) on the happy path; otherwise the synthesized `return r` short-circuits the enclosing function. `TryResult` lives in `core.try` and is re-exported via the prelude. Stdlib provides:

- `op_try` for `Option(T)` in [stdlib/core/option.f](../stdlib/core/option.f) — `Some(v)` continues with `v`, `None` early-returns `None`.
- `op_try` for `Result(T, E)` in [stdlib/std/result.f](../stdlib/std/result.f) — `Ok(v)` continues with `v`, `Err(e)` early-returns `Err(e)`.

The `R` type produced by `op_try` must match the enclosing function's declared return type exactly — there is no implicit error-type conversion. `?` is forbidden inside `defer` bodies (E2091) and outside any function (E2090). When no matching `op_try` exists for the operand type, the compiler emits E2092.

Lexer disambiguation: `?.` is a single token (safe member access) and always wins over `?` followed by `.`. Use `(expr?).field` to early-return then access. Postfix `?` binds at the same level as method calls — tighter than every binary operator (`a + b?` parses as `a + (b?)`).

### 5.4 Casting

`expr as Type` — explicit type conversion.

- Numeric: any integer ↔ integer (narrowing truncates, widening sign-extends).
- Float ↔ integer: `f64 as i32`, `i32 as f64`.
- Pointer → integer: `&T as usize|isize` reads an address. Warns (W2004); silence it per declaration with `#allow(W2004)`.
- Integer → pointer: **refused** (E2122). Fabricating a reference from an integer would let a laundered parameter address return and be written through, defeating the copy-on-write analysis of Section 3.2. The literal `0` is exempt — it is how a null reference is spelled, and a zero can never be a real address.
- Pointer ↔ pointer: `&T` ↔ `&U` (view cast, programmer's responsibility).
- `String` ↔ `u8[]`: zero-copy binary reinterpretation.

Implicit: `String` automatically accepted where `u8[]` expected. Reverse (`u8[]` → `String`) requires explicit `as String`.

---

## 6. Modules and Visibility

- Each source file is a module. `import path` brings the module's `pub` items into scope as bare names.
- **Imports are flat and non-transitive by default**: a plain `import B` from module A makes B's `pub` items visible inside A only — anyone importing A does **not** see B.
- **`pub import path`** opts into re-export. Anyone importing the current module also sees the `pub` items of the re-exported module. Re-exports compose transitively along chains of `pub import`. This is the only re-export mechanism — no aliases, no selective re-exports.
- **Overload resolution handles same-named imports**. Two different imports may bring in functions with the same name; the type checker resolves the call by parameter types. Candidates are ranked by **implicit-conversion count** first: an argument that matches its declared parameter type as-is always beats one that had to be coerced. A `String` argument IS a `String` — it decays to `u8[]` only when no `String` parameter takes it, so `write(&File, String)` wins over a `write(&File, u8[])` sibling for a string literal. Conversion-count ties fall to **structural specificity**: each concrete type constructor in a declared parameter is a constraint the call's arguments had to satisfy, and the candidate whose supplied parameters carry more of them wins — `deinit(&List($T))` beats the universal `deinit(&$T)` fallback for a list receiver,. Type variables contribute nothing to specificity, and a position is only scored when its argument's type is already fully known — parameters the call left to defaults, and positions whose argument still contains an unresolved type variable (an unsuffixed literal, a half-inferred aggregate), are skipped, since an unbound argument matches any parameter shape at zero cost and cannot corroborate structure. Skipped for *scoring* is not the same as unconstrained: an unsuffixed numeric literal carries a constraint to the numeric primitives (plus `char` for an integer literal), so a candidate whose parameter is a nominal, a reference, or a tuple fails to unify and never reaches ranking at all. Remaining ties fall to lower total cost (the UFCS receiver adaptation, omitted defaulted parameters), then fewer quantified type parameters, then literal-preference arbitration, then the **expected type**, and finally declaration order. The expected type is the type of the slot the call fills, where the slot already has one: an annotated `let`/`const` (`const p: Point = parse(d)`) or the target of an assignment (`p.at = parse(d)`). Among candidates that tie on every key above - overloads that differ only in their return type - the one whose return type fits the slot wins; with no typed slot, declaration order still decides. A UFCS call ranks in receiver tiers across all candidates: the receiver as written; only when no candidate takes it, the receiver adapted value ↔ `&T` (§7.2); only when none takes that, the receiver through `op_deref`. The keys above order candidates within the first tier anything matched in. The dot therefore never changes which overload wins: a catch-all `$T` that takes `x` as written beats `f(&X)`, exactly as `f(x)` would pick it. Genuinely ambiguous calls (no unique strictest overload) error at the call site. (The specificity count is a tuned heuristic standing in for a real constraint system.)
- **No aliases, no selective imports, no relative paths.**
- **Auto-imported core prelude.** Every module implicitly imports [`core.prelude`](../stdlib/core/prelude.f), a curated barrel that `pub import`s the core modules (`core.option`, `core.string`, `core.panic`, `core.cmp`, etc.). All core symbols are therefore visible without an explicit import. The prelude itself is the only module exempt from the auto-import.
- **Project-level globals.** A project may declare `[imports].global = ["std.prelude", ...]` in `flang.toml`; each entry is injected as an implicit private import into every project file. Project globals never propagate to stdlib or third-party modules.
- `pub` exposes declarations outside the file. Without `pub`: file-private.
- Visibility is two-level only — there is no `pub` on individual fields, and there are no property declarations. External "mutation" of a struct happens by re-construction (return a new value, or have the defining file expose mutating functions).
- Struct fields readable from any file, writable only in defining file (see scoped mutability in Section 8).
- **Import cycles are a library-level rule, not a module-level one.** Modules *within* one library may import each other freely, cycles included — the same model as a C# assembly or a Java package. Libraries may not: if library A depends on library B, no module of B may import a module of A. The library graph is a DAG, decided from the `[dependencies]` of each `flang.toml` before a single source file is read. (Not yet enforced — see `docs/known-issues.md`. The library graph is acyclic today; nothing checks that it stays so.)
- A symbol is visible in module M iff it is defined in M, OR it is `pub` and defined in a module reachable from M via `import` plus the `pub import` transitive closure.
- FQN-style references (e.g. `core.option.Option`) bypass visibility — an explicit dotted name is unambiguous and self-authorizing.

---

## 7. Compilation Model

### 7.1 Functions

- Overloading supported by name and parameter types, and by return type alone where the call fills a typed slot. The type checker selects the strictest applicable overload.
- **Default parameters**: `fn foo(x: i32, y: i32 = 10)`. Evaluated fresh at each call site, with its names resolved as at the declaration: the declaring module's imports, none of the caller's locals. Must follow required parameters.
- **Named arguments**: `foo(y = 20, x = 10)`. Positional args first. Not supported for indirect calls.
- **Variadic parameters**: `fn bar(..args: i32)`. Received as `i32[]` slice. One variadic, must be last. Foreign functions use C-style `...`.
- All three are caller-side transformations — lowering sees a normal positional argument list.

### 7.1.1 Symbol Naming

FLang permits overloading, generic specialization, and same-named functions in different modules; the target object format does not. Every function therefore has a **symbol** — the single, globally unique name it links under — distinct from its source **name**.

**A symbol is fixed before code generation.** By the time a program reaches a backend, every function definition carries its final symbol and every call names its callee's symbol directly. A backend emits symbols; it does not compute them.

This keeps code generation *overload-independent*. Deciding how two functions with the same source name are told apart requires overload resolution, default and variadic handling, generic specialization, and knowledge of the return-value ABI. That decision belongs to one place in a compiler, not to each backend — otherwise every target must reproduce it identically.

**Required properties.** A symbol must be:

1. **Unique** — distinct functions never collide, including same-named overloads and same-named functions in different modules.
2. **Deterministic** — a function's symbol depends only on the function itself: its module, name, parameter types and return type. Recompiling an unchanged declaration yields an unchanged symbol, and adding or removing an unrelated function never renames it. Builds are reproducible and separately-compiled units agree without coordination.
3. **Consistent** — a definition and every call to it name the same symbol.
4. **A valid target identifier** — for targets in the C family, matching `[A-Za-z_][A-Za-z0-9_]*`.

**Property 4 is total, not conditional.** A symbol is derived from the function's *module path* as well as its name, and a module path is not a FLang identifier: it is built from the project name and the source file path, both of which may contain any character the host filesystem and manifest allow. `name = "chess-fen"` is a legal project name. An encoding must therefore map **every** input byte to something the target admits — a pass-through default that assumes identifier-safe input violates this property, and the resulting symbol is not merely ugly but unparseable (`chess-fen_main_f` is a subtraction in C).

The escape must also be **injective over the whole input**, which follows from property 1: if two distinct source characters collapse to the same output, two distinct functions can collide. An encoding that maps several characters to `_` satisfies property 4 but weakens property 1, and is conforming only where the collapsed characters cannot both appear.

**The encoding is unspecified.** Programs cannot observe it, and targets with different identifier rules may need different encodings. Any encoding satisfying the four properties conforms. The two in-tree backends differ, which is allowed: the self-hosted compiler escapes injectively (`.` → `__`, `_` → `_0`, anything else → `_x<hex>`), while the reference collapses every non-identifier character to `_`.

Two names are exempt and keep their source spelling, because something outside the language already fixes them: the **entry point** (`main`) and **`#foreign` functions**, which name symbols defined elsewhere.

**Overloading and separate compilation.** Property 2 rules out schemes that number overloads in declaration order. A counter makes a symbol depend on how many same-named functions were seen first, so inserting a declaration renames later ones and independent compilation units cannot agree without sharing the counter. Encoding the parameter types instead makes each symbol self-contained. The return type is encoded too, since overloads may differ in it alone.

### 7.1.2 Name Case

Case is part of the language (RFC-039): a trailing lambda and named construction differ only in the name before `{` (`Point { x = 1 }` constructs, `spawn { work() }` passes a lambda), and the parser decides by the name's first character.

- A user-declared type (struct, enum, alias, contract) and a type parameter start with an uppercase letter.
- A function starts with a lowercase letter or `_`. `#foreign` functions keep their C names.
- A violation is E2155 at the declaration. Values are not constrained, and primitives (`i32`, `bool`, ...) count as type names.

### 7.2 UFCS

Any function with first parameter `T`, `move T` or `&T` can be called as `value.func(args)`. The dot is sugar for two rewrites, tried in order: `x.f(y)` is `f(x, y)`, and when that does not resolve, `f(&x, y)`. This is how methods work — no `impl` blocks.

**That rewrite is the only implicit reference in the language.** A free call passing `x` where the parameter is `&x` is an error, not an auto-reference; a reference is never implicitly dereferenced to a value; and the coercion ladder (§9.2) is closed to user types. The one user-defined adaptation, `op_deref` (§7.1), turns a reference into another reference and nothing else. Keeping both directions out is what keeps this from becoming C++'s implicit conversions.

**The receiver follows the first parameter** (§3.2). `f.close_file()` with `close_file(file: move File)` moves `f`; `xs.len()` with `len(self: List(T))` reads. A `move self` parameter of a non-copyable type is not reachable through a `&T` receiver or an `op_deref` hop (E2128): the value behind the reference stays with its owner.

### 7.3 Lambdas

A lambda is a brace block with its parameters before `=>` (RFC-039):

```flang
{ x => x * 2 }               // one parameter
{ acc, x => acc + x }        // several
{ p: &u8 => ... }            // annotated: x: T, x: &T, x: move T, x: $T
{ => count = count + 1 }     // no parameters
{ it * 2 }                   // arrow-less
```

- Parameters take the forms function parameters take, without defaults or variadics.
- The body is a block: statements, then an optional trailing expression that is its value. `return` inside a lambda is E1054, which keeps `return` meaning "leave the enclosing function" wherever it is written; leave a lambda early with `?`, `if`/`else` or `match`. A lambda body is outside every enclosing loop, so `break` and `continue` there are E1006 / E1007.
- There is no return-type slot. The return type comes from the expected function type or bound, else from the body; where nothing pins it, annotate the binding (`const f: fn(i32) i32 = { x => x + 1 }`). Where the expected function returns nothing, the body's last value is discarded.
- A lambda passed as an argument is checked after its call resolves, against the parameter it fills: its unannotated parameters take that function type's parameter types before the body is checked.
- The removed form `fn(x: i32) i32 { ... }` is E1053.

**Where a brace is a lambda.** Inside a call's parentheses (positional or named argument) and in trailing position, `{` always opens a lambda. Elsewhere it opens a lambda when the next tokens are `=>`, `ident =>`, `ident ,` or `ident :`, none of which can start a block; otherwise it is a block. The two tokens after the brace decide, with no backtracking and no name lookup.

**Trailing lambdas.** A `{` on the same line as a lowercase name, the `)` of a call through one, or a `.name` / `.name(args)` member opens a trailing lambda. It fills the callee's last callable parameter (a `fn(...)` type, or a type parameter bounded by one), and every parameter after that one must have a default; the parenthesized arguments fill the others as usual. A callee with no such parameter is E2156. The parentheses may be omitted when the lambda is the only argument:

```flang
spawn { work() }
with_c_path(path) { p => ... }
xs.map { it * 2 }
xs.fold(0i32) { a, b => a + b }
self.on_event { log(it) }        // a callable field
```

In an `if`, `while` or `for` header the `{` at the header's level opens the body, so a trailing lambda there is parenthesized: `if (xs.any { it > 0 }) { ... }`.

**Arrow-less lambdas and `it`.** A lambda with no `=>` takes its arity from the callable expected where it is passed: a function type, or a type parameter the callee bounds by one. At arity one its parameter is named `it`; at arity zero it has none, and an outer `it` stays visible. An expected arity above one, or none at all, is E2154. `it` is not a keyword: it names the parameter only inside an arrow-less lambda, shadowing any outer `it`, and a nested arrow-less lambda's `it` shadows the enclosing one's. An arrow-less lambda appears only in argument or trailing position.

A lambda with no captured names desugars to a synthesised module-level function. A lambda that references names from the enclosing scope is a **capturing closure** (RFC-014): the compiler synthesises an anonymous `__Closure_N` struct holding a reference to each captured binding and an `op_call(self: &__Closure_N, ...)` body that reads and writes each capture through `self`.

**Capture rules** (RFC-033):
- Every capture is by reference. The closure sees the binding's current value when it runs, and an assignment inside the body (`c = c + 1`, `xs.push(v)`, `&c`) writes the enclosing binding.
- A closure that outlives a captured binding dangles, as a returned `&local` does (§3.6).
- Moving a capture out of the closure is refused (E2131); a capture of a parameter without `move` stays read-only. The body is otherwise checked like any function body.
- A nested closure captures through the enclosing one: a name from further out is taken from the enclosing closure's environment.
- A capturing closure has an anonymous nominal type. It converts to a function type its signature fits, as any callable does (below), or travels through a generic parameter (`fn apply(f: $F, x: i32) i32 { return f(x) }`), which instantiates per closure type and calls its body directly.

**Function values** (RFC-037). `fn(P1, ..., Pn) R` is the type of any callable of that shape. A named function, a lambda and a capturing closure convert to it where a value of that type is expected: an argument, an initializer, a field, a context field. The value is a pair, `{ code, env }`: `code` is the callable's body and `env` its state, null for a named function or a non-capturing lambda and the closure's address for a capturing one. A function that takes `fn(...)` is compiled once, whatever is passed. The value borrows the closure it was made from and owns nothing, so it is copyable and lives no longer than the frame that made the closure; one made from a named function or a non-capturing lambda is valid anywhere. An overloaded name converts to the overload whose signature is the function type. Parameters and return match exactly, except that a reading parameter of a copyable type fills a `move` slot: the value handed over needs no release. A `move` parameter never fills a reading slot, whose caller lends its own storage. An unannotated lambda parameter takes the mode of the slot it fills, so `opt.map { it.len }` owns its payload.

**Parameter type inference** mirrors anonymous-struct rules. Each unannotated parameter must have its type inferable from one of:
- the corresponding parameter type at the call site (typed callback parameter, e.g. passing the lambda to `map(fn(T) U)`),
- **a generic `$F` slot bounded by a function type** (`where F: fn(T) bool`) — the bound, instantiated at the call, types the parameters before the body is checked (`xs.filter { it > floor }` needs no annotations),
- the return type of the enclosing function when the lambda is `return`ed,
- an explicit `let x: fn(T) U = { p => ... }` binding annotation,
- explicit annotations on the lambda parameters (`{ p: T => ... }`).

A no-context lambda is an error — diagnostic recommends adding annotations to the parameters or the binding site. Because a lambda argument's parameters take the bound's types before its body is checked, the body can pin what the call left open: `xs.fold(0) { a, x => a + x }` types the seed `0` from the elements.

**Stdlib callback convention** (RFC-037). Standard-library combinators (`List`/`Dict`/`Set` utilities, the `std.iter` adapters and consumers, `sort`'s comparator) type their callbacks as function values: `filter(keep: fn(T) bool)`, `sort(s, cmp: fn(T, T) Ord)`, `sort_by(s, key: fn(T) $K) where K: Ordered`. Each is compiled once whatever is passed, and the `std.iter` adapters store the value, so a chain instantiates per iterator type only. The function type types an unannotated lambda's parameters and gives an arrow-less lambda its arity. A combinator that lends the element calls `f(s[i])` with a reading parameter `fn(T)`; one that hands it over says `move`: the `std.iter` `map` adapter and every accumulator (`fold(init, f: fn(move A, T) A)`). A copyable reader fills a `move` slot; a non-copyable one does not, and an unannotated lambda there owns its parameter. A `fn(&T, &T) Ord` comparator is no `fn(T, T) Ord` (E2011). `Option`'s `map` and `flat_map` and `Result`'s `map`, `map_err` and `and_then` keep `f: $F where F: fn(move T) U`: each instantiation sees the callback's own mode, so a non-copyable reader (`opt.map(extract)`) and a callback that moves the payload on both fit, until a `move` parameter is released at scope end.

**Lazy-fallback convention.** A function whose parameter is a fallback - a value used only when the primary one is absent - comes in two forms under two names: the plain name takes the value, an `_else` suffix takes something that produces it.

```
pub fn unwrap_or(self: Option($T), fallback: T) T      // used as-is
pub fn unwrap_or_else(self: Option($T), make: fn() T) T    // called only when empty
pub fn get_or(self: Dict($K, $V), key: K, fallback: V) V
pub fn get_or_else(self: Dict($K, $V), key: K, make: fn() V) V
```

Arguments are evaluated before the call, so the plain form computes its fallback whether or not it is needed; the `_else` form defers that to the absent branch.

Two names rather than two overloads, because a single argument can satisfy both shapes at once. When `T` is itself callable - a type with an `op_call` returning its own type, say - one value is both a valid fallback and a valid fallback-producer, and no rule in the type system says which the caller meant. Overload ranking would still pick one, silently. The name is what carries the intent.

### 7.4 Iterator Protocol

`std.collections.iter` states the protocol as contracts (§2.3.2), so a generic function can require it: `Iterator` is a type with `fn next(self: &Self) Item?`, its element type read as `I.Item`, and `Iterable` one whose `fn iter(self: &Self) Iter` lends an `Iterator`. `for` itself keeps resolving `iter` and `next` as calls. The `std.iter` consumers take `it: move $I where I: Iterator`; each adapter's struct carries its bounds and stores its callback as a function value (`FilterIter(I: Iterator) { it: I, f: fn(I.Item) bool }`), which its constructor and methods hold by naming it.

`for x in collection` desugars to (conceptually — the compiler emits IR directly):

```
let it = iter(&collection)
loop {
    let n = next(&it)              // returns Element?
    n match {
        Some(x) => { /* body uses x */ }
        None    => { break }
    }
}
```

A `for` loop comes in two forms. They differ in what the loop variable binds, and each resolves its own pair of protocol methods:

| form           | resolves        | binds                                           | a type joins by defining                                                  |
| -------------- | --------------- | ----------------------------------------------- | ------------------------------------------------------------------------- |
| `for x in xs`  | `iter(&xs)`     | `x: T` — a copy per iteration                   | `fn iter(self: &T) Iterator` and `fn next(self: &Iterator) E?`            |
| `for &x in xs` | `iter_ref(&xs)` | `x: &T` — aliased into the collection's storage | `fn iter_ref(self: &T) RefIterator` and `fn next(self: &RefIterator) &E?` |

`for x in xs.iter_ref()` is the reference form spelled out.

**The loop owns what it iterates with**, as `for_each(it: move $I, body)` would: the state `iter` returned, when that state is not copyable (a drain), or else a non-copyable temporary iterable that `iter` only borrowed (`for e in walk_dir(p)?`). The loop releases it on every exit - the end of the iteration, `break`, `return`, `?` - with its `deinit`. An iterator's own `iter` that takes `move self` consumes a named iterator: `for x in d` leaves `d` dead. A copyable state, or an iterable named by a binding and borrowed, is not the loop's to release.

**A collection is not modified while it is being iterated.** An iterator is a snapshot of the
storage as it was when `iter` ran: a `List`'s iterator is the slice iterator over its elements at
that moment, in either direction (`iter_rev` walks last to first without the copy `reversed`
makes). Appending to the list inside the loop is outside the contract - the iterator may or may
not see the new elements, and a reallocation leaves it reading freed memory. Collect into a second
list, or drain a worklist with `pop`.

**Choose by aliasing, not by speed.** Take the reference form to mutate elements in place, or when the body must otherwise alias the collection's storage. It is not the faster one: the pointer stride can defeat vectorization, while the by-value copy is a local temporary the C backend eliminates under `--release` — measured on 48-byte structs, the by-value loop compiles to the same vectorized loop as manual indexing.

Which types iterate, and how:

- **`List` and slices** — both forms; they ship `iter_ref` alongside `iter`.
- **Iterator types** — every iterator is itself iterable, so adapters chain: `xs.iter().enumerate()`.
- **Fixed arrays `[T; N]`** — decay to a slice, so both forms work: `iter(&T[])` and `iter_ref(&T[])`. `for &el in arr { el.* = ... }` mutates the array in place.
- **A slice does not decay to a reference.** `T[]` in a `&T` slot is an error (**E2011**), including at a `#foreign` boundary: `&T` is non-null by type where a slice's `ptr` need not be, and the length would be dropped with nothing in the syntax marking it. Pass `s.ptr`, or the address of an element.
- **`String`** — **not** iterable by itself. Bytes or characters is a choice only the caller can make; index it instead.

### 7.5 Match Expression

Postfix syntax: `expr match { pattern [if guard] => result, ... }`. Postfix `match` is the lowest-precedence operator — `a + b match { ... }` parses as `(a + b) match { ... }`.

**Patterns** (RFC-010):

- **Unit variant** — `Quit`. Naked identifier resolves to enum variant in match position.
- **Qualified variant** — `Color.Red`. Disambiguates when the variant name conflicts.
- **Payload binding** — `Move(x, y)`, `Some(v)`. Variable sub-patterns bind the payload.
- **Nested** — `Some(Ok(x))`. Recursive payload destructuring.
- **Literal** — `42`, `b'A'`, `true`, `"hi"`, `-7`. Equality check via `op_eq`.
- **Range** — `0..10` (half-open), `0..=9` (inclusive), `..0`, `..=0`, `1..`. The `..=` token is pattern-only; non-pattern range expressions still use `..`.
- **Or-pattern** — `Red | Green | Blue`. Matches if any alternative matches.
- **Tuple** — `(a, b)`, `(0, _)`. Element-wise destructuring.
- **Struct** — `Point { x, y }`, `Point { x, .. }`. Strict construction; `..` ignores rest.
- **Wildcard** — `_`. Matches any value, no binding.
- **`else`** — Catch-all default arm.

**Guards** — `pat if cond => body` matches only if the pattern matches AND the bool guard evaluates true. Guards do not contribute to exhaustiveness (they may fail at runtime).

**Or-pattern bindings**: alternatives must bind the same variable names with the same types. Alternatives that introduce bindings (e.g., `Some(x) | Other(x)`) are not yet supported by lowering — see `docs/known-issues.md` "RFC-010 Follow-ups". Non-binding cases (`Red | Green | Blue`, `1 | 2 | 3`) work today.

**Range bounds**: must be compile-time literals of an integer, `char`, or `byte` type. Floats and strings are rejected (E2108) because they have no compile-time-checkable total ordering. Empty ranges (`5..3`) are rejected (E2109).

**Exhaustiveness**: enum scrutinees still require every variant covered (or a catch-all). Guarded arms don't count. Tuple/struct/range scrutinee exhaustiveness is not yet checked — provide an explicit catch-all until Phase 6 (Maranget) lands.

Match is an expression — all arms unify to a common type. Enum references auto-deref during matching.

**Binding mode**: a pattern variable bound to an *aggregate* (struct, enum payload, tuple element, array) names the scrutinee's own storage — `&binding` is a pointer into the scrutinee, and writing through the binding is visible to the matched value. This is what lets an accessor hand out a handle into a payload:

```
pub fn as_map(self: &Value) &OrderedDict(OwnedString, Value)? {
    return self.* match { Map(d) => Some(&d), else => null }
}
```

A binding bound to a *scalar* is a copy in its own slot, so an arm body may assign to it without touching the scrutinee.

**Ownership of bindings** follows the scrutinee, since an aggregate binding names its storage. Matching storage the function owns - a local, a `move` parameter - lets an arm move a binding out (`Some(v) => move v`), which empties that part of the scrutinee. Storage it does not own keeps its parts: under a reference or in an element, a binding may be read, shared and written, not moved out; under a parameter without `move` it may only be read, as the parameter itself (§3.2). Moving such a binding is E2131: taking the payload out of `o` needs `o: move Option(T)`. A temporary scrutinee belongs to the `match`, so its bindings own.

### 7.6 Directives

Prefixed with `#`, precede declarations:

| Directive            | Purpose                                                         |
| -------------------- | --------------------------------------------------------------- |
| `#foreign`           | C calling convention: an imported or C-callable function (not mangled), a C function type, or a C-layout-locked struct |
| `#deprecated("msg")` | Deprecation warning on usage                                    |
| `#inline`            | Inlining hint                                                   |
| `#intrinsic`         | Compiler-recognized stdlib intrinsic                            |
| `#simd`              | SIMD-aligned struct (16+ byte alignment)                        |

Unknown directives produce warning W2003.

#### `#foreign` on functions and function types

Every function has a calling convention; `flang` is the default, and `#foreign` is the C one. A
body-less `#foreign fn` imports a C function. A `#foreign fn` with a body is a FLang function in
the C convention: C calls it by its unmangled name, it takes no context or `env`, and it runs under
the root context (§4.4). FLang calls either directly.

`#foreign fn(P...) R` in type position is one C code pointer. A `#foreign` function converts to
it as itself, and so does a lambda written where one is expected that captures nothing: its body
is emitted in the C convention. A capturing lambda, a FLang function and a `fn` value do not
convert (E2111), and a `#foreign fn` is no `fn` value. A call through one is a plain C call.

```
#foreign fn qsort(base: &u8, n: usize, size: usize, cmp: #foreign fn(&u8, &u8) i32)

#foreign fn by_score(a: &u8, b: &u8) i32 {
    return (b as &Player).score - (a as &Player).score
}

qsort(base, n, size, by_score)
qsort(base, n, size, { a, b => (a as &Player).score - (b as &Player).score })
```

A struct passed by value as a parameter or return of a `#foreign fn` body or value is not
supported yet (known-issues).

#### `#foreign` on structs

`#foreign` on a struct declaration means **do what C does**. It opts the type out of the layout freedom in §2.4: fields stay in declaration order, padding is inserted exactly where the C ABI puts it, alignment is the C alignment, and nothing is reordered — now or in any future version. In generated C code, the struct typedef/definition is omitted when the type comes from an included C header.

This is the only way to give a struct a layout a C declaration can rely on, so it is a precondition for passing an aggregate across an FFI boundary by value. A plain struct's layout is chosen for FLang's benefit and matches no C declaration of the same members; `#foreign` is the marker that trades that optimisation for interoperability.

The two rules are deliberately complementary: **plain structs are laid out for FLang, `#foreign` structs are laid out for C.** Neither is a default the other can be recovered from — a type is declared for one world or the other.

```
pub type Color = #foreign struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
}
```

Note: `#foreign` and `#simd` must appear inline after `=` in type declarations (not as detached directives above the declaration). A field holding a callback is a `#foreign fn`; a `fn(...)` field is E2157.

### 7.6.1 C FFI Binding Generation

The compiler can automatically generate FLang FFI bindings from C headers:

```
flang -I raylib.h -L libraylib.a main.f
```

- `-I <header>` — parses the C header and generates `vendor/<name>.f` with `#foreign fn`, `#foreign struct`, and `pub const` declarations
- `-L <lib>` — passes the library to the C linker

**Type mapping:** C pointers map to `Option(&T)` (nullable). C enums map to `pub const: i32` values. C structs map to `#foreign struct` declarations. See `vendor/<name>.f` for the generated output.

### 7.7 Compile-Time Conditional `#if`

```
#if platform.os == "windows" {
    // windows-only code
} else {
    // other platforms
}
```

`#if` is *selection, not computation*: it chooses between alternatives
based on a closed, compiler-supplied context. It never computes code.

**Contract.** Both branches of a `#if` must always parse. Only the
active branch is type-checked and lowered; the inactive branch is
invisible to name resolution and semantic analysis. Consequently `#if`
gates *semantics* (platform APIs, foreign declarations, testing hooks),
never *syntax* — a parse error in either branch breaks the build on
every platform, by design.

**Positions.** `#if` is valid at statement level (inside function
bodies, including nested blocks) and at declaration level (top level of
a file). A declaration-level `#if` may contain type declarations,
functions, constants, tests, and nested `#if` directives — not imports
or generator definitions. It resolves once, at collection time: only
the active branch's declarations are collected, so the same names may
be declared in both branches without conflict.

**Divergence.** A `#if` statement diverges exactly when its active
branch diverges — an exhaustive `#if/else` whose branches both `return`
satisfies the missing-return check with no trailing dead code.

**Condition language.** Conditions follow FLang expression semantics,
evaluated at compile time over the context below: comparisons
(`==`, `!=`), logical `and` / `or` / `!`, `??`, parentheses, and
string/bool literals — the context holds only strings, bools, and
env lookups, so no other operand forms exist to compute with.
The syntax mirrors FLang's `if` — `#` means compile-time,
the rest is ordinary FLang: `#if cond { }`, no parens required
(`#if(cond)` still parses — `(cond)` is a parenthesized expression).
A condition must evaluate to a bool — `#if platform.os { }` is an
error, exactly as `if platform.os { }` is invalid FLang.

| Path              | Type   | Values                                         |
| ----------------- | ------ | ---------------------------------------------- |
| `platform.os`     | string | `"windows"`, `"linux"`, `"macos"`, `"unknown"` |
| `platform.arch`   | string | `"x86_64"`, `"arm64"`, `"x86"`, etc.           |
| `runtime.testing` | bool   | true when compiling with `test`                |
| `runtime.release` | bool   | true when compiling with `--release`           |
| `runtime.env`     | dict   | Build-time environment variables               |

The context's shape is declared in `core.comptime` (in the prelude):
`platform` is a constant of `Platform { os, arch }` and `runtime` one of
`Runtime { testing, release, env }`, where `env` is an `Environment`, a
process environment read one variable at a time through its index
operator (`env["KEY"]: String?`). The compiler supplies the two values
for the target being built; no runtime value of `platform` or `runtime`
exists yet. `Environment` works at run time too, and `std.env.env` reads
through it.

`platform.os` / `platform.arch` describe the **target**, which defaults
to the host; `--target-os` and `--target-arch` override them so any host
can emit any platform's code (cross-bootstrap). Unknown target values
are hard errors.

`runtime.env` follows FLang `Dict` semantics: indexing yields an
optional (`String?`), so an absent variable is a value, not an error —
unwrap with `??` before comparing:

```
#if (runtime.env["MODE"] ?? "") == "release" { ... }
```

**Type parameters.** Inside a generic function body the type parameters
in scope are compile-time names as well: `type_info(T)` is the `TypeInfo`
(§2.9) of the concrete type bound to `T`, and the condition is decided
per specialization. Because a generic body is checked and lowered only
per instantiation, this is the same evaluation point as the closed
context, and the contract is unchanged: both branches parse, only the
active branch of *that instantiation* is type-checked and lowered. That
is what makes the inactive branch free to name something the active
type lacks:

```
fn clone_elem(x: &$T, allocator: &Allocator) T {
    #if type_info(T).copyable {
        return x.*
    } else {
        return x.clone(allocator)
    }
}
```

A non-generic nominal visible from the module is a compile-time name
too (`#if type_info(FileHandle).copyable`), anywhere a statement-level
`#if` can stand; a bare generic nominal carries no arguments and is
E2116. A value binding in scope is a name as well, and `type_of(v)` is
the descriptor of its type (`#if type_of(x).copyable` on a parameter);
the two functions keep their run-time meanings, so `type_of(Point)` and
`type_info(x)` are refused (E2118) rather than guessed. `name`, `kind`
and `copyable` are the members available on a type named either way;
they read exactly what the runtime descriptor carries. `fields`, `variants`, `params` and `return_type` are
refused (E2120) rather than read as empty, and `size` / `align` are
refused as they are in templates. Declaration-level `#if` sees no type
names.

**Strictness.** Invalid conditions are hard errors, never silently
false: an unknown context name or member (`platform.oss`) is E2116, a
non-bool condition is E2117, and operand misuse (an optional compared
without `??`, non-bool `and`/`or` operands, a disallowed expression
form) is E2118.

### 7.8 Source Generators

Compile-time code generation prefixed with `#`. Runs between type collection and resolution.

```
#define(name, Param1: Kind, Param2: Kind) {
    // template body with #(expr) interpolation
    // #for var in collection { ... }
    // #if condition { ... } #else { ... }
}

#name(arg1, arg2)    // invocation
```

Parameter kinds: `Ident` (bare identifier), `Type` (type expression). Last param can be variadic: `..Param: Kind`.

**Template values.** An `Ident` parameter is an identifier (`Name.text` is its spelling; `#(Name)` pastes it). A `Type` parameter is the argument's `TypeInfo` (§2.9) — `T.name`, `T.kind` (compare with `TypeKind.Struct` etc.), `T.fields`, `T.variants`, `T.params`, `T.return_type`, with `field.name` / `field.type_info` and `variant.name` exactly as at run time. `size`, `align` and `offset` are not available at expansion time (layout is computed after expansion), and neither is `copyable` (derived after type resolution) — reading them is E2120; a generator that needs the bit emits `#if type_info(T).copyable` into its expansion and lets the specialization decide (§7.7). Any nominal, primitive or anonymous `struct { … }` may be passed as a `Type` argument. Builtin functions: `type_info(T)` (identity), `type_named("Name")` (look a type up by name, e.g. one generated earlier — E2003 if absent), `lower`, `snake_case`, `pascal_case`.

**Template directives.** `#(expr)` pastes the value's text; inside a string literal (`"#(expr)"`) it pastes it escaped, so the literal stays valid. `#for x in list { … }`, `#if cond { … } #elif cond { … } #else { … }`. `##` escapes a literal `#`.

Template `#if` **is** the `#if` directive of §7.7 — the same evaluator, the same closed context (`platform.*`, `runtime.*`, target overrides) and the same rules (bool conditions, unknown names are errors, `??` to unwrap `runtime.env[..]`), evaluated at expansion time with the template's parameters and `#for` variables in scope. `#(expr)` and `#for` iterables use that evaluator too. The one difference: a template `#if` never emits its inactive branch, so that branch is never parsed.

**Built-in generators:**

| Generator                                                    | Purpose                                     |
| ------------------------------------------------------------ | ------------------------------------------- |
| `#derive(T, eq, clone, debug, hash, serialize, deserialize)` | Derive implementations                      |
| `#enum_utils(E)`                                             | Generate `to_string`/`from_string` for enum |
| `#interface(Name, Spec)`                                     | Define vtable-based interface               |
| `#implement(Impl, Iface)`                                    | Implement interface for a type              |

Expansion runs once, after nominal types are collected and before they are resolved; generated declarations become part of the invoking module. Generated code may contain further definitions and invocations (nesting depth is limited to 8 — E2119). Expansion is in memory; `--emit-generated` writes each module's expansion to `<source>.generated.f` for inspection only.

### 7.9 FIR (Intermediate Representation)

Linear SSA IR: `IrModule` → `IrFunction` → `BasicBlock` → `Instruction`. Merge points use phi-via-alloca.

**Instruction categories:**
- **Memory**: `alloca`, `store`, `load`, `store_ptr`, `addressof`, `getelementptr`
- **Arithmetic**: `binary` (add, subtract, multiply, divide, modulo, comparisons)
- **Type conversion**: `cast` (integer, pointer, string/slice)
- **Control flow**: `return`, `jump`, `branch`
- **Calls**: `call` (mangled FLang or unmangled foreign)

Complex constructs (`for`, `if` expressions, `defer`, `match`) are desugared to basic blocks and branches.

---

## 8. Defined Behaviors

- **Memory initialization**: Zero-initialized by default (memset to 0).
- **Integer overflow**: Wrapping arithmetic (two's complement), no overflow detection.
- **Evaluation order**: Left to right for all operands, each fully evaluated before the next. See [5.1.1](#511-evaluation-order). Deliberately stronger than C (which leaves argument order unspecified), matching C# and Java.
- **Bounds checking** (planned): Optional runtime bounds checking for array and slice indexing. Not yet implemented — out-of-bounds access is currently undefined behavior.
- **Null safety**: `&T` is non-null by type. `&T?` requires explicit handling. The type system prevents accidental null dereference on non-optional references.
- **Scoped mutability**: Struct fields are writable only in the file that defines the struct; reads are unrestricted. Enforced by the type checker (E2114). Tuples (structural / anonymous) are exempt — they have no defining module. The rule applies to direct assignment (`x.field = v`); indexed assignment through a field (`x.list[i] = v`) goes through `op_index_ref` and is not a field write. Mutation across modules must go through the defining type's own functions.
- **String interpolation** (planned): `"text ${expr} more"` desugars to `StringBuilder.append()` calls — one builder, one allocation. Types without `format()` are a compile error in interpolation context.

---

## 9. Conventions

### 9.1 Entry Point

```
pub fn main() i32
```

Returns exit code. `0` indicates success. `main` runs under the root context (§4.4). An entry point is required for an executable project (`kind = "exe"`) but not for a library (`kind = "lib"`), which is consumed by source and never linked. Every `flang.toml` must declare `[project].kind` as `"exe"` or `"lib"`.

### 9.2 Testing

```
test "name" {
    assert_true(condition, msg)
    assert_eq(a, b, msg)
}
```

Requires `import std.test`. Test blocks are module-scoped, not exported. Run with `flang test`, optionally narrowed by a positional path filter and/or `--name <substr>` to select individual blocks by name. `panic(msg)` terminates with exit code 1; under `flang test` a panic is caught per-test (the runner reports it as a failure and continues).

### 9.3 Source Files

- Extension: `.f`
- Encoding: UTF-8

### 9.4 Standard Library

```
core/             runtime bindings, platform integration (auto-imported)
std/              standard modules: text (string, string_builder), allocator, option, result, ...
std/collections/  List, Dict, OrderedDict, Set, Stack, Deque, Bitset, the iterator combinators, Journal, MultiMap, StringPool
std/encoding/     serialization: the codec interfaces, the Value tree every format reads into, JSON, TOML, CSV
std/io/           input/output, filesystem, readers/writers
std/time/         Date, Time, DateTime, Instant, OffsetDateTime, Duration, Period, TimeZone, clocks
```

A folder with a façade module beside it - `std.collections` alongside `std/collections/`, `std.io`
alongside `std/io/`, `std.time` alongside `std/time/` - re-exports every child through `pub import`, so `import std.collections`
brings in every collection and `import std.collections.list` just the one.

**Collections come in a managed and an unmanaged flavour**. `UnmanagedList(T)` is
the buffer and every operation on it; the ones that allocate take the allocator at the call
(`xs.push(v, alloc)`), so a composite stores one allocator for all its children. `List(T)` pairs an
`UnmanagedList` with an allocator and allocates through that (`xs.push(v)`), reaching the storage
through `op_deref` so `xs.len`, `xs.pop()` and the rest read the same on either. The storage field
is `__storage`: readable, as every field is, and by convention not touched. A null `&Allocator` is
the current context's allocator (§4.1), so a zero-initialised `List` is a valid empty list. `Dict`,
`OrderedDict`, `Set`, `Stack` and `Deque` follow the same split (`UnmanagedDict`,
`UnmanagedOrderedDict`, `UnmanagedSet`, `UnmanagedStack`, `UnmanagedDeque`); the set and stack flavours wrap the dict and list of the matching flavour, so
an unmanaged composite stores no allocator at any depth. Where such a composite knows its
allocator for a scope, `s.items.managed(s.allocator)` makes a `ListRef(T)` (`DictRef(K, V)` for a
dict): a managed handle holding the storage by reference, so it reads and grows the field in place
through the managed API, and owns nothing - there is no `deinit` on it. The managed API itself is
one set of unmanaged functions plus a generator (`#managed_list`, `#managed_dict`) that emits the
forwarding overloads for each carrier; a transformation on either carrier returns a `List`/`Dict`,
since a new collection needs storage of its own. Only the building blocks come in two flavours.

**Ownership vocabulary (RFC-028, RFC-033).** Three names, used the same way on every type. `clone(self: &T, allocator: &Allocator? = null) T` is the explicit, allocating, deep duplicate: the only way to duplicate a non-copyable value, and the unmanaged flavour requires the allocator. Elements go through `#if type_info(T).copyable` (§7.7): copyable ones are copied, the rest cloned; there is no blanket `clone($T)`. There is no `copy` function anywhere: "copy" is the language's word for the bitwise duplicate that `move` replaces. `deinit(self: move T)` consumes its value; the unmanaged flavour is `deinit(self: move T, allocator: &Allocator)`, and no other shape exists in the standard library - anything else a value needs to release itself, it carries. `retain(self: &Rc(T)) Rc(T)` is the reference-count bump on `Rc` / `Arc`, so that `rc.clone()` peels through `op_deref` to `T`'s own `clone` and yields a `T`.

There is no blanket `deinit` either. A container releases an element through `release(value: move T)` (core.deinit), which is nothing for a copyable `T` and the type's own `deinit` otherwise - so a non-copyable type that declares none is a compile error at the container holding it, not a leak nothing reports. A type whose storage is released elsewhere - an arena, a registry that frees bodies of its own - says so by declaring an empty `deinit`, where the decision is visible and attributed. A type that carries a release obligation but owns no storage to mark `owned` holds a `NoCopy` (core.deinit): a zero-size field with an `owned` unit inside, so the derived bit stays derived. A drain holds one; its own `deinit` meets the obligation.
A composite built on them is managed only, storing its allocator once: `Journal(T)` (std.journal),
an undo log with nested checkpoints whose two buffers are reused across regions; `MultiMap(K, V)`
(std.multimap), a key-to-many-values table whose values share one pool, chained per key, so the
map is two allocations whatever the key count; `StringPool` (std.string_pool), interned strings in
one buffer named by a dense `StrId`, so a table that keys by name keys by an integer and every
name is stored once, whatever the number of tables citing it.
