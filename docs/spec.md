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

**Anonymous struct types** (`struct { ... }` written inline) appear only as the right-hand side of a `type` alias and as generator arguments. They are not first-class type expressions in arbitrary positions. Anonymous struct *values* (`.{ ... }`) require a target type from context — context-less `.{}` errors with a hint to add a type annotation.

**Anonymous type expressions**: `struct { ... }` and `enum { ... }` are valid anywhere a type appears — parameters, return types, variable annotations, function fields.

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

### 2.4 Structs

```
type Point = struct { x: i32, y: i32 }
type Vec2 = struct { x: f32, y: f32 }
```

Structs are always declared as a `type` alias whose RHS is a `struct(...) { ... }` builder. The legacy `struct Name { ... }` form has been removed (RFC-008, error E1050).

- All fields public (readable from any file).
- Field writes restricted to the defining file (scoped mutability — planned, not yet enforced).
- Layout optimized by compiler; declaration order ≠ memory order.
- Construction: `Point { x = 10, y = 20 }` (uses `=`, not `:`).
- Anonymous construction: `.{ x = 10, y = 20 }` (type from context).
- Field shorthand: `.{ x, y = 20 }` equivalent to `.{ x = x, y = 20 }`.
- **Strict construction**: every field must be assigned. `Point { x = 10 }` errors with E2050 ("struct literal missing field `<name>`") if `Point` has more fields. `Marker { }` is valid only when `Marker` has zero fields. Context-less `.{}` is invalid.

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

**Formattable protocol**: Types implement `fn format(self: T, sb: &StringBuilder)` to produce text. Users call `sb.append(value)` — primitive overloads write directly, generic fallback dispatches to `format()`.

**String interpolation** (RFC-004): `$"..."`, `$(args)"..."`, and `$sb"..."` are pure syntactic sugar over `StringBuilder.append` and `to_string`. The forms desugar as follows:

- `$"seg0{e1}seg1{e2}seg2"` becomes (roughly):
  ```
  ({ let __sb = string_builder(); defer __sb.deinit();
     __sb.append("seg0"); __sb.append(e1);
     __sb.append("seg1"); __sb.append(e2);
     __sb.append("seg2"); __sb.to_string() })
  ```
  — yields an `OwnedString`. Empty segments are skipped. Because `to_string()` transfers ownership and zeroes the builder, the deferred `deinit` is a no-op on success but still frees on panic.
- `$(args)"..."` forwards `args` to `string_builder(capacity: usize = 0, allocator: &Allocator? = null)`. A lone `&alloc` argument routes to the `allocator` slot; any other single positional arg lands in `capacity`.
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
- Unsuffixed integers and floats are inferred from context.

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
5. Callers use `defer x.deinit()` for scope-based cleanup.

```
let sb = string_builder(64)
defer sb.deinit()
```

This enables arena-based bulk deallocation: allocate many objects into an arena, free them all by resetting the arena.

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

### 5.2 Operator Functions

Every operator desugars to a function call. The stdlib provides implementations for primitives; user types define their own.

| Operator | Function |
|---|---|
| `+` `-` `*` `/` `%` | `op_add` `op_sub` `op_multiply` `op_divide` `op_modulo` |
| `==` `!=` `<` `>` `<=` `>=` | `op_eq` `op_ne` `op_lt` `op_gt` `op_le` `op_ge` |
| `&` `\|` `^` | `op_band` `op_bor` `op_bxor` |
| `[]` (ref-form) | `op_index_ref` |
| `[]` read (value-form) / `[]=` write (value-form) | `op_index` / `op_set_index` |
| `??` | `op_coalesce` |
| postfix `?` | `op_try` |
| `=` | `op_assign` |
| `+=` | `op_add_assign` |
| unary `-` / `!` | `op_neg` / `op_not` |
| `.field` (fallback) | `op_deref` |

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
- **Overload resolution handles same-named imports**. Two different imports may bring in functions with the same name; the type checker resolves the call by parameter types. Genuinely ambiguous calls (no unique strictest overload) error at the call site.
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

### 7.2 UFCS

Any function with first parameter `T` or `&T` can be called as `value.func(args)`. If the function expects `&T`, the receiver is automatically referenced. This is how methods work — no `impl` blocks.

### 7.3 Lambdas

`fn(x: i32, y: i32) i32 { x + y }` — anonymous, non-capturing. Desugars to a synthesized module-level function. Cannot capture enclosing scope variables.

**Parameter type inference** mirrors anonymous-struct rules. Each unannotated parameter must have its type inferable from one of:
- the corresponding parameter type at the call site (typed callback parameter, e.g. passing the lambda to `map(fn(T) U)`),
- the return type of the enclosing function when the lambda is `return`ed,
- an explicit `let x: fn(T) U = fn(p) { ... }` binding annotation,
- explicit annotations on the lambda parameters (`fn(p: T) { ... }`).

A no-context lambda is an error — diagnostic recommends adding annotations to the parameters or the binding site.

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

Make a type iterable by defining `fn iter(self: &T) Iterator` and `fn next(self: &Iterator) Element?`.

### 7.5 Match Expression

Postfix syntax: `expr match { pattern => result, ... }`. Postfix `match` is the lowest-precedence operator — `a + b match { ... }` parses as `(a + b) match { ... }`.

**Patterns**: unit variant (`Quit`), payload binding (`Move(x, y)`), qualified (`Color.Red`), nested (`Some(Ok(x))`), wildcard (`_`), literal (`42`, `b'A'`, `true`), `else` (default).

All variants must be covered or `else` required. Match is an expression — all arms unify to a common type. Enum references auto-deref during matching.

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

`#foreign` on a struct declaration locks its memory layout to C ABI conventions. The compiler will never reorder fields or change padding. In generated C code, the struct typedef/definition is omitted — it is provided by the included C header.

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
#if(platform.os == "windows") {
    // windows-only code
} else {
    // other platforms
}
```

Only the active branch is type-checked and lowered.

| Path | Type | Values |
|---|---|---|
| `platform.os` | string | `"windows"`, `"linux"`, `"macos"`, `"unknown"` |
| `platform.arch` | string | `"x86_64"`, `"arm64"`, `"x86"`, etc. |
| `runtime.testing` | bool | true when compiling with `test` |
| `runtime.release` | bool | true when compiling with `--release` |
| `runtime.env` | dict | Build-time environment variables |

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

**Built-in generators:**

| Generator | Purpose |
|---|---|
| `#derive(T, eq, clone, debug, hash, serialize, deserialize)` | Derive implementations |
| `#enum_utils(E)` | Generate `to_string`/`from_string` for enum |
| `#interface(Name, Spec)` | Define vtable-based interface |
| `#implement(Impl, Iface)` | Implement interface for a type |

Expansion runs up to 8 rounds, enabling generators that produce types or other generators. Output written to `<source>.generated.f`.

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
- **Bounds checking** (planned): Optional runtime bounds checking for array and slice indexing. Not yet implemented — out-of-bounds access is currently undefined behavior.
- **Null safety**: `&T` is non-null by type. `&T?` requires explicit handling. The type system prevents accidental null dereference on non-optional references.
- **Scoped mutability** (planned): Struct fields writable only in the defining file, read-only externally. Not yet enforced by the type checker.
- **String interpolation** (planned): `"text ${expr} more"` desugars to `StringBuilder.append()` calls — one builder, one allocation. Types without `format()` are a compile error in interpolation context.

---

## 9. Conventions

### 9.1 Entry Point

```
pub fn main() i32
```

Returns exit code. `0` indicates success.

### 9.2 Testing

```
test "name" {
    assert_true(condition, msg)
    assert_eq(a, b, msg)
}
```

Requires `import std.test`. Test blocks are module-scoped, not exported. Run with `--test` flag. `panic(msg)` terminates with exit code 1.

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
