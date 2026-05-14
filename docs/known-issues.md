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

### Unqualified Enum Variants Shadow Same-Named Types

**Status:** Open — workaround via renaming the type
**Affected:** name resolution; surfaces when a top-level type and a variant of another enum share a name

FLang lets you write a variant in shorthand form (no enum prefix) when the type is inferred from context — `Some(v)`, `NodeChild(n)`, etc. The resolver picks up bare `X` as an unqualified variant lookup whenever some in-scope enum has a variant called `X`. When a top-level **type** also named `X` exists, the variant wins and the type is shadowed: `X.Y` is parsed as "the `Y` member of the variant value `X`", not "the `Y` variant of the type `X`".

**Reproducer (current AST + CST):**

```flang
// flang_parser.cst:
pub type NodeKind = enum { ..., Directive, ... }

// flang_parser.ast:
pub type DeclAttribute = enum { Foreign, Inline, ... }
// (was `pub type Directive` — renamed precisely to dodge this issue)
```

With the original name `Directive`, `Directive.Inline` errored as `No variant Inline on enum NodeKind`, because `Directive` resolved to `NodeKind.Directive` first. Same shape with the AST's old `Literal` enum vs `Pattern.Literal` variant.

**Workaround (active):** rename the type when it would collide. `Directive` → `DeclAttribute`, `Literal` → `LiteralValue` in `lib/flang_parser/src/ast.f`.

**Fix direction:** replace the unqualified-variant shorthand with a leading-dot syntax — `.Some(v)` instead of `Some(v)` — modelled on `.{ ... }` for context-inferred struct literals. Bare names then always mean identifiers or types; `.Variant` always means "the named variant of whatever enum the context expects." Requires parser support for `.Ident` as a primary expression, resolver changes to drop unqualified-variant lookup, formatter emission, and a mechanical migration of every match arm + shorthand construction across stdlib / lib / tools / bootstrap / tests. Track as its own RFC before scheduling.

---

### Niche `Option(&Enum)` Match-Arm Auto-Deref Stripped the Option

**Status:** Fixed in `src/FLang.Semantics/HmAstLowering.cs`
**Affected:** `match` on `Option(&T)` where `T` is a tagged enum

`LowerMatch` had a pre-check that auto-dereferenced an `IrPointer { Pointee: IrEnum }` scrutinee so `e.* match { … }` and `e match { … }` could share the same pattern path. That check fired for niche-optimised `Option(&T)` too (also an `IrPointer { Pointee: IrEnum }`), stripping the nullable pointer down to its pointee. The match then went into the regular tagged-enum path looking for variants `Some`/`None` on the *underlying* enum — which doesn't have them — so the `Some(p)` payload binding never made it into `_locals` and any reference to `p` in the arm body emitted `E3002 Unresolved identifier`.

**Fix:** the auto-deref skips nullable pointers — only `IrPointer { Pointee: IrEnum, IsNullable: false }` is auto-dereffed. Niche `Option(&T)` keeps its IrPointer typing all the way into `LowerMatchNonEnum`, which already had a `Some(x)` binding path that strips the nullable bit and allocates a slot for `x`.

**Test:** `tests/FLang.Tests/Harness/enums/enum_match_niche_option_ref.f`

---

### Dict Entry Stride Ignores Alignment Padding

**Status:** Open — `Set(T)` works around by storing `u8` instead of `()`
**Affected:** `stdlib/std/dict.f` — `entry_byte_size`, every iteration / probe site

`Dict.entry_byte_size` returns `16 + size_of(K) + size_of(V)`, which is the raw entry size *before* trailing alignment padding. The actual entry layout includes padding so that the next entry's `hash: usize` lands on an 8-byte boundary. When the raw sum isn't already a multiple of 8 (e.g. `K = String` (16 bytes) + `V = i32` (4 bytes) → 36 raw, 40 actual; `K = OwnedString` + `V = ()` → 40 raw, 48 actual on platforms where `size_of(()) > 0`), pointer arithmetic in the iterator / probe loops walks off-stride and reads misaligned memory → heap corruption / `STATUS_STACK_BUFFER_OVERRUN` on first iter.

**Reproducer:**

```flang
let d: Dict(OwnedString, ()) = dict()
defer d.deinit()
d.set("a", ())
let it = d.iter()
let _ = it.next()        // crashes here
```

**Workaround:** avoid `Dict(K, V)` where `16 + size_of(K) + size_of(V)` isn't a multiple of 8. `Set(T)` chose `Dict(T, u8)` over `Dict(T, ())` for this reason (storing one byte instead of zero is the cheaper fix than rewriting `entry_byte_size`).

**Fix direction:** compute stride via the actual struct layout, e.g.:

```csharp
const align: usize = align_of(Entry(K, V))
const raw = 16 + size_of(K) + size_of(V)
return (raw + align - 1) / align * align
```

…or, simpler, just call `size_of(Entry(K, V))` if the type system supports it for the parameterised Entry. The current hand-rolled formula loses the trailing padding the C compiler implicitly emits.

---

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

### `Option(T)` Layout-Smashed When `T` Was Cycle-Broken

**Status:** Fixed in `src/FLang.IR/TypeLayoutService.cs`
**Affected:** mutually-recursive struct/enum chains where a struct holds the enum by value AND the enum's payload struct contains the by-value containing type through a generic indirection (`List(SubExpr)` inside `NamedInfo` inside `SubExpr.Named(NamedInfo)`).

The deferred-relower for cycle-broken layouts only re-queued types that
saw a fully-empty stub (`Size: 0, Fields.Length: 0`). It did not re-queue
types that saw a partially-laid-out type — a struct that had already
returned from `LowerStruct` with `usedStub = true` and a provisional size
computed against an inner stub. In the AST case, `NamedInfo` finished
with size 32 (its `List(SubExpr)` field had read the List stub mid-cycle
and stopped at the wrong size). `SubExpr` then sized its `Named` payload
against that 32-byte `NamedInfo`, so `sizeof(SubExpr)` was 40 — but the
C codegen later emitted `uint8_t payload[N]` from the same per-variant
size data, so the C struct definition also got `payload[32]` instead of
`payload[64]`. Every consumer that wrote a 64-byte `NamedInfo` into the
32-byte payload (`*(NamedInfo*)(&t + 8) = info`) smashed 32 bytes past
the end of the enclosing struct into the next stack local, corrupting
later reads of `n.generic_args.len` / `.cap` / `.allocator`.

Two changes fixed it:

1. `_deferredCNames: HashSet<string>` and `IsTentative(IrType)` —
   propagate "tentatively-laid-out" status through dependencies.
   `LowerStruct`/`LowerEnum` flag `usedStub = true` not only when a
   field type is a fully-empty stub but also when the field type's
   `CName` is currently in the deferred queue.
2. Re-lower pass writes new sizes into the cache without first removing
   the existing entries. Nested `LowerNominal` calls during a re-lower
   used to cache-miss and start a fresh stub cycle, sometimes pinging
   the same type back onto the queue and looping. Keeping the stale
   entry around means recursive lookups hit the cache (possibly with
   a stale size, fixed up next iteration) instead of inserting a new
   stub.

The deferred queue is in DFS post-order — dependencies before their
consumers — so a single forward pass converges. Iterating to fixpoint
isn't needed.

**Test:** `tests/FLang.Tests/Harness/enums/enum_mutual_recursion_by_value.f`

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

### Field-List `.push()` Silently No-Ops Through Some Access Paths

**Status:** Open
**Affected:** any caller mutating a nested `List` field through `obj.field.list.push(…)` or through a value-struct local — silent data loss

`List.push(self: &List(T), v: T)` mutates through a `&List` receiver. When the receiver expression chains through one or more struct field accesses, FLang sometimes resolves the chain as a temporary rvalue rather than an lvalue, so `push` mutates a copy that immediately disappears. The call compiles, runs, and is observable as a no-op at runtime.

Two reproducers, both from `lib/flang_codegen` builder development:

```flang
// (A) Local value struct, one level: m is `Module` by value.
let m = module()
m.functions.push(some_function())   // m.functions.len stays 0
```

```flang
// (B) Reference struct, two levels: self is `&FunctionBuilder`.
fn block_internal(self: &FunctionBuilder, ...) BlockBuilder {
    ...
    self.func.blocks.push(new_block)   // self.func.blocks.len stays 0
}
```

The matching one-level pattern through a reference works fine — `self.words.push(0u64)` in `stdlib/std/bitset.f` and `self.__args.push(...)` in `stdlib/std/process.f` are exercised by tests.

**Workaround:** define a small mutator on the defining type and call that. The method-call form preserves the place-ness:

```flang
// in fir.f, where Module is defined:
pub fn add_function(self: &Module, f: Function) {
    self.functions.push(f)
}

// caller — now mutates correctly:
m.add_function(some_function())
```

`lib/flang_codegen/src/fir.f` uses this pattern (`add_block`, `add_function`, `add_foreign`, `add_global`, `set_terminator`, `fresh_value_id`) so the builder in `builder.f` never has to reach into nested fields.

**Fix direction:** in lowering, audit the desugaring of `expr.field.method(...)` where `method` takes `&Self`. The compiler needs to thread the place through every intermediate field access, not materialise an rvalue copy at any step. Likely candidate: the auto-`&` insertion in UFCS / method-call lowering only fires on the outermost receiver, not on each intermediate field access. Worth a focused repro test (`tests/FLang.Tests/Harness/...`) before fixing.

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
