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
- ✅ Extended type parser for `&T`, `T?`, `List(T)` (parsing infrastructure)
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
- ✅ Generic struct syntax: `struct Box(T) { value: T }` (no `$` in type parameter list)
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

### ✅ Milestone 9: Strings (COMPLETE)

**Scope:** `String` type as struct, string literals, null-termination for C FFI.

**Completed:**

- ✅ String literals: `"hello world"`
- ✅ `String` type as `struct String { ptr: &u8, len: usize }` in stdlib
- ✅ Null-termination for C FFI (null byte not counted in `len`)
- ✅ String field access: `str.len`, `str.ptr`
- ✅ Compiler guarantees: always null-terminated
- ✅ Binary compatibility with `u8[]` slice
- ✅ Escape sequences: `\n`, `\t`, `\r`, `\\`, `\"`, `\0`
- ✅ `StringConstantValue` in FIR for global string data
- ✅ C codegen generates `struct String` with null-terminated data arrays

**Tests:** 3 new tests passing (string_basic.f, string_escape.f, string_length.f)

**Deferred to Later Milestones:**

- [ ] For loops over strings (UTF-8 code points or bytes) - needs M13: Iterator Protocol
- [ ] UTF-8 validation - assumed valid for now (compiler-generated literals are valid)

---

### ✅ Milestone 10: Memory Management Primitives (COMPLETE)

**Scope:** Core memory operations, allocator interface, manual memory management.

**Completed:**

- ✅ **Compiler intrinsics** (`size_of`, `align_of`):
  - ✅ Compile-time evaluation (constants, no runtime overhead)
  - ✅ Support for primitive types and struct types
  - ✅ Type checking integration
  - ✅ FIR lowering replaces calls with constant values
- ✅ **Lexer enhancement**: Underscore support in identifiers (e.g., `size_of`, `align_of`)
- ✅ Created `stdlib/core/mem.f`:
  - ✅ `#foreign fn malloc(size: usize) &u8?`
  - ✅ `#foreign fn free(ptr: &u8?)`
  - ✅ `#foreign fn memcpy(dst: &u8, src: &u8, len: usize)`
  - ✅ `#foreign fn memset(ptr: &u8, value: u8, len: usize)`
  - ✅ `#foreign fn memmove(dst: &u8, src: &u8, len: usize)`
- ✅ `defer` statement for cleanup:
  - ✅ Parse `defer` keyword and statement syntax
  - ✅ FIR lowering: execute deferred statements in LIFO order at scope exit
  - ✅ C code generation: deferred expressions lowered before returns/scope exits
- ✅ Foreign function call plumbing:
  - ✅ Parse `#foreign fn` and mark functions as foreign
  - ✅ Collect signatures in type solver (parameters + return type)
  - ✅ C codegen emits proper `extern` prototypes with correct return type
- ✅ **Cast operator (`as`)**:
  - ✅ Parse `expr as Type` syntax
  - ✅ Type checking for cast operations
  - ✅ Numeric casts (implicit and explicit): `u8 -> usize`, `i32 -> i64`, etc.
  - ✅ Pointer ↔ usize roundtrip casts: `&T as usize`, `usize as &T`
  - ✅ String ↔ slice conversions (explicit and implicit)
  - ✅ FIR lowering with `CastInstruction`
  - ✅ C codegen with proper C cast syntax
- ✅ **Zero-initialization**: Uninitialized variables automatically zeroed

**Deferred to Future Milestones:**

- [ ] `Allocator` interface (struct with function pointers)
- [ ] Basic heap allocator wrapping malloc/free

**Tests Added/Status:**

- ✅ 3 intrinsic tests passing:
  - `intrinsics/sizeof_basic.f` - Returns 4 for `i32`
  - `intrinsics/sizeof_struct.f` - Returns 12 for 3-field struct
  - `intrinsics/alignof_basic.f` - Returns 4 for `i32`
- ✅ 3 defer tests passing:
  - `defer/defer_basic.f` - Single defer in block scope
  - `defer/defer_multiple.f` - Multiple defers in LIFO order
  - `defer/defer_scope.f` - Defer in nested blocks
- ✅ 4 memory tests passing:
  - `memory/malloc_free.f` - Allocate, write, read, free
  - `memory/memcpy_basic.f` - Copy between buffers
  - `memory/memset_basic.f` - Fill memory with byte value
  - `memory/zero_init.f` - Zero-initialization verification
- ✅ 5 cast tests passing:
  - `casts/numeric_implicit.f` - Implicit integer widening (u8 → usize)
  - `casts/ptr_usize_roundtrip.f` - Pointer ↔ usize conversions
  - `casts/slice_to_string_explicit.f` - u8[] → String (explicit)
  - `casts/string_to_slice_implicit.f` - String → u8[] (implicit)
  - `casts/string_to_slice_view.f` - String field access as slice view

**Error Codes Added:**

- E2014: Intrinsic requires exactly one type argument
- E2015: Intrinsic argument must be type name
- E2016: Unknown type in intrinsic

**Note:** Use `Type($T)` when passing generic type parameters to intrinsics.

---

## Phase 3: Advanced Type System

_Goal: Generics, inference, and advanced type features._

### ✅ Milestone 11: Generics Basics (COMPLETE)

**Scope:** `$T` syntax, generic functions, basic monomorphization.

**Completed:**

- ✅ `$T` parameter binding syntax in lexer/parser and AST (`GenericParameterTypeNode`)
- ✅ Generic function parsing: `fn identity(x: $T) T`
- ✅ Argument-based type parameter inference (return-type inference deferred, now delivered)
- ✅ Monomorphization of generic functions with centralized name mangling
- ✅ FIR/codegen support via monomorphized specializations
- ✅ Test harness support for expected compile errors: `//! COMPILE-ERROR: E2101`
- ✅ Return-type–driven inference (incl. resolving `comptime_*` from expected type)

**Tests Added:**

- ✅ `generics/identity_basic.f` - Basic identity function with inference
- ✅ `generics/two_params_pick_first.f` - Multiple generic parameters
- ✅ `generics/generic_mangling_order.f` - Verify name mangling consistency
- ✅ `generics/cannot_infer_from_context.f` - Error E2101 validation
- ✅ `generics/conflicting_bindings_error.f` - Error E2102 validation

**Deferred to Milestone 12:**

- Generic constraints (structural)
- Generic struct monomorphization and collections

---

### Milestone 12: Generic Structs & Collections (IN PROGRESS)

**Scope:** `Option(T)`, `List(T)`, basic generic data structures.

**Completed:**

- ✅ Full generic struct monomorphization
  - ✅ Type parameter substitution for struct types
  - ✅ Field type resolution with generic parameters
  - ✅ Monomorphized struct instantiation and construction
- ✅ `Option(T)` type implementation:
  - ✅ Core definition: `struct Option(T) { has_value: bool, value: T }` in `stdlib/core/option.f`
  - ✅ `T?` sugar syntax for `Option(T)`
  - ✅ `null` keyword support (desugars to `Option(T)` with `has_value = false`)
  - ✅ Implicit value coercion: `let x: i32? = 5` → `Option(i32) { has_value = true, value = 5 }`
- ✅ `stdlib/std/option.f` helper functions:
  - ✅ `is_some(value: Option($T)) bool`
  - ✅ `is_none(value: Option($T)) bool`
  - ✅ `unwrap_or(value: Option($T), fallback: T) T`
- ✅ `List(T)` struct definition in `stdlib/std/list.f`:
  - ✅ Struct layout: `{ ptr: &T, len: usize, cap: usize }`
  - ✅ Binary compatible with `T[]` for first two fields

**Pending:**

- [ ] `List(T)` operations (currently stubs calling `__flang_unimplemented()`):
  - [ ] `list_new()` - Allocate empty list
  - [ ] `list_push()` - Append element with reallocation
  - [ ] `list_pop()` - Remove and return last element
  - [ ] `list_get()` - Index access
  - **Blocked on:** Allocator interface from M10

**Tests Added:**

- ✅ `generics/generic_struct_basic.f` - Generic struct `Pair(T)` with construction and field access
- ✅ `option/option_basic.f` - Option type with null, implicit coercion, unwrap_or
- 🔧 `lists/list_push_pop.f` - **FAILING** with type mismatch error (compiler bug, not missing feature)

---

### ✅ Milestone 13: Iterator Protocol (COMPLETE)

**Scope:** Full iterator protocol, for loops over custom types.

**Completed:**

- ✅ Iterator protocol implementation:
  - ✅ `fn iter(&T) IteratorState` protocol function
  - ✅ `fn next(&IteratorState) E?` protocol function
  - ✅ Type checking for iterator protocol compliance
  - ✅ Error codes: E2021 (type not iterable), E2023 (missing next function), E2025 (next returns wrong type)
- ✅ For loop desugaring to iterator protocol:
  - ✅ `for (x in iterable)` calls `iter(&iterable)` to get iterator state
  - ✅ Loop body wrapped with `next(&iterator)` calls until `null` returned
  - ✅ Element type inference from `Option(E)` return type
- ✅ Built-in iterators:
  - ✅ Range iterators: `0..5` syntax with `Range` and `RangeIterator` in `stdlib/core/range.f`
  - ✅ Range iterator implementation with `iter(&Range)` and `next(&RangeIterator)`
- ✅ Custom iterator implementations:
  - ✅ Support for user-defined iterators with custom state types
  - ✅ Examples: Countdown, Counter, Fibonacci iterators
- ✅ Error handling improvements:
  - ✅ Proper error spans (for loop span only includes `for (v in c)`, not body)
  - ✅ Skip body checking when iterator setup fails (prevents cascading errors)
  - ✅ Hint spans for E2025 pointing to return type of `next` function
  - ✅ Short type names in error messages (FormatTypeNameForDisplay helper)
  - ✅ Consistent, helpful error messages with proper grammar

**Tests Added:**

- ✅ `iterators/iterator_range_syntax.f` - Range syntax `0..5` in for loops
- ✅ `iterators/iterator_range_basic.f` - Range iterator with explicit Range struct
- ✅ `iterators/iterator_range_empty.f` - Empty range handling
- ✅ `iterators/iterator_with_break.f` - Break statement in iterator loops
- ✅ `iterators/iterator_with_continue.f` - Continue statement in iterator loops
- ✅ `iterators/iterator_custom_simple.f` - Simple custom iterator (Countdown)
- ✅ `iterators/iterator_custom_counter.f` - Custom iterator with separate state type
- ✅ `iterators/iterator_custom_fibonacci.f` - Complex custom iterator (Fibonacci)
- ✅ `iterators/iterator_error_no_iter.f` - E2021: Type not iterable
- ✅ `iterators/iterator_error_no_next.f` - E2023: Missing next function
- ✅ `iterators/iterator_error_next_wrong_return.f` - E2025: Wrong return type (i32 instead of i32?)
- ✅ `iterators/iterator_error_next_wrong_return_struct.f` - E2025: Wrong return type (struct instead of Option)

**Deferred to Later Milestones:**

- [ ] Array/slice iterators (needs slice iterator implementation)
- [ ] String iterators (code points or bytes)

---

## Phase 4: Language Completeness

_Goal: Fill in remaining language features._

### Milestone 14: Enums & Pattern Matching (IN PROGRESS)

**Scope:** Tagged unions, pattern matching (basic).

**Completed:**

- ✅ `enum` syntax parsing
- ✅ Generic enum declarations: `enum Result(T, E) { Ok(T), Err(E) }`
- ✅ Enum type registration with type parameters
- ✅ Variant construction (qualified and short forms)
- ✅ Basic pattern matching with match expressions
- ✅ Wildcard patterns (`_`) for ignoring values
- ✅ Variable binding patterns
- ✅ Exhaustiveness checking
- ✅ Enum instantiation for generic enums
- ✅ Pattern matching on enum references (`&EnumType`)
- ✅ Recursive generic enums (e.g., `enum List(T) { Cons(T, &List(T)), Nil }`)
- ✅ Generic enum variant construction with type inference from expected type

**Pending:**

- [ ] Nested patterns (e.g., `Some(Ok(x))`)
- [ ] Multiple wildcards in one pattern (e.g., `Move(_, y)` with 2+ fields)

---

### ✅ Milestone 15: Operators as Functions (COMPLETE)

**Scope:** Operator overloading via operator functions.

**Completed:**

- ✅ Define operator function names: `op_add`, `op_sub`, `op_mul`, `op_div`, `op_mod`, `op_eq`, `op_ne`, `op_lt`, `op_gt`, `op_le`, `op_ge`
- ✅ `OperatorFunctions` utility class with name mapping and symbol lookup
- ✅ Desugar operators to function calls in type checker
- ✅ Overload resolution for operator functions
- ✅ User-defined operator functions for custom struct types
- ✅ Proper error reporting (E2017) when operator not implemented

**Tests Added:**

- ✅ `operators/op_add_struct.f` - Custom `+` operator for struct
- ✅ `operators/op_sub_struct.f` - Custom `-` operator for struct
- ✅ `operators/op_eq_basic.f` - Equality operator
- ✅ `operators/op_eq_struct.f` - Custom `==` operator for struct
- ✅ `operators/op_lt_struct.f` - Custom `<` operator for struct
- ✅ `operators/op_error_no_impl.f` - E2017 error when no operator implementation

**Note:** Primitive operator functions in stdlib deferred (primitives use built-in operators).

---

### Milestone 16: Test Framework (COMPLETE)

**Scope:** Compiler-supported testing framework with `test` blocks and assertion functions.

**Key Tasks:**

- [x] `panic(msg: String)` function in `core/panic.f`
  - [x] Uses C `exit(1)` to terminate
  - [x] Prints message before terminating
  - [ ] Source location support (future: compiler intrinsic for file/line)
- [x] `assert_true(condition: bool, msg: String)` function
  - [x] Calls `panic(msg)` when condition is false
- [x] `assert_eq(a: $T, b: T, msg: String)` function
  - [x] Generic function for equality checks
  - [ ] Future: print expected vs actual on failure (needs ToString)
- [x] `test "name" { }` block syntax
  - [x] Parse `test` keyword followed by string literal and block
  - [x] `TestDeclarationNode` AST node
  - [x] Test blocks scoped to module (not exported)
  - [x] TypeChecker support via CheckTest()
- [x] Test discovery and execution
  - [x] CLI flag: `--test` to run tests instead of main
  - [x] Collect all `test` blocks from compiled modules
  - [x] Generate test runner that calls each test
  - [ ] Report pass/fail counts (deferred: currently just exits 0/1)
- [ ] Test isolation (deferred to future milestone)
  - [ ] Each test runs independently
  - [ ] Failures don't stop other tests
  - Requires setjmp/longjmp or subprocess execution

**Bug Fixes:**

- Fixed void-if codegen: skip storing void results in if blocks
- Fixed C codegen: add empty statement after labels with no instructions
- Fixed TypeChecker: remove \_functionStack guard for proper call resolution in tests

**Tests Added:**

- `test/test_block_basic.f` - Single test block with assertion
- `test/multiple_tests.f` - Multiple test blocks with various assertions
- `test/panic_basic.f` - panic() prints message and exits with code 1
- `test/assert_true_pass.f` - assert_true with true condition
- `test/assert_true_fail.f` - assert_true with false (exits with 1)
- `test/assert_eq_pass.f` - assert_eq equality check (pass)
- `test/assert_eq_fail.f` - assert_eq inequality (exits with 1)

---

### Milestone 16.1: Null Safety Operators

**Scope:** Ergonomic null handling operators.

**Key Tasks:**

- [x] Null-coalescing: `a ?? b`
  - [x] Parse `??` operator (low precedence, right-associative)
  - [x] Desugar to: `op_coalesce(a, b)`
  - [x] `Option(T)` implements `op_coalesce` via `unwrap_or` overloads
  - [ ] `Result(T, E)` implements `op_coalesce` to find first `Ok` or return error (deferred - Result type not yet implemented)
  - [x] Enables chaining: `a ?? b ?? c`
- [~] Null-propagation: `opt?.field` (partial - parsing and type checking done, lowering needs work)
  - [x] Parse `?.` operator for safe member access
  - [x] Type checking: unwrap Option, access field, wrap result in Option
  - [ ] IR lowering: conditional branch generation (complex, deferred)
- [ ] Early-return operator: `expr?` (deferred to future milestone)
  - [ ] Postfix `?` operator on nullable/Result expressions
  - [ ] Early return `null`/`Err` if `expr` has no value
  - [ ] Requires function return type context tracking

---

### ✅ Milestone 16.2: Language Ergonomics (COMPLETE)

**Scope:** Quality-of-life language features.

**Completed:**

- [x] `const` declarations
  - [x] Parse `const NAME: Type = expr` and `const NAME = expr`
  - [x] Immutable binding semantics (E2038: cannot reassign to const)
  - [x] Require initializer (E2039: const must have initializer)
  - [x] Top-level (module-scope) const declarations
  - [x] Struct literal initializers for global constants
  - [x] Function reference initializers for global constants
- [x] UFCS desugaring
  - [x] `obj.method(args)` → `method(obj, args)`
  - [x] Or `method(&obj, args)` if reference lifting required
  - [x] Method lookup in current module scope
  - [x] Works with generic functions

**Tests Added:**

- `const/const_basic.f` - Basic const declaration
- `const/const_inferred_type.f` - Const with type inference
- `const/const_with_expression.f` - Const with computed value
- `const/global_const_scalar.f` - Top-level scalar const
- `const/global_const_inferred.f` - Top-level const with type inference
- `const/global_const_multiple.f` - Multiple top-level consts
- `const/global_const_in_function.f` - Global const used in function
- `const/global_const_vtable.f` - Global struct const with function pointers (vtable pattern)
- `errors/error_e2038_const_reassign.f` - E2038 validation
- `errors/error_e2039_const_no_init.f` - E2039 validation
- `ufcs/ufcs_basic_value.f` - UFCS with value parameter
- `ufcs/ufcs_with_ref.f` - UFCS with reference lifting
- `ufcs/ufcs_with_args.f` - UFCS with additional arguments
- `ufcs/ufcs_generic.f` - UFCS with generic functions

**Note:** Compile-time evaluation deferred (const values are runtime-evaluated)

---

### ✅ Milestone 16.3: Auto-Deref for Reference Member Access (COMPLETE)

**Scope:** Automatic pointer dereferencing for field access (like C's `->` operator).

**Completed:**

- [x] Auto-deref for `&T` member access
  - [x] `ref.field` on `&Struct` auto-dereferences to access field directly
  - [x] Similar to C's `ptr->field` being equivalent to `(*ptr).field`
  - [x] `ref.*` remains explicit copy/dereference of the pointed-to value
  - [x] Works recursively for nested references (`&&T`, `&&&T`, etc.)
- [x] Updated TypeChecker's `CheckMemberAccessExpression` to auto-unwrap references recursively
- [x] Updated AstLowering to emit correct pointer arithmetic (no copy)
- [x] MemberAccessExpressionNode tracks `AutoDerefCount` for lowering

**Tests Added:**

- `autoderef/autoderef_basic.f` - Basic auto-deref on `&Struct`
- `autoderef/autoderef_nested.f` - Auto-deref with nested struct fields
- `autoderef/autoderef_double_ref.f` - Recursive auto-deref on `&&Struct`
- `autoderef/autoderef_assignment.f` - Auto-deref for field assignment
- `autoderef/autoderef_chain.f` - Auto-deref with nested field chain
- `autoderef/autoderef_second_field.f` - Auto-deref accessing second field (offset test)
- `autoderef/autoderef_mixed_sizes.f` - Auto-deref with mixed field sizes and alignment
- `autoderef/autoderef_last_field.f` - Auto-deref accessing last field in large struct
- `autoderef/autoderef_double_ref_offset.f` - Double auto-deref with non-first field access
- `autoderef/autoderef_assign_second.f` - Auto-deref assignment to non-first field

**Example:**

```flang
struct Point { x: i32, y: i32 }

fn sum(p: &Point) i32 {
    return p.x + p.y   // auto-deref: accesses through pointer directly
    // return p.*.x + p.*.y  // explicit deref: copies Point first
}
```

---

### ✅ Milestone 16.4: Function Types (COMPLETE)

**Scope:** First-class function types for passing functions as arguments.

**Completed:**

- ✅ Function type syntax: `fn(T1, T2) R`
  - ✅ Parse `fn(...)` in type position (mirrors declaration syntax)
  - ✅ `FunctionType` in type system with parameter types and return type
  - ✅ `FunctionTypeNode` AST node
- ✅ Type checking for function types
  - ✅ Function type compatibility (exact match on params + return - C semantics)
  - ✅ Named functions coerce to function type values
  - ✅ comptime_int literals coerce to expected parameter types
- ✅ Passing functions as arguments
  - ✅ `fn apply(f: fn(i32) i32, x: i32) i32 { return f(x) }`
  - ✅ Call expression on function-typed values (indirect calls)
- ✅ Storing functions in variables
  - ✅ `let f: fn(i32) i32 = my_function`
  - ✅ Calling through function-typed variables
- ✅ IR support
  - ✅ `FunctionReferenceValue` for function pointer values
  - ✅ `IndirectCallInstruction` for calls through function pointers
- ✅ C codegen: function pointers
  - ✅ Emit C function pointer syntax: `int32_t (*f)(int32_t)`
  - ✅ Special handling for alloca, load, and function parameters
  - ✅ Name mangling for function types in symbol names

**Deferred:**

- Generic function types (`fn($T) T`) - can be added later

**Tests:** 5 new tests passing

- ✅ `function_types/fn_type_basic.f` - Pass function as argument
- ✅ `function_types/fn_type_variable.f` - Store function in variable
- ✅ `function_types/fn_type_multiple_params.f` - Multiple parameter function types
- ✅ `function_types/fn_type_higher_order.f` - Higher-order function calls
- ✅ `function_types/fn_type_no_coercion_error.f` - Error test for type mismatch

---

### Milestone 16.5: Extended Types (Optional) [COMPLETE]

**Scope:** Additional type system features.

**Key Tasks:**

- [x] Multiple return values / tuples
  - [x] `(T, U)` tuple type syntax - desugars to anonymous struct `{ _0: T, _1: U }`
  - [x] Tuple construction: `(a, b)` desugars to `.{ _0 = a, _1 = b }`
  - [x] Tuple field access: `t.0` desugars to `t._0`
  - [x] Functions returning tuples
  - [x] Single-element tuple with trailing comma: `(x,)`
  - [x] Empty tuple / unit type: `()`

---

### Milestone 16.6: Result Type & Test Enhancements

**Scope:** Implement `Result(T, E)` enum and add test-related features for enum validation.

**Key Tasks:**

- [x] Implement `Result(T, E)` enum in `stdlib/core/result.f`
  - [x] `Ok(T)` and `Err(E)` variants
  - [x] Helper functions: `is_ok`, `is_err`, `unwrap`, `unwrap_or`, `unwrap_err`
- [x] Add Result-specific test assertions
  - [x] `assert_ok(result: Result($T, $E), msg: String)` - panic if Err
  - [x] `assert_err(result: Result($T, $E), msg: String)` - panic if Ok
- [x] Test Result enum with `test` blocks to validate enum system
  - [x] Basic Ok/Err construction and matching
  - [x] Generic type parameter inference
  - [x] Error propagation patterns

**Deferred to Milestone 18+:**

- [ ] Convert `struct Option(T)` to `enum Option(T) { Some(T), None }`
  - Requires updating all Option-related compiler code
  - Struct version works well for current use cases

---

## Phase 5: Standard Library

_Goal: Build a usable standard library._

### Milestone 17: Core Library

**Scope:** Essential runtime support.

**Tasks:**

- [ ] `core/mem.f` - Memory operations (already started in M10)
- [ ] `core/intrinsics.f` - Compiler intrinsics (dropped)
- [ ] `core/panic.f` - Panic handling (already implemented)
- [ ] `core/types.f` - Type aliases for primitives (incomplete, missing list of fields and their offsets)

---

### Milestone 18: Collections (COMPLETE)

**Scope:** Core data structures with allocator support.

**Status:** List(T) and Dict(K,V) fully implemented.

**Completed:**

- [x] `std/list.f` - `List(T)` generic dynamic array - **FULLY WORKING**
  - [x] Struct layout: `{ ptr: &T, length: usize, cap: usize, elem_size: usize }`
  - [x] `list_new(type: Type($T))` constructor using type introspection
  - [x] `push(&List(T), value: T)` - append with automatic reallocation
  - [x] `pop(&List(T)) T?` - remove and return last element
  - [x] `get(List(T), index: usize) T` - index access with bounds check (value semantics)
  - [x] `set(&List(T), index: usize, value: T)` - index assignment with bounds check
  - [x] `len(List(T)) usize` - element count (value semantics)
  - [x] `is_empty(List(T)) bool` - empty check (value semantics)
  - [x] `clear(&List(T))` - remove all elements (keep capacity)
  - [x] `deinit(&List(T))` - free backing storage
- [x] `std/dict.f` - `Dict(K, V)` hash table - **FULLY WORKING**
  - [x] Open addressing with linear probing (uses bounded `for-in` loops)
  - [x] Multiplicative hash function on raw key bytes
  - [x] Automatic growth at 75% load factor (capacity doubles, starting at 8)
  - [x] Tombstone-based deletion for correct probe chain handling
  - [x] Allocator support (`&Allocator?` field, defaults to `global_allocator`)
  - [x] Zero-value initialization (no constructor needed: `let d: Dict(K,V)`)
  - [x] `set(&Dict(K,V), key: K, value: V)` - insert or update
  - [x] `get(Dict(K,V), key: K) V?` - lookup
  - [x] `contains(Dict(K,V), key: K) bool` - membership test
  - [x] `remove(&Dict(K,V), key: K) V?` - delete with tombstone
  - [x] `len(Dict(K,V)) usize` - entry count
  - [x] `is_empty(Dict(K,V)) bool` - empty check
  - [x] `clear(&Dict(K,V))` - remove all entries (keep capacity)
  - [x] `deinit(&Dict(K,V))` - free backing storage

**Tests:**

- ✅ 3 list tests passing: `list_basic.f`, `list_push_pop.f`, `list_clear.f`
- ✅ 3 dict tests passing: `dict_basic.f`, `dict_remove.f`, `dict_overwrite.f`

---

### Milestone 19: String Types, Formatting & I/O

**Scope:** Implement the three-tier string ownership model (spec Section 3.5), the Formattable protocol (spec Section 3.5.5), string interpolation, and file I/O.

#### 19a: String Ownership Types

- [ ] `OwnedString` type in `stdlib/std/string.f`
  - [ ] Struct: `{ ptr: &u8, len: usize, allocator: &Allocator? }` (currently empty stub)
  - [ ] `deinit(&OwnedString)` — free buffer through allocator
  - [ ] `as_view(OwnedString) String` — explicit non-owning view (zero-copy)
  - [ ] `to_owned_string(String, &Allocator?) OwnedString` — allocate + copy
- [x] `String` is already non-owning (`core/string.f`: `{ ptr: &u8, len: usize }`, no allocator, no deinit)
  - [x] String literals produce `String` (static data)
  - [x] `op_eq`, `op_index`, `as_raw_bytes` implemented

#### 19b: StringBuilder

Partially implemented in `stdlib/std/string_builder.f`:

- [x] `StringBuilder` struct: `{ ptr: &u8, len: usize, cap: usize, allocator: &Allocator? }`
- [x] `string_builder(&Allocator?)` — constructor (default capacity 16)
- [x] `string_builder_with_capacity(usize, &Allocator?)` — constructor with capacity
- [x] `deinit(&StringBuilder)` — free buffer
- [x] `append(&StringBuilder, String)` — append string view (memcpy)
- [x] `append(&StringBuilder, u8)` — single byte
- [x] `append(&StringBuilder, u8[])` — byte slice
- [x] `as_string(&StringBuilder) String` — non-owning view
- [x] `clear(&StringBuilder)` — reset length without freeing
- [x] `reserve(&StringBuilder, usize)` — internal growth (double capacity)
- [x] `to_string(&StringBuilder) String` — allocates a copy (current impl returns `String`)
- [x] `writer(&StringBuilder) BufferedWriter` — writer interface adapter

Remaining:

- [ ] `append(&StringBuilder, i32)` / `u8` / `bool` / etc. — specialized primitive overloads
- [ ] `append(&StringBuilder, $T)` — generic fallback, calls `val.format(sb)`
- [ ] Update `to_string` to return `OwnedString` with move semantics (transfer buffer, reset builder)
- [ ] Add `to_string_copy` returning `OwnedString` (current `to_string` behavior — allocate + copy)
- [ ] Rename `as_string` → `as_view` per spec conventions

#### 19c: Formattable Protocol

- [ ] `fn format(self: T, sb: &StringBuilder)` convention for user-defined types
- [ ] `format` for `String` and `OwnedString`
- [ ] Verify generic `append($T)` dispatches to `format` via overload resolution

#### 19d: String Interpolation (Future)

- [ ] Parse `"text ${expr} more"` syntax in lexer/parser
- [ ] Desugar to `StringBuilder` + `append` calls + `to_string()` (see spec Section 3.5.5)
- [ ] Compile error for types without `format` implementation

#### 19e: I/O

- [ ] `std/io/file.f` - File I/O
- [ ] `std/io/fmt.f` - `print`, `println` using StringBuilder + format protocol
  - [ ] Replace current `core/io.f` stopgap (`printf`/`puts`) with proper implementation
  - [ ] `print` accepts any type with `format` — calls `sb.append(arg)` internally

Note: A minimal stopgap exists now in `core/io.f` providing `print` and `println` via C `printf`/`puts` for test use; this will be replaced by `std/io/fmt.f` in this milestone.

---

### Milestone 20: Utilities

**Scope:** Algorithms and helpers.

**Tasks:**

- [ ] `std/algo/sort.f` - Sorting algorithms
- [ ] `std/algo/search.f` - Binary search, etc.
- [ ] `std/math.f` - Math functions

---

## Phase 5b: Lambdas, Closures & Allocator Redesign

_Goal: First-class anonymous functions and a thread-local allocator model that eliminates viral allocator parameters._

### Milestone 21: Non-Capturing Lambdas

**Scope:** Anonymous function expressions that desugar to module-level functions + function references.

**Syntax:**

```
\ Anonymous function:
let add = fn(x: i32, y: i32) i32 { x + y }

\ Type-inferred params, including return type (from expected type):
let f: fn(i32) i32 = fn(x) { x + 1 }

\ As argument:
apply(fn(x) { x * 2 }, 5)
```

**Tasks:**

- [x] `LambdaExpressionNode` AST node (params with optional types, expr or block body)
- [x] Parser: `fn(...)` in expression position → lambda
- [x] TypeChecker: type-check lambda, infer param types from expected type context
- [x] TypeChecker: synthesize `FunctionDeclarationNode` (`__lambda_N`), add to generated list
- [x] TypeChecker: capture guard — error if lambda body references outer variables
- [x] AstLowering: lambda → `FunctionReferenceValue` pointing to generated function
- [x] Compiler pipeline: lower synthesized lambda functions alongside specializations
- [x] Tests: basic, block form, as argument, type inference, capture error

---

### Milestone 22: Thread-Local Variables & Allocator Redesign

**Scope:** `#thread_local` directive for per-thread global variables. Redesign stdlib to use a thread-local `current_allocator` instead of per-type `allocator: &Allocator?` fields.

**Design:**

```
\ Thread-local variable (each thread gets its own copy)
#thread_local
let current_allocator: &Allocator = &global_allocator

\ Override for a scope using defer:
const old = current_allocator
current_allocator = FixedBufferAllocator(buf)
defer current_allocator = old
```

**Tasks:**

- [ ] `#thread_local` directive: parser, AST, codegen (TLS segment in C backend)
- [ ] `current_allocator` thread-local variable in stdlib
- [ ] Stdlib helper: `using_allocator(&Allocator) &Allocator` (swap + return old)
- [ ] Redesign stdlib types: remove `allocator: &Allocator?` fields, use `current_allocator` instead
- [ ] Update List, Dict, StringBuilder, OwnedString to use `current_allocator`
- [ ] Tests: thread-local basics, allocator override + defer restore

---

### Milestone 23: Closures (Capturing Lambdas)

**Scope:** Lambdas that capture variables from enclosing scope. Environment struct allocated via `current_allocator`.

**Design:**

- Closure = fat pointer (function pointer + environment pointer)
- Captured variables copied by value into heap-allocated environment struct
- Environment allocated through `current_allocator` (thread-local)
- `deinit` frees environment through the allocator it was allocated with

**Tasks:**

- [ ] Capture analysis: detect which outer variables the lambda body references
- [ ] Environment struct generation: `__closure_env_N { allocator, captured_vars... }`
- [ ] Generated function takes hidden `env` parameter
- [ ] Fat pointer representation: function type becomes (fn_ptr, env_ptr) when captures exist
- [ ] Codegen: indirect calls pass environment pointer
- [ ] Stdlib helper: `with_allocator(&Allocator, fn() void)` using closures
- [ ] Tests: capture by value, closure as argument, closure with allocator override

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

- **Phase:** 5 (Standard Library)
- **Milestone:** 18 (Collections - COMPLETE)
- **Next Up:**
  - Milestone 19: String Types, Formatting & I/O (19a → 19b → 19c → 19d → 19e)
  - Complete M14 pending items (nested patterns, multiple wildcards)
- **Tests Passing:** 196 passed
  - ✅ 15 core tests (basics, control flow, functions)
  - ✅ 5 generics tests (M11)
  - ✅ 4 struct tests
  - ✅ 3 array tests
  - ✅ 3 string tests
  - ✅ 4 reference/pointer tests
  - ✅ 3 intrinsic tests
  - ✅ 3 defer tests
  - ✅ 4 memory tests
  - ✅ 5 cast tests
  - ✅ 7 enum tests (M14) - includes recursive enums
  - ✅ 12 match tests (M14)
  - ✅ 3 SSA tests (reassignment, print functions)
  - ✅ 12 iterator tests (M13)
  - ✅ 6 operator tests (M15)
  - ✅ 3 const tests (M16.2)
  - ✅ 4 UFCS tests (M16.2)
  - ✅ 2 const error tests (M16.2)
  - ✅ 10 auto-deref tests (M16.3)
  - ✅ 3 list tests (M18)
  - ✅ 3 dict tests (M18)

- **Total Lines of FLang Code:** ~700+ (test files + stdlib)
- **Total Lines of C# Compiler Code:** ~7,700+
