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

### Array Type C Code Generation

**Fixed:** M8 (2025-01-11)
**Was:** Generated invalid C syntax `int[3] array`
**Now:** Generates valid C syntax `int array[3]`

### Array Index Dynamic Offset

**Fixed:** M8 (2025-01-11)
**Was:** `GetElementPtrInstruction` always used offset `0` (hardcoded)
**Now:** Correctly uses calculated `index * element_size` offset
