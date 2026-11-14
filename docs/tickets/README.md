# Tickets

Design proposals for the language, compiler, stdlib and tooling. The text of every RFC lives
here, in git. Its state lives only in Linear, team Shade (`SH`): see
`docs/agents/issue-tracker.md`. Nothing in this folder records state, so nothing here changes
when work moves.

Each file opens with a YAML block; the body is free-form.

Fields: `type`, `created`, `linear`, then only where they apply: `requires`, `supersedes`,
`superseded-by`, `relates`.

- `type`: language, compiler, stdlib, tooling.
- `linear`: the Linear issue (`SH-NN`) or project (`P-SH-N`) that tracks the RFC.

## State

Read it from what `linear:` names:

- **Draft:** an open "Decide RFC-NNN" issue. Implement nothing from a draft.
- **Accepted:** the decide issue is Done, or `linear:` names a project.
- **Implemented:** the implementing issue or project is Done.
- **Dropped:** the issue or project is Canceled.

`superseded-by` on an implemented RFC means it shipped and was later replaced; on a dropped one,
it was replaced before it shipped.

## Moving an RFC

- **New:** add the file and a row below, and create a Linear issue "Decide RFC-NNN: <title>"
  in `SH` with labels `flang`, `RFC` and the area. Put its id in `linear:`.
- **Approve:** the owner closes the decide issue as Done. An agent does not approve its own RFC.
  Single-phase: one implementation issue; `linear:` then names it. Several phases: a project
  named for the outcome ("FLang <can now do X> (RFC-NNN)") with one issue per phase;
  `linear:` then names the project.
- **Phases land:** progress lives in Linear (issue states, project description). Do not add
  progress lines to the RFC.
- **Last phase lands:** the issue or project closes as Done. Where the shipped design differs
  from the text, a "Deviations" note at the top; otherwise the body is frozen and
  `docs/spec.md` governs. A replacing RFC sets `supersedes`, each replaced RFC `superseded-by`.
  The docs CLAUDE.md lists change in the same commit.
- **After shipping:** bugs go to Linear as `Bug` issues; limitations by design go to
  `docs/known-issues.md`. Neither reopens the RFC.
- **Drop:** cancel the Linear issue or project, and add `superseded-by` or a one-line reason at
  the top of the file.
- **Commits** landing RFC work carry `(RFC-NNN)`, so `git log --grep=RFC-NNN` is its history.
  Put the Linear id in the branch name or PR title (`sh-12-...`, `SH-12: ...`) so Linear links
  the work.

| RFC | Title | Type | Linear |
| --- | --- | --- | --- |
| [001](001-decouple-astlowering-from-typechecker.md) | Decouple HmAstLowering from HmTypeChecker | compiler | SH-58 |
| [002](002-consolidate-typechecker-state.md) | Consolidate HmTypeChecker State into Typed Registries | compiler | SH-59 |
| [003](003-basicblock-ir-builder-with-cfg.md) | Promote BasicBlock to IR Builder with CFG Construction | compiler | SH-60 |
| [004](004-string-interpolation.md) | String Interpolation | language | SH-29 |
| [005](005-async-runtime.md) | Async / Coroutines | language | P-SH-8 |
| [006](006-syntax-cleanup-quick-wins.md) | Syntax Cleanup — Quick Wins | language | SH-30 |
| [007](007-option-as-enum.md) | Option as Enum, `null` as `Option.None` | language | SH-31 |
| [008](008-single-declaration-form.md) | Single Declaration Form for Structs and Enums | language | SH-32 |
| [009](009-op-try-early-return.md) | `op_try` Early-Return Operator | language | SH-33 |
| [010](010-pattern-grammar-and-optional-flattening.md) | Pattern Grammar Extensions and `?.` Flattening | language | SH-34 |
| [011](011-template-dsl-extensions.md) | Source Generator Template DSL Extensions | compiler | SH-61 |
| [012](012-owned-transfer-tracking.md) | `Owned(T)` — transfer-aware cleanup helper | stdlib | SH-35 |
| [013](013-pub-import.md) | `pub import` and non-transitive import enforcement | language | SH-36 |
| [014](014-callable-types-and-closures.md) | `op_call` and closure literals | language | SH-37 |
| [015](015-fir-inliner-and-dce.md) | FIR optimization pipeline (inliner + DCE + cleanup passes) | compiler | P-SH-5 |
| [016](016-auto-deinit-directive.md) | `#auto_deinit` directive and the managed-lifecycle contract | language | SH-15 |
| [017](017-typer-as-library.md) | `flang_typer` — type system as a library | compiler | SH-38 |
| [018](018-fn-ref-promotion-and-callback-params.md) | `fn(T)` → `fn(&T)` promotion, and `&T` callback parameters in the stdlib | compiler | SH-62 |
| [019](019-callback-adaptation-and-generic-constraints.md) | Deferred designs from the lambda/stdlib-combinator milestone | language | SH-63 |
| [020](020-op-deref-argument-coercion.md) | `op_deref` argument coercion (deref chains at call sites) | language | SH-39 |
| [021](021-template-expansion-redesign.md) | Template Expansion Redesign — single-pass, in-memory, self-host parity | compiler | SH-40 |
| [022](022-demand-driven-checker.md) | Demand-driven checker - declaration-level queries, incremental invalidation | compiler | SH-41 |
| [023](023-language-server.md) | Language server - in-process, self-hosted, retires FLang.Lsp | tooling | P-SH-6 |
| [024](024-interned-types.md) | Interned types - `Ty` becomes a handle | compiler | SH-42 |
| [025](025-built-in-profiler.md) | Built-in profiler | tooling | P-SH-7 |
| [026](026-copy-on-write-parameters.md) | Copy-on-write parameters - elide the shadow when nothing writes or escapes | compiler | SH-43 |
| [027](027-diagnostic-rendering.md) | Diagnostic rendering - source snippets, carets and color | tooling | SH-44 |
| [028](028-owned-fields-and-move.md) | `owned` fields, non-copyable types, and `move` | language | SH-45 |
| [029](029-checking-uninstantiated-generic-bodies.md) | Checking uninstantiated generic bodies | compiler | SH-16 |
| [030](030-reference-form-operator-dispatch.md) | Reference-form operator dispatch | language | SH-64 |
| [031](031-owned-generic-consolidation.md) | `OwnedString`, a `String` that owns its buffer | stdlib | SH-46 |
| [033](033-parameter-declared-ownership.md) | Parameter-declared ownership | language | SH-47 |
| [034](034-typed-slice-intrinsics.md) | Typed slice intrinsics | language | SH-48 |
| [035](035-contracts.md) | Contracts | language | SH-49 |
| [036](036-associated-types-and-type-parameter-bounds.md) | Associated types, projection, and bounds on type parameters | language | SH-50 |
| [037](037-callable-values.md) | Function types as callable values | language | SH-51 |
| [038](038-runtime-context.md) | Runtime context | language | SH-52 |
| [039](039-lambda-syntax.md) | Lambda syntax | language | SH-53 |
| [040](040-coalesce-via-op-try.md) | `??` through `op_try` | language | SH-54 |
| [041](041-native-calling-convention.md) | Native calling convention | compiler | SH-17 |
| [042](042-loop-labels.md) | Loop labels | language | SH-55 |
| [043](043-memory.md) | Heap memory as an owned resource | language | SH-56 |
| [044](044-c-bindings-from-headers.md) | C bindings from headers, `#foreign union`, opaque types | compiler | SH-57 |
| [098](098-context-across-libraries.md) | Context across separately compiled libraries | compiler | SH-18 |
| [099](099-stack-only-types-and-bindings.md) | `#stack` types and stack-only bindings | language | SH-69 |
