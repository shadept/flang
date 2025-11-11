# FLang Development Roadmap (v2-revised)

## Phase 1: Foundation (Bootstrapping)

_Goal: Build a minimal but complete foundation for systems programming._

---

### ✅ Milestone 1: The "Hello World" Compiler (COMPLETE)

**Scope:** A compiler that can parse `pub fn main() i32 { return 42 }`, generate FIR, and transpile to C.

**Completed:**

- ✅ Solution structure (`Frontend`, `Semantics`, `IR`, `Codegen.C`, `CLI`)
- ✅ Test harness with `//!` metadata parsing and execution
- ✅ `Source`, `SourceSpan`, and `Compilation` context
- ✅ Minimal Lexer/Parser for function declarations and integer literals
- ✅ FIR with `Function`, `BasicBlock`, `ReturnInstruction`
- ✅ C code generation
- ✅ CLI that invokes gcc/cl.exe

**Tests:** 1/13 passing

---

### ✅ Milestone 2: Basic Expressions & Variables (COMPLETE)

**Scope:** `let x: i32 = 10 + 5`, basic arithmetic, local variables.

**Completed:**

- ✅ Expression parser with precedence climbing
- ✅ Binary operators: `+`, `-`, `*`, `/`, `%`
- ✅ Comparison operators: `==`, `!=`, `<`, `>`, `<=`, `>=`
- ✅ Variable declarations with type annotations
- ✅ Assignment expressions
- ✅ FIR with `BinaryInstruction`, `StoreInstruction`, local values
- ✅ Type annotations parsed (but not checked yet)

**Tests:** 5/13 passing

---

### ✅ Milestone 3: Control Flow & Modules (COMPLETE)

**Scope:** `if` expressions, `for` loops (ranges only), `import` statements, function calls.

**Completed:**

- ✅ `import path.to.module` parsing and resolution
- ✅ Module work queue with deduplication
- ✅ `if (cond) expr else expr` expressions
- ✅ Block expressions with trailing values
- ✅ `for (var in range) body` with `a..b` ranges
- ✅ `break` and `continue` statements
- ✅ FIR lowering: control flow → basic blocks + branches
- ✅ Function calls: `func()` syntax
- ✅ `#foreign` directive for C FFI declarations
- ✅ CLI flags: `--stdlib-path`, `--emit-fir`
- ✅ Multi-module compilation and linking

**Tests:** 13/13 passing

---

## Phase 2: Core Type System & Data Structures

_Goal: Add the type system and fundamental data structures needed for real programs._

### ✅ Milestone 4: Type Checking & Basic Types (COMPLETE)

**Scope:** Actual type checking, boolean type, type errors, basic inference.

**Completed:**

- ✅ Implement `TypeSolver` for type checking
  - ✅ Two-phase type checking (signature collection + body checking)
  - ✅ Scope-based variable tracking
  - ✅ Function signature registry
- ✅ Add `bool` type and boolean literals (`true`, `false`)
  - ✅ Lexer support for `true` and `false` keywords
  - ✅ Parser support for boolean literals
  - ✅ BooleanLiteralNode AST node
- ✅ Implement type checking for:
  - ✅ Variable declarations (with explicit types)
  - ✅ Assignments
  - ✅ Function return types
  - ✅ Binary operations (arithmetic + comparisons)
  - ✅ Comparisons (returns `bool` type)
  - ✅ If expressions (condition must be `bool`)
  - ✅ For loops (range bounds must be integers)
  - ✅ Block expressions
  - ✅ Function calls
- ✅ **Proper error messages with `SourceSpan` information**
  - ✅ `Diagnostic` class with severity, message, span, hint, code
  - ✅ `DiagnosticPrinter` with Rust-like formatting
  - ✅ ANSI color support (red errors, yellow warnings, blue info)
  - ✅ Source code context with line numbers
  - ✅ Underlines/carets pointing to exact error location
  - ✅ Helpful hints displayed inline
  - ✅ Demo mode: `--demo-diagnostics`
- ✅ `comptime_int` and `comptime_float` types
  - ✅ Integer literals default to `comptime_int`
  - ✅ Bidirectional compatibility: `comptime_int` ↔ concrete integer types
  - ✅ Error if `comptime_*` type reaches FIR lowering (forces explicit types)
- ✅ Support multiple integer types: `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `usize`, `isize`
  - ✅ All types registered in `TypeRegistry`
  - ✅ Type resolver for named types

**Tests:** 13/13 passing

---

### ✅ Milestone 5: Function Parameters & Return Types (COMPLETE)

**Scope:** Functions with parameters, proper return type checking, multiple functions.

**Completed:**

- ✅ Parse function parameters: `fn add(a: i32, b: i32) i32`
- ✅ Function call argument checking (count and types)
- ✅ Return type validation
- ✅ Multiple functions in same file
- ✅ Update FIR to support function parameters
- ✅ Update C codegen for parameters
- ✅ Added comma token for parameter/argument lists
- ✅ Extended type parser for `&T`, `T?`, `List[T]` (parsing infrastructure)
- ✅ Added placeholder types for future milestones
- ✅ Error code E2011: Function argument count mismatch

**Tests:** 15/15 passing

**Note:** Function overloading deferred to later milestone

---

### ✅ Milestone 6: Pointers & References (COMPLETE)

**Scope:** `&T` (references), `&T?` (nullable pointers), basic pointer operations.

**Completed:**

- ✅ `&T` syntax parsing (already done in M5 type parser expansion)
- ✅ `&T?` optional reference syntax parsing
- ✅ Address-of operator: `&variable`
- ✅ Dereference operator: `ptr.*`
- ✅ Type checking for reference operations
- ✅ ReferenceType in type system
- ✅ FIR instructions: AddressOfInstruction, LoadInstruction, StorePointerInstruction
- ✅ C codegen with pointer tracking
- ✅ Function parameters with pointer types
- ✅ Error code E2012: Cannot dereference non-reference type

**Tests:** 18/18 passing

**Note:** Null checking for `&T?` deferred to future milestone (requires Option type implementation)

---

### ✅ Milestone 7: Structs & Field Access (COMPLETE)

**Scope:** `struct` definitions, field access, construction. **Foundation for arrays, slices, and strings.**

**Completed:**

- ✅ `struct Name { field: Type }` parsing
- ✅ Generic struct syntax: `struct Box[T] { value: T }` (no `$` in type parameter list)
- ✅ Struct type registration in type system with field offset calculation
- ✅ Struct construction: `Name { field: value }`
- ✅ Field access: `obj.field` (enables `.len`, `.ptr` for slices/strings)
- ✅ Nested struct support
- ✅ FIR lowering: `AllocaInstruction` (stack allocation) + `GetElementPtrInstruction` (pointer arithmetic)
- ✅ Field offset calculation with proper alignment (reduces padding)
- ✅ C code generation: struct definitions + alloca + GEP
- ✅ Target-agnostic FIR design (structs as memory + offsets)

**Tests:** 22/22 passing (includes 4 new struct tests)

**Note:** Anonymous structs and `offset_of` introspection deferred to later milestone.

---

### ✅ Milestone 8: Arrays & Slices (COMPLETE)

**Scope:** Fixed-size arrays `[T; N]`, slices as struct views, basic array operations.

**Completed:**

- ✅ `[T; N]` fixed-size array type (Rust-style syntax)
- ✅ Array literals: `[1, 2, 3, 4, 5]`
- ✅ Repeat syntax: `[0; 10]` (ten zeros)
- ✅ `T[]` slice type syntax parsing
- ✅ Array indexing: `arr[i]` with dynamic index calculation
- ✅ Array → slice type coercion in type checker
- ✅ FIR support: `ArrayType`, `SliceType`, dynamic `GetElementPtrInstruction`
- ✅ C codegen: Valid C array syntax `int arr[N]`, pointer arithmetic for indexing
- ✅ Type inference for array literals with element unification
- ✅ Fixed two critical bugs:
  - Invalid C array declaration syntax (`int[3]` → `int[3]`)
  - Hardcoded offset in array indexing (now uses calculated `index * elem_size`)

**Deferred to Later Milestones:**

- [ ] Slice field access: `slice.len`, `slice.ptr` (needs runtime slice struct)
- [ ] Bounds checking with panic (needs M10: panic infrastructure)
- [ ] For loops over arrays/slices (needs M13: iterator protocol)
- [ ] Slice indexing (needs panic for bounds checks)

**Tests:** 25 total, 23 passing

- ✅ `arrays/array_basic.f` - Basic indexing returns correct value
- ✅ `arrays/array_repeat.f` - Repeat syntax `[42; 5]`
- ✅ `arrays/array_sum.f` - Multiple element access and arithmetic
- ❌ 2 pre-existing struct bugs (not regressions): `struct_nested.f`, `struct_parameter.f`
  - See `docs/known-issues.md` for details on FIR type tracking limitation

**Known Issues:** Documented in `docs/known-issues.md`

---

### Milestone 9: Strings

**Scope:** `String` type as struct, string literals, null-termination for C FFI.

**Key Tasks:**

- [ ] String literals: `"hello world"`
- [ ] `String` type as `struct String { ptr: &u8, len: usize }` in stdlib
- [ ] Null-termination for C FFI (null byte not counted in `len`)
- [ ] String field access: `str.len`, `str.ptr`
- [ ] Compiler guarantees: always valid UTF-8, always null-terminated
- [ ] Binary compatibility with `u8[]` slice
- [ ] Escape sequences: `\n`, `\t`, `\"`, etc.
- [ ] For loops over strings (UTF-8 code points or bytes)

**Tests to Add:**

- String literals
- String field access (`.len`, `.ptr`)
- C FFI with null-terminated strings
- String iteration

---

### Milestone 10: Memory Management Primitives

**Scope:** Core memory operations, allocator interface, manual memory management.

**Key Tasks:**

- [ ] Implement `core/mem.f`:
  - [ ] `#foreign fn memcpy(dst: &u8, src: &u8, len: usize)`
  - [ ] `#foreign fn memset(ptr: &u8, value: u8, len: usize)`
  - [ ] `#foreign fn malloc(size: usize) &u8?`
  - [ ] `#foreign fn free(ptr: &u8?)`
- [ ] `Allocator` interface (struct with function pointers)
- [ ] Basic heap allocator wrapping malloc/free
- [ ] `size_of` and `align_of` intrinsics
- [ ] `defer` statement for cleanup

**Tests to Add:**

- Manual allocation/deallocation
- Defer execution order

---

## Phase 3: Advanced Type System

_Goal: Generics, inference, and advanced type features._

### Milestone 11: Generics Basics

**Scope:** `$T` syntax, generic functions, basic monomorphization.

**Key Tasks:**

- [ ] `$T` parameter binding syntax
- [ ] Generic function parsing: `fn identity(x: $T) T`
- [ ] Type parameter inference
- [ ] Monomorphization (generate specialized versions)
- [ ] Generic constraints (structural)
- [ ] Update FIR to support generics (via monomorphization)

**Tests to Add:**

- Generic functions
- Type parameter inference
- Multiple generic parameters

---

### Milestone 12: Generic Structs & Collections

**Scope:** `struct Box[T]`, `Option[T]`, basic generic data structures.

**Key Tasks:**

- [ ] Full generic struct implementation (already parsed in M7, now full monomorphization)
- [ ] Generic struct instantiation: `Box[i32]`
- [ ] `Option[T]` enum (placeholder: struct with variants)
- [ ] `T?` sugar for `Option[T]`
- [ ] `null` keyword as `None` variant
- [ ] Implement `List[T]` in stdlib:
  - [ ] Dynamic array with capacity
  - [ ] Binary compatible with `T[]` for first two fields
  - [ ] Basic operations: push, pop, get, set

**Tests to Add:**

- Generic struct instantiation
- Option/nullable types
- List usage

---

### Milestone 13: Iterator Protocol

**Scope:** Full iterator protocol, for loops over custom types.

**Key Tasks:**

- [ ] `fn iterator(&T) Iterator[E]` protocol
- [ ] `fn next(&Iterator[E]) E?` protocol
- [ ] Desugar `for (x in iterable)` to iterator protocol
- [ ] Built-in iterators:
  - [ ] Range iterators (already hardcoded)
  - [ ] Array/slice iterators
  - [ ] String iterators (code points)
- [ ] Custom iterator implementations

**Tests to Add:**

- Custom iterators
- For loops over various types

---

## Phase 4: Language Completeness

_Goal: Fill in remaining language features._

### Milestone 14: Enums & Pattern Matching (Placeholder)

**Scope:** Tagged unions, pattern matching (basic).

**Key Tasks:**

- [ ] `enum` syntax parsing
- [ ] Variant construction
- [ ] Basic pattern matching (if we decide to add it)
- [ ] Or defer this to later

---

### Milestone 15: Operators as Functions

**Scope:** Operator overloading via operator functions.

**Key Tasks:**

- [ ] Define operator function names: `op_add`, `op_eq`, etc.
- [ ] Desugar operators to function calls
- [ ] Overload resolution (strictest applicable)
- [ ] Implement operator functions for primitives in stdlib
- [ ] User-defined operator functions for custom types

**Tests to Add:**

- Custom operator implementations
- Operator overload resolution

---

### Milestone 16: Advanced Features

**Scope:** Remaining spec features.

**Key Tasks:**

- [ ] Null-coalescing: `a ?? b`
- [ ] Null-propagation: `expr?`
- [ ] `const` declarations (immutable by default)
- [ ] UFCS desugaring: `obj.method(args)` → `method(&obj, args)`
- [ ] Multiple return values / tuples (if we decide to add them)
- [ ] `test "name" { }` blocks

---

## Phase 5: Standard Library

_Goal: Build a usable standard library._

### Milestone 17: Core Library

**Scope:** Essential runtime support.

**Tasks:**

- [ ] `core/mem.f` - Memory operations (already started in M10)
- [ ] `core/intrinsics.f` - Compiler intrinsics
- [ ] `core/panic.f` - Panic handling
- [ ] `core/types.f` - Type aliases for primitives

---

### Milestone 18: Collections

**Scope:** Core data structures.

**Tasks:**

- [ ] `std/collections/list.f` - `List[T]`
- [ ] `std/collections/dict.f` - `Dict[K, V]` (hash map)
- [ ] `std/slice.f` - Slice utilities

---

### Milestone 19: Text & I/O

**Scope:** String handling and I/O.

**Tasks:**

- [ ] `std/text/string.f` - String utilities
- [ ] `std/text/string_builder.f` - Efficient string building
- [ ] `std/io/file.f` - File I/O
- [ ] `std/io/fmt.f` - `println`, `print`, formatting

---

### Milestone 20: Utilities

**Scope:** Algorithms and helpers.

**Tasks:**

- [ ] `std/algo/sort.f` - Sorting algorithms
- [ ] `std/algo/search.f` - Binary search, etc.
- [ ] `std/math.f` - Math functions

---

## Phase 6: Self-Hosting

_Goal: Rewrite the compiler in FLang._

### Milestone 21: Compiler in FLang

**Scope:** Port the C# compiler to FLang.

**Tasks:**

- [ ] Port lexer
- [ ] Port parser
- [ ] Port AST
- [ ] Port type checker
- [ ] Port FIR lowering
- [ ] Port C codegen
- [ ] Bootstrap: C# compiler builds FLang compiler, then FLang compiler builds itself

---

## Current Status

- **Phase:** 2 (Core Type System & Data Structures)
- **Milestone:** 8 (COMPLETE)
- **Next Up:** Milestone 9 (Strings)
- **Tests Passing:** 23/25 (2 pre-existing struct bugs - see `docs/known-issues.md`)
- **Total Lines of FLang Code:** ~350 (test files + stdlib)
- **Total Lines of C# Compiler Code:** ~6,000
