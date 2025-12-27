# FLang Language Specification (v2-draft)

## 1. Core Philosophy

FLang is a modern systems programming language designed for explicit control, strong inference, and ergonomic syntax.
All operations have defined semantics and the language avoids undefined behavior.

- Manual memory control.
- Strong multi-phase type inference and unification.
- Structural typing.
- Immutable by default.
- Binary compatibility for core abstractions.

---

## 2. Syntax and Core Constructs

### 2.1 Variables and Mutability

- `const name = expr` declares an immutable binding.
- `let name = expr` declares a mutable binding.
- Variables are block-scoped.
- Mutability of struct fields is permitted only within the file that defines the struct (file-scope mutability).

### 2.2 References

- `&T` is a non-null reference to `T`.
- `&T?` is an optional reference.
- A C pointer corresponds to `&T?`. `void*` has no exact equivalent; `&u8?` is the closest.
- Reference writes follow file-scope mutability rules.

### 2.3 Structs

```
struct Name {
    field1: Type1
    field2: Type2
}
```

Structs may be generic. Generic parameters are introduced by `[T, U, ...]`.

- All fields are public.
- Field writes are allowed only in the defining file.
- Layout is optimized; declaration order does not determine memory order.
- Layout is stable per target/configuration and queryable via introspection.
- Anonymous structs: `.{ field = value, ... }`.
- Structural typing allows binding by field name.

### 2.4 Functions

```
fn name(parameters) ReturnType
```

- Functions may be generic.
- `$T` declares and binds a generic parameter at any position (parameter or return).
- Overloading is supported by name and compatible parameter types.
- The type system selects the strictest applicable overload; if multiple remain, it is an error.
- UFCS applies: `object.method(a, b)` desugars to `method(&object, a, b)`.
- C backend name mangling: all non-foreign functions are emitted with a mangled name derived from the base name and the parameter types (e.g., `name__i32__u64`). This guarantees unique C symbols for overloads. The `main` entrypoint is not mangled. Generic specializations are emitted using the same scheme. Name mangling occurs only during code generation; earlier phases (TypeSolver, FIR) preserve base names and attach type metadata.

### 2.5 Expressions and Control Flow

#### If Expression

```
if (cond) expr1 else expr2
```

- Yields the anonymous union of the types of `expr1` and `expr2`.
- If `else` is omitted, result type is `Option` of the type of `expr1`.

#### For Expression

```
for (pattern in iterable) block
```

- Only looping construct.
- Uses the iterator protocol; built-in for ranges, arrays, and slices.
- Supports `break` and `continue`.

#### Defer

```
defer expression
```

- Executes on scope exit in LIFO order.

#### Expression Statements

- A block may contain expression statements. Any expression is allowed as a statement; its value is ignored.
- The final expression before '}' is a trailing expression and yields the block value.


### 2.6 Arrays, Slices, Lists, Strings

- **Array:** `[T; N]` fixed-size value type with compile-time known size `N`.
  - Syntax: `let arr: [i32; 5] = [1, 2, 3, 4, 5]`
  - Repeat syntax: `let zeros: [i32; 10] = [0; 10]`
- **Slice (`T[]`):** fat pointer view represented as `struct Slice[T] { ptr: &T, len: usize }`; indexable and iterable.
  - Arrays automatically coerce to slices when needed.
  - Binary layout: pointer followed by length (platform-specific size).
- **List:** dynamic container from the standard library; binary-compatible with `T[]` for copy-free conversions.
- **String:** UTF-8 view represented as `struct String { ptr: &u8, len: usize }`.
  - Same binary layout as `u8[]` (struct `{ ptr: &u8, len: usize }`).
  - All `String` values are null-terminated for C FFI; the null byte is not counted in `len`. The standard library upholds this contract for non-literals (Strings are immutable; file-scope mutability applies).
  - String literals are static and compiler-guaranteed valid UTF-8 and null-terminated.
- The language guarantees syntax and layout compatibility for slices, lists, and strings.

### 2.7 Modules and Imports

- Each source file is a module.
- `pub` exposes declarations; `fn` without `pub` is module-private (not visible to importers).
- Function modifiers are flags: `pub` (visibility) and directives like `#foreign` (FFI). Future directives like `#inline` may apply.
- `import path` and `pub import path`.
- Cyclic imports are compile-time errors.
- Module names map to file paths.

#### Directives

- `#foreign`: declares a foreign function imported from the target’s C/ABI environment. Bodies are not provided; the backend does not mangle these names and relies on target headers for prototypes.
- `#intrinsic` (planned): declares a standard-library intrinsic symbol that the compiler may lower specially or map to target builtins. Intrinsics must live in `stdlib/core` and be declared with `#intrinsic` to be used. Like `#foreign`, intrinsic calls are never mangled; the backend provides target-specific support as needed.


---

## 3. Type System

### 3.1 Generics and Inference

- `$T` introduces a generic parameter and serves as the diagnostic binding site.
- Inference is multi-phase (constraint collection and resolution) and follows a Hindley–Milner discipline: constraints flow bidirectionally so return-position expectations, parameter annotations, and assignment targets all participate in solving.
- Untyped literals (`comptime_int`, `comptime_float`) are placeholders that must unify with a concrete type before type checking completes; otherwise the compiler emits `E2001` instead of lowering invalid FIR.
- Return positions may bind generics (e.g., `fn new_list(n: usize) List[$T]`).

### 3.2 Structural Typing

- Compatibility is structural; nominal identity is not required.
- Anonymous structs participate in structural matching.

### 3.3 Complete Inference

- The compiler infers over concrete, anonymous, and generic types.
- Untyped literals (`comptime_int`, `comptime_float`) unify to concrete types.

### 3.4 Option and Nullability

- `T?` is `Option[T]`.
- `null` denotes `None`.
- `&T?` models nullable references.

### 3.5 Strings

- Type: `String` represented as `struct String { ptr: &u8, len: usize }`.
- Representation: fat pointer `(ptr, len)` with the same binary layout as `u8[]`.
- All `String` values are null-terminated for FFI; the terminator is not counted in `len`.
- String literals are static and compiler-guaranteed valid UTF-8 and null-terminated.
- Mutable variants (e.g., `MutableString`) are binary-compatible with readonly counterparts.

### 3.6 Never Type

- `never` denotes computations that do not return; unifies with all types.

### 3.7 Introspection (Legacy)

```
#foreign fn as_bytes(p: &$T) &u8
#foreign fn as_ref(p: &u8) &$T
#foreign fn ref_at(base: &$T, index: usize) &$T
#foreign fn as_slice(ptr: &$T, len: usize) $T[]
#foreign fn offset_of($T, field: String) usize
```

- All are compile-time evaluable and usable in constant expressions.
- `offset_of` returns the actual compiled byte offset.

### 3.8 Type Literals and Runtime Type Information

FLang provides runtime type information through the built-in `Type` generic struct:

```flang
struct Type(T) {
    name: String  // Type name
    size: u8      // Size in bytes
    align: u8     // Alignment requirement
}
```

#### Type as a Generic Struct

`Type(T)` is a built-in generic struct that carries runtime metadata about type `T`. When you use a type name like `i32` or `Point` as a value, it becomes an instance of `Type` containing that type's metadata.

```flang
// Type literals - type names used as values
let t: Type(i32) = i32  // i32 is a value of type Type(i32)

// Access type metadata
let size: u8 = t.size      // 4
let alignment: u8 = t.align  // 4
let name: String = t.name   // "i32"
```

#### Type Introspection Functions

Type introspection functions are regular FLang library functions defined in `core.rtti`:

```flang
import core.rtti

// Defined in stdlib - these are regular FLang functions, not compiler intrinsics
pub fn size_of(t: Type($T)) usize {
    return t.size as usize
}

pub fn align_of(t: Type($T)) usize {
    return t.align as usize
}

// Usage
pub fn main() i32 {
    let s = size_of(i32)  // Returns 4
    let a = align_of(Point)  // Returns alignment of Point struct
    return s as i32
}
```

#### User-Defined Functions with Type Parameters

You can write your own functions that accept `Type($T)` parameters:

```flang
pub fn allocate_array(t: Type($T), count: usize) &u8? {
    let size_per_element = t.size as usize
    let total_size = size_per_element * count
    return malloc(total_size)
}

// Usage
let arr = allocate_array(i32, 10)  // Allocate array of 10 i32s
```

#### Global Type Metadata

The compiler automatically generates a global type metadata table (`__flang__type_table`) containing all instantiated types used in the program. Type literals are resolved to references into this table at compile-time.

#### Available Type Operations

- `size_of(Type($T)) -> usize`: Returns the size in bytes
- `align_of(Type($T)) -> usize`: Returns the alignment requirement
- Field access: `t.name`, `t.size`, `t.align` to access metadata directly

---

## 4. Operators

### 4.1 Null-Coalescing

```
a ?? b
```

- If `a` is `Option[U]` or `U?` and is present, yields unwrapped `U`; otherwise yields `b`.
- Result type is the least upper bound of `U` and the type of `b` (via anonymous union if necessary).

### 4.2 Null-Propagation

```
expr?
```

- If `expr` has type `U?`/`Option[U]` and is `null`, returns `null` from the enclosing function when that function’s return type is `V?`/`Option[V]`.
- Otherwise yields unwrapped `U`.
- May only appear in a function whose return type is optional/`Option`.

### 4.3 Operator-as-Function

- Every operator has a corresponding function name.
- The compiler rewrites operators to calls to these functions and may inline them.
- Overload resolution follows standard rules (strictest applicable or error).
- The standard library supplies operator functions for language primitives (`u8`, `i32`, `usize`, slices).
- User-defined types (including `List` and `String`) must provide their own operator functions.

**Examples (illustrative names):**

```
pub fn op_add(lhs: &A, rhs: B) C
pub fn op_sub(lhs: &A, rhs: B) C
pub fn op_eq(lhs: &A, rhs: B) bool
pub fn op_index(base: &A, index: I) R
pub fn op_index_set(base: &A, index: I, value: V) void
pub fn op_assign(lhs: &A, rhs: B) void
pub fn op_add_assign(lhs: &A, rhs: B) void
```

- The exact set of operator function names corresponds one-to-one with the language’s operators, including indexing and assignment forms.

---

## 5. Memory Model

- The language specifies no intrinsic allocator and no heap management guarantees.

### 2.8 Casting

- Syntax: `expr as Type`
- Semantics:
  - Numeric casts: any integer ↔ integer. Narrowing truncates; widening sign-extends where applicable.
  - Pointer/integer: `&T` ↔ `usize|isize`.
  - Pointer/pointer: `&T` ↔ `&U` allowed as a view cast. Binary compatibility is currently the programmer’s responsibility.
  - Blessed binary compatibility: `String` ↔ `u8[]` is a zero‑copy view.
- Implicit casts:
  - When a `u8[]` is expected, a `String` value is implicitly accepted (safe re‑interpretation; zero‑copy).
- Explicit casts:
  - Converting from `u8[]` to `String` requires an explicit `as String`. The compiler does not infer this conversion.


- Allocation and deallocation are provided by the standard library and may wrap C runtime facilities.
- The compiler guarantees deterministic type layouts per target/configuration and binary compatibility as stated.
- Struct layout is optimized; introspection provides actual offsets.
- We can take an address of a non temporary variable with `&var`, and we can dereference it with `ptr.*`.

---

## 6. Iterator Protocol

A type is iterable if functions exist (or are derivable) matching:

```
fn iterator(&T) Iterator[E]
fn next(&Iterator[E]) E?
```

`for (x in collection)` expands to this protocol until `null` is returned.
Built-in iterators exist for ranges (`a..b`, `a..`, `..b`), arrays, and slices.
The language uses standard library definitions for ranges, strings, and lists.

---

## 7. Compilation Model

- Multi-phase inference and semantic validation.
- AST is data-only; logic resides in analysis passes.
- FIR uses SSA form with versioned local variables. `if` and `for` lower to blocks and branches. Each assignment creates a new SSA version of the variable.
- The reference compiler emits portable C as a bootstrap target.

### 7.1 IR Instructions

The FLang intermediate representation (FIR) uses a linear SSA instruction set. Instructions are organized into basic blocks, with control flow managed by terminator instructions. Each value assignment creates a new SSA version.

#### Values

All instructions operate on values. There are three types of values in FIR:

- **`ConstantValue`**: Compile-time integer constants. Used for literal values, array sizes, offsets, etc.
- **`StringConstantValue`**: Compile-time string constants. String literals from source code. Emitted as static global variables by the backend.
- **`LocalValue`**: Local SSA values (variables or temporaries). Results of instructions or function parameters. Each has a unique name within its function scope (e.g., `t0`, `x`, `call_42`).

Each value has a name (for debugging/printing) and an optional type. Types may be null during early IR construction before type inference completes.

#### Memory Operations

- **`alloca`**: Allocates stack space for a value of the given type. Returns a pointer to the allocated space. Similar to LLVM's alloca.
- **`store`**: Creates a new SSA version of a local variable. Each store produces a unique versioned result value. For pointer stores, use `store_ptr`.
- **`load`**: Loads (dereferences) a value from a pointer: `ptr.*`
- **`store_ptr`**: Stores a value through a pointer: `ptr.* = value`
- **`addressof`**: Takes the address of a variable: `&var`
- **`getelementptr`**: Calculates the address of a struct field or array element. Takes a base pointer and a byte offset (constant or dynamic), returns pointer to the field/element.

#### Arithmetic and Comparison

- **`binary`**: Binary operations on two values. Supports:
  - Arithmetic: `add`, `subtract`, `multiply`, `divide`, `modulo`
  - Comparisons: `equal`, `not_equal`, `less_than`, `greater_than`, `less_than_or_equal`, `greater_than_or_equal`

#### Type Conversion

- **`cast`**: Converts a value from one type to another. Supports:
  - Integer casts (sign extension, truncation, zero extension)
  - Pointer casts
  - String to slice conversions
  - Slice to pointer conversions

#### Control Flow (Terminators)

These instructions must be the last instruction in a basic block:

- **`return`**: Returns from the current function with a value
- **`jump`**: Unconditional jump to a target basic block
- **`branch`**: Conditional branch to one of two basic blocks based on a condition

#### Function Calls

- **`call`**: Calls a function with arguments. Supports both FLang functions (with name mangling) and foreign/C functions (without mangling).

---

## 8. Defined Behaviors

- Out-of-bounds access: defined panic.
- Integer overflow: panic in debug; wraparound in release.
- Uninitialized memory: compile-time error.
- Null dereference: defined panic.
- Struct layout and alignment are guaranteed and discoverable via introspection.

---

## 9. Testing

- `test "name" { ... }` defines an isolated test block.
- The CLI test harness validates exit code, stdout, and stderr.

---

## 10. Standard Library Overview

```
core/              runtime bindings and platform integration
std/               standard modules
std/collections/   containers (List, Dict)
std/text/          string and text utilities
std/io/            input/output and filesystem
```

- The language relies on standard modules for ranges, strings, lists, and operator implementations for primitives and slices.

---

## 11. Conventions

- Source files use the `.f` extension.
- Entry points (optional):

```
pub fn main() i32
pub fn main(args: String[])
pub fn main(args: String[], env: String[])
```

- Exit code `0` indicates success.
- UTF-8 source encoding.
