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

### Self-hosted library layout

The self-hosted compiler is six libraries plus the `bootstrap` exe. Edges run one way; `flang_driver` is the only one that sees both halves of the pipeline. `flang_fmt` (the formatter) sits outside the pipeline chain: it depends only on `flang_parser` + `flang_core` and is consumed by `bootstrap` for `flang fmt`:

```
        flang_core        flang_codegen
         ^      ^              ^
         |      |              |
  flang_parser  |              |
         ^      |              |
         |      |              |
    flang_typer |              |
         ^   ^  |              |
         |   |  |              |
         | flang_analysis      |
         |   ^                 |
         |   |                 |
        flang_driver ----------+
             ^
          bootstrap
```

| library | holds | job |
|---|---|---|
| `flang_core` | spans, diagnostics | shared vocabulary |
| `flang_parser` | lexer, parser, projector, comptime | text to AST |
| `flang_typer` | checker, inference engine, registries | AST to `TypeCheckResult` |
| `flang_analysis` | `analyze.f`, `resolver.f`, `project.f` | manifest and import resolution, the BFS loader, the front half end to end |
| `flang_driver` | `lower.f`, `symbol_table.f`, `layout.f`, `compile.f` | checked program to FIR, then drives codegen, `cc` and the link |
| `flang_codegen` | FIR types, C backend | FIR to C |
| `flang_fmt` | `fmt.f` | CST-trivia rewriting formatter behind `flang fmt` |

`flang_driver` depends on `flang_analysis` rather than the reverse: lowering needs a checked program, and `compile.f` orchestrates both halves. Keeping `compile.f` on the lowering side is what stops the two libraries forming a cycle - the lowering `test {}` blocks build their fixtures through `analyze_source_set`.

### Self-hosted import resolution (`flang_analysis`)

The bootstrap compiler reimplements the same machinery in FLang. `flang_analysis/resolver.f` is the port: `resolve_import` mirrors `TryResolveImportPath` (project-name, dependency-name, then include-path rules — stdlib root via the `--stdlib-path` flag, then the working dir), and `module_fqn` mirrors `DeriveModulePath` (the inverse, classifying a file path under the project / dependency / stdlib roots). Dependency source roots are derived exactly as the C# does — read each dep's `flang.toml`, take the static prefix of its `source` glob.

`flang_analysis/analyze.f::analyze_project` is the BFS loader: it seeds the queue with the project's globbed entry sources plus the auto-imported `core.prelude`, follows each module's imports, deduplicates by file path, and type-checks the whole set through a single `check_all`. The module FQNs (not file paths) are passed as the per-module paths so symbol registration and visibility agree. Visibility is built in `flang_typer/checker.f::build_visibility` from the modules' `ImportDecl`s — `{M} ∪ imports(M)` then the `pub import` re-export closure, matching `GetVisibleModules`. `compile.f::build_program` lowers every module into one FIR program for a single link. `examples/multimod` is the end-to-end witness. Each module's text comes from `analyze.f::read_source`, which returns a supplied buffer when the caller named that path in `analyze_project`'s optional `overrides` map (an editor's unsaved text) and reads the file otherwise; keys are the forward-slash paths `resolver.normalize_sep` produces, so a key spelled any other way misses silently and compiles the stale file. `flang build` passes no overrides. (Known gap: structs crash the bootstrap typer — see [known-issues.md](known-issues.md).)

## `std.io` layering

Four modules, split by what the caller holds, with every syscall in one place:

```
std.io.types         FileKind, FileInfo, FsError        no deps, no syscalls
std.io.internal.fs   every #foreign + fs.c              raw_* over FsError
std.io.fs            a path      stat, exists, rename, walk_dir, glob, cwd
std.io.file          an open File   open/read/write/close, remove_file
std.io.dir           an open Dir    entries, create_dir, remove_dir
```

`internal.fs` is the only module in the tree that declares `#foreign`, and
`internal/fs.c` is the only place three per-platform disagreements are
resolved: errno / Win32 codes (translated to `FsError`), `O_*` open flags
(selected from a portable mode integer), and NUL-terminated C strings (copied
from the caller's `String` view, so no caller can forget). `file` and `dir`
translate `FsError` into `FileError` / `DirError` through one function each,
so a new errno mapping is added once, in the shim, and lands everywhere.

`std.io.types` exists because the lowest module cannot import the ones above
it, and because a qualified variant (`FileKind.Dir`) only resolves when its
declaring module is imported directly — see `docs/known-issues.md`.

Traversal (`walk_dir`, `glob`) lives in `fs` rather than `dir`: it yields
paths, and the directory handles it holds are an implementation detail. `Dir`
re-exposes both as `d.walk()` / `d.glob(pattern)` rooted at itself.

`std.path` is deliberately outside this tree. It is pure string algebra with
no filesystem access, which is what lets the compiler use it for `#line`
directives, module-path resolution, `flang.toml` globs and cache keys without
touching a disk. The two functions that did read the world, `cwd` and
`to_absolute`, moved to `std.io.fs`.

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

**Self-host side tables.** The self-hosted checker has no mutable AST
fields, so every semantic decision lands in `InferenceResults`, keyed by
node id (a span fingerprint). Beyond node types, resolved targets and
resolved operators, three tables carry call-shape decisions that
lowering cannot re-derive:

- `default_args` — the callee's default expressions for the parameters a
  call omitted, checked at the call site and appended after the explicit
  arguments.
- `arg_lists` — the COMPLETE parameter-ordered argument list, recorded
  when the AST's own order is not the call's order: a named-argument
  call (names select parameters) or a variadic call (the surplus is
  packed into one synthesized array literal). Lowering emits it in place
  of `call.args`; a call that needs one and has none refuses.
- `receiver_derefs` — the `op_deref` hops a receiver resolved through.
  On a call whose callee is a member access it means "peel the receiver
  through these"; on a call whose callee is NOT a member access it means
  "the callee value IS the receiver" (RFC-014 `op_call`), with an empty
  chain for the direct case.

**Self-describing results.** A node id packs `(file_id, start, length)`
into a `u64` and clamps a span longer than 64 KB or a file past 65535, so
it cannot be decoded back to the span it names. Every id the checker
mints goes through `checker.node_of`, which records the span in
`TypeCheckResult.spans`; `get_span` inverts an id, `path_of` maps a
`file_id` to its source path from `TypeCheckResult.file_paths` (owned
copies, so the snapshot names the file of any span it holds without the
project that produced it). `Field.decl_span` and `VariantDef.decl_span`
do the same for a struct field and an enum variant, whose declarations
have no node of their own. Both spans are metadata, outside a type
node's identity, so two records that differ only in where they were
written are still one type.

**Interned types (RFC-024).** In the self-hosted checker `Ty` is a
4-byte handle (`pub type Ty = u32`) into a `TypeInterner` - one `TyNode`
per distinct type, children as handles sliced out of one flat array,
identity by canonical rendering. `Void`, `Never`, `Error` and the 14
primitives hold fixed ids (`type.f`), so the common leaves never hash.
Consequences:

- `a == b` on handles IS type equality; there is no structural `equals`.
- Consumers match shapes via `interner.node(t)`; diagnostics render via
  `interner.format`. A `Var` node keys on (id, level) because
  `generalize`'s free-variable walk reads levels off the node.
- The engine owns the table and interns as inference works (`fresh_var`,
  `unify` bindings, `zonk`, `substitute` all produce handles); a per-node
  ground bit makes `zonk` the identity on var-free subtrees.
- `check_all` moves the table into the `TypeCheckResult`, which is the
  single owner of every type's storage; the result's tables hold
  handles. Lowering resolves through `result.interner` (via
  `LowerCtx.it` - see the known-issues entry on reference-crossing
  mutation).
- The table must not outlive the module sources: record keys embed field
  names, which are views into them.

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

Companion `.c` files that ship alongside `.f` sources (stdlib's `simd.c`, `bits.c`, `io/internal/fs.c`, `atomic.c`, plus any project-local C) are pre-compiled to `.obj` via `BuildCache` before the final link. Warm builds skip the C compile and just link the cached objects.

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

- **Name mangling only in codegen.** IR carries `SymbolBaseName` — the module-qualified base (`module.path.name`, stamped on `FunctionDeclarationNode.ModulePath` at signature collection) — and `HmCCodeGenerator` applies `IrNameMangling.MangleFunctionName()` (parameter/return tokens) when emitting C. Module qualification is load-bearing: two file-private functions with the same name and signature in different modules used to merge into one C symbol, with one body silently dropped. `main` and foreigns are never mangled.
- **Mangling is total over the module path.** The path comes from the project name and file path, not from a FLang identifier, so both manglers escape rather than pass bytes through — see `docs/spec.md` §7.1.1, property 4. Self-hosted (`symbol_table.f::append_module_path`): `.` → `__`, `_` → `_0`, any byte outside `[A-Za-z0-9]` → `_x<hex>`; injective, because a literal `_` always becomes `_0`, so `__` and `_x` can only come from an escape. Reference (`TypeLayoutService.SanitizeCName`): every character outside `[A-Za-z0-9_]` → `_`, which is total but lossy. `#foreign` structs keep their original C name and are exempt.
- **Foreign/intrinsic symbols are not mangled.** `#foreign` and `#intrinsic` calls use their declared names directly.
- **By-value aggregates cross C boundaries as real structs.** `IrType.Agg` carries `{name, size, align}`; the matching `AggDef` on `IrModule.aggs` carries the member list the backend emits as a `typedef struct`, nested types first. Members are faithful (a `f32` emits as `float`) because the platform ABI classifies a struct by its member types. Only foreign calls use this — native calls still pass addresses and return through sret. `symbol_table.f::agg_abi_safe` is the single gate, and it tests **layout agreement**: an aggregate may cross only if C's natural layout of its members reproduces the FLang layout, which rules out every `Repr.Auto` struct whose fields got reordered by descending alignment.
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

`TemplateExpander` (referred to as "source generators") runs **once**, between nominal-type collection and resolution (RFC-021 §2). One global worklist holds every invocation in import-topological + source order; each expansion's text is parsed as a declaration chunk, its declarations are **appended to the origin `ModuleNode`** (`ModuleNode.Append`) and its nominals collected on the spot, so later invocations see them. There are no synthetic modules, no module-path aliasing and no rounds. An invocation whose `Type` argument is not collected yet is parked and retried only after another expansion made progress (stdlib import cycles rule out a pure ordering); with no progress left it fails E2003. Invocations found inside generated code re-enter the worklist with generation + 1; generation 8 is E2119.

Expansion is entirely in memory. `--emit-generated` writes each origin's combined text to `<origin>.generated.f` for debugging — nothing reads it back. The LSP keeps the same text per analysis (`FileAnalysisResult.GeneratedFiles`): any span inside a generated source becomes a `flang-generated://<origin>.generated.f` location (`PositionUtil.SpanToLocation`), and the editor fetches the document through the custom `flang/generatedContent` request (`GeneratedContentHandler`; the VS Code extension registers a `TextDocumentContentProvider` for the scheme). Diagnostics inside generated code are not yet re-anchored to the invocation (RFC-021 §6). Each chunk is parsed against a `Source` padded with the lines already emitted for its origin, so spans and diagnostics line up with the emitted text without a second parse.

## Project Metadata (`project_info()` intrinsic)

`core.rtti` declares `ProjectInfo { name, version }` and `project_info() ProjectInfo`. The function body is a stub — `HmAstLowering` intercepts every call and substitutes a load from a per-project `GlobalValue` carrying the name + version sourced from that project's `flang.toml`.

Semantics: a call lexically inside module M returns the metadata of the project that owns M. Each project's source root is recorded in `Compilation.ProjectMetadata` (populated by `BuildCommand` and the LSP from each direct dep plus the consuming project). Resolution at lowering time walks `ProjectMetadata` and matches the call site's source file by source-root prefix. Stdlib call sites (and any module outside a known project) fall back to a `("stdlib", "")` sentinel global.

Implementation: see `HmAstLowering.IsProjectInfoIntrinsic` / `LowerProjectInfoIntrinsic` / `EnsureProjectInfoTableExists`. The intercept verifies the resolved target was declared in `core.rtti` to prevent a user-defined `project_info` from being captured. Per-project globals are emitted lazily — no global is added unless something actually calls the intrinsic.

This is how a library exposes its own version without hand-rolling a constant: `pub fn version() String { return project_info().version }`.

## Compile-Time Context

`Compilation.CompileTimeContext` is the closed compile-time context (`platform.*`, `runtime.*`, honoring `--target-os`/`--target-arch` and runtime overrides). There is exactly one evaluator over it — `CompileTimeEvaluator` (`FLang.Frontend`). Declaration-level `#if` (`IfDirectiveDeclarations`), statement-level `#if` (checker and lowering) and the template engine (`#if`, `#for`, `#(expr)`) all call it; templates layer their bindings (parameters, `#for` variables) over the context and pass `type_of`/field lookups. Semantics are FLang's: bool conditions (E2117), unknown names/members (E2116), optionals from dict lookups must be unwrapped with `??` (E2118), operators require matching operand types (E2118). `TemplateEngine` is only text assembly on top of it. Introspection values are `TypeInfoModel` (`FLang.Frontend/TypeInfoBuilder.cs`) — the compiler-side shape of `core.rtti.TypeInfo`. `TypeInfoBuilder` has two entry points that produce the same shape: `FromNominalDeclaration`/`FromTypeNode` over collected declarations (templates; layout unset, E2120 on access) and `FromResolved` over resolved types (the RTTI table in `HmAstLowering.EnsureTypeTableExists`, which adds size/align/offset and pointers). Adding a member to `TypeInfo` means adding it to the model and both builders — templates and the runtime see it together. A `CompileTimeError` raised inside a template is reported at the template expression's span with its own code, naming the invocation.

The self-host mirrors this with `flang_parser/comptime.f` over its own
`ComptimeCtx`. The context is a BUILD property, not a host property:
`--target-os` / `--target-arch` install it on the `ResolveCtx`, which
threads it into the checker AND into `LowerCtx` (`build_program` takes
it explicitly). Lowering evaluating statement-level `#if` against the
host while the checker used the target was a real cross-target
miscompile — the checked branch and the emitted branch differed.

## Formatter (`lib/flang_fmt`)

`flang fmt` formats the project's `flang.toml` source glob (or explicit file
arguments) in place; `--check` writes nothing and exits 1 when a file would
change. The work happens in `lib/flang_fmt`'s `format_source(source, &cfg)`,
a pure text-to-text function; file IO stays in `bootstrap/src/main.f`.

Design:

- **CST trivia rewriting.** The input is lexed and parsed to the lossless
  CST; style passes rewrite whitespace trivia and re-emit. Token text is
  never touched.
- **Verify gate.** Before returning, the output is re-lexed and re-parsed:
  it must parse cleanly, its token stream must match the input's with
  commas set aside (the one token separator policy may add or drop), and
  the two parse trees must have the same shape. A mismatch discards the
  output (`VerifyFailed`). Files with parse errors are refused, not
  formatted.
- **Structure is authored, layout is width-driven.** A newline can end a
  statement, so breaks between statements and inside brace bodies always
  stand, as do blank lines and comment placement. Breaks inside `(`/`[`
  groups and before `and`/`or` are layout: with `join-lines` on they
  re-flow, and `max-width` decides where lines break (after list commas,
  before `and`/`or`). A too-long line with no such break point stays long.
- **Comment reflow.** Runs of own-line `//` prose re-fill to `max-width`.
  Structure is left alone: lists, rulers, tables, indented example blocks,
  aligned columns, and any line with a non-ASCII byte (box drawing,
  arrows) pass through verbatim, and only a line filled past half of
  `max-width` joins with its successor, so deliberate short lines stay
  put. Comments trailing code are never reflowed.
- **Line endings.** The file's prevailing ending (first newline: LF or CRLF)
  is detected and preserved, so a checkout's eol convention is never a
  formatting change.

Configuration lives in a `[fmt]` table in `flang.toml`, parsed by
`flang_analysis/project.f` into verbatim key/value entries and applied via
`set_option` (unknown keys warn and are ignored):

| key | default | meaning |
|---|---|---|
| `indent` | `4` | spaces per indentation level |
| `max-width` | `100` | layout width in columns; `0` disables wrapping, joining, and reflow |
| `max-blank-lines` | `1` | maximum consecutive blank lines |
| `trailing-comma` | `"multiline"` | `no` / `multiline` / `always` - trailing comma in comma lists (call args, arrays, struct construction) |
| `separators` | `"no"` | same values - separators the grammar makes optional (struct fields, enum variants, match arms) |
| `join-lines` | `true` | re-flow layout breaks (groups, `and`/`or`) to `max-width` |
| `reflow-comments` | `true` | re-fill own-line comment prose to `max-width` |
| `semicolons` | `"remove"` | `remove` / `keep` - `a(); b()` becomes one statement per line |
| `if-stmt` | `"multiline"` | `multiline` / `keep` - single-line statement `if x { ... }` (guards included) |
| `if-else-stmt` | `"multiline"` | same values - statement `if/else` |
| `if-expr` | `"keep"` | same values - `if` in expression position |

`always` is accepted but its multiline forcing is not implemented yet; it
currently behaves as `multiline`.

Formatting runs to an internal fixpoint (a wrap inserted by one pass is an
authored break to the next, which can move a separator), capped at four
passes; an output still changing then is refused as a formatter bug.

## Language Server (LSP)

The compiler includes an in-process LSP server (`FLang.Lsp`) invoked via `--lsp`. It reuses the same compilation pipeline — parser, source generators, type checker — so editor diagnostics match compiler output exactly. Features: hover, go-to-definition, type definition, find-references, document symbols, workspace symbols (Ctrl-T / `#` search), inlay hints (inferred types), signature help, and live diagnostics.

`FLangWorkspace` keeps exactly **one shared whole-program analysis per analysis root** (a project's root, or the workspace directory for project-less files), replaced wholesale when any file of that root changes; every file of the root maps into the same result, and per-file diagnostics are extracted from it (`.generated.f` sidecars are never entry points — they are pulled in through their origin modules). This bounds memory by the number of projects and makes workspace indexing one whole-program check per root. The previous per-file model (one full compilation + inference tables retained per file, cascade re-analysis of dependents) grew to gigabytes on non-trivial workspaces and did O(files) whole-program checks at startup.

Edits made **outside the editor** (agents writing files, git operations, external tools) reach the server through `workspace/didChangeWatchedFiles`: the server registers client-side watchers for `**/*.f` and `**/flang.toml`, and incoming events are debounced per root (~400 ms) so a burst of file writes coalesces into a single re-analysis. Open-document buffers always win over disk during analysis, so watcher events for open files are harmless.

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
//! NO-COMPILE-WARNING: W0001
//! SKIP: reason
```

The harness compiles and runs each test, asserting exit code, stdout, and stderr match metadata. `COMPILE-ERROR`/`COMPILE-WARNING` tests assert compilation fails or warns with the specified error code; `NO-COMPILE-WARNING` asserts the given warning code is *not* emitted (regression guard for false-positive warnings).

**Execution mode.** By default the harness compiles in-process with the C# compiler. When the `FLANG` environment variable names a compiler binary, each test instead compiles by subprocessing `$FLANG --stdlib-path <repo>/stdlib build <test.f>` and running the produced executable against the same expectations — this is how the self-hosted bootstrap is scored against the corpus. Compile-diagnostic expectations match textually against the external compiler's rendered `severity[CODE]` output; a failing test's message includes the compiler's full stdout/stderr. With `FLANG` unset, behavior is unchanged.

**Test placement:** Language feature tests go in `tests/harness/`. Stdlib and self-hosted library tests (flang_core, flang_parser, flang_typer) are colocated in `.f` source files using `test "name" { ... }` blocks, run by `flang test` from the project directory. `flang test` resolves `[dependencies]` the same way `flang build` does, so a library's blocks can import its sibling libs.

`flang test` runs **only the project's own** `test {}` blocks — those whose source file is one of the compilation's entry inputs. A dependency's (and stdlib's) blocks are that dependency's concern, tested from its own directory; otherwise every consumer re-runs the whole transitive suite. A project with no blocks of its own links to an empty runner and reports zero tests rather than failing on a missing entry point.

**Filtering.** Two independent narrowing knobs: a positional `path-filter` selects which source files compile (`flang test path` builds only files whose path contains `path`), and `--name <substr>` (alias `-k`) selects which compiled `test {}` blocks actually run. The name filter is delivered to the synthesized runner via the `FLANG_TEST_FILTER` environment variable — kept out of `argv` so it never perturbs the arguments `std.env` tests observe — and matched as a case-sensitive substring of the test's display name.

**Driver model.** The self-hosted libraries are FLang source; their `test {}` blocks are compiled and executed by the **C# compiler** (`flang build`/`flang test`) — that is the test driver until the bootstrap compiler can self-host codegen, at which point the same suites run unchanged through the new pipeline.

**Compiler layout.** `dotnet build.cs` publishes the C# reference compiler to `dist/<rid>/flang-ref`, builds the self-hosted compiler with it, and installs that as `dist/<rid>/flang` — the default compiler. Installing a *copy* into `dist/` is also what stops a self-build from overwriting the binary running it: `flang build` in `bootstrap/` writes `bootstrap/build/flang`, never the one in `dist/`.

**Build incrementality.** A no-change `dotnet build.cs` costs ~2s, down from ~27s. Two things get it there:

- The publish runs `--no-restore` first and only pays for a restore when that fails. It used to fail *every* run: `dotnet build test.cs` restores `FLang.CLI` without a RID, which strips the RID-specific target from `obj/project.assets.json` and makes the next `dotnet publish -r <rid>` fail NETSDK1047. `<RuntimeIdentifiers>$(NETCoreSdkRuntimeIdentifier)</RuntimeIdentifiers>` in `FLang.CLI.csproj` keeps that target present no matter which entry point restores.
- `flang build` has no whole-project up-to-date check, so build.cs guards the ~10s stage-1 compile with a timestamp comparison against `bootstrap/`, `lib/`, `stdlib/` and `src/` (ignoring `build`/`bin`/`obj` directories). `src/` stands in for the reference binary, whose own timestamp says nothing — the publish re-copies it regardless. `--force` rebuilds anyway.

**Telling the two apart.** Both binaries name themselves in `--version` and `--help`: `flang 0.1.0-alpha (reference compiler, C#)` versus `flang 0.1.0 (self-hosted compiler, FLang; flang_parser 0.3.0)`. Ordinary diagnostics carry a plain `flang:` prefix in both.

**Gate A - analysis equivalence.** `flang --gate-a build` analyses the project, dirties the first, middle and last module in demand order, re-demands them through `flang_analysis/analyze.f::reanalyze` (which re-parses only what is stale and reuses every other module's AST), and requires the two `TypeCheckResult`s to be identical entry by entry: nominal registry, function registry, specialization registry, `node_types`, `resolved_targets`, `resolved_ops`, `instantiated_types`, `spans`, `file_paths`, plus the diagnostic count and the size of every remaining table. The comparison lives in `lib/flang_typer/src/result_diff.f`; types compare by their canonical `format` rendering and ids compare by value, so a renumbered nominal is a difference even when both ids name the same declaration. It also prints parse, name-collection, nominal-body, signature, body and settlement time cold versus re-demanded, since a cache that silently recomputed everything would otherwise pass unnoticed.

It exists for RFC-022: the harness and the stage-2 = stage-3 fixpoint both run cold and single-pass, so neither can catch a stale cache entry surviving an invalidation. Run it across `bootstrap/`, `lib/*` and `examples/*`; `examples/raylib` needs the raylib headers and reports "does not type-check" without them. `FLANG_GATE_DIRTY=<index|path>` dirties one chosen module instead of the default three; the per-module sweep loops it over every index, one process per module (each demand retires the result it replaces, so one process cannot afford a hundred re-demands).

**Lazy demand.** `flang build` checks bodies only for the demand set (RFC-022 §6): the project's own modules, `core.prelude`, the `[imports].global` modules, and everything transitively imported from any of them (`analyze.f::demand_mask` over the loader's import edges). A module outside the set gets no phase-3 slot at all - no node types, no diagnostics, no specializations - which is safe because identifier, operator and constant resolution are import-scoped, so nothing demanded can name it. Everything before phase 3 still runs for every module: type names resolve program-wide (leniently), and phase 2.5 stays eager so preamble literal verdicts are demand-independent. Lowering skips undemanded modules except their `#foreign` declarations (globally-linkable symbols, callable without an import) and skips specializations whose template lives in an undemanded module. `--eager` restores total demand; the LSP and the in-process analysis entry points run eager by default (`ResolveCtx.lazy_bodies`).

**Gate B - lazy/eager parity.** `flang --gate-b build` analyses the project under total demand and again under lazy demand and requires the two published diagnostic lists to be identical (compared as sorted `code|file|start|message` lines). Laziness may only ever skip work whose absence is invisible - a module outside the demand set is expected to be clean - and this is what checks that. It also reports how many module slots were skipped and the eager-versus-lazy body time, since a mask that silently demanded everything would otherwise pass unnoticed.

**W1003 unused functions.** `flang_analysis/src/unused.f` runs reachability over the recorded resolution edges - `resolved_targets`, `resolved_ops`, receiver-deref chains, and each specialization's overlay tables, with each site attributed to its enclosing function by span containment against the registry's declaration spans. Roots: `main`; every `pub fn` under `kind = "lib"`; sites outside any function body (constant initializers). Opt-in on a build (`-W`/`--warn-unused`), where `test {}` bodies are unchecked and every non-`pub` function of a test-bearing module is therefore rooted conservatively; the LSP checks test bodies and runs it with real test edges (`tests_checked = true`). `_`-prefixed names suppress, matching W1001.

**W1004 unused imports.** Same evidence, aggregated per importing file: the recorded edges, plus the modules whose nominals a file's node types cite, plus what its own declarations cite through the registries (struct fields, enum payloads, function signatures - a foreign or unreachable function's body is never checked, so nothing else records those), plus `std.string_builder` for any file with an interpolation desugar (its calls resolve on synthesized, fileless nodes). An `import M` warns when no edge from the file lands in M or in M's transitive `pub import` closure. Skips where a build is blind: test-bearing modules, generator declarers/invokers, targets exporting type aliases; `pub import` never warns. The first sweep over the tree found 26 dead imports (all removed) and zero false positives after the declaration-citation and interpolation attributions landed.

**The checker outlives one check.** `AnalyzedProject` owns the `Checker`, and `checker.f::begin_demand` readies it for the next demand. What carries is everything registered by a stable key: the nominal registry whole (`nominal_registry.f::carried_copy` - declared and generated names WITH their resolved bodies, plus the anonymous-record definitions and the map that interns them), the function registry whole (`function_registry.f::carried_copy` - schemes at their ids and list positions, with the instantiation templates, declared parameter lists and deprecations beside them), the constant types, the alias bodies, and each module's cached diagnostics, signature facts and body slot (`ModuleBodyCache`). Closure environments are rebuilt by every body pass - run or replayed - so `check_all` retires their ids into `recycled` on the way out and the next demand's identically-ordered registrations reclaim them. Everything else a check computes names variables of the engine that inferred it, and that engine goes.

**The type table outlives one check.** A carried body's `Ty` handles index the interner, so the table is one per project, not per check: `check_all` ships it inside the `TypeCheckResult` as before, and the next demand adopts it back out of that result (`result.f::take_interner` into `checker.f::adopt_interner`), appends, and ships it again. The table only grows, which is what keeps an earlier snapshot's handles valid; `result_diff` accordingly renders both sides of a comparison through the right-hand result's table. Record field names in the table are views into module sources, which is safe under the same retirement rule the registry already relies on: `AnalyzedProject` retires replaced sources rather than freeing them, and retires each replaced `TypeCheckResult` the same way (`retired_results`).

**When carried bodies re-resolve.** A carried body is valid only while the name set it resolved against holds still, so `check_all` falls back to resolving every body from source - exactly a cold check - when a demand adds a declared or generated name, removes one (a retirement nothing reclaimed), or changes a type alias. Alias change is detected by comparing canonical spellings of the retiring modules' alias bodies across re-collection (`render_alias_body`); a body with no canonical spelling counts as changed. Skipped modules still mint their type parameters' fresh variables and span nodes (`burn_type_param_vars`), so the engine's variable stream and the result's span table match a cold check's.

**When carried signatures re-run.** The signature pass follows the same carry rule per module: a module the demand did not re-parse skips it whenever the nominal carry holds AND the module's cached pass recorded nothing beyond node types, spans and resolved literals - a call or operator in a default value, a lambda, an anonymous literal or an interpolation makes the module re-run its pass every demand (`ModuleSigCache.cacheable`). A skipping module replays its cached diagnostics, spans and node types, and burns the variables the pass would have minted (`Engine::burn_var` - counter only, the carried table already holds the nodes), which is what keeps an unannotated constant's carried variable naming the slot the constants pass then binds. Because those handles are absolute ids, the cache is anchored to its position in the variable stream (`ModuleSigCache.vars_at_start`): an upstream edit that changes an earlier module's signature-tier variable count shifts every later position, and the affected modules re-run once to re-anchor. A module that re-runs has its registry entries retired first (`function_registry.f::retire_module`) so its declarations reclaim their slots and ids in place - overload order is part of resolution - and retirements left unclaimed are removed declarations, purged after the pass with their id-keyed side tables. The constants pass (phase 2.5) stays eager: at ~0.1% of a check, re-running every initializer is what keeps calls, generic picks and anonymous literals in initializers cold-identical without a cache of their own.

**When carried bodies replay.** Phase 3 runs one module SLOT at a time - the module's bodies, then the settlement of what they parked: anonymous literals, fn-name values, the specialization drain, the parked calls, a second drain, the literal sweep - and slots end sealed (unresolved parked work is abandoned, never handed to the next slot). Settlement per slot is sound because bodies never share inference variables; module constants, the one cross-body channel, are pinned by phase 2.5. The slot order is demand order, so every encounter-ordered assignment - specialization ids, closure environments, synthesized nodes - is decided per module, which is what lets a kept module REPLAY its slot from `ModuleBodyCache`: the capture window's facts (keys captured live, values harvested from the finished tables - the raw recordings cite engine bindings that die with their demand), the cached window diagnostics, counter burns, then a live re-run of the logged picks in cold process order and of the parked calls - at the ids and in the order a cold check assigns, re-pinning the burned variables the way the cold drain did. Slots replay only when the nominal carry holds, the signature tier's outputs are fingerprint-identical (schemes at reclaim, constants, default-value source text, nominal definitions), no module constant's variable is still open after phase 2.5, and the module's stream anchors (vars/synth/lambda at slot start) match; a slot whose window would emit a literal diagnostic or whose drain reported an uninferable pick re-runs every demand. A replayed slot views an earlier demand's `synth_strings` buffers, so a retired result is slimmed (`result.f::slim_retire` - tables freed, viewed buffers kept) rather than freed whole; `analyze.f::keep_retired_results` opts into whole retention for a caller that reads a pre-copy after the re-demand (gate A).

**The specialization registry outlives one check.** The registry travels the way the type table does: `check_all` ships it inside the result, and the next demand adopts it back (`result.f::take_specs` into `checker.f::adopt_specs`; a caller that still reads the previous result's tables after the re-demand - gate A - gets a deep copy via `specialization.f::carried_copy` and the original stays). A pick that lands on a carried entry - by its final key, or by call site through the hint lists (`ModuleBodyCache.spec_sites` for a slot's top-level picks, the previous incarnation's dep list for an in-place re-instantiation's nested picks) - REUSES it without re-checking the template body, provided the pick's instantiated signature is concrete at process time and a probe (`checker.f::spec_probe`) validates the entry and, transitively, everything its frame's drain resolved: not stale (template module re-parsed), still replayable (no diagnostic, no parked call, no flagged literal, a concrete final signature), and stream anchors matching at every position the replay would reach - the cached closure symbols bake counter values. Reuse burns the frame's own counter mints, re-registers its closure environments from cached facts, and touches its deps; anything that cannot be reused re-instantiates IN PLACE at the id it holds (`replace_at`), so the ids other modules' caches bake stay valid. Eviction is mark-and-sweep: every resolution stamps the registry's demand generation and `sweep` evicts what the demand never touched - a touched entry's deps are touched with it, so only whole undemanded subgraphs go. A global invalidation resets the registry whole; numbering restarts at zero, exactly a cold check.

`check_all`'s `recollect` list says which modules gather their names from source again; `reanalyze` sets it for exactly the modules it re-parsed. Those modules' declarations are retired from the registry first, each id remembered against its FQN, and a declaration that comes back is re-registered at the id it had, so a re-check hands out the ids a check from cold would. A declaration the edit removed leaves a hole; one the edit added mints a fresh id past every existing one rather than in its module's place. Numbering it where a cold check would puts it ahead of every declaration below it in the file and renumbers all of them, which is the one thing an id-keyed table cannot survive, so appending is the wanted behaviour and not an approximation of cold. What it costs is the oracle: an incremental result and a cold one over the same edited source agree on every declaration but not on the id sequence, so Gate A's by-value comparison only holds over unchanged text.

**Run everything:** `dotnet test.cs` runs the lit-style harness through the default compiler (`dist/<rid>/flang`); `--reference` switches to the in-process C# path, and `$FLANG` overrides both. `dotnet test-all.cs` runs `flang test` in each self-hosted project — it uses `$FLANG` if set, else `dist/<rid>/flang-ref`, because `test` is a reference-only command until the self-hosted CLI grows a test runner.
