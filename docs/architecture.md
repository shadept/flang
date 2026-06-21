# FLang Compiler Architecture

## Compilation Pipeline

```
Source → Lexer → Parser → Source Generators → HmTypeChecker → HmAstLowering (FIR) → Optimizations → HmCCodeGenerator → C99 → GCC/Clang → Native
```

All phases communicate through a central `Compilation` context object — phases never reference each other directly. `Compilation` owns source files, type registries (structs, enums, specializations), module metadata, and global constants.

### Imports and visibility

`Compilation.ModuleImports[M]` records the modules `M` imports (private + public); `ModuleReExports[M]` is the subset declared with `pub import`. `GetVisibleModules(M)` is a cached transitive closure: starting from `{M} ∪ ModuleImports[M]`, follow `ModuleReExports` edges only — never `ModuleImports` — and union the result. This implements the spec's rule that bare imports are non-transitive while `pub import` re-exports propagate.

Lookup is filtered through this set: `FunctionRegistry.Lookup` and `TypeRegistry.LookupNominalType` accept a `visibleModules` argument; symbols defined outside the visible set are excluded from candidates. FQN-style references (containing a dot) bypass the filter — an explicit dotted name is unambiguous.

Generic body checking pushes the call-site module onto `InferenceContext.SpecializationCallers`. `GetVisibleModules()` unions this stack with the current module's visibility, so a generic body can dispatch to user-defined overloads imported by the caller (e.g. UFCS extensions) even when the generic's defining module does not import them.

Module origin (`Stdlib`, `Project`, `External`) is tagged at load time in `ModuleOrigins` and used to scope project-level features. `flang.toml [imports].global` lists modules that are injected as implicit private imports into every `Project`-origin file; stdlib and (future) third-party modules are unaffected.

### Project kind (`[project].kind`)

`kind` is a **mandatory** field in `[project]`, one of `"exe"` or `"lib"`:

- `exe` — `flang build` compiles and links a native executable. A `main` entry point is required (the C linker errors otherwise).
- `lib` — `flang build` compiles the generated C to an object for validation but does **not** link, and no entry point is required. A library is consumed by *source* (see Dependencies), so no binary artifact is needed; the object is the proof it compiles. The output lands at `<output>/<name>.obj` (or `.o`).

`flang init` writes `kind = "exe"` and a `src/main.f`; `flang init <name> --lib` writes `kind = "lib"` and a `src/<name>.f` exporting a `pub fn`. `flang test` is kind-agnostic — it always synthesizes a test runner with its own entry point.

The source root for a `**/*.f`-style glob with no static prefix is the project directory itself; this is what lets a project (e.g. `std`) whose files sit directly under its root resolve its own `import <name>.foo` to source rather than re-loading a packaged copy off the stdlib path.

### Dependencies (`[dependencies]`)

Path-based libraries are declared under `[dependencies]` in `flang.toml`:

```toml
[dependencies]
flang_parser = { path = "../lib/flang_parser" }
```

`DependencyResolver.ResolveDirect` loads each dep's own `flang.toml`, validates that `[project].name` matches the table key, and resolves the dep's source root. The mapping `(dep_name → source_root)` is threaded into `Compilation.DependencySourceRoots` and consumed by two symmetric paths:

- `Compilation.TryResolveImportPath` — when the first segment of an import path matches a dep name, the remainder resolves against the dep's source root (`import flang_parser.lexer` → `<dep_src>/lexer.f`).
- `TemplateExpander.DeriveModulePath` — when a parsed file is under a dep's source root, its module path is prefixed with the dep's name (so the symbol registry agrees with the import side).

The dep's `[project].name` IS its import namespace; library files live directly under the source root, never inside a redundant `<source_root>/<name>/` subfolder. This mirrors how the current project resolves its own imports. Resolution is flat (no transitive deps), path-only (no registry, semver, or lockfile). Per-dep `[build.<os>]` libs/cflags/headers carry through to the consuming project's link line.

### Self-hosted import resolution (`flang_driver`)

The bootstrap compiler reimplements the same machinery in FLang. `flang_driver/resolver.f` is the port: `resolve_import` mirrors `TryResolveImportPath` (project-name, dependency-name, then include-path rules — stdlib root via the `--stdlib-path` flag, then the working dir), and `module_fqn` mirrors `DeriveModulePath` (the inverse, classifying a file path under the project / dependency / stdlib roots). Dependency source roots are derived exactly as the C# does — read each dep's `flang.toml`, take the static prefix of its `source` glob.

`flang_driver/driver.f::analyze_project` is the BFS loader: it seeds the queue with the project's globbed entry sources plus the auto-imported `core.prelude`, follows each module's imports, deduplicates by file path, and type-checks the whole set through a single `check_all`. The module FQNs (not file paths) are passed as the per-module paths so symbol registration and visibility agree. Visibility is built in `flang_typer/checker.f::build_visibility` from the modules' `ImportDecl`s — `{M} ∪ imports(M)` then the `pub import` re-export closure, matching `GetVisibleModules`. `compile.f::build_program` lowers every module into one FIR program for a single link. `examples/multimod` is the end-to-end witness. (Known gap: structs crash the bootstrap typer — see [known-issues.md](known-issues.md).)

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

Lowering keys locals by name (`HmAstLowering._locals`). A block is a lexical scope: it tracks the `let`/`const` bindings it introduces and undoes them on exit, so a name shadowed inside a block resolves back to the outer binding afterwards. Parameter copy-on-write promotions and pattern bindings are deliberately function-scoped and survive block exit.

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

## Project Metadata (`project_info()` intrinsic)

`core.rtti` declares `ProjectInfo { name, version }` and `project_info() ProjectInfo`. The function body is a stub — `HmAstLowering` intercepts every call and substitutes a load from a per-project `GlobalValue` carrying the name + version sourced from that project's `flang.toml`.

Semantics: a call lexically inside module M returns the metadata of the project that owns M. Each project's source root is recorded in `Compilation.ProjectMetadata` (populated by `BuildCommand` and the LSP from each direct dep plus the consuming project). Resolution at lowering time walks `ProjectMetadata` and matches the call site's source file by source-root prefix. Stdlib call sites (and any module outside a known project) fall back to a `("stdlib", "")` sentinel global.

Implementation: see `HmAstLowering.IsProjectInfoIntrinsic` / `LowerProjectInfoIntrinsic` / `EnsureProjectInfoTableExists`. The intercept verifies the resolved target was declared in `core.rtti` to prevent a user-defined `project_info` from being captured. Per-project globals are emitted lazily — no global is added unless something actually calls the intrinsic.

This is how a library exposes its own version without hand-rolling a constant: `pub fn version() String { return project_info().version }`.

## Compile-Time Context

`Compilation.CompileTimeContext` provides platform/OS/arch/runtime values for `#if` directive evaluation during parsing.

## Language Server (LSP)

The compiler includes an in-process LSP server (`FLang.Lsp`) invoked via `--lsp`. It reuses the same compilation pipeline — parser, source generators, type checker — so editor diagnostics match compiler output exactly. Features: hover, go-to-definition, type definition, find-references, document symbols, workspace symbols (Ctrl-T / `#` search), inlay hints (inferred types), signature help, and live diagnostics. `FLangWorkspace` manages document state with incremental re-analysis on file changes.

On `initialize`, `FLangWorkspace.IndexWorkspace` runs project-scoped eager indexing on a background task. It discovers every `flang.toml` reachable from the workspace root (both walk-up to find an enclosing project and walk-down to find nested projects in a monorepo), resolves each project's source root via `ProjectLoader.ResolveSourceRoot`, and analyzes every `.f` file under those roots. Stdlib is deliberately *not* scanned directly — modules from `StdlibPath` are pulled in only when a project transitively imports them (via auto-imported prelude or explicit `import std.…`), so a project that doesn't use stdlib doesn't pay for it. When no `flang.toml` is reachable, indexing falls back to scanning `WorkingDirectory` directly. Build/IDE directories (`bin/`, `obj/`, `dist/`, `node_modules/`, `.git/`, `.vs/`, anything starting with `.`) are pruned during traversal.

Find-references inverts the resolved-target edges the type checker stores on each usage node (e.g. `IdentifierExpressionNode.ResolvedVariableDeclaration`, `CallExpressionNode.ResolvedTarget`, `TypeCheckResult.ResolvedOperators`). `ReferenceFinder` resolves the cursor to a `ReferenceTarget` (function / local-decl / struct-field / nominal-type), then walks every parsed module via `AstNodeFinder.Walk` looking for nodes that point back at that target. Functions / types / fields are searched across **every open file's analysis** (`FLangWorkspace.GetAllAnalyses`) — downstream callers only exist in their own analysis's `ParsedModules`, not in the defining file's analysis. Functions are identified by `(file-path, char-offset, length)` (*not* `SourceSpan`, whose `FileId` is per-`Compilation`) so the same logical decl matches across analyses; generic specializations preserve the original `NameSpan` so they fold into the same identity. Result locations are dedup'd across analyses by `(uri, range)`. Local variables and parameters stay scoped to a single analysis because identity is by AST node reference.

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

**Test placement:** Language feature tests go in `tests/FLang.Tests/Harness/`. Stdlib and self-hosted library tests (flang_core, flang_parser, flang_typer) are colocated in `.f` source files using `test "name" { ... }` blocks, run by `flang test` from the project directory. `flang test` resolves `[dependencies]` the same way `flang build` does, so a library's blocks can import its sibling libs.

`flang test` runs **only the project's own** `test {}` blocks — those whose source file is one of the compilation's entry inputs. A dependency's (and stdlib's) blocks are that dependency's concern, tested from its own directory; otherwise every consumer re-runs the whole transitive suite. A project with no blocks of its own links to an empty runner and reports zero tests rather than failing on a missing entry point.

**Filtering.** Two independent narrowing knobs: a positional `path-filter` selects which source files compile (`flang test path` builds only files whose path contains `path`), and `--name <substr>` (alias `-k`) selects which compiled `test {}` blocks actually run. The name filter is delivered to the synthesized runner via the `FLANG_TEST_FILTER` environment variable — kept out of `argv` so it never perturbs the arguments `std.env` tests observe — and matched as a case-sensitive substring of the test's display name.

**Driver model.** The self-hosted libraries are FLang source; their `test {}` blocks are compiled and executed by the **C# compiler** (`flang build`/`flang test`) — that is the test driver until the bootstrap compiler can self-host codegen, at which point the same suites run unchanged through the new pipeline.

**Run everything:** `dotnet test-all.cs` runs the C# harness plus `flang test` in each self-hosted project. It uses `$FLANG` if set, else `dist/<rid>/flang.exe`; point `$FLANG` at the bootstrap compiler to test the same suites through it.
