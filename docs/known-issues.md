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

### `defer x.deinit()` + `return x.to_string()` Double-frees

**Status:** Open — workaround in place across stdlib and bootstrap
**Affected:** `StringBuilder.to_string`, `OwnedString`, any builder-style transfer

`defer` captures arguments at the defer statement (per RFC-006). Calling
`defer sb.deinit()` then `return sb.to_string()` is intended to be safe —
`to_string` resets `sb.cap = 0` so the deferred `deinit` becomes a no-op.
In practice the deferred call sees the StringBuilder's pre-`to_string`
state, frees the buffer the returned `OwnedString` points at, and the
caller observes `owned.len == 0` (the OwnedString struct lives on the
freed stack slot or its bytes are clobbered).

**Workaround:** drop the `defer` whenever the function returns the
transferred OwnedString. Bind locals explicitly and `deinit()` them after
the return value is built. Example:

```
const a = strip_carriage_returns(src)
const b = trim_lines(a.as_view())
const result = ensure_trailing_newline(b.as_view())
a.deinit()
b.deinit()
return result
```

**Fix direction:** decide capture semantics — either document defer as
by-reference (and adjust codegen) or honour the snapshot semantics and
drop the comment in `string_builder.to_string` that claims the
defer-then-transfer pattern works.

### `defer x.deinit()` + Return Expression Reading `x` (Second Form)

**Status:** Open — same root cause as the "defer + to_string" entry
above; manifests through any field/method read on `x` inside a return
expression, not just `to_string`
**Affected:** `defer owned.deinit()` followed by any expression that
materialises a view or field of `owned` (e.g. `owned.as_view()`,
`owned.ptr`, `owned.len`) in the function's return value

Reproduced with `tests/FLang.Tests/Harness/`-shaped single-file
fixtures (see `/tmp/repro/case_a.f` shape):

```
pub fn main() i32 {
    let s = make_hello()
    defer s.deinit()
    return len_of(s.as_view())   // len_of receives empty String
}
```

The emitted C orders `deinit(s)` BEFORE the call argument evaluation:

```c
deinit__...(s);                  // defer fired
as_view__...(__ret, s);          // s.ptr = NULL, s.len = 0 — view is empty
len_of__...(__ret);              // sees len = 0
```

`OwnedString.deinit` zeroes `ptr`/`len`/`allocator` (see
`stdlib/std/string.f` `deinit`), so the subsequent reads observe the
post-deinit state, not the pre-deinit one. Identical mechanism to the
documented `defer sb.deinit()` + `return sb.to_string()` zero-length
case: the defer fires before the return expression evaluates.

**Workaround:** drop the `defer` and call `deinit()` explicitly after
the return value has been materialised:

```
const result = len_of(s.as_view())
s.deinit()
return result
```

**Fix direction:** same as the parent entry — defer's snapshot
semantics need to be decided. Either defer captures at the point of
return (so the value passed to the inner call has already been
read by then), or codegen must emit the deferred call after every
sub-expression of the return statement has been evaluated. The
current ordering — defer-then-return-expression — is consistent with
"defer fires when the function is about to return," but it fires too
early relative to the return expression's operand evaluation.

### `std.io.file` Was Cross-Platform-Broken in Two Ways

**Status:** Fixed in `stdlib/std/io/file.f`

1. **`open(path, O_WRONLY|O_CREAT|O_TRUNC)` deleted files on Windows.** The
   Linux constant `O_CREAT = 64` is `_O_TEMPORARY` on Windows — files
   opened with it disappear on `close`. Flags now go through
   `open_flags(mode)` which switches on `platform.os`. Windows reads and
   writes also force `_O_BINARY`, so CRLF translation never corrupts
   byte-exact round-trips.
2. **`read_all` overwrote length on each iteration** (`sb.len = n` instead
   of `sb.len += n`), so any file larger than one read window was
   truncated. The same function used `defer sb.deinit()` with a final
   `return Ok(sb.to_string())`, hitting the defer bug above and returning
   zero-length OwnedStrings even for small files. Both fixed; the loop
   accumulates and the function deinits manually on error paths.

`open(path, flags)` now takes a third `mode` argument (POSIX requires it
when `O_CREAT` is set). Callers were already going through `open_file`.

---

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

### Bootstrap Lexer Can't Reach `$(args)"..."` / `$ident"..."` From `tokenize()`

**Status:** Open
**Affected:** `lib/flang_parser/src/lexer.f`, bootstrap parser

`mark_next_string_interp()` requires the parser to call it between tokens. The current bootstrap parser drains `tokenize()` into a `List(Token)` upfront, so the hook is unreachable and only the inline `$"..."` form is recognised. The other two forms fall back to `Dollar + (group / identifier) + StringLiteral`. The bootstrap parser (`lib/flang_parser/src/parser.f`, v0.3.0) handles the fallback shape directly: a `$` token followed by an identifier or a balanced `(...)` then `StringLiteral` lands in an `InterpolatedStringExpr` CST node, just without the structured hole/segment children.

**Fix direction:** drive `next_token()` from the parser instead of pre-tokenising.

---

### Nested `$"..."` Leaks the Inner OwnedString

**Status:** Open
**Affected:** String interpolation (RFC-004) desugar

`$"outer {$"inner"} end"` desugars the inner interp to a `string_builder().to_string()` expression whose result — an `OwnedString` temporary — is passed to the outer `append`. The temporary's buffer is never reclaimed because FLang has no value-destructor (Drop) mechanism today. Output is correct; memory is not. Same shape as any `sb.append(from_view(...))` call.

**Workaround:** bind the inner to a `let` with explicit `defer deinit()`, or use form 3 (`$sb"..."`) to write directly into an outer builder.

**Fix direction:** either (a) have the outer desugar allocate with a scope-tied allocator and skip per-temporary frees, or (b) introduce destructors for `OwnedString` (wider language change).

**Test:** `tests/FLang.Tests/Harness/interpolation/nested_interp.f` (pins output, not memory).

---

### Overloaded Functions Can't Be Used As First-Class Values

**Status:** Open
**Affected:** Type inference when a bare function name is passed as a `fn(...)` value

`op_cmp` is overloaded across many types. Passing it as a function-typed argument — e.g. `_quicksort_range(s, 0, s.len, op_cmp)` — fails because overload resolution has no expected type at the point the name is taken as a value, and the compiler picks the first registered overload (typically `op_cmp(String, String)`) regardless of context.

**Workaround:** Wrap in an inline lambda: `fn(a: T, b: T) Ord { return op_cmp(a, b) }`. This defers overload resolution until the call site, where T is concrete. The `std.sort` wrappers (`sort(s)`, `quicksort(s)`, etc.) use this pattern internally.

**Future:** Context-directed overload resolution — when a bare function name is coerced to a `fn(...)` type, pick the overload whose signature matches.

---

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
