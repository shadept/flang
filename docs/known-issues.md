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

### Generic Struct Field Assignment via Reference Causes Compiler Hang

**Status:** Open (blocks M18: Collections)
**Affected:** Type checker or lowering for generic struct methods
**Impact:** Any function that takes `&GenericStruct($T)` and modifies a field hangs the compiler indefinitely

**Problem:**
When a generic function takes a reference to a generic struct and attempts to modify a field, the compiler hangs (infinite loop or extremely slow processing). This pattern is fundamental to implementing mutable collections like `List(T)` and `Dict(K, V)`.

**Minimal Reproduction:**
```flang
struct List(T) {
    ptr: &T
    len: usize
}

fn push(list: &List($T)) bool {
    list.len = list.len + 1  // This line causes infinite hang
    return true
}

pub fn main() i32 {
    let zero: usize = 0
    let list = List(i32) { ptr = zero as &i32, len = 0 }
    push(&list)
    return list.len as i32
}
```

**Working Cases:**
- Generic functions with non-generic struct parameters work fine
- Generic functions that only READ fields of generic structs work fine
- Non-generic functions that modify generic struct fields work fine

**Root Cause:**
Unknown - likely in TypeChecker monomorphization, UFCS resolution, or auto-deref handling for generic struct references.

**Workaround:**
None practical. Collections implementations must wait for fix.

**Related Milestone:** M18 (Collections)

---

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

### Import Statements Must Be At Top of File

**Status:** Open (parser limitation)
**Affected:** Module organization, co-located tests

**Problem:**
The parser only accepts `import` statements at the beginning of a file, before any declarations. This prevents organizing code with imports closer to where they're used, and complicates co-located test patterns where tests at the bottom of a file might need additional imports (like `std.test`).

**Example that fails:**
```flang
pub fn foo() i32 { return 42 }

// Tests section
import std.test  // ERROR: unexpected token 'import'

test "foo works" {
    assert_eq(foo(), 42, "should be 42")
}
```

**Workaround:**
Place all imports at the top of the file, even if they're only used by tests at the bottom.

**Solution:**
Modify the parser to allow `import` statements anywhere at the top level, or to allow a second import section before test blocks.

**Milestone:** Low priority - workaround is simple

---

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

### Generic Instantiation: AST Cloning vs Side Table

**Status:** Technical debt - current implementation uses AST deep cloning
**Affected:** `TypeChecker.EnsureSpecialization`, generic function instantiation

**Current Design:**
When instantiating a generic function (e.g., `pick(a: $A, b: $B)` called as `pick(1i32, 0u64)`), the type checker must resolve calls within the body using the concrete types. Currently, this works by:
1. Deep cloning the function body AST for each instantiation
2. Type-checking each cloned body independently
3. Storing `CallExpressionNode.ResolvedTarget` on the cloned nodes

**Why cloning is necessary now:**
- `CallExpressionNode.ResolvedTarget` is mutable and stored directly on the AST
- Without cloning, multiple instantiations share the same body AST
- The second instantiation's type-check overwrites the first's `ResolvedTarget`
- This caused `helper(a, b)` inside `pick(i32, u64)` to incorrectly resolve to `helper(u64, i32)`

**Why type-checking each instantiation is required:**
FLang uses structural typing without explicit trait/interface bounds. The constraints on generic parameters are implicit - they're discovered by type-checking the body with concrete types. For example, calling `helper(a, b)` inside a generic constrains `$A` and `$B` to types for which a matching `helper` overload exists. This is similar to C++ templates or duck typing.

**Proposed future solution - Side Table:**
Replace `CallExpressionNode.ResolvedTarget` with a side table:
```csharp
Dictionary<(CallExpressionNode, SpecializationKey), FunctionDeclarationNode> _callResolutions
```
This keeps the AST immutable while allowing different resolutions per instantiation. The lowering phase would look up resolutions from this table instead of reading from the AST.

**Benefits of side table approach:**
- AST remains immutable (better for caching, debugging, error reporting)
- No need to implement and maintain deep clone for every AST node type
- Cleaner separation between syntax (AST) and semantics (resolutions)

**Related code:**
- `TypeChecker.CloneStatements()` / `CloneExpression()` - current cloning implementation
- `TypeChecker.EnsureSpecialization()` - where cloning is invoked
- `CallExpressionNode.ResolvedTarget` - the mutable field causing the issue

---

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

### Generic Specialization Overload Resolution Collision

**Fixed:** M16 (2026-01-19)
**Was:** When a generic function body called an overloaded function (e.g., `helper(a, b)` with overloads `helper(i32, u64)` and `helper(u64, i32)`), multiple instantiations of the generic would resolve to the same overload. The second instantiation's type-check overwrote the first's `CallExpressionNode.ResolvedTarget` because both shared the same body AST.
**Now:** `EnsureSpecialization` deep-clones the body AST for each instantiation, giving each its own `CallExpressionNode` instances. Each instantiation's overload resolution is preserved independently.
**Note:** This is a pragmatic fix; see "Generic Instantiation: AST Cloning vs Side Table" in Future Architectural Changes for the planned cleaner solution.

**Related Tests:**
- `tests/FLang.Tests/Harness/generics/generic_mangling_order.f`

### Option Type Coercion from Integer Literals

**Fixed:** M16 (2026-01-19)
**Was:** `let d: i32? = 5` left the variable uninitialized. The integer literal's type was captured AFTER `UnifyTypes` had already bound the TypeVar to the Option type, so `WrapWithCoercionIfNeeded` saw both types as `i32?` and skipped creating the `ImplicitCoercionNode` for the wrap.
**Now:** `CheckVariableDeclaration` captures the original initializer type BEFORE calling `UnifyTypes`, ensuring the coercion from `comptime_int` to `i32?` is correctly detected and wrapped.

**Related Tests:**
- `tests/FLang.Tests/Harness/option/option_basic.f`

### Recursive Generic Functions Stack Overflow

**Fixed:** M14 (2026-01-19)
**Was:** Recursive generic functions (e.g., `fn count_list(lst: &List($T)) i32` calling itself) caused stack overflow during type checking. The `EnsureSpecialization` method registered the specialization key AFTER `CheckFunction` completed, causing infinite recursion when the function body contained recursive calls.
**Now:** Specialization registration (`_emittedSpecs.Add` and `_specializations.Add`) happens BEFORE `CheckFunction` is called, allowing recursive calls within the function body to find the already-registered specialization.

**Related Tests:**
- `tests/FLang.Tests/Harness/enums/enum_recursive_ok.f`

### Match Expression on Reference Types

**Fixed:** M14 (2026-01-19)
**Was:** Matching on `&EnumType` (e.g., `lst match { ... }` where `lst: &List(i32)`) failed with E1001 because `LowerMatchExpression` tried to cast the scrutinee's type directly to `EnumType`, ignoring the reference wrapper.
**Now:** `LowerMatchExpression` unwraps `ReferenceType` before casting to `EnumType`.

**Related Tests:**
- `tests/FLang.Tests/Harness/enums/enum_recursive_ok.f`

### Generic Enum Variant Construction Type Inference

**Fixed:** M14 (2026-01-19)
**Was:** `let nil: List(i32) = List.Nil` generated code with unsubstituted type parameter (`List_T` instead of `List_i32`) because `CheckMemberAccessExpression` didn't propagate the expected type to variant construction.
**Now:** `CheckMemberAccessExpression` accepts an optional `expectedType` parameter. When constructing a generic enum variant and the expected type is a concrete instantiation of the same enum, the concrete type is used instead of the template.

**Related Tests:**
- `tests/FLang.Tests/Harness/enums/enum_recursive_ok.f`

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
