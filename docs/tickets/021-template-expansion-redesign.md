# RFC-021: Template Expansion Redesign — single-pass, in-memory, self-host parity

**Type:** Compiler mechanism + source-generator DSL revision
**Status:** Proposed
**Supersedes:** RFC-011 (template DSL extensions) — its `#let`/`#match` are deferred, not rejected
**Amends:** ADR-0006 §5 (templates emitting directive `#if`) — withdrawn, see §3
**Depends on:** None

## Summary

1. Expansion happens **once, at one point in the timeline** (after parse + nominal
   collection, before nominal resolution), as a single worklist pass. The 8-round
   loop, synthetic `__gen_*` modules, module-path aliasing and the `__combined_*`
   re-parse are removed.
2. Expansion is **100% in memory**. `.generated.f` is never read by any compiler.
   `--emit-generated` writes it for debugging; the LSP serves the same text as a
   virtual document.
3. The self-host compiler gets its **own expander** and drops every sidecar
   mechanism (`generated_sidecar`, `combine_with_sidecar`, `module_fqn` stripping,
   the glob exclusion).
4. Template `#if` **is** directive `#if`: same evaluator, same closed context
   (`platform.*`, `runtime.*`, target overrides), same strict semantics, evaluated
   at expansion time with template bindings in scope.
5. DSL fixes driven by the five stdlib templates: `Type` params bind the resolved
   nominal, `#elif`, string-literal interpolation, no `type_of(string)` round-trips.

## Motivation

Current state (reference: `src/FLang.Frontend/TemplateExpander.cs`,
`src/FLang.CLI/Compiler.cs:295-321`):

- Expansion is interleaved with collection/resolution per round because
  `#implement` reaches the previous round's output through
  `type_of(Iface.name + "Vtable")` (`stdlib/std/interface.f:38`). Nothing else
  needs rounds.
- Output is re-parsed twice (per-invocation synthetic module, then the
  concatenated `__combined_` module) so spans point into `.generated.f` — a file
  the LSP refuses to open (`TextDocumentSyncHandler.cs:86`).
- `.generated.f` is written best-effort by the CLI, never by the LSP, never read
  by the reference, and **required** by the self-host via textual concatenation
  (`lib/flang_driver/src/driver.f:284`). It is gitignored. A clean clone's
  self-build silently loses every generated symbol (docs/known-issues.md
  §"Template sidecars are build artifacts").
- `Type` params are textual; metadata needs `type_of(T.name)`. String literals
  are hand-built (`#("\"" + v.name + "\"")`). `Ident` is compared to strings
  (`#if Trait == "eq"`). Enum variants are `.fields`.

The sidecar existed only because the self-host could not expand. Once it can,
persistence is a debugging convenience, not a mechanism.

## Design

### 1. Timeline

```
parse all modules
collect nominal types            (names + field AST nodes, no resolution)
EXPAND                           ← the one spot
resolve nominal types
collect signatures → check → lower
```

Invariant (unchanged): a generator may inspect any declared type's name,
fields/variants and field type *syntax*; generated types may be used as fields
of original types because resolution has not run.

### 2. The pass

Worklist = every generator invocation, ordered by **module import-topological
order**, then **source order** within a module. For each invocation:

1. Bind arguments (§5). A `Type` argument whose nominal is not collected yet
   **parks** the invocation; it is retried only after some other expansion
   made progress. No progress left → E2003. (Pure import order is not enough:
   the stdlib has a real cycle `std.io.writer → conv → test → list → dict →
   string → string_builder → std.io.writer`, found during phase 1.)
2. Evaluate the body into text.
3. Parse the text as a declaration list (not a module: no imports, no module
   header). Parse errors are reported at the invocation span with the generated
   snippet attached (§6).
4. **Append** the declarations to the origin `ModuleNode`. Collect their
   nominals now. Any `#define` among them is registered now. Any generator
   invocation among them is appended to the worklist **after the current
   module's remaining invocations**.

The worklist drains in one slot. Depth is bounded by a generation counter on
each enqueued invocation; exceeding 8 generations is **E2119 template expansion
depth exceeded**, reported at the originating invocation (today's cap is
silent).

All 23 in-tree invocations (audited 2026-08-23) satisfy the order: every
`#implement(Impl, Iface)` has `Impl` local and `Iface` from an imported module
or earlier in the same file; every `#interface`/`#enum_utils`/`#derive` target
is local.

Generated declarations live in the origin module: same import scope, same
visibility, same FQN prefix. No aliasing, no synthetic modules.

### 3. Template `#if` = directive `#if`: one context, one evaluator, one execution

There is a single compile-time evaluator in each compiler (reference:
`DirectiveConditionEvaluator` / `TemplateEngine.EvaluateCondition` merge into
one; self-host: `flang_parser/src/comptime.f`). The template engine does not
have its own expression interpreter — it **calls the same evaluator** the
declaration-level `#if` directive calls, with the same context object and the
same execution path. The only difference is the environment passed in:

- directive `#if`: closed context only — `platform.os`, `platform.arch`,
  `runtime.testing`, `runtime.env[..]`, honoring `--target-os`/`--target-arch`
  and every runtime override;
- template body: that same closed context **plus** the template bindings
  (parameters and `#for` variables), layered on top.

Same rules everywhere: the condition must be `bool`; unknown name →
E2116/E2117/E2118; expressions are parsed by the ordinary expression parser
(§5). Template interpolation `#(expr)` and `#for` iteration evaluate through
the same evaluator — there is one value model and one execution engine for
all compile-time evaluation in the compiler.

Because expansion is in-memory per build, the target context is always the
*current* build's — nothing bakes the host OS into a persisted file. ADR-0006
§5 ("templates must emit directive `#if` text") is therefore withdrawn. A
template `#if` never emits its inactive branch, so that branch is never
parsed; this is the one deliberate difference from declaration-level `#if`
(which parses both).

### 4. `.generated.f` and the LSP

- No compiler reads `.generated.f`. Delete: `resolver.f:generated_sidecar`,
  `driver.f:combine_with_sidecar`, the `.generated.f` strip in
  `resolver.f:module_fqn`, `project.f:glob_sources` exclusion,
  `TestHarness.cs:88` filter, `FLangWorkspace.cs:278/534` filters,
  `TextDocumentSyncHandler.IsGeneratedFile`. Keep the `.gitignore` entry and
  `InitCommand` line so stray debug output stays untracked.
- `--emit-generated` (CLI; off by default) writes `<origin>.generated.f` with
  the exact text the pass produced, one `// #name(args)` header per invocation.
  Emission failure is a warning, never swallowed silently.
- LSP: generated declarations carry `origin = invocation span`; go-to-definition
  on a generated symbol opens a read-only virtual document
  (`flang-generated:///<origin path>`) whose content is that module's generated
  text, with the definition's span inside it. Diagnostics inside generated code
  are reported at the invocation span (§6), so no diagnostic ever targets the
  virtual document. The future self-hosted LSP does the same from its in-memory
  expansion.

### 5. DSL revisions — introspection is `core.rtti`

**The template `Type` value IS `core.rtti.TypeInfo`** (`stdlib/core/rtti.f:24`).
Compile-time generation and runtime introspection have the same use cases
(walk fields, walk variants, inspect function signatures, spell a type), so
they share one definition. Where today's `TypeInfo` is too thin, **`TypeInfo`
is extended** — not shadowed by a template-only vocabulary.

Extended `core.rtti` — **one** addition, because exactly one need is
unmet (`#enum_utils` walks enum variants and today reads them out of
`fields`):

```
TypeInfo {
    name: String                    // spelled type, re-parseable as a type expression
    size: usize
    align: usize
    kind: TypeKind                  // Primitive | Array | Struct | Enum | Function (unchanged)
    type_params: String[]
    type_args: &TypeInfo[]
    fields: FieldInfo[]             // Struct
  + variants: VariantInfo[]         // Enum
    params: ParamInfo[]             // Function
    return_type: &TypeInfo          // Function
}
FieldInfo     { name, offset, type_info: &TypeInfo }
ParamInfo     { name, type_info: &TypeInfo }
+ VariantInfo { name: String }      // deliberately a struct, not String[]: future fields (payload, value) land here without changing `variants`' type — minimal blast radius
```

No `is_*` flags: kind checks are `T.kind == TypeKind.Struct`. No `element`,
`length`, payload types or explicit variant values — no template or runtime
consumer needs them today; each is added when a use appears, following the
rule below.

Rules:
- A `T: Type` parameter binds the `TypeInfo` of the argument directly;
  `T.fields`, `T.variants`, `T.kind`, `T.params` work with no
  `type_of(T.name)` round-trip. `type_of(T)` remains valid (identity), as at
  run time.
- Enum variants move from `fields` to `variants`. `#enum_utils` and the
  `FieldsOrVariants` fallback in the reference change accordingly; runtime
  consumers of `fields` on an enum (none in-tree today) migrate.
- `field.type_info.name` is the spelled type, emitted verbatim — as today.
- `size`, `align` and `offset` are **not available at expansion time**
  (layout needs resolution, which has not run). Reading them in a template is
  **E2120 layout not available at template time**, never a silent 0. All other
  members are available in both worlds.
- The expander builds `TypeInfo` values from the collected nominals and field
  ASTs; the backend builds the runtime table from resolved types. Both go
  through **one constructor** (`TypeInfoBuilder` in the reference, its
  self-host mirror) so the two views cannot drift; the template path simply
  leaves layout unset.
- Anything a template needs that `TypeInfo` lacks is added to `TypeInfo` —
  and only when needed, never for convenience. Template-only accessors are
  not allowed.

| Change | Replaces | Sites |
|---|---|---|
| `T: Type` binds `TypeInfo` | textual `TypeNode`, `type_of(T.name)` everywhere | derive, enum_utils, interface, implement |
| `T.variants` | `type_of(E.name).fields` on enums | enum_utils |
| `Type` invocation args accept any type expression (qualified names, generic instances, anonymous `struct{}`/`enum{}`) | bare identifier only | — |
| `Ident` params are a distinct `Ident` value; `Trait == eq` against a bare identifier literal, or `Trait.text == "eq"` | `Trait == "eq"` | derive |
| `#elif cond {` | `#else #if cond {` | derive (6 chains) |
| String-literal interpolation: `"#(x)"` inside a literal emits a correctly escaped literal | `#("\"" + x + "\"")` | enum_utils, derive |
| `type_named(Iface.name + "Vtable")` — the one remaining string lookup, resolved against nominals collected **so far in this pass** (open question 2); returns `TypeInfo` | `type_of(string)` | implement |
| `#if` per §3 | template-private `#if` | all |

`#let` and `#match` (RFC-011) stay deferred: no stdlib template needs them.
`##` escapes a literal `#`.

Value model (closed): the `core.rtti` types (`TypeInfo`, `FieldInfo`,
`VariantInfo`, `ParamInfo`, `TypeKind`) plus `Ident`, `String`, `Int`, `Bool`
and slices of them. Template expressions are parsed by the compiler's ordinary
expression parser (the self-host's `#if` already reuses `parse_expression`)
and evaluated over this model — settling ADR-0006's parked question: **the DSL
is a FLang expression subset, not a sibling language**, and its introspection
surface is the runtime's.

### 6. Diagnostics

Every generated node records `origin: Span` (the invocation). A diagnostic
inside generated code renders as:

```
file.f:165: error E2011 in #implement(File, Reader): no overload of `read` ...
    generated: |   return self.read(buf)
```

Template-time errors (bad member, type mismatch in `#if`, depth exceeded) are
reported at the template expression's span inside the `#define` body **and**
the invocation span.

### 7. Generated source is readable (self-host)

Template-body whitespace is **not significant** in the output. The
self-host emits generated declarations re-indented and line-normalized,
regardless of how the `#define` body was laid out. The reference compiler's
verbatim-slice output (`buf: u8[], )`, stray blank lines, doubled
indentation) is explicitly not the standard.

Example (syntax illustrative):

```
#define(point, fType: Type, len: Int) {
  type Point = struct {
    #for f in ["x", "y", "z", "w"].take(len) {
      #(f): #(fType.name),
    }
  }
}
```

expands, for `fType = f32, len = 3`, to exactly:

```
type Point = struct {
  x: f32,
  y: f32,
  z: f32,
}
```

Mechanism — a minimal normalizer, not a full formatter:

1. The expander produces raw text as in §2.
2. That text is lexed and parsed into the trivia-bearing CST
   (`lib/flang_parser/src/trivia.f`) — the same parse step §2 already
   requires, so no extra pass over the source.
3. A CST printer emits it back with trivia **rewritten**: leading whitespace
   of every line replaced by `2 × brace-depth` spaces; runs of blank lines
   (the residue of `#for`/`#if` lines that emitted nothing) collapsed to
   none inside a declaration and one between declarations; trailing
   whitespace dropped. Tokens, comments and intra-line spacing are otherwise
   printed as lexed. Each invocation's output is preceded by a single
   `// #name(args)` comment line.
4. The printed text is what `--emit-generated` writes, what the LSP virtual
   document serves, and what diagnostic snippets (§6) quote. It is *also* the
   text whose spans generated nodes carry, so the three always agree.

This is deliberately the smallest rule set that makes the example hold.
Alignment, line-wrapping and intra-line spacing rules belong to a future
formatter; when one exists it replaces step 3 wholesale. The reference
compiler is not required to match byte-for-byte (it is being retired), but
its `--emit-generated` should apply the same rules where cheap so the
harness expectations can be shared.

## Implementation phases

1. ~~**Reference, mechanism.**~~ landed 2026-08-23: `ExpandAll` is the §2
   worklist, appends to origin modules (`ModuleNode.Append`), synthetic /
   aliasing / combined machinery and `ResolveOriginFile` deleted,
   `--emit-generated` flag, E2119, generator error codes now real codes
   (they were passed as hints). Harness 546/546 with the DSL untouched.
   LSP virtual document landed the same day (`flang-generated://` scheme,
   `flang/generatedContent` request, content provider in vscode-flang).
2. **Reference, evaluator unification** (§3). One compile-time evaluator:
   `TemplateEngine` and `DirectiveConditionEvaluator` collapse into it;
   template `#if`/`#(expr)`/`#for` and directive `#if` all execute through
   it, differing only in the bindings layered over the closed context.
3. **Reference, DSL + RTTI** (§5). Extend `core.rtti` with `variants`/`VariantInfo`; one `TypeInfoBuilder`
   feeding both the template evaluator and the runtime metadata table. Update
   the five stdlib templates and the harness fixtures in
   `tests/harness/source_generators/`.
4. **Self-host.** `flang_parser`: parse `#define` bodies into
   verbatim/interpolation/for/if nodes instead of `consume_balanced`. New
   `lib/flang_driver/src/expand.f` (or a `flang_template` lib) implementing §2
   over the collected nominals, plus the CST printer/normalizer of §7. Delete
   all sidecar code. Self-build from a clean clone must succeed; stage-2 =
   stage-3 fixpoint must hold.
5. Docs: `spec.md` §7.8 rewritten; `architecture.md` pipeline; `self-host.md`
   template rows → ✅; `known-issues.md` sidecar entries closed; `error-codes.md`
   E2119, E2120.

## Out of scope

- Jai-style reactions / compile-wide queries (ADR-0006 §4) — parked.
- `#let`, `#match`, user-defined template helpers.
- Transformative macros (rewriting user declarations) — still rejected.

## Open questions

1. Should `--emit-generated` write one file per origin (today) or one
   `build/generated/` tree? One-per-origin keeps the LSP virtual-document path
   trivially derivable. Recommendation: per origin, as today.
2. `Iface.name + "Vtable"` in `#implement` is the last string-keyed lookup.
   Alternative: `#interface` registers a template-visible association so
   `#implement` writes `Iface.vtable`. Cleaner, but requires expander-owned
   state across invocations. Recommendation: keep the string lookup for now;
   revisit if a second such pattern appears.
