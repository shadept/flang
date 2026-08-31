# FLang Compiler Architecture

## Compilation Pipeline

```
Source → Lexer → CST → AST → Source Generators → Checker → Lowering (FIR) → Optimizations → C Backend → C99 → cc → Native
```

| phase | lives in |
|---|---|
| Lexer, CST, AST projection, comptime | `lib/flang_parser` |
| Manifest/import resolution, the module loader | `lib/flang_analysis` |
| Type inference, registries | `lib/flang_typer` |
| AST → FIR lowering, symbols, layout, the build driver | `lib/flang_driver` |
| FIR, optimization passes, C backend | `lib/flang_codegen` |

`AnalyzedProject` carries a load's module set, its `TypeCheckResult`, and the registries the next demand reuses; phases hand it along rather than referencing each other.

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

The self-hosted compiler is six libraries plus the `compiler` exe. Edges run one way; `flang_driver` is the only one that sees both halves of the pipeline. `flang_fmt` (the formatter) sits outside the pipeline chain: it depends only on `flang_parser` + `flang_core` and is consumed by `compiler` for `flang fmt`:

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
          compiler
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

`flang_analysis/resolver.f` owns import resolution: `resolve_import` applies the project-name, dependency-name, then include-path rules (stdlib root via the `--stdlib-path` flag, then the working dir), and `module_fqn` is its inverse, classifying a file path under the project / dependency / stdlib roots. Dependency source roots come from reading each dep's `flang.toml` and taking the static prefix of its `source` glob.

`flang_analysis/analyze.f::analyze_project` is the BFS loader: it seeds the queue with the project's globbed entry sources plus the auto-imported `core.prelude`, follows each module's imports, deduplicates by file path, and type-checks the whole set through a single `check_all`. The module FQNs (not file paths) are passed as the per-module paths so symbol registration and visibility agree. Visibility is built in `flang_typer/checker.f::build_visibility` from the modules' `ImportDecl`s — `{M} ∪ imports(M)` then the `pub import` re-export closure, matching `GetVisibleModules`. `compile.f::build_program` lowers every module into one FIR program for a single link. `examples/multimod` is the end-to-end witness. Each module's text comes from `analyze.f::read_source`, which returns a supplied buffer when the caller named that path in `analyze_project`'s optional `overrides` map (an editor's unsaved text) and reads the file otherwise; keys are the forward-slash paths `resolver.normalize_sep` produces, so a key spelled any other way misses silently and compiles the stale file. `flang build` passes no overrides. (Known gap: structs crash the typer — see [known-issues.md](known-issues.md).)

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
- **Recursive children are `&T` into the module arena.** A category enum is as
  large as its largest arm, and an arm is as large as the nodes it stores by
  value, so one fat field sets the price of every node in the category: a bare
  `break` used to cost 440 bytes because `LetStmt` carried an `Expr` (240) and
  a `TypeExpr?` (112) inline. Every recursive child - `Expr`, `TypeExpr`,
  `Pattern`, `BlockExpr` - is therefore stored as a reference, boxed into the
  module arena at projection time (`Projector.boxed` / `boxed_opt`). Boxing
  moves bytes *within* the arena; it introduces no lifetime and no free
  obligation, and `Module.deinit` still reclaims everything in one call.

  | | before | after |
  |---|---|---|
  | `Expr` | 240 | 104 |
  | `Stmt` | 440 | 104 |
  | `Decl` | 408 | 136 |
  | `FunctionParam` | 400 | 64 |
  | `LetStmt` | 432 | 88 |
  | `ExpressionStmt` | 264 | 32 |
  | `IfExpr` | 168 | 56 |
  | `LambdaExpr` | 232 | 72 |

  `Expr`'s floor is now `InterpolatedStringExpr` (96) and `Stmt`'s is
  `IfDirectiveStmt` (96); both are `List`-shaped, so the next move on either is
  the list header, not another box.

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

**CST storage.** The CST is struct-of-arrays: one `Cst` owns `nodes`,
`tokens` and one flat `children` array, and a node names its children as a
`ChildSpan` window into that array. A stored node is 20 bytes and a stored
child 8 (an index plus which array it indexes); the token list is *moved* in
from the lexer rather than copied, so a caller that hands tokens to `parser()`
must not free them itself. Consumers walk with `CstNode`, a stack cursor
carrying the stored record plus a `&Cst`, so `kind`/`start`/`end` read as
fields and children come from `child_count()` / `child(i)`.

The previous shape gave every node its own `List(CstChild)` — one heap
allocation per node — and stored children by value, so parsing copied every
token out of the lexer's array and every finished node into its parent's list.
On the compiler corpus that was 220,513 allocations and 407,353 token copies;
the flat form is three allocations per module, halves lex+parse peak memory
(19.7 MB to 8.4 MB) and cuts allocation count by 52%. It also settles
ownership — see the known-issues entry.

**Trivia is derived, not stored.** A `Token` is 32 bytes - kind, `text`, `offset` - and owns
nothing. Whitespace and comments used to hang off it as two owned `Trivia[]` slices plus the
allocator to free them: 40 of the token's 80 bytes, and a heap allocation per token, recording
views into a buffer that is kept alive anyway. Every byte between one token's text and the next IS
trivia by construction, so `trivia.f` walks it on demand (`trivia_in`, `trailing_end`,
`spans_newline`) and `Cst` exposes `token_leading` / `token_trailing`. `Token.line` went the same
way - the formatter and folding ranges count newlines as they walk, and the diagnostic path already
builds a `LineIndex`.

Two rules make the derivation correct. Every walk is **bounded by the next token's offset**: inside
an interpolated string the bytes after a hole's `}` belong to the segment token, not to the gap, so
an unbounded scan emits them twice. And a consumer must emit a token's **leading trivia before its
text and trailing after**, because the formatter reads `pending_newlines` immediately after a token
and expects the newline that follows it to be counted already. `trailing_end` is the split point:
at most one run of horizontal whitespace, one line comment, one newline.

On the compiler corpus this takes lex+parse from 509,347 allocations to 2,229 (243,408 of them were
trivia slices), churn from 299 MB to 62 MB, and lexing 36% faster. The losslessness invariant is
unchanged - concatenating leading + text + trailing over every token still reproduces the source
byte-for-byte - it is simply no longer materialised.

**AST arenas.** Each `Module` owns an `ArenaAllocator` holding its whole
AST, released in one bulk free (`ast.f`). Arena pages grow geometrically -
the first is `page_size` (4 KB), each subsequent page doubles up to
`ARENA_MAX_PAGE_SIZE` (128 KB). A fixed page size cannot serve both ends:
4 KB pages waste a fraction of every page and cost one `malloc` per page,
while a large fixed page wastes most of the only page a small module ever
allocates. On a compiler self-check the growth curve cuts end-of-page slack
from 32 MB to 11 MB and page allocations from 33,181 to 1,778, while a
module small enough to fit one page still costs 4 KB.

**Arena list growth.** An arena that never reclaims turns `List` growth into
a leak: `reserve` used to allocate a new buffer and free the old one, and
`arena_dealloc` was a no-op, so every buffer a list outgrew stayed for the
arena's lifetime. Three changes remove it.

- `DEFAULT_CAPACITY` is budgeted in **bytes**, not elements
  (`default_capacity`, `list.f`): 1 KB worth of elements, clamped to
  `[1, 8]`. A fixed element count makes the first allocation scale with
  `size_of(T)` - at 16 slots a `List(Stmt)` grabbed 7 KB to hold one
  statement. Rust's `RawVec::MIN_NON_ZERO_CAP` splits its minimum on
  element size for the same reason.
- `reserve` grows through `realloc` rather than alloc-copy-free, and
  `arena_realloc`/`arena_dealloc` handle the block at the bump cursor in
  place - the last allocation grows, shrinks, or is released by moving
  `page.offset`, copying nothing. `fixed_realloc` already did this; the
  arena was the outlier. (`realloc` carries no alignment argument, so a
  block that has to move takes 16-byte alignment rather than guessing the
  caller's.)
- The projector sizes each list from the CST up front
  (`child_capacity` over `node_child_count`, `projector.f`): the node
  children are an exact upper bound on the elements projected out of them,
  so a list is filled without ever growing. Counting the slots directly
  rather than through `child` keeps it under 1% of check time.

On a compiler self-check these take AST arena bytes from 155 MB to 66 MB,
peak RSS from 374 MB to 250 MB, and `flang check` from 717 ms to 413 ms.
With the boxed AST above the arena lands at 33 MB, RSS at 209 MB, and the
check at 388 ms.

**Interned types (RFC-024).** In the self-hosted checker `Ty` is a
4-byte handle (`pub type Ty = u32`) into a `TypeInterner` - one `TyNode`
per distinct type, children as handles sliced out of one flat array,
identity by structure. `Void`, `Never`, `Error` and the 14
primitives hold fixed ids (`type.f`), so the common leaves never hash.
Consequences:

- `a == b` on handles IS type equality; there is no structural `equals`.
- The lookup key is `TyKey`, a fixed-size struct with `#derive(eq, hash)`,
  so `Dict` settles collisions itself and interning allocates nothing on a
  hit. Variable-arity children do not fit a fixed struct, so a child
  sequence is interned separately as a cons chain and enters the key as one
  id; those ids live in their own space and never escape `interner.f`.
  Record fields carry a name and get their own cell type and dict, so the
  common lists do not pay for a `String` they never use.
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

### Parameter copy elision

`lib/flang_driver/src/param_elision.f` runs on each function as the builder finishes it, before it
reaches an `IrModule`. It removes the prologue shadow copy of a by-value aggregate parameter whose
body neither writes to it nor lets its address escape, which is what spec §3.2 promises. It is part
of lowering rather than the optimization pipeline because the elision is a language guarantee, not a
speed-up: the address of a read-only parameter is observably the caller's, and E2122 exists to keep
that observation sound.

The analysis is intraprocedural and reads no callee bodies - any tainted address reaching a call
argument is an escape. Working on FIR is what makes the classification total: twelve instruction
forms cover every construct the language has, since desugars, operators, UFCS receivers and template
expansions all arrive as loads, stores, geps and calls.

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

## Build Cache — NOT IMPLEMENTED

Companion `.c` files (stdlib's `simd.c`, `bits.c`, `io/internal/fs.c`, `atomic.c`, plus any project-local C) are recompiled on every build. `flang_codegen/src/backend.f` reserves the seam — `IrModule` carries pre-compiled objects to link as-is — but nothing populates it, so a warm build pays the same C compile as a cold one.

The design below is the shape to build against, kept because it was implemented once and the constraints still hold. A `build/cache/` directory in a working tree is a leftover, not a live cache.

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
- **Mangling is total over the module path.** The path comes from the project name and file path, not from a FLang identifier, so both manglers escape rather than pass bytes through — see `docs/spec.md` §7.1.1, property 4. `symbol_table.f::append_module_path`: `.` → `__`, `_` → `_0`, any byte outside `[A-Za-z0-9]` → `_x<hex>`; injective, because a literal `_` always becomes `_0`, so `__` and `_x` can only come from an escape. `#foreign` structs keep their original C name and are exempt.
- **Foreign/intrinsic symbols are not mangled.** `#foreign` and `#intrinsic` calls use their declared names directly.
- **By-value aggregates cross C boundaries as real structs.** `IrType.Agg` carries `{name, size, align}`; the matching `AggDef` on `IrModule.aggs` carries the member list the backend emits as a `typedef struct`, nested types first. Members are faithful (a `f32` emits as `float`) because the platform ABI classifies a struct by its member types. Only foreign calls use this — native calls still pass addresses and return through sret. `symbol_table.f::agg_abi_safe` is the single gate, and it tests **layout agreement**: an aggregate may cross only if C's natural layout of its members reproduces the FLang layout, which rules out every `Repr.Auto` struct whose fields got reordered by descending alignment.
- **Foreign structs skip codegen.** `IrStruct.IsForeign` structs have no typedef or definition emitted — the `#include` of the original C header provides them. Their `CName` is the original C name (e.g. `Color`), not mangled.
- **Intrinsics declared in `stdlib/core`** with `#intrinsic` directive.

## Bootstrap Seed (`boot/`)

The committed artifact a clean clone can rebuild the compiler from with only a C99 compiler, and since the reference compiler's retirement the only way in. One directory per target (`boot/win-x64`, `boot/linux-x64`, `boot/darwin-arm64`), each holding `flang.c` — the whole compiler as stage-2-emitted C for that target's `#if` context — plus the stdlib's hand-written runtime sidecar `.c` files, copied so the seed is a closed set even when HEAD's stdlib drifts. `boot/SEED` records version, commit, and date. Cold start: `make` (or `build.bat` on Windows) in the seed directory produces `flang-seed`, which builds the current sources.

- **The only writer is `dotnet run promote.cs`.** It refuses unless stage-2 = stage-3 emitted C is byte-identical and the full harness is green under stage 2, then emits every target's seed via `flang -E -T <os> -A <arch> build` (`-E` stops after writing the generated C — no toolchain runs, so one host emits all targets). Each promote is its own commit, tagged `seed/<YYYYMMDD>`. One tag per date, naming that date's current seed: a second promote on the same date moves it (`git tag -f`, force-pushed), and the superseded promote stays reachable on `main`.
- **Seed rule.** Compiler, `lib/*`, and `stdlib` sources may only use language features the current seed supports. New feature order: implement, harness-test, promote, then use. Promotion is deliberate (feature about to be used in compiler source, runtime/ABI change, periodic refresh), not per-commit.
- **CI `bootstrap` job** (skips until a seed exists): cc the seed, seed builds stage 1, stage 1 builds stage 2, stage 2 builds stage 3, assert stage-2 C == stage-3 C. The diverse-double-compiling check that ran beside it needed a second, independently-rooted compiler; the seed is the only root left, so a compiler that miscompiles itself consistently would satisfy the fixpoint. Restoring root diversity (a second C compiler, an archived binary) is open.

Survey of how other self-hosted compilers bootstrap, and the rationale for this shape: `docs/notes/self-host-bootstrapping.md`.

## Instrumentation (`--stats`)

Every readout the compiler has about its own run is behind one flag, accepted by `build`, `check` and `test`. There are no environment variables: a switch the compiler reads is a CLI option, and a knob the *produced binary* needs is baked in at build time by the generated entry point, which hands it to the runtime sidecar before anything else runs.

`--stats` prints, in this order:

| Line | Source |
|---|---|
| `(N modules, N nodes typed)` | the analyzed project |
| lowering skip report | `IrModule.skip_notes`, one line per function lowering refused, with the reason (temporary scaffold, see `lower.f`) |
| `interner:` | `TypeInterner` counters - distinct types, intern calls, hits, cons cells |
| `memory:` | AST arena capacity against bytes handed out, page count, source bytes, and each side table's own capacity |
| `allocator:` | a `CountingAllocator` wrapped around the global allocator for the run: allocs, reallocs, frees, live, peak, total |
| `timings:` | wall time per phase, the typechecker broken into its own nine |

Under `test` it also arms the ledger in `stdlib/std/test.c`, so a leaking test reports the allocation stack behind each group of leaked blocks (see §Testing).

`live` in the allocator line counts everything still out when the readout runs, the readout's own structures included, so it is a floor on what leaked rather than the leak itself. Arena pages are counted twice across the two lines - once as bytes the arena took from the global allocator, once as arena capacity.

The profiler is separate (§Profiler): it changes codegen and costs runtime, so it stays its own flag rather than riding on a readout.

## Profiler (`--profile`)

Self-hosted compiler only (RFC-025). `flang build -p` instruments the target program for profiling; the flag implies `--release` so the profile measures optimized codegen. `-p` instruments the application's functions only — stdlib time bills to the calling application function's self time, the way a foreign call's does — and `-P`/`--profile-all` widens to the whole program. At process exit the binary writes a flat table (calls, self ms, inclusive ms, ns/call, sorted by self time) to stderr; with `--profile-out <path>` on the build it also writes folded stacks (`a;b;c <self_ns>` per call path), the input format of speedscope / inferno / flamegraph.pl.

**Display names.** Reports show `module.path.name(&Type,u32)`, not mangled symbols. The pretty form is built where symbols are assigned (`symbol_table.f::pretty_symbol`, the one place holding fqn + typed signature), keyed by mangled symbol, and travels on `IrModule.displays`; parameter types render by short name — the function's fqn already places the frame, and short parameters keep the folded output an order of magnitude smaller. Symbols without an entry (`main`, foreigns, generated helpers) display as themselves.

**Compile side** (`lib/flang_codegen/src/instrument.f`, invoked from `flang_driver.compile::build_program`): a FIR pass that runs after every other FIR transform, so earlier passes (the shim inliner's size budget in particular) see the uninstrumented module and make the same decisions as a plain build. Each instrumented function gets a dense id, `__flang_prof_enter(id)` as its first instruction, and `__flang_prof_exit()` before every `Ret`. Anything erased before the pass runs (inlined-away functions, once self-hosted inlining lands) is never instrumented — its cost bills to the caller, where it actually runs; a function that still exists at instrumentation time is profiled as the call it actually is, `#inline`-annotated or not. `tools/profiler_check` (`check.ps1`) is the acceptance suite: a ground-truth workload with exact call counts and per-function time budgets, validating counts, self/inclusive accuracy under direct and mutual recursion, `?` early returns, `dump()`/`reset()` window separation, folded-file invariants, and overflow degradation. `main` additionally gets `__flang_prof_register(count, names, names_len)` as its very first instruction (ahead of const-init wiring), carrying a newline-separated name-table global. The driver links `stdlib/std/profile.c` as the probe runtime, deduped against the companion-`.c` rule for projects that import `std.profile`.

**Runtime side** (`stdlib/std/profile.c`): probes maintain a call tree — one node per distinct call path, `{func_id, first_child, next_sibling, parent, calls, total_ticks}` in a preallocated pool with move-to-front sibling lists — plus a shadow stack of `{node, t_enter}`. The hot path is two raw cycle-counter reads (`rdtsc` / `cntvct_el0`; OS clock fallback), a usually-one-compare child lookup, and a few stores; ticks-to-ns conversion, name lookup, per-function aggregation, and sorting all happen at dump. Self time is interval-accounted at runtime: every probe event closes an interval billed to the node that was executing. (Deriving self as "span minus child spans" at dump would mis-attribute under recursion collapse — a re-entry's subtree hangs under the outer node, so the frames temporally in between would absorb its whole cost.) Enter reads the clock after its lookup and exit reads it first, so probe bookkeeping bills to the caller, where a startup calibration (timed enter/exit pairs against the empty tree) subtracts it from self times at dump. **Recursion is collapsed at runtime**: re-entering a function whose span is already open reuses the open node (call counted, time covered by the outer span, deeper distinct calls attach under the same node) — without this a recursive checker mints one path per recursion level and any pool drowns; a side effect is that no node ever has a same-function ancestor, so inclusive sums are correct by construction. Pool and stack sizes are baked in at build time (`--profile-nodes`, default 1Mi / `--profile-depth`, default 8Ki), handed to the runtime by the generated entry point before the first probe; overrun never corrupts pairing and is reported in the dump header. The folded file is cut at a fixed 32 MB budget that keeps the heaviest paths — folded lines are order-independent, so the cut drops only the lightest tail, and the dump says how much; the kept lines are written in first-entry order, so a viewer's time-ordered layout shows the program's phases left to right (true aggregates live in the left-heavy view — folded data carries no timestamps). `std.profile` exposes `dump()` / `reset()` for phase-scoped profiling; both are no-ops in uninstrumented builds. Single-threaded, like the FLang runtime.

## C FFI Binding Generation — NOT IMPLEMENTED

Generating FLang bindings from a C header (`flang -I raylib.h`) was a reference-compiler feature built on CppAst; the self-hosted CLI has no `-I` and no header parser. Bindings are hand-written today: `examples/raylib` carries a checked-in `vendor/` module.

Writing bindings by hand, the conventions to follow are the ones the generator used, and the ones the C backend still expects:

- C pointers map to `Option(&T)`. C enums map to `pub const: i32`. C structs map to `#foreign struct`.
- Foreign header paths travel on `IrModule.foreign_includes` and are emitted as `#include` directives in the generated C.

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
a pure text-to-text function; file IO stays in `compiler/src/main.f`.

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
- **The layout shows the parse.** FLang has no statement terminator and the
  parser is greedy, so a line opening with a binary operator, `.`, `(` or
  `[` continues the line above rather than starting a statement. Three of
  those tokens - `-`, `(` and `[` - could equally open a statement, so a
  break in front of one draws two statements where the parse has one; they
  are joined back onto the line they continue. The rest cannot be misread
  at the start of a line and keep their authored break, rendered one step
  deeper than statement indent. Joining is conditional on the previous
  token being able to end an expression: after an open brace, `(` opens a
  statement of its own and is left alone.
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

**Self-hosted (`flang lsp [-s <stdlib>]`, `lib/flang_lsp`)** — the successor, in-process in the compiler. Speaks LSP over stdio through `std.rpc.jsonrpc` (Content-Length framing + JSON-RPC 2.0 envelope over `Reader`/`Writer`, so transcripts are testable in-process with `MemReader`). Single-threaded. Implemented so far: initialize/shutdown/exit lifecycle, position-encoding negotiation (utf-8 preferred, utf-16 fallback), full-sync document store (`didOpen`/`didChange`/`didClose`/`didSave`), per-document line index / position codec, `publishDiagnostics` with `$/progress`, the tier-1 features (`documentSymbol`, `foldingRange`, syntax diagnostics per keystroke), one file per feature under `src/handlers/`, and `workspace/symbol` over a per-module symbol index (`src/index.f`: the documentSymbol outline flattened to name/kind/span/container, kept on each open project parallel to its modules, rebuilt after every analysis; project-origin modules only; ASCII case-insensitive substring match, client fuzzy-ranks on top). Feature requests answer MethodNotFound until their phase lands; the roadmap is RFC-023 §Implementation phases.

Cursor-level features (`hover`, `definition`, `typeDefinition`, `references`, `inlayHint`, `signatureHelp`) answer from the last analysis through `src/query.f`: the checker records the span of every node it touched (`TypeCheckResult.spans`), so cursor-to-node is a linear scan for the innermost recorded span at the offset - no AST-finder. Base tables are scanned first, then the specialization overlays (a generic body is checked only per instantiation, so its answers carry one concrete instantiation's types; an uninstantiated template answers nothing). Hover is word-anchored - it answers only with a node starting at the identifier under the cursor and reports the identifier's range, so keywords, annotations and void statement nodes answer null - and renders the node's checked type (or a function target's declaration slice); binder names and parameters have their own typed nodes (`LetStmt.name_span`, `ForStmt.var_span`, param slots; pattern variables and match guards were already per-node). A free variable renders by its declared `$T` name (`checker.type_param_names`); any other open type is never shown. Definition tiers: resolved target at the cursor; then the identifier against the registries (nominal FQN tails, function overload sets - stdlib included); then the ModuleIndex workspace-wide (template `#name`s, tests, consts). References inverts `resolved_targets` (overlays included, deduped), project-scoped, with a declaration-cursor fallback to the name's overload set. signatureHelp works off the live buffer - backward paren scan for the callee and argument index, registry overload set by name, signature labels sliced from each declaration's source up to the body brace. inlayHint walks the module AST for annotation-less `let`/`for` binders and renders their checked types. `textDocument/formatting` runs `lib/flang_fmt`'s `format_source` over the live buffer with the governing manifest's `[fmt]` table applied, answering one whole-document TextEdit.

Analysis model (`src/workspace.f`): projects open lazily — the first `didOpen` of a file under a `flang.toml` runs `analyze_project` over that project (rooted anywhere via `resolver.f::resolve_ctx_at`), synchronously between messages and behind a `$/progress` spinner. A keystroke gets parse-only diagnostics (`src/handlers/syntax_diagnostics.f`, milliseconds); the type tier catches up on `didSave` (`reanalyze`, dirty = the saved file) and on `workspace/didChangeWatchedFiles` (a changed `.f` re-checks; a created/deleted `.f` or any `flang.toml` event rebuilds the project whole). Open buffers always win over disk: every analysis passes the document store's buffers as overrides. Every project-origin file's diagnostics are (re)published after each analysis, empty lists included — that is what clears fixed errors. URIs convert to resolver-convention paths in `src/uri.f` (forward slashes, lowercase drive). The RFC's idle-path demand driving and ~300 ms debounce await stdin polling, which stdio `Reader` cannot do yet; until then a request arriving mid-analysis waits (LSP clients tolerate this — no request timeouts).

The server also emits a custom `flang/serverStatus` notification (after `initialized` and after every analysis): compiler version, workspace folder names, and each open project with its error count. The VS Code extension renders it as a status-bar item, launching the server as `flang lsp -s <p>`.

## Diagnostics

All phases report errors via `Diagnostic` objects with `SourceSpan` locations. Phases add diagnostics and continue when possible — exceptions are not used for user-facing errors. The CLI aggregates and prints diagnostics before exiting.

**Rendering.** `flang_core.render` turns one `Diagnostic` into the framed form — header, `-->`
location, gutter, source lines, caret run — and returns it as a string. It is pure: the path, the
source, a `flang_core.line_index` over it, and a `RenderStyle` all arrive through the signature, so
the whole layout is covered by ordinary test blocks. Caret columns are display columns, so a line
carrying tabs or non-ASCII still gets carets under the right characters.

`compiler/src/frontend.f` is the IO edge: it picks the source by the span's file id, builds each
file's line index once, resolves the style, and writes to **stderr** (build progress goes to
stdout). Color is decided once per run from `--color=auto|always|never`, where `auto` means stderr
is a terminal, `NO_COLOR` is unset and `TERM` is not `dumb`; on Windows, saying yes also enables the
console's escape handling through `std.terminal.enable_ansi`.

The LSP does not use the renderer — it ships structured diagnostics and lets the editor draw them.

**`#allow(CODE, ...)`.** A declaration may name diagnostic codes to silence within its own span.
The filter runs in `flang_analysis` over the assembled list, after every phase has contributed, so
one directive covers parse, resolution, type and warning diagnostics alike. Declaration-level only.

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

**Execution mode.** Every test compiles by subprocessing `$FLANG build --stdlib-path <repo>/stdlib <test.f>` and running the produced executable against its expectations; `$FLANG` defaults to `dist/<rid>/flang`. Compile-diagnostic expectations match textually against the compiler's rendered `severity[CODE]` output; a failing test's message includes the compiler's full stdout/stderr. The harness therefore holds no compiler code of its own — it is a process driver, which is what lets it score any binary, including a stage-2 built minutes ago.

**Test placement:** Language feature tests go in `tests/harness/`. Stdlib and self-hosted library tests (flang_core, flang_parser, flang_typer) are colocated in `.f` source files using `test "name" { ... }` blocks, run by `flang test` from the project directory. `flang test` resolves `[dependencies]` the same way `flang build` does, so a library's blocks can import its sibling libs.

`flang test` runs **only the project's own** `test {}` blocks — those in modules the loader marked `project_origin`. A dependency's (and stdlib's) blocks are that dependency's concern, tested from its own directory; otherwise every consumer re-runs the whole transitive suite. A project with no blocks of its own still links and reports zero tests, which is a success: nothing failed.

**Checking test bodies is opt-in.** `ResolveCtx.check_tests` decides whether phase 3 visits `test {}` bodies at all. A build leaves it off, so a test-only call records no resolution edge and instantiates no specialization — which is why W1003 roots test-bearing modules conservatively there. `flang test`, `flang check` and the LSP turn it on. It widens the *check*, never the module set: the same files load either way, so no filter can change what compiles.

**Filtering.** Both knobs apply at **lowering**, not at glob: a positional path filter keeps blocks whose source path contains it, and `--name <substr>` (alias `-n`) keeps blocks whose label contains it, case-sensitively. Filtering therefore shrinks the binary to exactly what will run while leaving the project's module set whole — a filtered-out file is still compiled and still imported. It also means the compiler knows the match count before the C compiler runs, so `found 0 test(s)` is reported without a link.

**The runner.** Lowering emits each block as a nullary void `__ftest_<n>__` and records `(label, symbol)` on `IrModule.tests`; the backend generates the C entry point from that list. Nothing recovers test identity by parsing instructions. In test mode the project's own `main` is not lowered at all — the runner is the entry point — and the constant initializers, which an ordinary build splices into `main`, become a `__flang_const_init` the runner calls first. A block whose body lowering refuses is reported and dropped from the list, so the runner can never name a symbol that is not in the binary.

The runner is table-driven: one `setjmp` site over an array of function pointers rather than an unrolled block per test, which keeps the generated C small for a suite of any size (the tree has ~1000 blocks). Every counter it mutates lives at file scope, because a local modified between `setjmp` and `longjmp` is indeterminate afterwards (C99 7.13.2.1p3). The header line is flushed *before* the block runs, so a test that crashes the process still names itself.

**Failure and recovery.** `core.panic.panic` calls `__flang_test_abort` under `#if runtime.testing`. The backend defines that in every translation unit: inside a test binary it `longjmp`s back to the runner, which marks the test failed and continues; anywhere else the flag is never set and it is a plain `exit(1)`. Only panics take this route — a deliberate `exit` remains a process exit even under a runner.

**Leak tracking.** `flang test` installs `std.test`'s tracking allocator as the process-wide default (`std.allocator.set_global_allocator`) before the first test, so every `or_global()` in the code under test resolves to it without a test passing anything. The ledger itself is C (`stdlib/std/test.c`): FLang keeps the vtable, which needs the `u8[]?` layout, and C keeps the list of live blocks, which does not. After a passing test the runner reports the blocks still out; after a failing one it only resets, because a `longjmp` unwind skips every `defer` and what is still allocated says nothing. Resetting forgets the ledger entries but never frees the memory — a lazily-initialized global built by one test is still live for the next, and reclaiming it would hand that test a dangling pointer. Leaks are reported, not failed.

**Leak attribution.** `flang test --stats` makes the ledger record a native stack for every block, and makes the runner print the allocation stacks behind a test's leaked blocks, grouped so identical stacks report once with their block and byte totals. Generated functions carry external linkage and mangled FLang FQNs, so the frames read as the FLang call chain that allocated:

```
  leaked 1 block(s), 16 byte(s)
    1 block(s), 16 byte(s) allocated at:
      std__string_0builder__to_0string__ref_std__string_0builder__StringBuilder +0x11d
      std__string__from_0view__core__string__String__... +0xf8
      flang_0lsp__workspace__canonical_0root__... +0x1a1
```

Symbols come from dbghelp on MSVC and `backtrace_symbols` on glibc/macOS; elsewhere the frames print as bare addresses. Off by default — a stack per allocation costs both the capture and the memory to hold it.

**Driver model.** `dotnet test-all.cs` runs every project's blocks through `dist/<rid>/flang`, or `$FLANG` when set.

**Option placement.** The self-hosted CLI is `flang <command> [options] [args]`. The command comes first and every option is parsed against it, from a format built as the shared set (`-h -V -v -s -T -A`) plus that command's own — `test` has `-n/--name`, `build` has `-p/--profile`, `fmt` has `--check`. An option ahead of the command belongs to no command and is refused, `--help` and `--version` excepted. This is what lets two commands use the same letter for different things, and it means one `getopts` pass handles long forms, `--name=value`, clustering and `--` uniformly instead of each handler re-parsing `argv` by hand. The reference CLI accepts either order.

**Compiler layout.** `dotnet run build.cs` builds `compiler/` and installs the result as `dist/<rid>/flang`. The builder is that same installed compiler when it exists, else the cold-start seed at `boot/<rid>/flang-seed`. Installing a *copy* into `dist/` is what stops a self-build from overwriting the binary running it: `flang build` in `compiler/` writes `compiler/build/flang`, never the one in `dist/`.

Stage 1 additionally runs from a copy of the builder (`dist/<rid>/flang-builder`) whenever the builder and the install target are the same file. Windows keeps an executable's image open for a moment after the process exits, so copying onto it races that release — intermittently, which is the worst way to find out.

**Build incrementality.** A no-change `dotnet run build.cs` costs ~2s. `flang build` has no whole-project up-to-date check, so build.cs guards the ~7s stage-1 compile with a timestamp comparison against `compiler/`, `lib/` and `stdlib/` (ignoring `build`/`bin`/`obj` directories). `--force` rebuilds anyway.

**Version.** `--version` and `--help` render `<name> <version> (self-hosted compiler, FLang; flang_parser <version>)` from `project_info()`. Both names and both versions come out empty today — `project_info` is not intercepted at lowering, so the call returns its stdlib body's zero value (docs/known-issues.md §"Minimal RTTI"). Ordinary diagnostics carry a plain `flang:` prefix.

**Lazy demand.** `flang build` checks bodies only for the demand set (RFC-022 §6): the project's own modules, `core.prelude`, the `[imports].global` modules, and everything transitively imported from any of them (`analyze.f::demand_mask` over the loader's import edges). A module outside the set gets no phase-3 slot at all - no node types, no diagnostics, no specializations - which is safe because identifier, operator and constant resolution are import-scoped, so nothing demanded can name it. Everything before phase 3 still runs for every module: type names resolve program-wide (leniently), and phase 2.5 stays eager so preamble literal verdicts are demand-independent. Lowering skips undemanded modules except their `#foreign` declarations (globally-linkable symbols, callable without an import) and skips specializations whose template lives in an undemanded module. `--eager` restores total demand; the LSP and the in-process analysis entry points run eager by default (`ResolveCtx.lazy_bodies`).

**W1003 unused functions.** `flang_analysis/src/unused.f` runs reachability over the recorded resolution edges - `resolved_targets`, `resolved_ops`, receiver-deref chains, and each specialization's overlay tables, with each site attributed to its enclosing function by span containment against the registry's declaration spans. Roots: `main`; every `pub fn` under `kind = "lib"`; sites outside any function body (constant initializers). Opt-in on a build (`-W`/`--warn-unused`), where `test {}` bodies are unchecked and every non-`pub` function of a test-bearing module is therefore rooted conservatively; the LSP checks test bodies and runs it with real test edges (`tests_checked = true`). `_`-prefixed names suppress, matching W1001.

**W1004 unused imports.** Same evidence, aggregated per importing file: the recorded edges, plus the modules whose nominals a file's node types cite, plus what its own declarations cite through the registries (struct fields, enum payloads, function signatures - a foreign or unreachable function's body is never checked, so nothing else records those), plus `std.string_builder` for any file with an interpolation desugar (its calls resolve on synthesized, fileless nodes). An `import M` warns when no edge from the file lands in M or in M's transitive `pub import` closure. Skips where a build is blind: test-bearing modules, generator declarers/invokers, targets exporting type aliases; `pub import` never warns. The first sweep over the tree found 26 dead imports (all removed) and zero false positives after the declaration-citation and interpolation attributions landed.

**The checker outlives one check.** `AnalyzedProject` owns the `Checker`, and `checker.f::begin_demand` readies it for the next demand. What carries is everything registered by a stable key: the nominal registry whole (`nominal_registry.f::carried_copy` - declared and generated names WITH their resolved bodies, plus the anonymous-record definitions and the map that interns them), the function registry whole (`function_registry.f::carried_copy` - schemes at their ids and list positions, with the instantiation templates, declared parameter lists and deprecations beside them), the constant types, the alias bodies, and each module's cached diagnostics, signature facts and body slot (`ModuleBodyCache`). Closure environments are rebuilt by every body pass - run or replayed - so `check_all` retires their ids into `recycled` on the way out and the next demand's identically-ordered registrations reclaim them. Everything else a check computes names variables of the engine that inferred it, and that engine goes.

**The type table outlives one check.** A carried body's `Ty` handles index the interner, so the table is one per project, not per check: `check_all` ships it inside the `TypeCheckResult` as before, and the next demand adopts it back out of that result (`result.f::take_interner` into `checker.f::adopt_interner`), appends, and ships it again. The table only grows, which is what keeps an earlier snapshot's handles valid; `result_diff` accordingly renders both sides of a comparison through the right-hand result's table. Record field names in the table are views into module sources, which is safe under the same retirement rule the registry already relies on: `AnalyzedProject` retires replaced sources rather than freeing them, and retires each replaced `TypeCheckResult` the same way (`retired_results`).

**When carried bodies re-resolve.** A carried body is valid only while the name set it resolved against holds still, so `check_all` falls back to resolving every body from source - exactly a cold check - when a demand adds a declared or generated name, removes one (a retirement nothing reclaimed), or changes a type alias. Alias change is detected by comparing canonical spellings of the retiring modules' alias bodies across re-collection (`render_alias_body`); a body with no canonical spelling counts as changed. Skipped modules still mint their type parameters' fresh variables and span nodes (`burn_type_param_vars`), so the engine's variable stream and the result's span table match a cold check's.

**When carried signatures re-run.** The signature pass follows the same carry rule per module: a module the demand did not re-parse skips it whenever the nominal carry holds AND the module's cached pass recorded nothing beyond node types, spans and resolved literals - a call or operator in a default value, a lambda, an anonymous literal or an interpolation makes the module re-run its pass every demand (`ModuleSigCache.cacheable`). A skipping module replays its cached diagnostics, spans and node types, and burns the variables the pass would have minted (`Engine::burn_var` - counter only, the carried table already holds the nodes), which is what keeps an unannotated constant's carried variable naming the slot the constants pass then binds. Because those handles are absolute ids, the cache is anchored to its position in the variable stream (`ModuleSigCache.vars_at_start`): an upstream edit that changes an earlier module's signature-tier variable count shifts every later position, and the affected modules re-run once to re-anchor. A module that re-runs has its registry entries retired first (`function_registry.f::retire_module`) so its declarations reclaim their slots and ids in place - overload order is part of resolution - and retirements left unclaimed are removed declarations, purged after the pass with their id-keyed side tables. The constants pass (phase 2.5) stays eager: at ~0.1% of a check, re-running every initializer is what keeps calls, generic picks and anonymous literals in initializers cold-identical without a cache of their own.

**When carried bodies replay.** Phase 3 runs one module SLOT at a time - the module's bodies, then the settlement of what they parked: anonymous literals, fn-name values, the specialization drain, the parked calls, a second drain, the literal sweep - and slots end sealed (unresolved parked work is abandoned, never handed to the next slot). Settlement per slot is sound because bodies never share inference variables; module constants, the one cross-body channel, are pinned by phase 2.5. The slot order is demand order, so every encounter-ordered assignment - specialization ids, closure environments, synthesized nodes - is decided per module, which is what lets a kept module REPLAY its slot from `ModuleBodyCache`: the capture window's facts (keys captured live, values harvested from the finished tables - the raw recordings cite engine bindings that die with their demand), the cached window diagnostics, counter burns, then a live re-run of the logged picks in cold process order and of the parked calls - at the ids and in the order a cold check assigns, re-pinning the burned variables the way the cold drain did. Slots replay only when the nominal carry holds, the signature tier's outputs are fingerprint-identical (schemes at reclaim, constants, default-value source text, nominal definitions), no module constant's variable is still open after phase 2.5, and the module's stream anchors (vars/synth/lambda at slot start) match; a slot whose window would emit a literal diagnostic or whose drain reported an uninferable pick re-runs every demand. A replayed slot views an earlier demand's `synth_strings` buffers, so a retired result is slimmed (`result.f::slim_retire` - tables freed, viewed buffers kept) rather than freed whole;

**The specialization registry outlives one check.** The registry travels the way the type table does: `check_all` ships it inside the result, and the next demand adopts it back (`result.f::take_specs` into `checker.f::adopt_specs`). A pick that lands on a carried entry - by its final key, or by call site through the hint lists (`ModuleBodyCache.spec_sites` for a slot's top-level picks, the previous incarnation's dep list for an in-place re-instantiation's nested picks) - REUSES it without re-checking the template body, provided the pick's instantiated signature is concrete at process time and a probe (`checker.f::spec_probe`) validates the entry and, transitively, everything its frame's drain resolved: not stale (template module re-parsed), still replayable (no diagnostic, no parked call, no flagged literal, a concrete final signature), and stream anchors matching at every position the replay would reach - the cached closure symbols bake counter values. Reuse burns the frame's own counter mints, re-registers its closure environments from cached facts, and touches its deps; anything that cannot be reused re-instantiates IN PLACE at the id it holds (`replace_at`), so the ids other modules' caches bake stay valid. Eviction is mark-and-sweep: every resolution stamps the registry's demand generation and `sweep` evicts what the demand never touched - a touched entry's deps are touched with it, so only whole undemanded subgraphs go. A global invalidation resets the registry whole; numbering restarts at zero, exactly a cold check.

`check_all`'s `recollect` list says which modules gather their names from source again; `reanalyze` sets it for exactly the modules it re-parsed. Those modules' declarations are retired from the registry first, each id remembered against its FQN, and a declaration that comes back is re-registered at the id it had, so a re-check hands out the ids a check from cold would. A declaration the edit removed leaves a hole; one the edit added mints a fresh id past every existing one rather than in its module's place. Numbering it where a cold check would puts it ahead of every declaration below it in the file and renumbers all of them, which is the one thing an id-keyed table cannot survive, so appending is the wanted behaviour and not an approximation of cold. What it costs is the oracle: an incremental result and a cold one over the same edited source agree on every declaration but not on the id sequence, so Gate A's by-value comparison only holds over unchanged text.

**Run everything:** `dotnet test.cs` runs the lit-style harness and `dotnet test-all.cs` runs `flang test` in each project. Both compile through `dist/<rid>/flang`, or `$FLANG` when set — which is how a stage-2 compiler is scored before a promote.
