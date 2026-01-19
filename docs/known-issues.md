# Known Issues & Technical Debt

This document tracks known bugs, limitations, and technical debt in the FLang compiler.

---

## How to Add Items

When you discover a bug or limitation:

1. Add it to the appropriate section above
2. Include: Status, Affected components, Problem description, Solution, Related tests
3. Reference the milestone or phase where it should be fixed
4. Update when fixed (move to "Recently Fixed" section or remove)

---

## Critical Issues

### FIR: Lack of Type Information in Values

**Status:** Partially addressed (IR values now carry FLang types)
**Affected:** Struct field storage, function parameter codegen
**Impact:** Causes segfaults in `struct_nested.f` and `struct_parameter.f` tests


**Problem:**
The FIR `Value` type (`LocalValue`, `ConstantValue`) doesn't track type information. This causes issues when:

1. Storing a struct value into a struct field - we store the pointer address instead of copying the struct bytes
2. Passing struct pointers as function parameters - codegen defaults to `int*` instead of `struct T*`

**Example Bug (struct_nested.c line 19):**

```c
int* field_ptr_3 = (int*)((char*)alloca_2 + 0);
*field_ptr_3 = inner;  // BUG: Stores pointer address, not struct contents
```

Should be:

```c
struct Inner* field_ptr_3 = (struct Inner*)((char*)alloca_2 + 0);
memcpy(field_ptr_3, inner, sizeof(struct Inner));
```

**Root Cause:**

- `LocalValue` is just a `string Name` - no type attached
- C codegen defaults to `int*` for all pointers
- No way to distinguish `struct Foo*` from `int*` at codegen time

**Solution (implemented incrementally):**
- IR values now carry `FLang.Core.FType? Value.Type`
- Lowering attaches types for literals, temporaries, addresses, loads, GEPs, calls, and many locals
- C backend maps FLang types to C types (`TypeRegistry.ToCType`) instead of defaulting to `int`
- Next step: ensure all value producers set `Value.Type` consistently and teach `StorePointerInstruction` to emit `memcpy` for struct-by-value copies

**Workaround:** None — tracked as ongoing refactor


**Related Tests:**

- `tests/FLang.Tests/Harness/structs/struct_nested.f` (FAIL - segfault)
- `tests/FLang.Tests/Harness/structs/struct_parameter.f` (FAIL - segfault)

**Milestone:** Fix in Phase 2 refactoring (before self-hosting)

---

## Deferred Features

### FFI Pointer Returns and Casts

**Status:** Not implemented (blocks memory tests)
**Affected:** Foreign calls returning pointers, explicit casts (`as`)

**Problem:**
- Codegen now emits correct `extern` prototypes, but call result locals are still typed as `int` in generated C.
- The language does not yet support `as` casts used by memory tests.

**Solution:**
1. Add type-carrying FIR values (see Critical Issue: Lack of Type Information) to type call results correctly at codegen time.
2. Implement cast syntax and semantics (`expr as T`) in parser, type checker, and lowering.

**Related Tests:**
- `tests/FLang.Tests/Harness/memory/malloc_free.f`
- `tests/FLang.Tests/Harness/memory/memcpy_basic.f`
- `tests/FLang.Tests/Harness/memory/memset_basic.f`

**Milestone:** Complete as part of finishing M10 FFI or in M11 if cast syntax lands there.



### Bounds Checking with Panic

**Status:** Planned for M8 completion
**Affected:** Array/slice indexing

**Problem:**
Currently no runtime bounds checking on `arr[i]` - out-of-bounds access causes undefined behavior.

**Solution:**

1. Add panic runtime support (`core/panic.f`)
2. Emit bounds check before every index operation:
   ```c
   if (index >= array_length) {
       panic("index out of bounds");
   }
   ```
3. Add `--no-bounds-check` flag for release builds

**Dependencies:**

- Requires panic infrastructure (foreign `abort()`, panic message formatting)
- Should be part of M10 (Memory Management Primitives)

---

### Slice Indexing

**Status:** Not implemented
**Affected:** `T[]` slice types

**Problem:**
`IndexExpressionNode` only handles `ArrayType`, not `SliceType`. Attempting to index a slice gives error E3005.

**Solution:**

1. Extract `ptr` and `len` fields from slice struct
2. Emit bounds check: `if (index >= slice.len) panic(...)`
3. Load from `slice.ptr[index]`

**Related:** Depends on bounds checking infrastructure

---

## Minor Issues

### Error Code Inconsistencies

**Status:** Partially fixed
**Affected:** Error reporting throughout compiler
**Impact:** Some error codes in documentation don't match implementation

**Remaining Discrepancies:**

1. **E2006/E2007 vs E3006/E3007:** Documentation says break/continue outside loop should report E2006/E2007 (semantic analysis), but these errors are actually caught during lowering (E3006/E3007).

2. **E2015 vs E2019:** E2015 is documented as "Intrinsic requires exactly one type argument" but is also used for "missing field in struct construction" at line 2310 in TypeChecker.cs. E2019 is the documented code for missing fields (line 1728).

**Fixed:**
- E1004/E1005: Parser now correctly emits E1004 for invalid array lengths and E1005 for invalid repeat counts (was E1002)
- E0XXX: Error codes E0000, E0001, E0002 are now documented

**Root Cause:**
Error codes were not consistently applied during development. Some semantic checks are performed during lowering rather than type checking.

**Solution:**
- Documentation has been updated to reflect actual error codes emitted
- Test suite validates actual error codes
- Future: Consider refactoring to move semantic checks earlier (E2006/E2007) and standardizing E2015/E2019

**Related Tests:**
- `tests/FLang.Tests/Harness/errors/` - 21 error code tests

---

### Coercions: Array→Slice and String↔u8[] in declarations/calls

Status: Open (partial)
Affected: TypeSolver (compatibility checks and variable declarations)
Impact: Declarations and calls that rely on implicit view conversions still fail in some contexts:
- `let bytes: u8[] = arr` (where `arr: [u8; N]`) reports E2002
- `takes_bytes(s)` (where `s: String`, `takes_bytes(b: u8[])`) reports E2011
- Explicit casts `s as u8[]` and `bytes as String` sometimes report E2020

Root cause hypothesis:
- The initializer/call argument types are computed correctly, but the compatibility path used in variable declarations and overload resolution isn’t consistently applying the view rules.

Mitigations applied:
- Extended `IsCompatible` to handle `ref [T;N] -> T[]`, and `String -> T[]` cases.
- Added additional coercion checks in variable declarations.

Next steps:
- Audit where `IsCompatible` is called in overload selection; ensure the same rules are used for both declarations and call matching.
- Add targeted unit tests for coercions in both var binding and call contexts.

Related tests:
- tests/FLang.Tests/Harness/casts/slice_to_string_explicit.f
- tests/FLang.Tests/Harness/casts/string_to_slice_implicit.f
- tests/FLang.Tests/Harness/casts/string_to_slice_view.f


### Dynamic GetElementPtr Offset Type

**Status:** Fixed in M8
**Was:** `GetElementPtrInstruction.ByteOffset` was `int` (constant only)
**Now:** `Value ByteOffset` (supports dynamic offsets from `LocalValue`)

This was fixed to support dynamic array indexing with runtime index calculations.

---

## Future Architectural Changes

### Move to SSA Form

**Status:** Consideration for post-self-hosting

**Current:** FIR uses named local variables (not SSA)
**Benefit:** Would simplify optimizations, make type tracking easier

**Decision:** Keep current design until self-hosting, then evaluate

---

## Temporary Limitations

### Minimal I/O (`core/io.f`) uses C stdio printf length specifier

Status: Intentional stopgap for tests
Affected: `print`, `println`

Current behavior:
- `print` and `println` call C `printf` with a literal format `"%.*s"` and pass the FLang string length and pointer. This avoids format-string injection and does not rely on a trailing NUL.
- `println` appends a newline via the format string.

Remaining limitation:
- Embedded NUL bytes in the string will truncate output due to `%s` semantics.

Planned fix:
- Replace with proper `std/io/fmt.f` in Milestone 19 that writes bytes using `fwrite` (or buffered writers) and supports formatting without `%s` truncation.

Related Tests:
- `tests/FLang.Tests/Harness/strings/print_basic.f`
- `tests/FLang.Tests/Harness/strings/println_basic.f`

Milestone: 19 (Text & I/O)


## Recently Fixed

### Generics: Return Type Name Resolution

**Fixed:** 2025-12-06
**Was:** Generic function signatures failed to recognize return-type identifiers (e.g., `fn identity(x: $T) T`) as parameters, triggering E2003 during signature collection and body checks because the type solver lost track of `$T` outside argument positions.
**Now:** The type solver maintains an explicit generic-parameter scope per function, so both parameters and return types resolve to `GenericParameterType` values consistently. Specializations reuse the captured scope, preventing regressions in later inference passes.

**Related Tests:**
- `tests/FLang.Tests/Harness/generics/identity_basic.f`
- `tests/FLang.Tests/Harness/generics/two_params_pick_first.f`
- `tests/FLang.Tests/Harness/generics/cannot_infer_from_context.f`
- `tests/FLang.Tests/Harness/generics/conflicting_bindings_error.f`

### String Literal Naming Collisions

**Fixed:** M8 (2025-11-14)
**Was:** String literal names were generated per-function using local counters, causing duplicate identifiers (e.g., `str_0`) when compiling multiple modules into one C translation unit.
**Now:** String literal names are allocated from a compilation-wide counter, ensuring global uniqueness across files.

### Generic Specialization Mangling Order

**Fixed:** M8 (2025-11-14)
**Was:** Generic mangled names used alphabetical order of generic parameter names, causing collisions when the same concrete types were bound in different parameter positions (e.g., `fn(a: i32, b: u64)` vs `fn(a: u64, b: i32)`).
**Now:** Mangles type arguments in the order of first appearance across the function’s parameter types, preserving call-site parameter ordering and preventing collisions.

**Related Tests:**
- `tests/FLang.Tests/Harness/generics/generic_mangling_order.f`

### Array Type C Code Generation

**Fixed:** M8 (2025-01-11)
**Was:** Generated invalid C syntax `int[3] array`
**Now:** Generates valid C syntax `int array[3]`

### Array Index Dynamic Offset

**Fixed:** M8 (2025-01-11)
**Was:** `GetElementPtrInstruction` always used offset `0` (hardcoded)
**Now:** Correctly uses calculated `index * element_size` offset
