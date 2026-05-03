# RFC-013 — `pub import` and non-transitive import enforcement

**Status:** Implemented (2026-05-03)

## Problem

`docs/spec.md` §6 stated imports were "flat and non-transitive" and mentioned `pub use` as a re-export mechanism. Neither was true:

1. The lookup filter in `FunctionRegistry` allowed *any* `pub` symbol from *any* loaded module to be referenced by short name. Visibility was effectively global. The transitive-leak made the spec's "non-transitive" claim aspirational.
2. `pub use` did not exist — no token, no AST node, no parser path.
3. The auto-prelude (`stdlib/core/predule.f`, typo'd) "worked" only because of the leak: its plain `import core.cmp` lines pulled those modules into the compilation, after which the leak made all their `pub` items globally visible. There was no real re-export.

## Decision

Adopt the Rust/Nim model: opt-in re-export via a new modifier on `import`, plus a curated auto-prelude.

1. **`pub import path`** is the only re-export mechanism. Re-exports compose transitively along chains of `pub import`. Plain `import` remains non-transitive.
2. **`core.prelude`** (renamed from the typo'd `predule`) is auto-imported into every module. It uses `pub import` to re-export the core modules, so all core symbols are visible without explicit imports.
3. **`std.prelude`** is a regular file users opt into with `import std.prelude`. Curates a small set of widely-used `std` modules. Not auto-imported.
4. **`flang.toml [imports].global`** lets projects inject implicit private imports into every project file. Scoped to `Project`-origin modules only — stdlib and (future) third-party packages are isolated.
5. **No `pub use`** — `pub import` matches FLang's existing pattern of `pub` as a visibility prefix on declarations and avoids introducing a second related keyword.

## Mechanism

`Compilation` tracks `ModuleImports[M]` (all imports) and `ModuleReExports[M]` (subset that is `pub import`). `GetVisibleModules(M)` computes a cached transitive closure: `{M} ∪ ModuleImports[M]` plus the closure over `ModuleReExports` edges only. `FunctionRegistry.Lookup` and `TypeRegistry.LookupNominalType` filter by this set; FQN-style references (with a dot) bypass.

Generic specialization is handled by tracking a stack of caller modules in `InferenceContext.SpecializationCallers` and unioning their visibility into the lookup set during body checking. This preserves UFCS-extension dispatch — the generic body can still resolve to user-defined overloads imported by the caller.

`ModuleOrigin` (`Stdlib` / `Project` / `External`) is set during module load. Project-level globals only apply when `Origin == Project`; `External` is reserved for the future package system.

## Implementation phases

1. Plumbing: `IsPublic` on `ImportDeclarationNode`, parser support, `Compilation.ModuleImports/ModuleReExports`, `GetVisibleModules`. No behavior change.
2. Rename `stdlib/core/predule.f` → `stdlib/core/prelude.f`, update loader and references.
3. Convert prelude to `pub import`. Add minimal `stdlib/std/prelude.f`.
4. `ModuleOrigin` tagging in `ModuleCompiler`. `[imports].global` parsing in `ProjectLoader`. Synthetic-import injection in `Compiler` and `FLangWorkspace`.
5. Flip the lookup filter to honor `Visible[M]`. Bypass for FQN-style references. Specialization-caller visibility union for generics. Remove the cross-module function-name leak via `_ctx.Scopes.Bind` (functions resolve through `LookupFunctions`, which is visibility-aware).
6. Validate: stdlib files were silently relying on transitive leaks for `std.option`, `std.result`, `std.mem`, `std.encoding.utf8`, etc. Added explicit imports.
7. Test matrix in `tests/FLang.Tests/Harness/imports/`:
   - `transitive_leak_regression.f` — non-transitive enforcement (expects `E2004`).
   - `pub_import_parses.f` — parser sanity check.
   - `pub_import_reexport.f` — single-step re-export.
   - `pub_import_chain.f` — multi-step `pub import` chain.
   - `pub_import_diamond.f` — two paths to same module, no duplicate-symbol error.
8. Spec, architecture, and known-issues docs updated; this RFC checked in.

## Migration impact

Within this PR: ~7 stdlib files and ~6 user tests needed explicit imports they had been silently inheriting via the leak. The compilation graph (which files get parsed) was unchanged — only visibility filtering changed.

Future user-facing impact: any user code that had been relying on transitive leaks must add explicit imports. The error message (`E2004 Unresolved function`) is actionable.

## Deferred

- Per-folder or per-build-target scoping for `[imports].global`.
- `pub import` cycle detection (currently handled implicitly by the visibility-cache's `explored` set; explicit error message would be friendlier).
- Per-file opt-out of the auto-prelude (e.g. for stdlib bootstrapping or tests). Not needed yet.
- LSP completion currently uses the same `Visible[M]` machinery, but UI improvements (e.g. suggesting an `import` on unresolved symbols) are future work.
