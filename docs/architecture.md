# FLang Compiler Architecture

## Compilation Pipeline

```
Source → Lexer → Parser → Source Generators → HmTypeChecker → HmAstLowering (FIR) → Optimizations → HmCCodeGenerator → C99 → GCC/Clang → Native
```

All phases communicate through a central `Compilation` context object — phases never reference each other directly. `Compilation` owns source files, type registries (structs, enums, specializations), module metadata, and global constants.

## AST Design

- **Top-down only.** No parent pointers. Context is passed down during traversal, never looked up.
- **Two-phase properties:** Parser creates immutable syntactic data (names, operators, structure). `HmTypeChecker` later writes mutable semantic fields (resolved types, targets, operators). Semantic fields are nullable, null until type checking.
- **Analysis logic lives in dedicated solvers/visitors**, never in AST node methods.

## Type System

- **`InferenceEngine`** handles type unification and resolution. Short-lived per function scope. Holds active generic substitutions. Coercion rules (e.g., `u8` → `u16`, `comptime_int` → `i32`) are implemented via `IInferenceCoercionRule`.
- **Eager monomorphization.** Generic functions are instantiated with concrete types during type checking. `HmTypeChecker.EnsureSpecialization()` deep-clones the generic body, substitutes type parameters, and type-checks the specialization. Generic templates never reach IR.
- **Iterator protocol:** Any type used in `for` must have `iter()` returning a type with `next()` returning `Option[E]`.
- **`TypeLayoutService`** computes memory layouts (alignment, offsets) for struct types, used by lowering for implicit reference passing of large values.
- **`op_deref` fallback:** When `ResolveFieldAccess()` can't find a field on a nominal type, or when UFCS call resolution fails, the compiler tries `TryResolveOperator("op_deref", [&Type])`. For field access, the resolved function is appended to `MemberAccessExpressionNode.OpDerefChain`. For UFCS calls, the chain is stored in `CallExpressionNode.UfcsOpDerefChain`. Lowering replays the chain as function calls before the field GEP or function call.

## Intermediate Representation (FIR)

Linear IR: `IrModule` → `IrFunction` → `BasicBlock` → `Instruction`. Merge points use phi-via-alloca (allocate slot, store from each branch).

Complex constructs (`for`, `if` expressions, `defer`, `match`) are desugared into basic blocks and branches during AST → FIR lowering.

## Optimization Passes

Entry point: `IrOptimizer.Run(module)`. The compiler does not manage passes or cascade loops directly — `IrOptimizer` owns the full lifecycle and iterates internally until the module is stable. Adding, removing, or reordering passes is transparent to `Compiler.cs`.

Each orchestrator iteration runs **function-level optimizations first, then the inliner**. This order matters: the inliner's heuristic uses raw instruction count against a fixed threshold, so shrinking a function before the inliner sees it can turn an ineligible call into an eligible one. It also saves cascade iterations — a shrunk function reaches the inliner the same round it was produced.

Individual passes are **single-pass** and do not iterate internally. Each pass returns `bool` so the orchestrator knows whether to re-run. Cascading eliminations fall to the next orchestrator iteration (capped at 10 iterations as a safety net against oscillation).

- **Inlining** (`InliningPass`): Function inlining with its own internal cascade (leaves first).
- **Peephole** (`PeepholeOptimizer`): Local, sliding-window patterns only — store-load forwarding and copy fusion (load+store → `CopyInstruction`, GEP+load → `CopyFromOffsetInstruction`, GEP+store → `CopyToOffsetInstruction`).
- **Dead code elimination** (`DeadCodeElimination`): Removes side-effect-free instructions with zero-use results.
- **Dead store elimination** (`DeadStoreElimination`): Removes writes to non-escaped allocas whose contents are never read. Alloca identity is tracked by name (`LocalValue` instances aren't reliably reference-equal across the IR).
- **Shared helpers** (`IrInstructionHelpers`): `Resolve`, `GetOperands`, `GetResult`, `RewriteOperands`. Used by all passes and the inliner.

Per-function order inside `IrOptimizer.OptimizeFunction`: Peephole → DCE → DSE → DCE, then a single final `Rebuild` that applies substitutions and removes dead instructions. The second DCE sweeps orphans exposed by DSE in the same iteration; deeper cascades fall to the next orchestrator iteration.

`IrOptimizer` is also the place to gate passes on future compiler flags (`--O0`, `--O2`, debug builds).

### Future IR optimizations

The following are redundancies in the generated IR that Clang eliminates at `-O2` but could be addressed in FIR for better unoptimized debug builds and reduced C output size. `match_arm_control_flow.f` is a good test case — Clang collapses `loop_break()` to `ret i32 33` and `early_return()` to a branchless `select`.

- **Constant enum construction:** `Action.Stop` (payload-less) generates 3 allocas + load + store; could emit a single constant struct.
- **Redundant scrutinee copy:** match lowers the scrutinee into a second alloca for tag extraction even when the original is already addressable.
- **Dead block elimination:** `break`/`continue`/`return` in expression position emit a `dead` basic block for subsequent unreachable code; these could be pruned.
- ~~**Dead stores / unused allocas**~~ — Implemented. See `DeadStoreElimination`. Limitations: (a) large allocas that go through a `memset`-zero-init call are kept alive because the call is treated as a generic escape; recognising `memset`/`memcpy` as writes-only-to-arg would unlock these. (b) Partial dead stores (one field read, another written and never read) conservatively keep the whole alloca live.

## Build Cache

Companion `.c` files that ship alongside `.f` sources (stdlib's `simd.c`, `bits.c`, `io/fs.c`, `atomic.c`, plus any project-local C) are pre-compiled to `.obj` via `BuildCache` before the final link. Warm builds skip the C compile and just link the cached objects.

**Layout.** Colocated with build outputs at `<outputDir>/cache/`:

```
build/
  fcsv.exe
  cache/
    stdlib/simd.obj
    stdlib/bits.obj
    cache.json
```

- Objects live under `<dep>/<basename>.obj`. `dep` is `stdlib` for files under the stdlib tree, else the project name (or `local` for single-file builds).
- `cache.json` is the only metadata. Schema: `{ version, flags_hash, entries: { "<dep>/<basename>.obj": { src, src_mtime_unix, src_size, src_hash } } }`.

**Invalidation.** Two scopes:

- `flags_hash` at the top of `cache.json` — SHA-256 over compiler path + name, profile (release/debug), cflags, target triple (`<os>-<arch>`), and `FlangVersion.Current`. Mismatch on load wipes the cache contents and starts fresh. This is the only thing that triggers a bulk invalidation.
- Per-entry `src_mtime_unix` + `src_size` — cheap freshness check on every lookup. On mismatch we fall back to a content hash before declaring a miss; this tolerates `git checkout`, `cp` without `-p`, NFS clock skew, etc., without forcing a recompile when the bytes are actually unchanged.

**Writes.** Object publication uses atomic temp+rename so a torn write leaves the old `.obj` in place and the next run notices via the freshness check. The manifest is read-modify-written without cross-process coordination — under concurrent writers (test harness) the natural failure mode is a lost manifest entry, which causes one redundant recompile on the next miss. Bounded, self-healing, no correctness risk.

**Lifecycle.** The cache lives inside `build/`; `flang clean` (or `rm -rf build/`) reclaims it. There are no separate `flang cache` subcommands and no TTL/pruning machinery — the build directory is the unit of truth.

## C99 Backend

- **Name mangling only in codegen.** IR preserves base function names. `HmCCodeGenerator` applies `IrNameMangling.MangleFunctionName()` when emitting C. `main` is never mangled.
- **Foreign/intrinsic symbols are not mangled.** `#foreign` and `#intrinsic` calls use their declared names directly.
- **Foreign structs skip codegen.** `IrStruct.IsForeign` structs have no typedef or definition emitted — the `#include` of the original C header provides them. Their `CName` is the original C name (e.g. `Color`), not mangled.
- **Intrinsics declared in `stdlib/core`** with `#intrinsic` directive.

## C FFI Binding Generation

The compiler can parse C headers and generate FLang bindings via the `-I` flag:

```
flang -I raylib.h -L libraylib.a main.f
```

**Pipeline:** CLI receives `-I <header>` → `ICHeaderParser` (CppAst implementation) parses the header → `FLangBindingGenerator` produces FLang source → written to `vendor/<name>.f` → module compiler discovers it via `import vendor.<name>`.

**Architecture:**
- `ICHeaderParser` (`src/FLang.CLI/FFI/`) is an abstraction interface returning intermediate model types (`CFunction`, `CStruct`, `CEnumConstant`). The CppAst implementation can be swapped.
- `FLangBindingGenerator` converts the intermediate model to FLang source text.
- C pointers map to `Option(&T)`. C enums map to `pub const: i32`. C structs map to `#foreign struct`.
- Foreign header paths propagate through `IrModule.ForeignIncludes` and are emitted as `#include` directives in the generated C code.

## Source Generators

`TemplateExpander` (referred to as "source generators") runs between type collection and resolution. Generates source-level expansions (e.g., operator overloads, protocol implementations) before type checking.

## Compile-Time Context

`Compilation.CompileTimeContext` provides platform/OS/arch/runtime values for `#if` directive evaluation during parsing.

## Language Server (LSP)

The compiler includes an in-process LSP server (`FLang.Lsp`) invoked via `--lsp`. It reuses the same compilation pipeline — parser, source generators, type checker — so editor diagnostics match compiler output exactly. Features: hover, go-to-definition, type definition, document symbols, inlay hints (inferred types), signature help, and live diagnostics. `FLangWorkspace` manages document state with incremental re-analysis on file changes.

## Diagnostics

All phases report errors via `Diagnostic` objects with `SourceSpan` locations. Phases add diagnostics and continue when possible — exceptions are not used for user-facing errors. The CLI aggregates and prints diagnostics before exiting.

## Testing

Data-driven lit-style tests. Self-contained `.f` files with embedded metadata:

```flang
//! TEST: test_name
//! EXIT: 0
//! STDOUT: expected output
//! STDERR: expected error
//! COMPILE-ERROR: E0001
//! COMPILE-WARNING: W0001
//! SKIP: reason
```

The harness compiles and runs each test, asserting exit code, stdout, and stderr match metadata. `COMPILE-ERROR`/`COMPILE-WARNING` tests assert compilation fails or warns with the specified error code.

**Test placement:** Language feature tests go in `tests/FLang.Tests/Harness/`. Stdlib tests are colocated in `.f` source files using `test "name" { ... }` blocks.
