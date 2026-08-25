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

| Syntax | Meaning |
|---|---|
| `[T; N]` | Fixed-size array |
| `T[]` | Slice — fat pointer `{ ptr: &T, len: usize }` |
| `&T` | Non-null reference |
| `T?` | Optional — sugar for `Option(T)` |
| `&T?` | Nullable reference — sugar for `Option(&T)` |
| `(A, B)` | Tuple — sugar for anonymous struct `{ _0: A, _1: B }` |
| `()` | Unit (empty tuple) |
| `fn(T1, T2) R` | Function type |
| `Type(T)` | Runtime type descriptor |

**Tuples** desugar to anonymous structs with a double-underscore prefix to avoid collisions with user fields: `(A, B)` → `{ __0: A, __1: B }`, access via `t.0` → `t.__0`. User-defined fields named `_0`, `_1`, etc. remain valid. Trailing comma distinguishes single-element tuple `(x,)` from grouped expression `(x)`.

**Anonymous type expressions**: `struct { ... }` and `enum { ... }` are valid anywhere a type appears — parameters, return types, variable annotations, function fields, and the right-hand side of a `type` alias. Anonymous struct *values* (`.{ ... }`) require a target type from context — context-less `.{}` errors with a hint to add a type annotation.

**Structural typing**: FLang is nominally typed for named structs and enums. However, tuples and anonymous structs are structurally typed — compatibility is determined by field names and types, not by declaration identity. A function accepting `{ _0: i32, _1: i32 }` will accept a tuple `(i32, i32)`. This is the foundation for planned broader structural typing: anonymous structs will serve as the entry point for TypeScript-style structural compatibility, where any value with matching fields satisfies an anonymous struct type constraint.

### 2.3 Generics

`$T` introduces a type parameter. After binding, `T` (without `$`) refers to it. Type parameters can appear in any position.

```
fn identity(x: $T) T { return x }
```

Generic structs and enums use parentheses on the `struct` / `enum` keyword:

```
type Pair = struct(T) { first: T, second: T }
type Result = enum(T, E) { Ok(T), Err(E) }
```

**Instantiation uses parentheses**: `Option(i32)`, `List(String)`, `Result(JsonValue, JsonError)`.

Inference is multi-phase: constraints flow bidirectionally from return positions, parameter annotations, and assignment targets. Untyped integer and float literals are placeholders that must unify with a concrete type before compilation completes.

A type parameter in scope **shadows** any nominal of the same name: inside `fn wrap(e: $E) Result(T, E)`, `E` is the parameter even if a type named `E` is visible.

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

Variants can carry zero or more payload types. Tags assigned sequentially starting at 0 (first variant = 0, next = 1, ...).

**Naked enums** (C-style): when any variant has `= value`, all variants are integer-tagged with no payloads. Tags auto-increment from previous value.

```
type Ord = enum { Less = -1, Equal = 0, Greater = 1 }
```

**Enum ↔ integer casts:**
- `e as i32` extracts the tag. Valid for any enum.
- `(n as MyEnum)` constructs a variant by tag value. **Only allowed for bare enums** — enums where every variant is payload-less. Allowing this on a payload-carrying enum would leave payload bytes uninitialized; the type checker rejects it with E2020.

Useful for FFI where a C shim returns an error code that matches the FLang discriminant layout. If a niche optimization later shifts bare-enum discriminants (see §2.7), both sides of the FFI boundary must update together — keep the C constants and the FLang enum declaration in the same file or adjacent files.

**Variant construction**: `Color.Red` (qualified), `Result.Ok(42)` (with payload), `Ok(42)` (short form when unambiguous).

### 2.6 String Types

Three types with explicit ownership. All share layout `{ ptr: &u8, len: usize }` and guarantee null-termination for C FFI.

**String** — non-owning view. No `deinit`. Used for literals, parameters, temporary references. Same binary layout as `u8[]`.

**OwnedString** — owns its buffer. Must be freed via `deinit()`. Follows allocator pattern. Produced by `StringBuilder.to_string()`, `from_view()`.

**StringBuilder** — owning, mutable, growable buffer. `append()` adds content. `to_string()` transfers buffer to OwnedString (move semantics — builder resets). `as_view()` returns non-owning String view.

| From | To | Method | Cost |
|---|---|---|---|
| `OwnedString` | `String` | `.as_view()` | Zero-copy |
| `String` | `OwnedString` | `from_view(s, allocator)` | Allocates + copies |
| `StringBuilder` | `OwnedString` | `.to_string()` | Zero-copy (move) |
| `StringBuilder` | `String` | `.as_view()` | Zero-copy (temporary) |

Conversions are always explicit — no implicit coercions between string types.

**Formattable protocol**: Types implement `fn format(self: T, sb: &StringBuilder, spec: String)` to produce text. Users call `sb.append(value)` — primitive overloads write directly, generic fallback dispatches to `format()`.

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

| Inner type | Representation | Rationale |
|---|---|---|
| `&T` (reference) | `IrPointer(T, IsNullable: true)` — a nullable pointer | Niche: `None` encoded as 0 pointer. Zero overhead vs. raw `&T`. |
| Anything else | Tagged enum with `None` (tag `0`) and `Some(T)` variants | Generic enum layout. |

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

`Type(T)` is a built-in generic struct carrying runtime metadata. Type names used as values become `Type(T)` instances. The compiler generates a global type metadata table for all instantiated types.

> `Type(T)` is the generic (phantom-`T`) view of the raw `TypeInfo`, à la Java `Class<T>` / `Class`; `Type(T)` -> `TypeInfo` is implicit phantom erasure. Descriptors are interned, so `&TypeInfo` pointer identity is type identity. See [ADR-0001](adr/0001-type-t-is-the-generic-view-of-typeinfo.md).

`TypeInfo` (`core.rtti`) carries `name`, `size`, `align`, `kind: TypeKind`, `fields: FieldInfo[]` (structs), `variants: VariantInfo[]` (enums), `params: ParamInfo[]` and `return_type` (function types). It is also the introspection surface of source generators (§7.8): the same struct, the same members, so compile-time generation and runtime reflection never diverge. `TypeInfo` grows only for a demonstrated need — no convenience flags (`is_struct` is `kind == TypeKind.Struct`).

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
- Unsuffixed integers and floats are inferred from context. A bare literal as a cast operand takes the cast's target type (`0xFFFF_FFFF as u64` is a `u64` constant, not an `i32` converted). A literal that no context ever pins is an error (**E2001**).

### 2.12 Trailing Commas

Comma-separated lists accept a trailing comma uniformly: function-call arguments, struct/enum literal fields, parameter lists, generic type parameters, enum variant declarations, match arms (when commas are used as separators inside a single arm body), array literals, etc. The single-element tuple `(x,)` keeps its distinct meaning — the trailing comma is what makes `(x,)` a 1-tuple rather than a grouped expression.

### 2.13 Comments

`// line comment to end of line` is the only comment form. There is no `/* */` block comment, no `///` doc comment. Editor tooling handles "comment out a block" by inserting `//` per line.

---

## 3. Value Semantics

### 3.1 Storage and Assignment

Every named binding has a memory location. `let x = expr` performs a shallow byte-copy. Pointers inside are copied as-is (aliasing possible). No hidden reference counting.

### 3.2 Function Arguments

**Implicit reference, copy-on-write:**

- Caller passes address of each argument (implicit reference).
- Callee reads through pointer (no copy for read-only access).
- On first write to a parameter, the compiler inserts a shadow copy (alloca + memcpy). All subsequent accesses use the shadow.
- The caller's value is never mutated by the callee.

This is transparent — source code reads as pass-by-value, but large structs avoid unnecessary copies.

### 3.3 Return Values

| Return type | Mechanism |
|---|---|
| Small values (≤ register size) | Returned in registers |
| Large structs | Caller allocates slot, passes hidden `__ret` pointer as first argument. Callee writes directly to slot. |

This is transparent to the programmer — `return expr` works uniformly.

### 3.4 References

- `&x` takes address of a variable.
- `ptr.*` explicit dereference (produces a copy).
- `ptr.field` auto-dereference (reads/writes through pointer, no copy). Recursive through `&&T`.

### 3.4.1 Place Expressions

A **place expression** (lvalue) denotes a storage location. A **value expression** (rvalue) denotes a value with no location of its own. Every expression is lowered in exactly one of these two modes, and which mode applies is a property of the *context*, not of the expression.

**The place forms.** These, and only these, denote places:

| Form | Place when |
|---|---|
| `x` | `x` is a local, parameter, or global |
| `p.*` | always — the pointer already is the address |
| `base.field` | `base` is a place, or is a reference |
| `base[i]` | `base` is a place, or is a reference or slice |

Everything else — call results, literals, arithmetic, struct literals, `match` results — is a value expression. A place is also usable as a value (by loading it); a value is not usable as a place.

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

Variables are valid from declaration to end of enclosing block. No move semantics, no consume semantics. Accessing a variable always succeeds if in scope (C-like).

### 3.6 Safety Model

The compiler does not enforce memory safety beyond scoped mutability (planned). The following are the programmer's responsibility:

- Double-free
- Use-after-free
- Aliased mutation
- Data races
- Dangling references (String views must not outlive backing data)

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
    realloc: fn(&u8, memory: u8[], new_size: usize) u8[]?
    dealloc: fn(&u8, memory: u8[]) void
}
```

**Rules:**

1. Types that allocate have an `allocator: &Allocator?` field.
2. Null allocator falls back to `global_allocator` (wraps `malloc`/`free`) via `or_global()`.
3. All allocation/realloc/free go through the allocator — never raw `malloc`/`free`.
4. Types that allocate provide `deinit()` for deterministic cleanup.
5. Callers use `defer x.deinit()` for scope-based cleanup, registered right after the value is created.
6. **Every `deinit()` is idempotent**: the first call nulls the value's owning state (pointer/cap/payload), so a second call is a no-op — never a double free. A type either only calls deinits that are themselves safe, or resets its own state so later calls no-op.
7. **Containers cascade**: `List.deinit`, `Dict.deinit`, `Option.deinit`, etc. call `deinit()` on their live elements (keys and values for dicts) before freeing their storage; the universal no-op fallback (`core.deinit`) makes this unconditional. Do not hand-loop element deinits before a container deinit — and never deinit values obtained from container *iteration* or by-value indexing, which yield copies whose cleanup leaves the stored element pointing at freed memory. Mutate stored values in place through `get_ref`/`op_index_ref`.
8. **`Dict.set` on an existing key deinits the overwritten value** (and the unused new key for owned-key dicts). The read-copy-modify-`set` pattern is therefore unsound for owned values; update through `get_ref` instead.

```
let sb = string_builder(64)
defer sb.deinit()
```

This enables arena-based bulk deallocation: allocate many objects into an arena, free them all by resetting the arena.

**Defer ordering on `return`.** A `return expr` evaluates `expr` first, then fires the active defers in LIFO order, then transfers control. This lets `defer x.deinit()` coexist with a return expression that reads `x` (`return x.as_view().len`, `return sb.to_string()`, etc.) — the read observes `x`'s pre-deinit state, and the deferred call sees whatever state the return expression left behind (e.g. `to_string` zeroes the builder so the deferred `deinit` is a no-op). Returning `x` itself by value while a `defer x.deinit()` is active still frees the buffer the copy points at — defer fires after the copy is materialised but before the function returns. Don't defer-deinit a value you're returning by value; drop the defer in that case.

### 4.2 Zero Initialization

All memory is zero-initialized by default. Variables declared without an initializer are memset to zero. The compiler may optimize this away when provably written before read.

### 4.3 Reference Counting (Rc and Arc)

`Rc(T)` provides shared ownership of a heap-allocated value. `Arc(T)` is the thread-safe variant using atomic operations on the reference count. Both live in `std.rc`.

**Control block layout**: `RcInner(T) = { ref_count: usize, value: T }`. Single heap allocation — no separate allocation for the control block.

**Construction**:
- `rc(value, allocator?)` / `arc(value, allocator?)` — copies value into a new heap allocation.
- `rc_alloc(allocator?)` / `arc_alloc(allocator?)` — zero-initializes for in-place fill via `op_deref`.

**Operations**:
- `.clone()` — explicit refcount bump. Returns a new handle to the same value. Shallow copy of an Rc/Arc is an alias (no hidden costs).
- `.deinit()` — decrements refcount. At zero, calls `T.deinit()` (statically dispatched via monomorphization — no function pointer in the control block) then frees the allocation.
- `.op_deref()` — returns `&T`, enabling transparent field access: `rc.field` instead of `rc.borrow().field`.

**Arc atomics**: `Arc.clone()` uses `atomic_fetch_add`, `Arc.deinit()` uses `atomic_fetch_sub`. Backed by C11 `<stdatomic.h>` via `std.atomic`.

**Conventions**: Internal fields use `__` prefix (`__inner`, `__allocator`). No `Weak` references yet — `RcInner` stays opaque for future addition.

---

## 5. Operators

### 5.1 Precedence (highest to lowest)

| Level | Operators |
|---|---|
| 13 | `as` (postfix typed cast) |
| 12 | `*` `/` `%` |
| 11 | `+` `-` |
| 10 | `<<` `>>` `>>>` |
| 9 | `&` (bitwise AND) |
| 8 | `^` (XOR) |
| 7 | `\|` (OR) |
| 6 | `..` |
| 5 | `<` `>` `<=` `>=` |
| 4 | `==` `!=` |
| 3 | `and` |
| 2 | `or` |
| 1 | `??` (right-assoc) |
| 0 | `match` (postfix, lowest) |

- `as` is a postfix typed operator that binds tighter than every binary operator: `a + b as i32` parses as `a + (b as i32)`.
- Postfix `match` binds looser than every binary operator: `a + b match { ... }` parses as `(a + b) match { ... }`.
- `and`/`or` are keywords, short-circuit, bool operands only.
- `!expr` logical NOT, `&expr` address-of (prefix unary).
- `>>` arithmetic right shift (sign-preserving). `>>>` logical right shift (zero-fills).

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

Operators on primitive types are compiler built-ins, resolved and emitted directly as arithmetic — no function call is involved. For user types, an operator resolves to the corresponding `op_*` function below (recorded on the node by the checker, emitted as an ordinary call by lowering); a user type enables an operator by defining that function.

| Operator | Function |
|---|---|
| `+` `-` `*` `/` `%` | `op_add` `op_sub` `op_mul` `op_div` `op_mod` |
| `==` `!=` `<` `>` `<=` `>=` | `op_eq` `op_ne` `op_lt` `op_gt` `op_le` `op_ge` |
| `&` `\|` `^` | `op_band` `op_bor` `op_bxor` |
| `[]` (ref-form) | `op_index_ref` |
| `[]` read (value-form) / `[]=` write (value-form) | `op_index` / `op_set_index` |
| `??` | `op_coalesce` |
| postfix `?` | `op_try` |
| `=` | `op_assign` |
| `+=` | `op_add_assign` |
| unary `-` / `!` / `~` | `op_neg` / `op_not` / `op_bnot` |
| `.field` (fallback) | `op_deref` |
| `t(args)` (callable types) | `op_call` |

**`op_call`** (RFC-014): when `t(args)` is invoked and `t`'s type defines `fn op_call(self: T, ...)` or `fn op_call(self: &T, ...)`, the call rewrites to `op_call(t, args...)` (or `op_call(&t, args...)`). Any type can become callable — comparators with state, function objects, iterator-like wrappers, and (Phase 2) capturing closures. Multiple `op_call` overloads on the same type are resolved by the existing overload mechanism. `op_call` resolution chains through `op_deref`: `Owned(F)` is callable when `F` is, no special-casing required. `op_call` dispatch also applies in field position: `h.f(args)` where field `f`'s type defines `op_call` (e.g. a capturing closure stored in a struct field) rewrites to `op_call(&h.f, args...)`, calling in place through the field — no local copy needed.

**`op_deref`**: When `x.field` or `x.method()` fails to resolve on type `X`, the compiler looks for `fn op_deref(self: &X) &T`. If found, resolution retries on `T`. This applies to both field access and UFCS method calls. Chains through multiple layers: `Rc(Wrapper(Point)).x` resolves through two `op_deref` calls. Own fields and methods on `X` always take priority — `op_deref` is only consulted when direct resolution fails. This is a general-purpose language feature, not specific to smart pointers.

**Indexing (`[]`)** — two mutually exclusive patterns for user-defined types:

| Pattern | Signature | Enabled syntax |
|---|---|---|
| **Ref-form** (lvalue storage) | `fn op_index_ref(self: &Self, idx: Idx) &T` | `x[i]` read, `x[i] = v` write, `&x[i]` address-of |
| **Value-form** (computed read) | `fn op_index(self, idx: Idx) T` (any return shape: `T`, `T?`, `T[]`, ...) | `x[i]` read only |
| **Value-form** (optional setter) | `fn op_set_index(self: &Self, idx: Idx, v: V)` | `x[i] = v` write |

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

**Null-coalescing `??`**: If `a` is `Option(T)` with a value, yields unwrapped `T`; otherwise yields `b`. Right-associative, chainable: `a ?? b ?? c`.

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
- Pointer ↔ integer: `&T` ↔ `usize|isize`.
- Pointer ↔ pointer: `&T` ↔ `&U` (view cast, programmer's responsibility).
- `String` ↔ `u8[]`: zero-copy binary reinterpretation.

Implicit: `String` automatically accepted where `u8[]` expected. Reverse (`u8[]` → `String`) requires explicit `as String`.

---

## 6. Modules and Visibility

- Each source file is a module. `import path` brings the module's `pub` items into scope as bare names.
- **Imports are flat and non-transitive by default**: a plain `import B` from module A makes B's `pub` items visible inside A only — anyone importing A does **not** see B.
- **`pub import path`** opts into re-export. Anyone importing the current module also sees the `pub` items of the re-exported module. Re-exports compose transitively along chains of `pub import`. This is the only re-export mechanism — no aliases, no selective re-exports.
- **Overload resolution handles same-named imports**. Two different imports may bring in functions with the same name; the type checker resolves the call by parameter types. Candidates are ranked by **structural specificity** first: each concrete type constructor in a declared parameter is a constraint the call's arguments had to satisfy, and the candidate whose supplied parameters carry more of them wins — `deinit(&List($T))` beats the universal `deinit(&$T)` fallback for a list receiver, and a concrete-receiver method like `any(&Dict($K,$V), $F)` beats an unconstrained catch-all like `any($I, $F)`. Type variables contribute nothing, and a position is only scored when its argument's type is already fully known — parameters the call left to defaults, and positions whose argument still contains an unresolved type variable (an unsuffixed literal, a half-inferred aggregate), are skipped, since an unbound argument matches any parameter shape at zero cost and cannot corroborate structure. Specificity ties fall to lower coercion cost, then fewer quantified type parameters, then literal-preference arbitration, and finally declaration order. A UFCS receiver's adapted value ↔ `&T` form competes inside the same ranked candidate set (at a small cost penalty) rather than in a fallback pass, so a catch-all matching the un-adapted receiver cannot preempt a more specific overload that needs the adaptation. Genuinely ambiguous calls (no unique strictest overload) error at the call site. (The specificity count is a tuned heuristic standing in for a real constraint system.)
- **No aliases, no selective imports, no relative paths.**
- **Auto-imported core prelude.** Every module implicitly imports [`core.prelude`](../stdlib/core/prelude.f), a curated barrel that `pub import`s the core modules (`core.option`, `core.string`, `core.io`, `core.cmp`, etc.). All core symbols are therefore visible without an explicit import. The prelude itself is the only module exempt from the auto-import.
- **Project-level globals.** A project may declare `[imports].global = ["std.prelude", ...]` in `flang.toml`; each entry is injected as an implicit private import into every project file. Project globals never propagate to stdlib or third-party modules.
- `pub` exposes declarations outside the file. Without `pub`: file-private.
- Visibility is two-level only — there is no `pub` on individual fields, and there are no property declarations. External "mutation" of a struct happens by re-construction (return a new value, or have the defining file expose mutating functions).
- Struct fields readable from any file, writable only in defining file (see scoped mutability in Section 8).
- Cyclic imports (including `pub import` cycles) are compile errors.
- A symbol is visible in module M iff it is defined in M, OR it is `pub` and defined in a module reachable from M via `import` plus the `pub import` transitive closure.
- FQN-style references (e.g. `core.option.Option`) bypass visibility — an explicit dotted name is unambiguous and self-authorizing.

---

## 7. Compilation Model

### 7.1 Functions

- Overloading supported by name and parameter types. The type checker selects the strictest applicable overload.
- **Default parameters**: `fn foo(x: i32, y: i32 = 10)`. Evaluated fresh at each call site. Must follow required parameters.
- **Named arguments**: `foo(y = 20, x = 10)`. Positional args first. Not supported for indirect calls.
- **Variadic parameters**: `fn bar(..args: i32)`. Received as `i32[]` slice. One variadic, must be last. Foreign functions use C-style `...`.
- All three are caller-side transformations — lowering sees a normal positional argument list.

### 7.1.1 Symbol Naming

FLang permits overloading, generic specialization, and same-named functions in different modules; the target object format does not. Every function therefore has a **symbol** — the single, globally unique name it links under — distinct from its source **name**.

**A symbol is fixed before code generation.** By the time a program reaches a backend, every function definition carries its final symbol and every call names its callee's symbol directly. A backend emits symbols; it does not compute them.

This keeps code generation *overload-independent*. Deciding how two functions with the same source name are told apart requires overload resolution, default and variadic handling, generic specialization, and knowledge of the return-value ABI. That decision belongs to one place in a compiler, not to each backend — otherwise every target must reproduce it identically.

**Required properties.** A symbol must be:

1. **Unique** — distinct functions never collide, including same-named overloads and same-named functions in different modules.
2. **Deterministic** — a function's symbol depends only on the function itself: its module, name, and parameter types. Recompiling an unchanged declaration yields an unchanged symbol, and adding or removing an unrelated function never renames it. Builds are reproducible and separately-compiled units agree without coordination.
3. **Consistent** — a definition and every call to it name the same symbol.
4. **A valid target identifier** — for targets in the C family, matching `[A-Za-z_][A-Za-z0-9_]*`.

**Property 4 is total, not conditional.** A symbol is derived from the function's *module path* as well as its name, and a module path is not a FLang identifier: it is built from the project name and the source file path, both of which may contain any character the host filesystem and manifest allow. `name = "chess-fen"` is a legal project name. An encoding must therefore map **every** input byte to something the target admits — a pass-through default that assumes identifier-safe input violates this property, and the resulting symbol is not merely ugly but unparseable (`chess-fen_main_f` is a subtraction in C).

The escape must also be **injective over the whole input**, which follows from property 1: if two distinct source characters collapse to the same output, two distinct functions can collide. An encoding that maps several characters to `_` satisfies property 4 but weakens property 1, and is conforming only where the collapsed characters cannot both appear.

**The encoding is unspecified.** Programs cannot observe it, and targets with different identifier rules may need different encodings. Any encoding satisfying the four properties conforms. The two in-tree backends differ, which is allowed: the self-hosted compiler escapes injectively (`.` → `__`, `_` → `_0`, anything else → `_x<hex>`), while the reference collapses every non-identifier character to `_`.

Two names are exempt and keep their source spelling, because something outside the language already fixes them: the **entry point** (`main`) and **`#foreign` functions**, which name symbols defined elsewhere.

**Overloading and separate compilation.** Property 2 rules out schemes that number overloads in declaration order. A counter makes a symbol depend on how many same-named functions were seen first, so inserting a declaration renames later ones and independent compilation units cannot agree without sharing the counter. Encoding the parameter types instead makes each symbol self-contained.

### 7.2 UFCS

Any function with first parameter `T` or `&T` can be called as `value.func(args)`. If the function expects `&T`, the receiver is automatically referenced. This is how methods work — no `impl` blocks.

### 7.3 Lambdas

`fn(x: i32, y: i32) i32 { x + y }` — anonymous. A lambda with no captured names desugars to a synthesised module-level function (effectively a bare function pointer). A lambda that references names from the enclosing scope is a **capturing closure** (RFC-014): the compiler synthesises an anonymous `__Closure_N` struct holding the captures *by value* and an `op_call(self: &__Closure_N, ...)` body that projects each capture reference through `self`.

**Capture rules** (RFC-014, Phase 2):
- Capture is by value at the point the lambda is constructed; later mutation of the outer name is invisible inside the closure.
- Captured names are read-only inside the body; assigning to one is **E2112**.
- A capturing closure has an anonymous nominal type and **cannot decay into a bare `fn(...) Ret` slot** (E2111) — that slot has no env storage. Pass capturing closures through a generic parameter (`fn apply(f: $F, x: i32) i32 { return f(x) }`) which dispatches via `op_call`.
- Single-level capture only. A nested closure that captures a name an enclosing closure also captures is rejected with **E2113** until transitive-capture lowering lands.
- `&local` capture-by-reference syntax is not yet implemented; explicit reference captures are a follow-up.

**Parameter type inference** mirrors anonymous-struct rules. Each unannotated parameter must have its type inferable from one of:
- the corresponding parameter type at the call site (typed callback parameter, e.g. passing the lambda to `map(fn(T) U)`),
- **a generic `$F` slot** — the lambda's fresh parameter/return vars are pinned by the *instantiation's* body re-check at the point the callable is invoked (`xs.filter(fn(x) { x > floor })` needs no annotations even though `filter` is duck-typed),
- the return type of the enclosing function when the lambda is `return`ed,
- an explicit `let x: fn(T) U = fn(p) { ... }` binding annotation,
- explicit annotations on the lambda parameters (`fn(p: T) { ... }`).

A no-context lambda is an error — diagnostic recommends adding annotations to the parameters or the binding site. One inference-order consequence of the `$F` path: a value whose type is pinned *only* through the instantiation (e.g. `fold`'s seed when `f` is duck-typed) cannot resolve a bare numeric literal — write `xs.fold(0i32, fn(a, x) { a + x })`, not `fold(0, …)`.

**Stdlib callback convention.** Standard-library combinators (`List`/`Dict`/`Set` utilities, the `std.iter` adapters and consumers, `sort`'s comparator) type their callbacks as duck-typed generic parameters (`f: $F`), never as concrete `fn(...)` types: any callable fits — bare functions, non-capturing lambdas, and capturing closures — and monomorphization makes the dispatch direct. Callbacks are **value-mode**: combinators invoke `f(element)` with values, and §3.2's implicit-reference copy-on-write ABI makes that copy-free for read-only callbacks. Ref-mode callbacks (`fn(&T)`) do not adapt to value invocation (and vice versa); argument-adaptation rules are a deliberate open design point (docs/tickets/019).

### 7.4 Iterator Protocol

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

| form | resolves | binds | a type joins by defining |
|---|---|---|---|
| `for x in xs` | `iter(&xs)` | `x: T` — a copy per iteration | `fn iter(self: &T) Iterator` and `fn next(self: &Iterator) E?` |
| `for &x in xs` | `iter_ref(&xs)` | `x: &T` — aliased into the collection's storage | `fn iter_ref(self: &T) RefIterator` and `fn next(self: &RefIterator) &E?` |

`for x in xs.iter_ref()` is the reference form spelled out.

**Choose by aliasing, not by speed.** Take the reference form to mutate elements in place, or when the body must otherwise alias the collection's storage. It is not the faster one: the pointer stride can defeat vectorization, while the by-value copy is a local temporary the C backend eliminates under `--release` — measured on 48-byte structs, the by-value loop compiles to the same vectorized loop as manual indexing.

Which types iterate, and how:

- **`List` and slices** — both forms; they ship `iter_ref` alongside `iter`.
- **Iterator types** — every iterator is itself iterable, so adapters chain: `xs.iter().enumerate()`.
- **Fixed arrays `[T; N]`** — decay to a slice, so both forms work: `iter(&T[])` and `iter_ref(&T[])`. `for &el in arr { el.* = ... }` mutates the array in place.
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

### 7.6 Directives

Prefixed with `#`, precede declarations:

| Directive | Purpose |
|---|---|
| `#foreign` | C FFI function (no body, not mangled) or C-layout-locked struct |
| `#deprecated("msg")` | Deprecation warning on usage |
| `#inline` | Inlining hint |
| `#intrinsic` | Compiler-recognized stdlib intrinsic |
| `#simd` | SIMD-aligned struct (16+ byte alignment) |

Unknown directives produce warning W2003.

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

Note: `#foreign` and `#simd` must appear inline after `=` in type declarations (not as detached directives above the declaration).

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

| Path | Type | Values |
|---|---|---|
| `platform.os` | string | `"windows"`, `"linux"`, `"macos"`, `"unknown"` |
| `platform.arch` | string | `"x86_64"`, `"arm64"`, `"x86"`, etc. |
| `runtime.testing` | bool | true when compiling with `test` |
| `runtime.release` | bool | true when compiling with `--release` |
| `runtime.env` | dict | Build-time environment variables |

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

**Template values.** An `Ident` parameter is an identifier (`Name.text` is its spelling; `#(Name)` pastes it). A `Type` parameter is the argument's `TypeInfo` (§2.9) — `T.name`, `T.kind` (compare with `TypeKind.Struct` etc.), `T.fields`, `T.variants`, `T.params`, `T.return_type`, with `field.name` / `field.type_info` and `variant.name` exactly as at run time. `size`, `align` and `offset` are not available at expansion time (layout is computed after expansion) — reading them is E2120. Any nominal, primitive or anonymous `struct { … }` may be passed as a `Type` argument. Builtin functions: `type_of(T)` (identity), `type_named("Name")` (look a type up by name, e.g. one generated earlier — E2003 if absent), `lower`, `snake_case`, `pascal_case`.

**Template directives.** `#(expr)` pastes the value's text; inside a string literal (`"#(expr)"`) it pastes it escaped, so the literal stays valid. `#for x in list { … }`, `#if cond { … } #elif cond { … } #else { … }`. `##` escapes a literal `#`.

Template `#if` **is** the `#if` directive of §7.7 — the same evaluator, the same closed context (`platform.*`, `runtime.*`, target overrides) and the same rules (bool conditions, unknown names are errors, `??` to unwrap `runtime.env[..]`), evaluated at expansion time with the template's parameters and `#for` variables in scope. `#(expr)` and `#for` iterables use that evaluator too. The one difference: a template `#if` never emits its inactive branch, so that branch is never parsed.

**Built-in generators:**

| Generator | Purpose |
|---|---|
| `#derive(T, eq, clone, debug, hash, serialize, deserialize)` | Derive implementations |
| `#enum_utils(E)` | Generate `to_string`/`from_string` for enum |
| `#interface(Name, Spec)` | Define vtable-based interface |
| `#implement(Impl, Iface)` | Implement interface for a type |

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

Returns exit code. `0` indicates success. An entry point is required for an executable project (`kind = "exe"`) but not for a library (`kind = "lib"`), which is consumed by source and never linked. Every `flang.toml` must declare `[project].kind` as `"exe"` or `"lib"`.

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
core/           runtime bindings, platform integration (auto-imported)
std/            standard modules
std/encoding/   serialization (JSON, codec)
std/io/         input/output, filesystem, readers/writers
std/            collections (List, Dict), text (string, string_builder), allocator
```
