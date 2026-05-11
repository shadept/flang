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

### RFC-010 Follow-ups

**Status:** Phases 1–5 and Phase 7 of [RFC-010](tickets/010-pattern-grammar-and-optional-flattening.md) landed. Phase 6 (proper Maranget-style exhaustiveness) deferred.

**What works:** or-patterns (`A | B | C`), guard clauses (`pat if cond`), tuple destructuring (`(a, b)`), struct destructuring (`Type { x, y, .. }`), range patterns (`a..b`, `a..=b`, `a..`, `..b`, `..=b` — `..=` is a pattern-only token), and `?.` flattening (chained `Option(Option(_))` projections collapse to `Option(_)`).

**What's deferred:**

1. **Maranget exhaustiveness.** The existing exhaustiveness check is still ad-hoc — it tracks variant names for enum scrutinees and treats any catch-all (`_` / `else` / variable / or-pattern containing one) as full coverage. New pattern forms don't yet feed a unified coverage matrix:
    - **Tuple/struct scrutinees** are not exhaustiveness-checked. A non-enum match without a catch-all silently runs no body when no arm matches (zero-init result). Pre-existing gap, not made worse by RFC-010.
    - **Range patterns** don't tile the integer domain. `n match { ..0 => …, 0 => …, 1.. => … }` over `i32` requires a `_` arm even though the ranges fully cover the domain.
    - **Or-patterns** don't distribute coverage across alternatives for non-enum scrutinees.
   Phase 6 is the right place to fix all of these together — Maranget's "useful clauses" matrix algorithm gives a uniform answer for variants, ranges, tuples, structs, and or-patterns. Until then, prefer explicit catch-all arms.
2. **Variable bindings in or-pattern alternatives** (`Some(x) | Other(x)`) — rejected with **E2105** until lowering grows binding-slot allocation. The non-binding cases (`Red | Green | Blue`, `1 | 2 | 3`, range alternatives) work today.

---

### RFC-014 Phase 2 Follow-ups

**Status:** Phase 1 (`op_call`) and Phase 2 (capturing lambdas, by-value) landed. Single-level capturing closures synthesise an anonymous `__Closure_N` struct holding captures by value, and an `op_call(self: &__Closure_N, ...)` body with capture references projected through `self`. Tests in `tests/FLang.Tests/Harness/closures/`. Coercion of capturing closures into bare `fn(...) ret` slots is rejected with **E2111**; assignment to a captured name from inside the body is rejected with **E2112** (capture is by value, so the write would only mutate the closure's own field, which is misleading).

**What's deferred:**

1. **Nested capturing closures (E2113).** A closure that captures a name an enclosing closure also captures requires transitive-capture lowering (the inner closure pulls its env field from the outer's env field). Today this is rejected up-front with E2113. Closures nested inside non-capturing closures (or whose captures don't overlap with the outer closure's) work fine.
2. **Capture-by-reference (`&local`).** RFC §"Out of scope". Initial implementation captures only by value; explicit `&local` capture syntax + lifetime story is a follow-up.
3. **Stdlib follow-ups.** Making `FilterIter` / `MapIter` generic over the callable type, and adding `box(allocator, callable)` to `std.owned`, are unblocked by Phase 2 but tracked separately. The generic-over-callable iterator change requires call resolution to handle `f(args)` where `f`'s type is a TypeVar bound to a closure NominalType — not yet wired.

---

### `match` on Value-Type Optional Doesn't Yield Ref Bindings

**Status:** Open (low priority — workarounds exist for current consumers)
**Affected:** any future wrapper that wants `&T` access into an inline `Option(T)` field where `T` is a value type

When a `match` arm binds a payload, the binding is always **by value**. `match self.field { Some(v) => &v, … }` over a struct field of type `Option(T)` gives a stack-temp pointer, not a pointer into the field — verified by mutation test.

**Workaround:** `Owned(T)` originally hit this when the RFC spec'd `value: T?`; the production design switched to `value: &T?` (niche-optimized to a nullable pointer), where the payload IS a `&T` and `Some(p) => p` works without ref-binding. Generalizes: any wrapper that needs `&T` access should store `&T?` rather than `T?`. For container types that own internal heap (`StringBuilder`, `List`, `Dict`), use the `take(&self) T` pattern instead — defer + take handles transfer without needing to wrap.

**If we ever need it:** Rust-style default binding modes (when scrutinee descends through `&`, flip pattern bindings to ByRef) is the principled fix. ~2 days in `HmTypeChecker.CheckPattern` + pattern lowering. Not currently blocking anything, so deferred.

---

### RFC-007 Follow-ups

**Status:** Phase 5 of [RFC-007](tickets/007-option-as-enum.md) deferred
**Affected:** `stdlib/core/option.f`, `src/FLang.IR/TypeLayoutService.cs`

`Option` is now a tagged enum (`enum(T) { None, Some(T) }`) with niche layout for `Option(&T)` preserved. Field-access shims (`opt.has_value` / `opt.value`) have been removed; the stdlib and tests now use `match` / `is_some()` / `unwrap()` / `unwrap_or()` / `?.` exclusively. Remaining items:

1. **None-tag depends on declaration order.** Today `None` is declared first in `stdlib/core/option.f` so it gets discriminant `0` and zero-initialized memory means `None`. A more robust fix is to teach the layout to assign Option's `None` tag deterministically regardless of source order — folded into the planned bare-enum niche optimization (§"Niche Optimization for `Option(BareEnum)`" below).
2. **Niche optimization for bare-enum payloads.** RFC-007 §Out-of-scope and the existing item below still apply: `Option(BareEnum)` should collapse to a single tag word once we shift discriminants to start at 1.

---

### Nested `$"..."` Leaks the Inner OwnedString

**Status:** Open
**Affected:** String interpolation (RFC-004) desugar

`$"outer {$"inner"} end"` desugars the inner interp to a `string_builder().to_string()` expression whose result — an `OwnedString` temporary — is passed to the outer `append`. The temporary's buffer is never reclaimed because FLang has no value-destructor (Drop) mechanism today. Output is correct; memory is not. Same shape as any `sb.append(from_view(...))` call.

**Workaround:** bind the inner to a `let` with explicit `defer deinit()`, or use form 3 (`$sb"..."`) to write directly into an outer builder.

**Fix direction:** either (a) have the outer desugar allocate with a scope-tied allocator and skip per-temporary frees, or (b) introduce destructors for `OwnedString` (wider language change).

**Test:** `tests/FLang.Tests/Harness/interpolation/nested_interp.f` (pins output, not memory).

---

### Generic Tuple Types Leak TypeVars Across Call Sites

**Status:** Open
**Affected:** `InferenceEngine.cs`, tuple type handling in overload resolution

Generic `op_cmp` over anonymous tuples of arity ≥ 2 — `fn op_cmp(a: ($T1, $T2), b: (T1, T2)) Ord` — corrupts type inference in unrelated code once the signature is registered. Concretely, `std.conv`'s `parse_f64` fails to typecheck with *"returns `f64`, got `u64`"* on `return Ok((result, pos))`, where `result: f64` but the tuple is inferred as `(u64, usize)`. Single-element generic `($T,)` works.

**Partial fixes already landed:** four `NominalType` traversals were blind to `FieldsOrVariants` when `TypeArguments.Count == 0` — the path anonymous tuples use to encode their structure. Fixed in `InferenceEngine.cs`: `CollectFreeVars` (tuple field TypeVars now get generalized), `Substitute` (fresh-replaced on `Specialize`), `Zonk` (resolved at the end of inference), `ResolveNominal` (bound TypeVars surface through union-find). The single-arity case started working after these.

**Reproduction gap:** minimal standalone repros (separate test file with `Result((u64, usize), E)` + `Result((f64, usize), E)` plus the generic tuple `op_cmp`) pass. Only `std.conv` triggers the failure when compiled as part of the stdlib. Next step is bisecting `std.conv` down until the error disappears.

**Leads — further paths that read anon tuple `FieldsOrVariants` without going through `Resolve` first:**

1. **`AnonymousStructCoercionRule.TryApply`** at [CoercionRules.cs:190-222](src/FLang.Semantics/CoercionRules.cs:190). Reads `fromStruct.FieldsOrVariants[i].Type` and unifies against target fields. If the tuple field is a TypeVar already bound via union-find, the coercion rule sees the unresolved TypeVar; binding it again could misbind.

2. **`UnifyInternal` for anon types** at [InferenceEngine.cs:248-256](src/FLang.Semantics/InferenceEngine.cs:248) — recurses into fields via `UnifyInternal`, but `return new NominalType(..., na.FieldsOrVariants, ...)` returns the *first operand's* fields verbatim. If callers cache that returned type on an AST node and later read its fields without a fresh `Resolve`, they see stale TypeVars that were bound by a later unification to a different concrete type.

3. **Identity short-circuit** at [InferenceEngine.cs:146-161](src/FLang.Semantics/InferenceEngine.cs:146) — `a.Equals(b)` treats TypeVars in anon-type fields as wildcards, so `(T1, T2)` "equals" `(f64, usize)`. Fields unify, then `return a` — so the signature's tuple NominalType (with original TypeVar IDs) propagates back to the caller instead of the concrete one. If the signature instance is shared across call sites, those original TypeVar IDs accumulate bindings across calls.

4. **Specialization caching** at [HmTypeChecker.Specialization.cs](src/FLang.Semantics/HmTypeChecker.Specialization.cs) — the key function (`AppendTypeSpecKey`) correctly distinguishes anon tuple instances by field types, but worth sanity-checking that `EnsureSpecialization` isn't reusing a spec across incompatible concrete type bindings.

Most-likely culprit: #3 combined with the signature's NominalType instance being shared across all call sites of `op_cmp` (one object per `pub fn op_cmp(...)` declaration, reused for every call).

**Workaround:** `std.cmp` does not ship generic tuple `op_cmp` overloads yet. Define `op_cmp` on your concrete tuple type (`fn op_cmp(a: (i32, String), b: (i32, String)) Ord`) until the root cause is fixed. The `std.sort` public API is already compatible — adding tuple overloads later is additive.

---

### Overloaded Functions Can't Be Used As First-Class Values

**Status:** Open
**Affected:** Type inference when a bare function name is passed as a `fn(...)` value

`op_cmp` is overloaded across many types. Passing it as a function-typed argument — e.g. `_quicksort_range(s, 0, s.len, op_cmp)` — fails because overload resolution has no expected type at the point the name is taken as a value, and the compiler picks the first registered overload (typically `op_cmp(String, String)`) regardless of context.

**Workaround:** Wrap in an inline lambda: `fn(a: T, b: T) Ord { return op_cmp(a, b) }`. This defers overload resolution until the call site, where T is concrete. The `std.sort` wrappers (`sort(s)`, `quicksort(s)`, etc.) use this pattern internally.

**Future:** Context-directed overload resolution — when a bare function name is coerced to a `fn(...)` type, pick the overload whose signature matches.

---

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


### ~~`defer` in a Nested Block Escapes Its C Scope~~

**Status:** Fixed
**Affected:** C codegen — `defer` lowering across nested blocks

A `defer` registered inside a nested lexical block (e.g. inside an `if` branch or a `for` body) used to be emitted only at the outer function's exit path. The deinit call ended up past the closing `}` of the block that declared its allocas, so the generated C referenced undeclared identifiers (`error C2065: 'alloca_33': undeclared identifier`) — and on targets that accepted it, the deinit fired long past the resource's live range.

**Fix** (in `HmAstLowering`): every `BlockExpressionNode` is now a defer scope. `PushDeferScope`/`PopDeferScope` bracket each block; the `_deferStack` records defers in LIFO, and a parallel `_deferScopeMarks` stack records the stack depth at each scope entry. On a normal scope exit the scope's defers are emitted and popped. `return` emits every active defer (down to depth 0); `break`/`continue` emit defers from the top down to the depth recorded when the loop was entered. All emissions respect `_currentBlock.IsTerminated`.

**Regression tests** (under `tests/FLang.Tests/Harness/defer/`):
- `defer_nested_block_heap.f` — the exact shape that crashed `examples/tree`.
- `defer_{break,continue,return}_unwinds.f` — pins the LIFO unwind order.
- `defer_{break,continue,return}_no_fallthrough.f` — pins that code after these jumps never runs, using a side-effect counter returned as the exit code.
- `defer_nested_loops.f` — pins that inner `break` fires only the innermost loop's defers.

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

The parser only accepts `import` statements (including `pub import`) before any declarations. Cannot place imports closer to where they're used or before test blocks at the bottom of a file.

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

---

### Niche Optimization for `Option(BareEnum)`

**Status:** Not implemented
**Affected:** `TypeLayoutService` — Option layout for payload-less enum types

Today only `Option(&T)` has a niche-based layout (null pointer encodes `None`). Every other `Option(T)` — including `Option(E)` where `E` is a payload-less enum — uses the full `{ has_value: bool, value: T }` struct.

**Proposal:** when `E` is a bare enum (no variants have payloads), shift discriminants to start at 1 instead of 0 so tag 0 can represent `None`. `Option(E)` collapses to a single enum-sized word. Matches the nullable-pointer trick from `Option(&T)`.

**Impact:** discriminant values of bare enums change. FFI code must continue to map between C integer codes and FLang variants *by name* — never cast raw discriminants. This is now documented in spec.md §2.5 and §2.7.

**Related:** `TypeLayoutService.LowerNominal` (where `Option(&T)` niche lives), `HmTypeChecker.Declarations.cs` `nextTag` assignment.
