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

**Top-Level Constants:**

Constants can be declared at module (file) level outside of functions:

```flang
const BUFFER_SIZE: i32 = 1024
const DEFAULT_NAME = "unnamed"

struct AllocatorVTable {
    alloc: fn(&usize) &u8?
    free: fn(&u8?) void
}

const default_allocator = AllocatorVTable {
    alloc = system_alloc,
    free = system_free
}

pub fn main() i32 {
    return BUFFER_SIZE
}
```

- Top-level constants must have an initializer.
- Initializers must be compile-time constant expressions (literals, struct constructions with constant fields, function references).
- Top-level constants are visible to all functions in the module.

### 2.2 References and Auto-Dereference

- `&T` is a non-null reference to `T`.
- `&T?` is an optional reference.
- A C pointer corresponds to `&T?`. `void*` has no exact equivalent; `&u8?` is the closest.
- Reference writes follow file-scope mutability rules.

**Auto-Dereference for Member Access:**

FLang automatically dereferences references when accessing struct fields, providing ergonomic pointer handling similar to C's `->` operator:

```flang
struct Point { x: i32, y: i32 }

fn sum(p: &Point) i32 {
    // Auto-deref: p.x accesses field through pointer directly
    // Equivalent to C's ptr->x or (*ptr).x
    return p.x + p.y
}

fn explicit_deref(p: &Point) i32 {
    // Explicit deref with .* copies the pointed-to value first
    return p.*.x + p.*.y
}
```

- `ref.field` on `&Struct` auto-dereferences to access the field directly (no copy).
- `ref.*` explicitly dereferences, producing a copy of the pointed-to value.
- Auto-deref works recursively: `pp.field` on `&&Struct` dereferences twice.
- Auto-deref applies to both reads and writes: `p.x = 10` modifies through the pointer.

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

### 2.3.1 Tuples

Tuples are syntactic sugar for anonymous structs with positional fields (`_0`, `_1`, `_2`, ...).

**Tuple Syntax Desugaring:**

| Operation | User Writes | Desugared Form          |
| --------- | ----------- | ----------------------- |
| Type      | `(A, B)`    | `{ _0: A, _1: B }`      |
| Value     | `(10, 20)`  | `.{ _0 = 10, _1 = 20 }` |
| Access    | `t.0`       | `t._0`                  |

**Examples:**

```flang
// Basic tuple creation and access
let t = (10, 20)
let sum = t.0 + t.1    // 30

// Tuple type annotation
let p: (i32, i32) = (5, 10)

// Tuples in function signatures
fn make_pair(a: i32, b: i32) (i32, i32) {
    return (a, b)
}

fn sum_pair(p: (i32, i32)) i32 {
    return p.0 + p.1
}
```

**Special Cases:**

- `(x)` is a grouped expression (just `x`), not a tuple.
- `(x,)` with a trailing comma is a single-element tuple.
- `()` is the empty tuple (unit type).

**Structural Typing Compatibility:**

Because tuples desugar to anonymous structs, any function expecting `{ _0: i32, _1: i32 }` will automatically accept a tuple `(i32, i32)`.

### 2.4 Enums (Tagged Unions)

Enums represent tagged unions - a type that can be one of several named variants, each optionally carrying payload data.

```
enum Name {
    Variant1
    Variant2(Type1)
    Variant3(Type1, Type2)
}

// Naked enum (C-style, explicit integer tags, no payloads)
enum Ord {
    Less = -1
    Equal = 0
    Greater = 1
}
```

**Declaration:**

- `enum Name { Variant, ... }` declares an enum with unit (no payload) and payload variants.
- Generic enums: `enum Result(T, E) { Ok(T), Err(E) }`
- Variants may have zero or more payload types.
- Tag values are assigned sequentially (0, 1, 2, ...) by default.
- **Naked enums** (C-style): Variants may have explicit integer tag values using `= <integer>` syntax. If any variant has an explicit tag, the enum is a naked enum and no variant may carry payload data. Implicit tag values auto-increment from the previous variant's value (first defaults to 0). Duplicate tag values are a compile error.

**Memory Layout:**

- Layout is opaque and determined by the compiler's `EnumType` class.
- Initial implementation uses a discriminant tag (4-byte i32) followed by a union of variant payloads.
- Future optimizations may use niche optimization (see below).
- Always query `EnumType` layout methods; never hardcode assumptions.

**Niche Optimization (Future Work):**

Enums may use niche optimization to eliminate the discriminant tag by exploiting unused bit patterns:

- `Option(&T)`: Uses null pointer (0x0) for `None`, actual pointer value for `Some(&T)`
  - Size: Same as `&T` (one pointer), not tag + pointer
- `Option(bool)`: Uses 0/1 for `Some(false)`/`Some(true)`, 2 for `None`
- `Option(NonZeroU32)`: Uses 0 for `None`, non-zero values for `Some(n)`

The compiler recognizes special types (references, `NonZero` wrappers) and automatically applies niche optimization where possible.

**Variant Construction:**

Variants are constructed using dot notation, consistent with module/struct qualified names:

```
let cmd1 = Command.Quit           // Fully qualified
let cmd2 = Command.Move(10, 20)   // With payload
let cmd3 = Move(10, 20)           // Short form (when unambiguous)
```

- Fully qualified: `EnumName.Variant` or `EnumName.Variant(args)`
- Short form: `Variant` or `Variant(args)` when type inference can determine the enum type
- Short form is allowed when there's no ambiguity (only one enum in scope with that variant name, or expected type is known)

### 2.5 Functions

```
fn name(parameters) ReturnType
```

- Functions may be generic.
- `$T` declares and binds a generic parameter at any position (parameter or return).
- Overloading is supported by name and compatible parameter types.
- The type system selects the strictest applicable overload; if multiple remain, it is an error.
- UFCS applies: `object.method(a, b)` desugars to `method(object, a, b)` or `method(&object, a, b)` depending on the first parameter type of the resolved function. If the function expects a reference (`&T`), the receiver is lifted to a reference; if it expects a value (`T`), the receiver is passed as-is. If the receiver is already a reference and the function expects a value, the reference is accepted (implicit dereference).
- C backend name mangling: all non-foreign functions are emitted with a mangled name derived from the base name and the parameter types (e.g., `name__i32__u64`). This guarantees unique C symbols for overloads. The `main` entrypoint is not mangled. Generic specializations are emitted using the same scheme. Name mangling occurs only during code generation; earlier phases (TypeSolver, FIR) preserve base names and attach type metadata.
- **Function types**: Functions are first-class values. The syntax `fn(T1, T2) R` denotes a function type taking parameters of types `T1` and `T2` and returning `R`. Optional parameter names are allowed for documentation: `fn(x: T1, y: T2) R` is equivalent to `fn(T1, T2) R`; the names are ignored semantically.

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

##### Lowering of For-in Loops (Iterator Protocol)

The `for-in` loop in FLang is desugared by the compiler into a sequence of calls to the iterator protocol functions. This involves obtaining an iterator, repeatedly calling `next` on it, and handling the `null` return value to signal the end of the iteration.

For a `for` loop of the form:

```flang
for (<elem> in <collection>) {
    // <body>
}
```

The compiler transforms this into equivalent pseudocode that follows the iterator protocol:

```
// 1. Obtain an iterator for the collection
let it = iter(<collection>);

// 2. Start an infinite loop
loop {
    // 3. Get the next element from the iterator
    let n = next(it);

    // 4. Check if there are no more elements
    if (n.has_value == false) {
        break; // Exit the loop
    }

    // 5. Extract the value from the optional (remove optional wrapper)
    let <elem> = n.value;

    // 6. Execute the loop body
    // <body>
}
```

**Explanation of Lowering Steps:**

1.  **`iter(<collection>)`**: The compiler first generates a call to the `iter` function, passing the `<collection>` as an argument. This function is expected to return an instance of an iterator struct, which holds the necessary state for iteration and has the `next` function defined for it.
2.  **Loop Structure**: A conceptual `loop` (or `while(true)`) is created in the intermediate representation.
3.  **`next(it)`**: Inside the loop, a call to the `next` function is made, passing the iterator instance (`it`). The `next` function is expected to return `E?` (an `Option(E)`), which will not have a value (be `null`) when there are no more elements.
4.  **Termination Condition**: The result of `next(it)` (`n`) is checked. If `n` is `null`, it signifies the end of the collection, and a `break` instruction is generated to exit the loop, jumping to the block after the loop.
5.  **Element Extraction**: If `n` is not `null`, the actual element value is extracted from the `Option(E)` (e.g., `n.value`). This value is then bound to the `<elem>` variable declared in the `for` loop's pattern.
6.  **Loop Body Execution**: The original `<body>` of the `for` loop is then executed with `<elem>` available in scope.

This approach provides a flexible and extensible mechanism for iteration, allowing custom types to implement the `iter` and `next` functions to become iterable in FLang. `break` and `continue` statements within the `<body>` are lowered to jumps to the appropriate loop exit or continuation points, respectively.

#### Defer

```
defer expression
```

- Executes on scope exit in LIFO order.

#### Match Expression

Match expressions enable pattern matching on enum values:

```
expr match {
    pattern1 => result_expr1,
    pattern2 => result_expr2,
    else => default_expr
}
```

**Syntax:**

- `scrutinee match { arms }` where scrutinee is the value being matched
- Each arm: `pattern => expression,`
- Optional `else` clause as catch-all: `else => expression`

**Semantics:**

- Match is an expression - evaluates to a value (type unified across all arms)
- Scrutinee must have enum type or reference to enum (`EnumType` or `&EnumType`)
  - References may be automatically dereferenced during lowering, or inspected directly (for now, up to implementation)
  - Matching on other types is a compile error (may support more types in future)
- Arms are evaluated in order; first matching pattern wins
- Pattern variables are bound in the arm's expression scope only

**Patterns:**

1. **Wildcard pattern (`_`)**: Matches anything, discards the value

   ```
   Write(_) => "message"   // Matches Write variant, ignores payload
   ```

2. **Variable binding pattern**: Binds the matched value to a variable

   ```
   Some(x) => x + 1        // Binds payload to x
   Move(x, y) => x + y     // Binds both payload fields
   ```

3. **Enum variant pattern**: Matches a specific enum variant
   ```
   Quit => 0               // Unit variant (no payload)
   Some(value) => value    // Variant with payload
   Result.Ok(x) => x       // Fully qualified variant
   ```

- Nested patterns: `Option.Some(Result.Ok(x))` - destructure nested enums
- Multiple wildcards: `Move(_, y)` - ignore first field, bind second

**Exhaustiveness Checking:**

The compiler enforces exhaustive pattern matching:

- All enum variants must be covered, OR
- An `else` clause must be present

```
// ERROR: Non-exhaustive (missing None variant)
let x = opt match {
    Some(v) => v
}

// OK: All variants covered
let x = opt match {
    Some(v) => v,
    None => 0
}

// OK: else clause covers remaining cases
let x = cmd match {
    Quit => 0,
    else => 1
}
```

**Error Codes:**

- E2030: Match on non-enum type
- E2031: Non-exhaustive pattern match (missing variants)
- E2032: Pattern arity mismatch (wrong number of payload fields)

**Lowering:**

Match expressions are desugared to if-else chains checking the discriminant tag:

```
cmd match {
    Quit => expr1,
    Move(x, y) => expr2
}

// Lowered to:
if (cmd.tag == 0) {           // Quit
    expr1
} else if (cmd.tag == 1) {    // Move
    let x = cmd.payload.field0
    let y = cmd.payload.field1
    expr2
}
```

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
- Address-of: `&var` takes the address of a non-temporary variable.
- Explicit dereference: `ptr.*` dereferences a pointer, producing a copy of the value.
- Auto-dereference: `ptr.field` on `&Struct` automatically dereferences to access the field (see Section 2.2).

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

- If `a` is `Option(T)` or `T?` and has a value, yields unwrapped `T`; otherwise yields `b`.
- Desugars to `op_coalesce(a, b)` function call.
- Two overloads in `std.option`:
  - `op_coalesce(opt: &Option(T), fallback: T) -> T` - unwrap or use fallback value
  - `op_coalesce(first: &Option(T), second: &Option(T)) -> &Option(T)` - returns first if present, otherwise second
- Operator has lowest precedence (lower than `==`/`!=`), right-associative.
- Enables chaining: `a ?? b ?? c` evaluates as `a ?? (b ?? c)`.

### 4.2 Safe Member Access

```
opt?.field
```

- If `opt` has type `Option(T)` or `T?` and has a value, yields `Option(field_type)` containing `opt.value.field`.
- If `opt` is `null`, yields `null` (as `Option(field_type)`).
- Enables safe chaining: `a?.b?.c` propagates null through the chain.
- **Status**: Parsing and type checking implemented; IR lowering in progress.

### 4.3 Early-Return Operator (Planned)

```
expr?
```

- If `expr` has type `Option(U)` and is `null`, early-returns `null` from the enclosing function.
- If `expr` has type `Result(U, E)` and is `Err(e)`, early-returns `Err(e)` from the enclosing function.
- Otherwise yields unwrapped `U`.
- May only appear in a function whose return type is `Option` or `Result`.
- **Status**: Planned for future milestone.

### 4.4 Logical Operators

```
a and b
a or b
```

- `and`: returns `false` without evaluating `b` if `a` is `false` (short-circuit).
- `or`: returns `true` without evaluating `b` if `a` is `true` (short-circuit).
- Both operands must be `bool`. Non-bool operands are a compile error (`E2046`).
- These are built-in operators only — no user-defined overloading via operator functions.
- **Precedence** (highest to lowest):
  - `* / %` (8)
  - `+ -` (7)
  - `..` (6)
  - `< > <= >=` (5)
  - `== !=` (4)
  - `and` (3)
  - `or` (2)
  - `??` (1)

### 4.5 Operator-as-Function

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
pub fn op_coalesce(opt: Option(T), fallback: T) T
```

- The exact set of operator function names corresponds one-to-one with the language's operators, including indexing and assignment forms.

**Auto-derived operators:**

- `op_eq` / `op_ne`: If only one is defined, the compiler auto-derives the other by negating the result.
- `op_cmp`: If a type defines `fn op_cmp(a, b) Ord`, the compiler auto-derives all six comparison operators (`<`, `>`, `<=`, `>=`, `==`, `!=`) when they are not explicitly defined. The derivation uses `op_cmp(a, b) <op> 0` (e.g., `op_cmp(a, b) < 0` for `<`). This works because `Ord` is a naked enum with `Less = -1`, `Equal = 0`, `Greater = 1`. Explicitly defined operators (including auto-derived `op_eq`/`op_ne`) take priority over `op_cmp` derivation.

---

## 5. Memory Model

- The language specifies no intrinsic allocator and no heap management guarantees.

---

## 6. Value Semantics

### 6.1 Storage

Every named binding has a memory location. Values are sequences of bytes. No hidden reference counting or GC.

### 6.2 Assignment

```
let x = expr
```

Shallow byte-copy of `expr` into `x`'s storage. Both exist independently. Pointers inside are copied as-is (aliasing possible).

### 6.3 Function Arguments

```
fn foo(a: T, b: U) R
```

**Caller side:** Passes address of `a` and `b` (implicit reference).

**Callee side:**

- Read access: operates on original bytes via pointer (no copy)
- Write access: compiler inserts copy-on-first-write into local shadow, all subsequent accesses use the shadow

Caller's value is **never mutated** by callee.

### 6.4 Return

For return type `T` where `sizeof(T) > PLATFORM_REGISTER_SIZE`:

1. **Caller** allocates storage for the return value
2. **Caller** passes hidden pointer to this storage as implicit first argument
3. **Callee** writes directly into that pointer
4. **Callee** returns nothing (or just the pointer for chaining)

#### Transparent Syntax

```flang
// What you write
fn make_point(x: i32, y: i32) Point {
    return .{ x = x, y = y }
}

let p = make_point(3, 4)
```

```flang
// What compiler generates (conceptual)
fn make_point(__ret: &Point, x: i32, y: i32) {
    __ret.* = .{ x = x, y = y }
}

let p: Point = <uninitialized>
make_point(&p, 3, 4)
```

#### Rules

| Return type                           | Mechanism                     |
| ------------------------------------- | ----------------------------- |
| Primitives, small structs (≤ N bytes) | Returned in registers, copied |
| Larger structs                        | Caller-provided slot          |

### 6.5 Scope & Lifetime

Variables valid from declaration until enclosing block ends. No invalidation via "move" or "consume." Accessing a variable always succeeds if in scope (C-like semantics).

### 6.6 Scoped Mutability

For `struct Point { x: i32, y: i32 }` defined in file A:

- **File A:** Fields readable and writable
- **File B (imports A):** Fields readable, writes are compile errors

Functions in A can mutate via `self` (implicit reference that permits write-back):

```flang
fn translate(self: &Point, dx: i32, dy: i32) {
    self.x = self.x + dx  // mutates caller's actual storage
}
```

### 6.7 Summary Table

| Operation        | Semantics                                                      |
| ---------------- | -------------------------------------------------------------- |
| `let x = y`      | shallow copy (memcpy)                                          |
| `foo(x)`         | pass by implicit reference, copy-on-write inside               |
| `return x`       | shallow copy to caller                                         |
| `x.field` (read) | always allowed                                                 |
| `x.field = v`    | allowed only in defining scope                                 |
| `foo(&x)`        | explicit mutable reference, callee can mutate caller's storage |

### 6.8 Safety Model

The compiler enforces scoped mutability for invariant protection, nothing else. The following are the programmer's responsibility:

- Double-free
- Use-after-free
- Aliased mutation
- Data races

---

## 7. Iterator Protocol

A type is iterable if functions exist (or are derivable) matching:

```
fn iterator(&T) Iterator[E]
fn next(&Iterator[E]) E?
```

`for (x in collection)` expands to this protocol until `null` is returned.
Built-in iterators exist for ranges (`a..b`, `a..`, `..b`), arrays, and slices.
The language uses standard library definitions for ranges, strings, and lists.

---

## 8. Compilation Model

- Multi-phase inference and semantic validation.
- AST is data-only; logic resides in analysis passes.
- FIR uses SSA form with versioned local variables. `if` and `for` lower to blocks and branches. Each assignment creates a new SSA version of the variable.
- The reference compiler emits portable C as a bootstrap target.

### 8.1 IR Instructions

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

## 9. Defined Behaviors

- Out-of-bounds access: defined panic.
- Integer overflow: panic in debug; wraparound in release.
- Uninitialized memory: compile-time error.
- Null dereference: defined panic.
- Struct layout and alignment are guaranteed and discoverable via introspection.

---

## 10. Testing

### Test Blocks

Test blocks define unit tests inline in source files:

```flang
import std.test

test "addition works" {
    let a: i32 = 2
    let b: i32 = 3
    assert_eq(a + b, 5, "2 + 3 should equal 5")
}

test "boolean assertion" {
    assert_true(true, "true should be true")
}
```

- `test "name" { ... }` defines a test block scoped to the module
- Test blocks are not exported and only run in test mode
- Multiple test blocks can exist in a single file

### Assertion Functions

Import `std.test` to access assertion functions:

- `assert_true(condition: bool, msg: String)` - panics if condition is false
- `assert_eq(a: $T, b: T, msg: String)` - panics if `a != b`

### Running Tests

Use the `--test` CLI flag to run tests instead of `main()`:

```bash
flang --test myfile.f
./myfile
```

When `--test` is passed:

1. All `test` blocks are collected from compiled modules
2. A test runner replaces `main()` and executes each test
3. Exit code 0 indicates all tests passed
4. Exit code 1 indicates a test failed (via panic)

### Panic Function

The `panic(msg: String)` function in `core.panic` terminates the program:

```flang
import core.panic

pub fn main() i32 {
    panic("something went wrong")
    return 0  // unreachable
}
```

- Prints the message to stdout
- Exits with code 1

---

## 11. Standard Library Overview

```
core/              runtime bindings and platform integration
std/               standard modules
std/collections/   containers (List, Dict)
std/text/          string and text utilities
std/io/            input/output and filesystem
```

- The language relies on standard modules for ranges, strings, lists, and operator implementations for primitives and slices.

---

## 12. Conventions

- Source files use the `.f` extension.
- Entry points (optional):

```
pub fn main() i32
pub fn main(args: String[])
pub fn main(args: String[], env: String[])
```

- Exit code `0` indicates success.
- UTF-8 source encoding.

### Runtime Polymorphism Convention

For vtable-based polymorphism, use the following pattern:

1. Define the vtable as a struct with function pointer fields (first parameter is type-erased `&u8`):

```flang
pub struct WriterVTable {
    write: fn(impl: &u8, data: u8[]) usize,
    flush: fn(impl: &u8) bool
}
```

2. Define the interface as a struct with a type-erased pointer and vtable reference:

```flang
pub struct Writer {
    impl: &u8,
    vtable: &WriterVTable
}
```

3. Concrete types provide a conversion function named after the interface:

```flang
fn interface_name(instance: &ConcreteType) Interface
```

This enables UFCS-style calls that read naturally:

```flang
let alloc = state.allocator()    // FixedBufferAllocatorState -> Allocator
let writer = file.writer()       // File -> Writer
let reader = socket.reader()     // Socket -> Reader
```

The concrete state is owned by the caller; the interface is a borrowed view. The state must outlive the interface.
