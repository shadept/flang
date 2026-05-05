# FLang

A statically-typed compiled language targeting C99 via a C# compiler. This glossary names the concepts the codebase, docs, and commit history use — not general programming terms.

## Language

### Compilation pipeline

**Compilation**:
The central context object that owns source files, type registries, module metadata, and global constants for one compiler invocation. All phases communicate through it; phases never reference each other directly.
_Avoid_: context, session, build (use **Compilation**)

**Source generators**:
The `TemplateExpander` phase that runs between type collection and resolution and emits source-level expansions (operator overloads, protocol implementations) before type checking.
_Avoid_: macros, codegen (codegen means C99 emission)

**HmTypeChecker**:
The Hindley-Milner type checker. Writes resolved types, targets, and operators into the previously-immutable AST as mutable semantic fields.
_Avoid_: type resolver, semantic analyzer

**InferenceEngine**:
The unification engine inside `HmTypeChecker`. Short-lived per function scope; holds active generic substitutions; applies `IInferenceCoercionRule` for built-in coercions.
_Avoid_: unifier, solver

**Constrain-then-resolve**:
The standing pattern for delayed type decisions in `HmTypeChecker`. When a piece of syntax can't pick its type until usage informs it (unsuffixed integer literals, generic `list()` learning `T` from `push`, overloaded function names used as values), the inference path returns a fresh `TypeVar`, queues the AST node into a pending list (`_unsuffixedLiterals`, `_pendingFnRefResolutions`, `_pendingSpecializations`), and resolves it in a post-pass once unification has constrained the variable. Prefer this over plumbing an `expectedType` parameter through `InferExpression` — adding hint-threading creates one-off mechanisms that don't compose with the rest of HM, biases toward the call-site context that originated the hint, and grows the surface area of every inference rule. The pending-list approach instead works in any context where the TypeVar gets unified, including struct field assignments, returns, and indirect calls — and falls out of the same machinery that already handles `list()` learning its `T`.
_Avoid_: bidirectional inference, expected-type plumbing, type hints (when the actual lever is a deferred TypeVar)

**Specialization**:
A concrete instantiation of a generic function or type produced by `HmTypeChecker.EnsureSpecialization()`. FLang uses **eager monomorphization**: generic templates are deep-cloned and type-checked per call site and never reach the IR.
_Avoid_: instantiation, monomorph

**HmAstLowering**:
The phase that lowers the type-checked AST into FIR. Desugars `for`, `if` expressions, `defer`, and `match` into basic blocks and branches.
_Avoid_: IR builder

**FIR**:
FLang's linear intermediate representation: `IrModule` → `IrFunction` → `BasicBlock` → `Instruction`. Merge points use phi-via-alloca.
_Avoid_: IR (when ambiguous), middle-end

**IrOptimizer**:
The owner of the optimization lifecycle. Iterates internally until the module is stable (capped at 10). Each pass is single-pass and returns `bool` so the orchestrator knows whether to re-run.
_Avoid_: pass manager, opt driver

**HmCCodeGenerator**:
The C99 backend. Applies `IrNameMangling.MangleFunctionName()` when emitting C; `main`, `#foreign` symbols, and `#intrinsic` symbols are never mangled.
_Avoid_: C emitter, codegen (use **HmCCodeGenerator** when specific)

### Type system

**op_deref chain**:
The fallback path the compiler walks when field access or a UFCS call fails on type `X` and `fn op_deref(self: &X) &T` is defined. The resolved chain is stored on `MemberAccessExpressionNode.OpDerefChain` or `CallExpressionNode.UfcsOpDerefChain` and replayed during lowering.
_Avoid_: deref coercion, auto-deref

**Iterator protocol**:
The contract any type used in `for` must satisfy: `iter()` returns a type whose `next()` returns `Option(E)`.
_Avoid_: iterable

**Formattable protocol**:
The contract for printable types: `fn format(self: T, sb: &StringBuilder)`. Users always call `sb.append(value)`; the generic fallback dispatches to `format()`.
_Avoid_: Display, Stringer, ToString

**Bare enum**:
An enum where every variant is payload-less, regardless of how tags are assigned. The cast `(n as MyEnum)` and the no-`op_eq`-required `==` rule both predicate on this property.
_Avoid_: payloadless enum, simple enum (see Flagged ambiguities for **naked enum**)

**Naked enum**:
The C-style subset of bare enums where at least one variant uses `= value`. All variants must be payload-less (E2047) and tags auto-increment from previous explicit values.
_Avoid_: integer enum, C enum

### Strings and ownership

**String**:
A non-owning view `{ ptr: &u8, len: usize }`. No `deinit`. Same binary layout as `u8[]`. Used for literals, parameters, and temporary references.
_Avoid_: str, view, slice (when string-specific)

**OwnedString**:
An owning string that must be freed via `deinit()`. Produced by `StringBuilder.to_string()` or `from_view()`.
_Avoid_: heap string, allocated string

**StringBuilder**:
An owning, mutable, growable buffer. `to_string()` transfers the buffer into a fresh `OwnedString` (move semantics — the builder resets).
_Avoid_: rope, buffer

**Owned(T)**:
A heap-pointer wrapper with explicit transfer tracking — `__value: &T?` plus a cleanup callback. Pair with `defer buf.deinit()` for cleanup-on-error and `buf.transfer()` for hand-off-on-success. **Strictly for raw heap pointers** from an allocator; stack values are owned by their frame, and header-owns-heap types (`StringBuilder`, `List`, `Dict`) carry their own lifecycle through the header without wrapping. Doubles as FLang's `Box`-shaped abstraction — a single owning pointer with a destructor — so a separate `Box` type would be redundant.
_Avoid_: Box, scope guard, smart pointer (use **Owned**)

### Stdlib conventions

**Allocator pattern**:
The vtable-based allocator convention used by every stdlib type that allocates: an `allocator: &Allocator?` field, `or_global()` to fall back to `global_allocator` when null, and never raw `malloc`/`free`.
_Avoid_: alloc strategy, custom allocator (the pattern itself is the term)

### Foreign function interface

**#foreign**:
The directive that marks a function as an external C symbol (no body, name not mangled) or locks a struct's layout to C ABI (no typedef emitted; provided by `#include`).
_Avoid_: extern, c-import

**#intrinsic**:
The directive marking a function the compiler recognises directly. Declared in `stdlib/core`; name is not mangled.
_Avoid_: builtin, magic

**Binding generation**:
The pipeline `flang -I <header>` runs: `ICHeaderParser` → intermediate model (`CFunction`, `CStruct`, `CEnumConstant`) → `FLangBindingGenerator` → `vendor/<name>.f`. C pointers map to `Option(&T)`; C enums to `pub const: i32`; C structs to `#foreign struct`.
_Avoid_: bindgen (use the full term)

### Build infrastructure

**BuildCache**:
The cached pre-compiled `.obj` store for companion `.c` files (stdlib's `simd.c`, `bits.c`, `io/fs.c`, `atomic.c`, plus project-local C). Lives at `<outputDir>/cache/`, indexed by `cache.json`.
_Avoid_: object cache, build artifacts

**flags_hash**:
The SHA-256 in `cache.json` over compiler path/name, profile, cflags, target triple, and `FlangVersion.Current`. Mismatch wipes the cache; this is the only bulk-invalidation trigger.
_Avoid_: cache key, fingerprint

### Test harness

**Lit-style harness**:
The data-driven `.f` test format consumed by `dotnet test.cs`. Tests live in `tests/FLang.Tests/Harness/` and embed `//! TEST:`, `//! EXIT:`, `//! STDOUT:`, `//! STDERR:`, `//! COMPILE-ERROR:`, `//! COMPILE-WARNING:`, `//! SKIP:` directives.
_Avoid_: integration tests, end-to-end tests

**Test block**:
A `test "name" { ... }` block colocated in a stdlib `.f` source file. Used for stdlib unit tests; language feature tests use the lit-style harness instead.
_Avoid_: unit test (when ambiguous), assertion block

## Relationships

- A **Compilation** owns the entire pipeline; every phase reads and writes through it.
- **Source generators** run before **HmTypeChecker**; **HmTypeChecker** runs before **HmAstLowering**.
- **HmTypeChecker** produces **Specializations**; only specializations reach **FIR**.
- **HmAstLowering** produces **FIR**; **IrOptimizer** rewrites it; **HmCCodeGenerator** emits C99 from it.
- An **OwnedString** can be viewed as a **String** (zero-copy); a **String** can be promoted to an **OwnedString** via `from_view` (allocates).
- A **StringBuilder** is consumed into an **OwnedString** via `to_string()` (move).
- Every **Naked enum** is a **Bare enum**. The reverse is not true.
- The **Allocator pattern** participates in every owning stdlib type (including **OwnedString** and **StringBuilder**).
- **Binding generation** emits `#foreign` declarations into `vendor/<name>.f`.
- The **BuildCache** is invalidated wholesale by **flags_hash** mismatch; per-entry freshness is `mtime + size`, falling back to content hash.

## Example dialogue

> **Dev:** "If I add a coercion from `i64` → `i32`, where does it go?"
> **Compiler engineer:** "As an `IInferenceCoercionRule` consulted by the **InferenceEngine**. Don't put it in **HmAstLowering** — coercions must be visible during type checking so **Specializations** unify correctly."

> **Dev:** "Can I cast `(0 as Result(i32, Error))` to construct an `Ok`?"
> **Compiler engineer:** "No — `Result` carries payloads, so it isn't a **Bare enum**. The cast is only legal on bare enums; the type checker rejects payload-carrying enums with E2020."

> **Dev:** "I want to format a custom type with `println`."
> **Compiler engineer:** "Implement the **Formattable protocol** — `fn format(self: T, sb: &StringBuilder)`. The generic `append` overload picks it up automatically."

## Flagged ambiguities

- **"Bare enum" vs "naked enum"** — both appear in the docs and source. Resolution: a **Bare enum** is *any* payload-less enum (the property the type system predicates on for casts and `==`). A **Naked enum** is the C-style *subset* where at least one variant uses an explicit `= value` tag. Every naked enum is bare, but auto-tagged enums like `enum Color { Red, Green, Blue }` are bare without being naked. Use **bare enum** when discussing semantics (cast eligibility, `==` lowering); use **naked enum** when discussing the explicit-tag form (E2047, FFI integer codes).
- **"Codegen"** — used informally for both "source generators" (the `TemplateExpander` phase) and "C code generation" (`HmCCodeGenerator`). Resolution: prefer **Source generators** for the pre-typecheck expansion phase and **HmCCodeGenerator** for C99 emission. Don't use "codegen" without qualification.
