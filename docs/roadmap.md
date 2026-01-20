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
- Fixed TypeChecker: remove _functionStack guard for proper call resolution in tests

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
- [x] UFCS desugaring
  - [x] `obj.method(args)` → `method(obj, args)`
  - [x] Or `method(&obj, args)` if reference lifting required
  - [x] Method lookup in current module scope
  - [x] Works with generic functions

**Tests Added:**

- `const/const_basic.f` - Basic const declaration
- `const/const_inferred_type.f` - Const with type inference
- `const/const_with_expression.f` - Const with computed value
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

### Milestone 16.4: Function Types

**Scope:** First-class function types for passing functions as arguments.

**Key Tasks:**

- [ ] Function type syntax: `fn(T1, T2) R`
  - [ ] Parse `fn(...)` in type position (mirrors declaration syntax)
  - [ ] `FunctionType` in type system with parameter types and return type
- [ ] Type checking for function types
  - [ ] Function type compatibility (exact match on params + return)
  - [ ] Named functions coerce to function type
- [ ] Passing functions as arguments
  - [ ] `fn apply(f: fn(i32) i32, x: i32) i32 { return f(x) }`
  - [ ] Call expression on function-typed values
- [ ] Generic function types
  - [ ] `fn map(f: fn($T) T, x: T) T`
  - [ ] Type inference from function argument
- [ ] C codegen: function pointers
  - [ ] Emit C function pointer syntax: `int (*f)(int)`
  - [ ] Pass function addresses as arguments

**Tests Planned:**

- `functions/fn_type_basic.f` - Pass function as argument
- `functions/fn_type_generic.f` - Generic function type parameter
- `functions/fn_type_call.f` - Call function-typed value
- `functions/fn_type_return.f` - Return function from function

---

### Milestone 16.5: Extended Types (Optional)

**Scope:** Additional type system features.

**Key Tasks:**

- [ ] Multiple return values / tuples
  - [ ] `(T, U)` tuple type syntax
  - [ ] Tuple construction and destructuring
  - [ ] Functions returning tuples

---

### Milestone 16.6: Enum Option Migration

**Scope:** Replace struct Option(T) with enum Option(T) for better semantics.

**Key Tasks:**

- [ ] Update `stdlib/core/option.f` to use enum definition
- [ ] Update pattern matching to support `Some(x)` / `None` variants
- [ ] Update compiler tests and stdlib code
- [ ] Implement `Result(T, E)` enum to demonstrate enum system

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

- [ ] `std/collections/list.f` - `List(T)`
- [ ] `std/collections/dict.f` - `Dict(K, V)` (hash map)
- [ ] `std/slice.f` - Slice utilities

---

### Milestone 19: Text & I/O

**Scope:** String handling and I/O.

**Tasks:**

- [ ] `std/text/string.f` - String utilities (incl. `fn to_cstr(s: &String) &u8` that returns a null-terminated pointer: if `s.ptr[s.len] == 0` return `s.ptr`; otherwise allocate `len+1`, copy, append `\0`).

- [ ] `std/text/string_builder.f` - Efficient string building
- [ ] `std/io/file.f` - File I/O
- [ ] `std/io/fmt.f` - `println`, `print`, formatting

Note: A minimal stopgap exists now in `core/io.f` providing `print` and `println` via C `printf`/`puts` for test use; this will be replaced by `std/io/fmt.f` in this milestone.

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

- **Phase:** 4 (Language Completeness)
- **Milestone:** 16.3 (COMPLETE - Auto-Deref for Reference Member Access)
- **Next Up:**
  - **M16.4:** Function Types (first-class functions as arguments)
  - Complete M14 pending items (nested patterns, multiple wildcards)
  - **M16.5:** Extended Types (tuples - optional)
  - **M16.6:** Enum Option Migration (replaces struct Option)
  - Fix pre-existing generics overload resolution bug (`generic_mangling_order.f`)
  - Fix pre-existing option test bug (`option_basic.f`)
- **Tests Passing:** 148/149

  - ✅ 15 core tests (basics, control flow, functions)
  - ✅ 5 generics tests (M11)
  - ✅ 4 struct tests
  - ✅ 3 array tests
  - ✅ 3 string tests
  - ✅ 3 reference/pointer tests
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
  - ❌ 1 list test failing (unimplemented feature)

- **Total Lines of FLang Code:** ~600+ (test files + stdlib)
- **Total Lines of C# Compiler Code:** ~7,700+
