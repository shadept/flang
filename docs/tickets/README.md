# Tickets

Design proposals for the language, compiler, stdlib and tooling: the planning queue and the log
of every feature. Each file opens with a YAML block; the body is free-form.

Fields: `status`, `type`, `created`, then only where they apply: `accepted`, `implemented`,
`requires`, `supersedes`, `superseded-by`, `relates`.

Type: language, compiler, stdlib, tooling.

| Status | Next | Meaning |
| --- | --- | --- |
| `draft` | owner | Design open, or parked; a parked RFC says what it waits on. Not implemented. |
| `accepted` | agent | Design approved, nothing landed. `accepted:` holds the approval date. |
| `in-progress` | agent | Some phases landed. Opens with a progress line naming the next phase. |
| `implemented` | - | Every planned phase shipped. `implemented:` holds the landing date. Final. |
| `dropped` | - | Never shipped. `superseded-by` names the replacement, or a line at the top says why. Final. |

Superseded is a field, not a status: `implemented` + `superseded-by` shipped and was later replaced,
`dropped` + `superseded-by` was replaced before it shipped.

## Moving an RFC

- **Approve:** the owner moves `draft` to `accepted` and sets `accepted:`. An agent does not
  approve its own RFC.
- **First phase lands:** `in-progress`, with a progress line at the top: what landed, what is next.
- **Last phase lands:** `implemented` with `implemented:` set to the landing commit's date; index
  row updated; progress line removed. Where the shipped design differs from the text, a
  "Deviations" note at the top; otherwise the body is frozen and `docs/spec.md` governs. A
  replacing RFC sets `supersedes`, each replaced RFC `superseded-by`. The docs CLAUDE.md lists
  change in the same commit.
- **After shipping:** bugs and limitations go to `docs/known-issues.md`; they do not reopen the RFC.
- **Drop:** `dropped`, with `superseded-by` or a one-line reason.
- **Commits** landing RFC work carry `(RFC-NNN)`, so `git log --grep=RFC-NNN` is its history.

| RFC | Title | Type | Status | Created | Implemented |
| --- | --- | --- | --- | --- | --- |
| [001](001-decouple-astlowering-from-typechecker.md) | Decouple HmAstLowering from HmTypeChecker | compiler | dropped | 2026-03-25 |  |
| [002](002-consolidate-typechecker-state.md) | Consolidate HmTypeChecker State into Typed Registries | compiler | dropped | 2026-03-25 |  |
| [003](003-basicblock-ir-builder-with-cfg.md) | Promote BasicBlock to IR Builder with CFG Construction | compiler | dropped | 2026-03-26 |  |
| [004](004-string-interpolation.md) | String Interpolation | language | implemented | 2026-04-19 | 2026-04-19 |
| [005](005-async-runtime.md) | Async / Coroutines | language | draft | 2026-04-21 |  |
| [006](006-syntax-cleanup-quick-wins.md) | Syntax Cleanup — Quick Wins | language | implemented | 2026-05-03 | 2026-05-03 |
| [007](007-option-as-enum.md) | Option as Enum, `null` as `Option.None` | language | implemented | 2026-05-03 | 2026-05-03 |
| [008](008-single-declaration-form.md) | Single Declaration Form for Structs and Enums | language | implemented | 2026-05-03 | 2026-05-03 |
| [009](009-op-try-early-return.md) | `op_try` Early-Return Operator | language | implemented | 2026-05-03 | 2026-05-03 |
| [010](010-pattern-grammar-and-optional-flattening.md) | Pattern Grammar Extensions and `?.` Flattening | language | implemented | 2026-05-03 | 2026-05-04 |
| [011](011-template-dsl-extensions.md) | Source Generator Template DSL Extensions | compiler | dropped | 2026-05-03 |  |
| [012](012-owned-transfer-tracking.md) | `Owned(T)` — transfer-aware cleanup helper | stdlib | implemented | 2026-05-03 | 2026-05-03 |
| [013](013-pub-import.md) | `pub import` and non-transitive import enforcement | language | implemented | 2026-05-03 | 2026-05-03 |
| [014](014-callable-types-and-closures.md) | `op_call` and closure literals | language | implemented | 2026-05-05 | 2026-08-20 |
| [015](015-fir-inliner-and-dce.md) | FIR optimization pipeline (inliner + DCE + cleanup passes) | compiler | in-progress | 2026-05-05 |  |
| [016](016-auto-deinit-directive.md) | `#auto_deinit` directive and the managed-lifecycle contract | language | draft | 2026-05-11 |  |
| [017](017-typer-as-library.md) | `flang_typer` — type system as a library | compiler | implemented | 2026-05-15 | 2026-08-29 |
| [018](018-fn-ref-promotion-and-callback-params.md) | `fn(T)` → `fn(&T)` promotion, and `&T` callback parameters in the stdlib | compiler | dropped | 2026-08-20 |  |
| [019](019-callback-adaptation-and-generic-constraints.md) | Deferred designs from the lambda/stdlib-combinator milestone | language | dropped | 2026-08-20 |  |
| [020](020-op-deref-argument-coercion.md) | `op_deref` argument coercion (deref chains at call sites) | language | implemented | 2026-08-20 | 2026-09-16 |
| [021](021-template-expansion-redesign.md) | Template Expansion Redesign — single-pass, in-memory, self-host parity | compiler | implemented | 2026-08-23 | 2026-08-24 |
| [022](022-demand-driven-checker.md) | Demand-driven checker - declaration-level queries, incremental invalidation | compiler | implemented | 2026-08-25 | 2026-08-27 |
| [023](023-language-server.md) | Language server - in-process, self-hosted, retires FLang.Lsp | tooling | in-progress | 2026-08-25 |  |
| [024](024-interned-types.md) | Interned types - `Ty` becomes a handle | compiler | implemented | 2026-08-26 | 2026-08-26 |
| [025](025-built-in-profiler.md) | Built-in profiler | tooling | in-progress | 2026-08-27 |  |
| [026](026-copy-on-write-parameters.md) | Copy-on-write parameters - elide the shadow when nothing writes or escapes | compiler | implemented | 2026-08-29 | 2026-08-30 |
| [027](027-diagnostic-rendering.md) | Diagnostic rendering - source snippets, carets and color | tooling | implemented | 2026-08-30 | 2026-08-30 |
| [028](028-owned-fields-and-move.md) | `owned` fields, non-copyable types, and `move` | language | implemented | 2026-08-30 | 2026-08-31 |
| [029](029-checking-uninstantiated-generic-bodies.md) | Checking uninstantiated generic bodies | compiler | draft | 2026-09-01 |  |
| [030](030-reference-form-operator-dispatch.md) | Reference-form operator dispatch | language | dropped | 2026-09-01 |  |
| [031](031-owned-generic-consolidation.md) | `OwnedString`, a `String` that owns its buffer | stdlib | implemented | 2026-09-01 | 2026-09-16 |
| [033](033-parameter-declared-ownership.md) | Parameter-declared ownership | language | implemented | 2026-09-14 | 2026-10-10 |
| [034](034-typed-slice-intrinsics.md) | Typed slice intrinsics | language | implemented | 2026-10-10 | 2026-10-10 |
| [035](035-contracts.md) | Contracts | language | implemented | 2026-10-11 | 2026-10-11 |
| [036](036-associated-types-and-type-parameter-bounds.md) | Associated types, projection, and bounds on type parameters | language | implemented | 2026-10-11 | 2026-10-11 |
| [037](037-callable-values.md) | Function types as callable values | language | implemented | 2026-10-11 | 2026-10-19 |
| [038](038-runtime-context.md) | Runtime context | language | implemented | 2026-10-17 | 2026-10-18 |
| [039](039-lambda-syntax.md) | Lambda syntax | language | implemented | 2026-10-17 | 2026-10-18 |
| [040](040-coalesce-via-op-try.md) | `??` through `op_try` | language | implemented | 2026-10-18 | 2026-10-18 |
| [041](041-native-calling-convention.md) | Native calling convention | compiler | draft | 2026-10-18 |  |
| [042](042-loop-labels.md) | Loop labels | language | implemented | 2026-11-10 | 2026-11-13 |
| [043](043-memory.md) | Heap memory as an owned resource | language | implemented | 2026-10-25 | 2026-10-26 |
| [044](044-c-bindings-from-headers.md) | C bindings from headers, `#foreign union`, opaque types | compiler | implemented | 2026-11-13 | 2026-11-14 |
| [098](098-context-across-libraries.md) | Context across separately compiled libraries | compiler | draft | 2026-10-25 |  |
| [099](099-stack-only-types-and-bindings.md) | `#stack` types and stack-only bindings | language | draft | 2026-08-27 |  |
