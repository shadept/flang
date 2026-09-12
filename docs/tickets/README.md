# Tickets

Design proposals for the language, compiler, stdlib and tooling. Each file opens with a
YAML block; the body is free-form.

Fields: `status`, `type`, `created`, then only where they apply: `implemented`, `requires`,
`supersedes`, `superseded-by`, `relates`.

Status: draft, deferred, accepted, provisional, implemented, superseded, withdrawn.
Type: language, compiler, stdlib, tooling.

| RFC | Title | Type | Status | Created | Implemented |
| --- | --- | --- | --- | --- | --- |
| [001](001-decouple-astlowering-from-typechecker.md) | Decouple HmAstLowering from HmTypeChecker | compiler | withdrawn | 2026-03-25 |  |
| [002](002-consolidate-typechecker-state.md) | Consolidate HmTypeChecker State into Typed Registries | compiler | withdrawn | 2026-03-25 |  |
| [003](003-basicblock-ir-builder-with-cfg.md) | Promote BasicBlock to IR Builder with CFG Construction | compiler | withdrawn | 2026-03-26 |  |
| [004](004-string-interpolation.md) | String Interpolation | language | draft | 2026-04-19 |  |
| [005](005-async-runtime.md) | Async / Coroutines | language | draft | 2026-04-21 |  |
| [006](006-syntax-cleanup-quick-wins.md) | Syntax Cleanup — Quick Wins | language | implemented | 2026-05-03 | 2026-05-03 |
| [007](007-option-as-enum.md) | Option as Enum, `null` as `Option.None` | language | implemented | 2026-05-03 | 2026-05-03 |
| [008](008-single-declaration-form.md) | Single Declaration Form for Structs and Enums | language | implemented | 2026-05-03 | 2026-05-03 |
| [009](009-op-try-early-return.md) | `op_try` Early-Return Operator | language | implemented | 2026-05-03 | 2026-05-03 |
| [010](010-pattern-grammar-and-optional-flattening.md) | Pattern Grammar Extensions and `?.` Flattening | language | implemented | 2026-05-03 | 2026-05-04 |
| [011](011-template-dsl-extensions.md) | Source Generator Template DSL Extensions | compiler | superseded | 2026-05-03 |  |
| [012](012-owned-transfer-tracking.md) | `Owned(T)` — transfer-aware cleanup helper | stdlib | implemented | 2026-05-03 | 2026-05-03 |
| [013](013-pub-import.md) | `pub import` and non-transitive import enforcement | language | implemented | 2026-05-03 | 2026-05-03 |
| [014](014-callable-types-and-closures.md) | `op_call` and closure literals | language | provisional | 2026-05-05 |  |
| [015](015-fir-inliner-and-dce.md) | FIR optimization pipeline (inliner + DCE + cleanup passes) | compiler | draft | 2026-05-05 |  |
| [016](016-auto-deinit-directive.md) | `#auto_deinit` directive and the managed-lifecycle contract | language | draft | 2026-05-11 |  |
| [017](017-typer-as-library.md) | `flang_typer` — type system as a library | compiler | provisional | 2026-05-15 |  |
| [018](018-fn-ref-promotion-and-callback-params.md) | `fn(T)` → `fn(&T)` promotion, and `&T` callback parameters in the stdlib | compiler | withdrawn | 2026-08-20 |  |
| [019](019-callback-adaptation-and-generic-constraints.md) | Deferred designs from the lambda/stdlib-combinator milestone | language | draft | 2026-08-20 |  |
| [020](020-op-deref-argument-coercion.md) | `op_deref` argument coercion (deref chains at call sites) | language | implemented | 2026-08-20 | 2026-08-23 |
| [021](021-template-expansion-redesign.md) | Template Expansion Redesign — single-pass, in-memory, self-host parity | compiler | draft | 2026-08-23 |  |
| [022](022-demand-driven-checker.md) | Demand-driven checker - declaration-level queries, incremental invalidation | compiler | implemented | 2026-08-25 | 2026-08-27 |
| [023](023-language-server.md) | Language server - in-process, self-hosted, retires FLang.Lsp | tooling | accepted | 2026-08-25 |  |
| [024](024-interned-types.md) | Interned types - `Ty` becomes a handle | compiler | implemented | 2026-08-26 | 2026-08-26 |
| [025](025-built-in-profiler.md) | Built-in profiler | tooling | provisional | 2026-08-27 |  |
| [026](026-copy-on-write-parameters.md) | Copy-on-write parameters - elide the shadow when nothing writes or escapes | compiler | implemented | 2026-08-29 | 2026-08-30 |
| [027](027-diagnostic-rendering.md) | Diagnostic rendering - source snippets, carets and color | tooling | implemented | 2026-08-30 | 2026-08-30 |
| [028](028-owned-fields-and-move.md) | `owned` fields, non-copyable types, and `move` | language | accepted | 2026-08-30 |  |
| [029](029-checking-uninstantiated-generic-bodies.md) | Checking uninstantiated generic bodies | compiler | deferred | 2026-09-01 |  |
| [030](030-reference-form-operator-dispatch.md) | Reference-form operator dispatch | language | draft | 2026-09-01 |  |
| [031](031-owned-generic-consolidation.md) | `Owned(T)`, one ownership wrapper | stdlib | draft | 2026-09-01 |  |
| [099](099-stack-only-types-and-bindings.md) | `#stack` types and stack-only bindings | language | deferred | 2026-08-27 |  |
