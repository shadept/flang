# ADR-0006: `#if` is selection; compile-time generation is (future) Jai-style reactions

**Status:** Accepted — 2026-08-20. `#if` half implemented in both compilers; the
generator-reactions half is direction-setting for the template-engine redesign.
**Affects:** `docs/spec.md` §7.7 (rewritten); `DirectiveConditionEvaluator` /
`IfDirectiveDeclarations` (reference); `flang_parser/comptime.f` (self-host);
the future source-generator redesign.

## Context

FLang has two compile-time mechanisms that shared syntax but not semantics: the
`#if` directive (an AST-level conditional evaluated at check time) and the
template engine (`#define` bodies with textual `#for`/`#if` expanded before
parsing). Both consumed the same loose expression evaluator, where an unknown
name was silently `null`/false and a non-empty string was truthy — so a typo'd
`platform.oss` silently compiled the wrong branch on every platform. The
question was whether `#if` should grow toward general compile-time execution
(Zig/Jai-style) or stay a config conditional, and what the template engine's
end state is (it aims at Roslyn-generator/T4-style codegen: close language gaps
with libraries — `#interface`, `#enum_utils`, compile-time truth tables — via
compile-time *introspection*, not runtime reflection).

## Decision

1. **`#if` is selection, not computation.** It chooses between alternatives over
   a closed, compiler-supplied context (`platform.*`, `runtime.*`) and never
   computes code. Spec'd self-contained — no reference to templates, which will
   be redefined separately.
2. **`#if` follows FLang semantics.** Syntax mirrors `if` (`#` = compile time,
   no parens: `#if cond { }`); conditions must be bool; unknown names are hard
   errors (E2116/E2117/E2118); `runtime.env` behaves as a FLang `Dict`
   (indexing yields `String?`, unwrap with `??`). Both branches always parse;
   only the active branch is checked and lowered — `#if` gates semantics,
   never syntax. Decl-level `#if` resolves once at collection; this is cheap
   *because* the context is closed.
3. **The context is the TARGET's, not the host's.** `--target-os` /
   `--target-arch` override it so any host can emit any platform's C — the
   cross-bootstrap story.
4. **The template engine's future is the Jai message-loop shape**: global,
   event-driven reactions over checked declarations (compilation-wide queries
   allowed at quiescence points), fixed-point convergence, **additive-only
   textual emission** — no in-place rewriting of user declarations (Jai and
   Roslyn both landed here; transformative macros stay rejected). A narrow
   compiler interception hook is the named future answer if transparent
   instrumentation ever becomes real. Reactions run in the template DSL with a
   small curated stdlib mirroring FLang — full compile-time execution of FLang
   is permanently out of scope for this language.
5. **Recorded requirements on the template redesign:** templates must be able
   to *emit* directive `#if` text (today the template engine consumes `#if`
   itself), because expansion-time platform branching would bake the build
   host's OS into checked-in `.generated.f` sidecars.

## Consequences

- Silent-wrong-branch bugs are structurally gone; a typo fails every build.
- Version/syntax gating is explicitly not `#if`'s job (a parse error in any
  branch breaks all platforms); if FLang ever needs it, that is a new tool.
- Parked, deliberately: whether the template DSL is formally a FLang expression
  subset (the self-host's `#if` conditions already are — they reuse
  `parse_expression`) or a curated sibling language.
