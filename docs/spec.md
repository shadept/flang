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

**Tuples** desugar to anonymous structs: `(A, B)` → `{ _0: A, _1: B }`, access via `t.0` → `t._0`. Trailing comma distinguishes single-element tuple `(x,)` from grouped expression `(x)`.

**Anonymous type expressions**: `struct { ... }` and `enum { ... }` are valid anywhere a type appears — parameters, return types, variable annotations, function fields.

**Structural typing**: FLang is nominally typed for named structs and enums. However, tuples and anonymous structs are structurally typed — compatibility is determined by field names and types, not by declaration identity. A function accepting `{ _0: i32, _1: i32 }` will accept a tuple `(i32, i32)`. This is the foundation for planned broader structural typing: anonymous structs will serve as the entry point for TypeScript-style structural compatibility, where any value with matching fields satisfies an anonymous struct type constraint.

### 2.3 Generics

`$T` introduces a type parameter. After binding, `T` (without `$`) refers to it. Type parameters can appear in any position.

```
fn identity(x: $T) T { return x }
```

Generic structs and enums use parentheses:

```
struct Pair(T) { first: T, second: T }
enum Result(T, E) { Ok(T), Err(E) }
```

**Instantiation uses parentheses**: `Option(i32)`, `List(String)`, `Result(JsonValue, JsonError)`.

Inference is multi-phase: constraints flow bidirectionally from return positions, parameter annotations, and assignment targets. Untyped integer and float literals are placeholders that must unify with a concrete type before compilation completes.

### 2.4 Structs

```
struct Point { x: i32, y: i32 }
type Vec2 = struct { x: f32, y: f32 }       // alternative syntax
```

- All fields public (readable from any file).
- Field writes restricted to the defining file (scoped mutability — planned, not yet enforced).
- Layout optimized by compiler; declaration order ≠ memory order.
- Construction: `Point { x = 10, y = 20 }` (uses `=`, not `:`).
- Anonymous construction: `.{ x = 10, y = 20 }` (type from context).
- Field shorthand: `.{ x, y = 20 }` equivalent to `.{ x = x, y = 20 }`.

### 2.5 Enums (Tagged Unions)

```
enum Color { Red, Green, Blue }
enum Result(T, E) { Ok(T), Err(E) }
type JsonError = enum { UnexpectedChar, UnexpectedEnd }
```

Variants can carry zero or more payload types. Tags assigned sequentially (0, 1, 2...).

**Naked enums** (C-style): when any variant has `= value`, all variants are integer-tagged with no payloads. Tags auto-increment from previous value.

```
enum Ord { Less = -1, Equal = 0, Greater = 1 }
```

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

### 2.7 Option and Nullability

```
pub type Option = struct(T) { has_value: bool, value: T }
```

- `T?` is sugar for `Option(T)`.
- `null` represents the absent value.
- `&T?` models nullable references.
- Methods: `is_some()`, `is_none()`, `unwrap_or(fallback)`, `expect(msg)`, `map(fn(T) U)`.

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

- Type suffix: `42i32`, `0xffu8`, `3.14f32`. Valid suffixes: all integer primitives, `f32`, `f64`.
- Hex: `0xff`, `0xDEAD_BEEF`.
- Underscore separators: `1_000_000`, `0xff_ff`.
- Scientific notation: `1.5e10`, `3e-4`.
- Unsuffixed integers and floats are inferred from context.

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

---

## 5. Operators

### 5.1 Precedence (highest to lowest)

| Level | Operators |
|---|---|
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
| `[]` read / `[]=` write | `op_index` / `op_set_index` |
| `??` | `op_coalesce` |
| `=` | `op_assign` |
| `+=` | `op_add_assign` |
| unary `-` / `!` | `op_neg` / `op_not` |

**Auto-derivation:**
- `op_eq` auto-derives `op_ne` (and vice versa) by negation.
- `op_cmp(a, b) Ord` auto-derives all six comparison operators. Explicitly defined operators take priority.

### 5.3 Null Operators

**Null-coalescing `??`**: If `a` is `Option(T)` with a value, yields unwrapped `T`; otherwise yields `b`. Right-associative, chainable: `a ?? b ?? c`.

**Safe member access `?.`**: `opt?.field` yields `Option(field_type)` — the field value if present, `null` otherwise. Chainable: `a?.b?.c`.

**Early return `?`** (planned): `expr?` on `Option(U)` early-returns `null` if absent, otherwise unwraps. On `Result(U, E)` early-returns `Err(e)` if error, otherwise unwraps. Enclosing function must return compatible `Option` or `Result`.

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

- Each source file is a module. `import path` brings a module into scope.
- `pub` exposes declarations outside the file. Without `pub`: file-private.
- Struct fields readable from any file, writable only in defining file (see scoped mutability in Section 8).
- Cyclic imports are compile errors.
- Core modules are auto-imported.

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

`fn(x: i32, y: i32) i32 { x + y }` — anonymous, non-capturing. Desugars to a synthesized module-level function. Parameter types inferred when context available. Cannot capture enclosing scope variables.

### 7.4 Iterator Protocol

`for x in collection` desugars to:

```
let it = iter(&collection)
loop {
    let n = next(&it)      // returns T?
    if n == null { break }
    let x = n.value
    // body
}
```

Make a type iterable by defining `fn iter(self: &T) Iterator` and `fn next(self: &Iterator) Element?`.

### 7.5 Match Expression

Postfix syntax: `expr match { pattern => result, ... }`.

**Patterns**: unit variant (`Quit`), payload binding (`Move(x, y)`), qualified (`Color.Red`), nested (`Some(Ok(x))`), wildcard (`_`), literal (`42`, `b'A'`, `true`), `else` (default).

All variants must be covered or `else` required. Match is an expression — all arms unify to a common type. Enum references auto-deref during matching.

### 7.6 Directives

Prefixed with `#`, precede declarations:

| Directive | Purpose |
|---|---|
| `#foreign` | C FFI function (no body, not mangled) |
| `#deprecated("msg")` | Deprecation warning on usage |
| `#inline` | Inlining hint |
| `#intrinsic` | Compiler-recognized stdlib intrinsic |

Unknown directives produce warning W2003.

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
