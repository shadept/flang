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

### Parser Crash: `while` Keyword Not Recognized

**Status:** Open
**Affected:** `Parser.cs`
**Problem:** `while` is not a FLang keyword — the language uses `loop` with `break` for loops. Using `while` causes parse errors or crashes (e.g. `GenericTypeNode` crash when `{` is misinterpreted).
**Workaround:** Use `loop { if condition { break } ... }` instead of `while condition { ... }`.

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

1. **E3006/E3007:** `break`/`continue` outside loop is now caught during parsing (E1006/E1007). E3006/E3007 remain in lowering as safety net but should be deprecated once parser validation is proven reliable.
2. **E2015:** Used for both "intrinsic requires one type argument" and "missing field in struct construction". E2019 (documented for missing fields) is never emitted.

---

### `#foreign` Directive Doesn't Manage C Includes

**Status:** Open
**Affected:** C codegen preamble, `#foreign fn` declarations

Foreign function declarations (`#foreign fn`) rely on the C codegen preamble (`HmCCodeGenerator.cs`) having the right `#include` headers. When a new foreign function needs a header not already included (e.g., `ioctl` needs `<sys/ioctl.h>`), the codegen preamble must be manually updated.

**Future:** Allow `#foreign` to specify required C headers, or auto-detect them from a mapping table.

---

### ~~Recursive Enum Type Layout Incorrect When Containing Generic Containers~~

**Status:** Fixed
**Affected:** TypeLayoutService, C codegen — recursive enum types with generic containers

Recursive enums containing generic containers (e.g., `enum Expr { Add(List(Expr)) }`) had incorrect payload sizes in generated C. The type layout cache's stub-breaking mechanism for recursive types caused stale size=0 stubs to be used when computing enum payload sizes, resulting in undersized `payload[]` arrays and segfaults at runtime. Additionally, enum codegen did not emit alignment padding between tag and payload, causing C `sizeof` to disagree with the IR's computed size.

**Fixed by:**
- Deferred re-lowering: types computed with stale stubs are re-lowered after all dependencies have final sizes
- `ResolveEnum` in `CollectIrType` to prefer the canonical cached version
- Enum C codegen now emits `__attribute__((aligned(N)))` and `__pad[]` when payload alignment exceeds tag alignment

**Tests:** `enum_recursive_via_list.f`, `struct_recursive_via_list.f`

---

### json.f Cannot Compile Due to writer.f Duplicate Definitions

**Status:** Open
**Affected:** stdlib — `std/io/writer.f`, `std/encoding/json.f`

`json.f` imports `writer.f`, which fails type checking with E2103 (duplicate definition of `write_byte` and `write_str`). This blocks all json.f compilation and testing. The recursive type layout issue that previously affected `JsonValue` is now fixed — the remaining blocker is the writer.f duplicate function problem.

**Workaround:** None.

---

---

### Option.map Resolves Function Param as Enum Variant

**Status:** Workaround applied
**Affected:** Semantic analysis — generic function specialization with enum types

When `Option(T).map(f: fn(T) U)` is specialized with an enum type (e.g., `T = JsonValue`), the compiler incorrectly resolves the function parameter `f` as an enum variant constructor call instead of a function call. Produces `E3037: Variant 'f' not found in enum`.

**Workaround:** `List.get` rewritten to avoid calling `Option.map`, preventing the specialization from being triggered.

**Future:** Fix name resolution in generic specialization to prefer function parameters over enum variant lookup.

---

### ~~Never Type Not Implemented as Bottom Type~~

**Status:** Fixed
**Affected:** Type inference, match expressions, control flow expressions

`never` is now a proper bottom type. It unifies with any type `T` (resolving to `T`), so diverging expressions like `panic()` and `exit()` can appear in match arms alongside concrete types. The lowering and C codegen skip unreachable code after `never`-returning calls.

**Fixed by:**
- Unification rule in `InferenceEngine.UnifyInternal`: `never` unifies with any type
- `panic()` and `exit()` return types changed to `never` in `stdlib/core/panic.f`
- Lowering skips coercions and dead stores after `never`-typed expressions
- C codegen treats `IrNeverPrim` like `IrVoidPrim` for call/return emission

**Test:** `tests/FLang.Tests/Harness/generics/never_type_basic.f`

---

### ~~Break, Continue, and Return Cannot Appear in Expression Position~~

**Status:** Fixed
**Affected:** Parser, type checker, lowering — control flow in expressions

`break`, `continue`, and `return` are now `ExpressionNode` subclasses with type `never`. They can appear in match arm bodies (and continue to work in statement position via `ExpressionStatementNode` wrapping). The parser restricts placement — they are not valid in arbitrary sub-expression positions (e.g., function arguments). `break`/`continue` outside loops are caught at parse time (E1006/E1007); lowering retains E3006/E3007 as safety net.

**Fixed by:**
- `BreakNode`, `ContinueNode`, `ReturnNode` extend `ExpressionNode` (replacing old `StatementNode` subclasses)
- Parser recognizes them in statement position and match arm bodies, with `_loopDepth` tracking for break/continue validation
- Type checker infers all three as `never`, which unifies with other arm types via existing never-unification rule
- Lowering handles them in `LowerExpression`, emitting control flow IR and returning `IrNeverPrim`

**Test:** `tests/FLang.Tests/Harness/match/match_arm_control_flow.f`

---

### ~~List(T) Generic Monomorphization Produces Wrong Specialization~~

**Status:** Fixed
**Affected:** C codegen — generic function instantiation

Fixed by including the return type in both the specialization key (`BuildSpecKey`) and the C function name mangling (`IrNameMangling.MangleFunctionName`). Specializations with identical parameter types but different return types now produce distinct keys and distinct C symbols.

**Test:** `tests/FLang.Tests/Harness/generics/generic_multi_return_type.f`

---

### ~~No Bitwise NOT Operator~~

**Status:** Fixed
**Affected:** Parser, operators

Added `~` as a prefix unary operator. Built-in for all integer types (same as `&`, `|`, `^`). Produces compile error E2017 on `bool` and floating-point types. Supports user-defined `op_bnot` via operator function dispatch.

**Test:** `tests/FLang.Tests/Harness/operators/bitwise_not.f`, `bitwise_not_bool_error.f`, `bitwise_not_float_error.f`

---

### Inlined Helper Function Stack Variable Codegen

**Status:** Open
**Affected:** C codegen — function inlining with local arrays

Non-pub helper functions using `let buf: [u8; 1] = [0; 1]` followed by vtable dispatch generate C code referencing undeclared `alloca_1` identifiers.

**Workaround:** Use `let byte = b; w.write(slice_from_raw_parts(&byte, 1))` instead of local array pattern.

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
