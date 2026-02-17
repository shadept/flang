# Known Issues & Technical Debt

This document tracks known bugs, limitations, and technical debt in the FLang compiler.

---

## How to Add Items

When you discover a bug or limitation:

1. Add it to the appropriate section
2. Include: Status, Affected components, Problem description, Solution, Related tests
3. Update when fixed (remove or move to bottom)

---

## Open Issues

### Generic Parameter Binding Order Not Tracked

**Status:** Deferred
**Affected:** Type inference for generic function calls

`$T` syntax distinguishes binding sites (`$T`) from use sites (`T`), but both become `GenericParameterType("T")` in the type system — the distinction is lost after parsing.

**Current workaround:** Anonymous struct arguments are deferred during overload resolution, and TypeVars are accepted as wildcards during generic binding. Handles the common case.

**Future:** Track `IsBindingSite` on `GenericParameterType` to enable proper two-pass type inference based on binding order.

---

### Foreign Function Argument Type Checking Bypassed

**Status:** Open
**Affected:** TypeChecker — foreign function calls

Calls to `#foreign fn` may bypass strict argument type checking, allowing implicit narrowing (e.g., passing `usize` to `i32` param) without error. Normal functions correctly reject this with E2011.

**Workaround:** Ensure `#foreign fn` declarations match the types you intend to pass, or explicitly cast arguments.

---

### Array-to-Slice Coercion in Struct Construction

**Status:** Open (1 SKIP test)
**Affected:** C codegen — struct field initialization

Assigning `[T; N]` to a `T[]` slice field in a struct literal passes type checking but fails at C compilation — the coercion is not emitted for struct field initializers.

**Workaround:** Pass the array through a function accepting `T[]`:

```flang
fn make_wrapper(data: u8[]) Wrapper {
    return Wrapper { data = data, pos = 0 }
}
```

**Test:** `tests/FLang.Tests/Harness/structs/struct_slice_field_init.f` (SKIP)

---

### Error Code Inconsistencies

**Status:** Minor
**Affected:** Error reporting

1. **E3006/E3007:** `break`/`continue` outside loop is caught during lowering (E3006/E3007), not semantic analysis (E2006/E2007). Documentation and implementation are out of sync.
2. **E2015:** Used for both "intrinsic requires one type argument" and "missing field in struct construction". E2019 (documented for missing fields) is never emitted.

---

### `#foreign` Directive Doesn't Manage C Includes

**Status:** Open
**Affected:** C codegen preamble, `#foreign fn` declarations

Foreign function declarations (`#foreign fn`) rely on the C codegen preamble (`HmCCodeGenerator.cs`) having the right `#include` headers. When a new foreign function needs a header not already included (e.g., `ioctl` needs `<sys/ioctl.h>`), the codegen preamble must be manually updated.

**Future:** Allow `#foreign` to specify required C headers, or auto-detect them from a mapping table.

---

## Deferred Features

### FFI Pointer Returns and Casts

**Status:** Not implemented
**Affected:** Foreign calls returning pointers, `as` casts for FFI types

Call result locals from `#foreign fn` are still typed as `int` in generated C. Full `as` cast support needed for memory tests.

**Tests blocked:**

- `tests/FLang.Tests/Harness/memory/malloc_free.f`
- `tests/FLang.Tests/Harness/memory/memcpy_basic.f`
- `tests/FLang.Tests/Harness/memory/memset_basic.f`

---

### Bounds Checking on Arrays

**Status:** Partial

Slices (`T[]`) have runtime bounds checking via `op_index` in `core/slice.f`. Built-in array (`[T; N]`) indexing uses unchecked pointer arithmetic.

**Future:** Emit bounds checks for array indexing, add `--no-bounds-check` flag for release builds.

---

### Nested Generics Not Supported in Type Positions

**Status:** Open
**Affected:** Parser — type expressions

Nested generic types like `Result(Option(u64), Error)` cause parse errors (`expected CloseParenthesis`). The parser cannot distinguish nested generic arguments from function call syntax when type parameters themselves have type parameters.

Additionally, tuples inside enum variants are flattened: `Result((i64, usize), E)` treats `Ok` as having 2 bindings instead of 1 tuple, breaking `unwrap()` and pattern matching.

**Workaround:** Use concrete wrapper structs instead of nested generics or tuples in generic type parameters.

---

## Temporary Limitations

### Import Statements Must Be At Top of File

**Status:** Open (parser limitation)

The parser only accepts `import` statements before any declarations. Cannot place imports closer to where they're used or before test blocks at the bottom of a file.

**Workaround:** Place all imports at the top.

---

### Minimal I/O (`core/io.f`) Uses C stdio

**Status:** Intentional stopgap

`print`/`println` use C `printf` with `"%.*s"`. Embedded NUL bytes truncate output.

**Future:** Replace with `std/io/fmt.f` using `fwrite` in Milestone 19.

---

## Future Architectural Changes

### Generic Instantiation: AST Cloning vs Side Table

**Status:** Technical debt

Currently deep-clones function body AST for each generic instantiation so each has independent `CallExpressionNode.ResolvedTarget`. Works but is wasteful.

**Proposed:** Replace with a side table `Dictionary<(CallExpressionNode, SpecializationKey), FunctionDeclarationNode>` to keep AST immutable.

**Related:** `TypeChecker.CloneStatements()`, `TypeChecker.CloneExpression()`, `EnsureSpecialization()`

---

### Implicit Reference Passing for Large Structs

**Status:** Implemented
**Affected:** HmAstLowering, HmCCodeGenerator, IrModule, TypeLayoutService

Large structs/enums (size > 8 bytes) are now passed by implicit reference and returned via caller-provided hidden slot:
- **Params:** `IrParam.IsByRef = true`, callee receives pointer; reads load through pointer, writes use copy-on-write (alloca + load + store)
- **Returns:** `IrFunction.UsesReturnSlot = true`, hidden `__ret` pointer prepended to params; callee stores result through `__ret` and returns void
- **Call sites:** Caller alloca + store for large value args; alloca return slot + load for large returns
- **Function pointers:** `IrFunctionPtr` stores original types (for name mangling); C codegen applies ABI transformation via `GetAbiFunctionPtr()` when emitting C function pointer types
- **Direct calls, indirect calls (vtable), for-loop iter/next, operator overloads** all handled uniformly via `EmitFLangCall` helper
- **Foreign functions** excluded from transformation (C ABI preserved)

**Test:** `tests/FLang.Tests/Harness/structs/struct_large_pass_return.f`

---

### Move to SSA Form

**Status:** Post-self-hosting consideration

FIR uses named local variables (not SSA). Would simplify optimizations. Keep current design until self-hosting.
