# Self-Host Status — Feature Coverage

The single source of truth for what the self-hosted compiler
(`bootstrap` + `lib/flang_*`) can and cannot do, per pipeline stage.
The "milestone" names (M1–M6) used in commit messages were invented as
the work went along; this document supersedes them as the roadmap.
Update it in the same commit as any coverage change.

Status legend: ✅ done · ⚠️ partial (details in Notes) · ❌ missing
(lowering *refuses* the enclosing function rather than miscompile —
see `lower.f`'s `unlowerable`).

**Contract: lowering only ever sees concrete types.** Generic
*templates* are never lowered — the typer's specialization pass
(`flang_typer/src/specialization.f`) owns producing fully-type-checked
concrete instantiations, and lowering consumes those like any
monomorphic function. Any `Ty.Var` reaching lowering is a **compiler
bug**, not an input to tolerate: today's transitional guards
(`declares_generic`, the `ty_concrete` signature gate, `layout.f`'s
`Var → 4 bytes` fallback, `ty_to_ir`'s `i64` fold) exist only because
the specialization pass is not fed yet; once it is, the fallbacks must
become hard failures, mirroring the reference's `TypeLayoutService`
no-defaulting throw.

**Self-host need** is measured, not guessed: occurrence counts across
the 98 modules the self-build compiles (`bootstrap/src`, `lib/*/src`,
`stdlib`, sidecars excluded), formatted `uses/files`. Counts are from
2026-08-19; re-measure when they matter. Anything the compiler's own
`main` transitively reaches must eventually lower; a near-zero count
means the sources could be *rewritten to avoid the feature* if that is
cheaper than implementing it.

## Pipeline stages

| Stage | Status | Notes |
|---|---|---|
| Lexing (trivia-attached) | ✅ | `flang_parser.lexer` |
| CST parsing | ✅ | round-trips every in-tree source byte-identical via `flang_fmt` |
| AST projection | ✅ | `flang_parser.projector` |
| Name resolution + imports | ✅ | project-wide; type names resolve program-wide (import-strict later) |
| Type inference (HM) | ⚠️ | 0 errors self-checking compiler + stdlib (98 modules), but 8 of 24 expression forms are unvisited and rejection power lags the reference — see the type-checking section below |
| AST → FIR lowering | ⚠️ | the subset below; everything outside refuses, never miscompiles |
| C backend (FIR → C99 → exe) | ✅ | for all FIR the lowering emits; links stdlib C runtime sidecars |
| Full self-build | ❌ | every lowered function compiles and links; `main` still refuses (see below) |
| Stage-2 = stage-3 fixpoint | ❌ | blocked on full lowering coverage |

## Type checking

"0 self-check errors" means the checker *accepts* all the valid code in
this repository — it does not mean it checks everything, and it does
not mean it *rejects* what the reference rejects. Two axes:

### Inference coverage (does valid code get real types?)

| Feature | Status | Self-host need | Notes |
|---|---|---|---|
| Declarations, signatures, aliases, module consts | ✅ | everywhere | generic aliases + alias-cycle detection missing |
| Statements (all 10 `Stmt` forms, divergence tracking) | ✅ | everywhere | |
| Literals, identifiers, blocks, binary ops | ✅ | everywhere | |
| Calls: overloads, defaults window, UFCS (+`op_deref` peel), fn-field + indirect | ✅ | everywhere | named-argument calls fall back to a fresh var |
| Enum variant construction (incl. payloads) | ✅ | ~1550/60+ (`Some` 645, `Enum.Variant(...)` 475, `None` 243, `Ok`/`Err` 185) | recorded as `RtEnumVariant` for lowering |
| Struct literals, member access (substituted generic fields) | ✅ | everywhere | named generic literal without args is E2019 |
| `if`/`match` joins (order-independent, `Never` identity) | ✅ | everywhere | E2074/E2075 |
| Assignment, address-of, deref, casts, tuples, ranges, indexing | ✅ | `as` casts: 845/75 | index operator pick recorded with `is_ref_form` |
| Unary ops (`-x`, `!x`, `~x`) | ❌ | `!` 191/28, `~` 35/12, neg ~5 | falls to `_ => fresh_var()`; operand subtree never visited — see known-issues.md (float-neg miscompile risk) |
| Lambdas | ❌ | 23/5 | unvisited subtree |
| Array literals `[a, b]` | ❌ | ~52/9 | unvisited subtree |
| Interpolated strings `$"…"` | ❌ | 60/15 | unvisited subtree |
| `a?.b`, `a ?? b`, `a?` | ❌ | `?` (op_try) 28/13 · `??` 5/4 · `?.` 3/3 | unvisited subtrees; `??`/`?.` nearly rewritable-away, `?` is wanted (ticket 009) |
| Specialization (eager monomorphization of generic fns) | ❌ | everywhere (`List`/`Dict`) | `SpecializationRegistry` exists (dedup cache, clone-and-requeue design) but **nothing calls `ensure_specialization` yet** — `result.specializations` is always empty. Generic bodies are checked once, generically, with call-resolution diagnostics *silenced*; per-clone re-checking un-silences them |
| Templates (`#interface`, `#derive`, …) expanded natively | ❌ | every `.generated.f` sidecar | relies on sidecars from a reference-compiler run |
| `#if` compile-time conditionals evaluated | ❌ | 27/10 (incl. `file.f::open_flags`, in `main`'s graph) | |

An unvisited subtree types as an unconstrained fresh var: the code
around it may still check clean while errors inside it go unreported —
the checker's biggest soundness caveat.

### Rejection power (does invalid code get diagnosed?)

| Check | Status | Notes |
|---|---|---|
| Type mismatches through unification (incl. coercion rules) | ✅ | |
| Overload/arity failures (E2011/E2004) | ✅ | outside generic bodies |
| Match exhaustiveness (E2030/E2031) | ❌ | reference checks it; self-host `check_match` deliberately does not |
| Non-place assignment target (`f() = 1`) | ❌ | lowering refuses the function instead — loud but imprecise |
| Dual index-operator forms on one type (E2077) | ❌ | winner is deterministic; only the diagnostic is missing |
| Harness `COMPILE-ERROR` corpus parity | ❌ | most expected-error tests check clean through the bootstrap and proceed to codegen |

The narrative history behind these lives in docs/known-issues.md
§"Bootstrap Self-Host: Remaining Typer Gaps"; this table is the
current-state summary.

## Lowering — declarations and signatures

| Feature | Status | Self-host need | Notes |
|---|---|---|---|
| Free functions, scalar params/returns | ✅ | everywhere | |
| Aggregate params/returns (structs, enums, tuples, arrays, String, slices) | ✅ | everywhere | by-pointer, callee copies; returns via trailing sret buffer |
| `&T?` / niche `Option(&T)` params and returns | ✅ | everywhere (allocators) | classified scalar `ptr` |
| Foreign (`#foreign`) scalar signatures | ✅ | everywhere | variadic declared but not callable |
| Foreign aggregate signatures | ❌ | 0 in `main`'s graph | byte-buffer aggregates have no C ABI spelling for externs |
| Generic templates skipped (never lowered) | ✅ | by design | `declares_generic` — correct end-state behavior, templates have no single layout |
| Specialized instantiations (from `result.specializations`) | ❌ | everywhere (`List`/`Dict`/iterators) | the largest single gap, but it is **typer-fed**: lowering just walks the concrete clones and mangles symbols with their instantiation types — see the contract at the top |
| Defaulted params at call sites | ❌ | ~500 decl sites; omitted at most calls | needs default-expr materialization from callee scope |
| Named arguments | ❌ | **2/1 — rewritable-away** | checker leaves the call unresolved |
| Variadic calls | ❌ | declarations only (printf family is fixed-arity overloads) — likely avoidable | needs per-argument types at the call site |
| Function values / indirect calls / fn-typed fields | ❌ | fn-typed fields in checker/backend dispatch | `CallIndirect` exists in FIR; lowering never emits it |
| Lambdas / closures | ❌ | 23/5 | needs closure conversion + capture record |
| Global `const` declarations | ❌ | 101/17 | `read_binding` covers locals only |
| `test` blocks (self-host `flang test`) | ❌ | dev workflow, not `main`'s graph | bootstrap CLI has no `test` subcommand |
| Template directives (`#enum_utils`, `#derive`, `#interface`, …) | ⚠️ | every sidecar | not expanded; checked-in `.generated.f` sidecars stand in |
| `#if` compile-time conditionals | ❌ | 27/10 | statement- and decl-level |

## Lowering — statements

| Feature | Status | Self-host need | Notes |
|---|---|---|---|
| `let` (annotated, inferred, uninitialized zero-init) | ✅ | everywhere | value semantics with copy-elision for fresh temporaries |
| Assignment (locals, fields, derefs, indexed places) | ✅ | everywhere (incl. all 172 `x[i] = v` sites — every one is ref-form or built-in, a place) | value-form `op_index` targets refuse; see `op_set_index` below |
| `return` | ✅ | everywhere | incl. sret copies |
| `if` / `else` (stmt + expr) | ✅ | everywhere | block-parameter joins |
| `while`, `loop`, `break`, `continue` | ✅ | everywhere | |
| `for` over integer ranges | ✅ | everywhere | induction var as block param |
| `for` over iterators (iterator protocol) | ❌ | 25/19 | needs generic `next()` calls → monomorphization |
| `defer` | ❌ | 190/20 | needs LIFO scope-exit schedule on every exit edge |

## Lowering — expressions

| Feature | Status | Self-host need | Notes |
|---|---|---|---|
| Int / bool / char / byte literals | ✅ | everywhere | chars decode escapes + UTF-8 |
| `null` | ✅ | everywhere | niche → null ptr; tagged Option → zeroed buffer (None = tag 0) |
| Float literals | ❌ | 115/11 (dict load factor is in `main`'s graph) | needs a float literal parser |
| String literals | ❌ | ~6700 (largest count in the codebase) | needs the data segment |
| String interpolation `$"…"` | ❌ | 60/15 | data segment + formatting calls |
| Arithmetic / bitwise / comparison / short-circuit on primitives | ✅ | everywhere | |
| Unary ops | ⚠️ | `!` 191/28 | lowered, but on unchecked (fresh-var) types — see known-issues |
| Operators dispatching to user `op_*` fns (aggregate operands) | ❌ | String `==` everywhere | checker records `ResolvedOperator` only on index nodes today |
| Struct literals (concrete, incl. explicit generic args) | ✅ | everywhere | `Pair { … }` without args is E2019 |
| Anonymous `.{ … }` literals | ⚠️ | **192/50** | typed via nominal coercion; lowering follows the node type — verify end-to-end when construction lands |
| Member access (nested paths, place + value) | ✅ | everywhere | generic fields load at substituted widths |
| Address-of `&x`, dereference `p.*` | ✅ | everywhere | |
| Direct calls, UFCS, overloads | ✅ | everywhere | |
| Enum variant construction (`Some(x)`, `Color.Red`, `None`) | ❌ | **~1550/60+ — the single biggest blocker** | proposed next (M7) |
| Indexing: `op_index_ref` / `op_index` / built-in | ✅ | everywhere | |
| `op_set_index` (value-form indexed assignment) | ❌ | **0 sites in `main`'s graph** — all 172 `x[i] = v` sites are places (arrays/slices via the built-in path, `List` via `op_index_ref`); dict sugar `d[k] = v` is unused (`.set(...)` throughout) | keep refused until a use appears |
| Range slicing `xs[a..b]` on built-in bases | ❌ | 105/21 | needs bounds-clamped Slice construction |
| `match` | ✅ | everywhere | see patterns below |
| Casts `x as T` | ❌ | 845/75 | conversion matrix unwritten (FIR has the instructions) |
| Array literals `[a, b]` | ❌ | ~52/9 | element layout + slot construction |
| Tuple literals `(a, b)` | ❌ | 9/6 — small; rewritable to structs if cheaper | |
| `a?` (op_try early return) | ❌ | 28/13 | ticket 009; desugars through `TryResult` |
| `a ?? b` (coalesce) | ❌ | 5/4 | small |
| `a?.b` (null propagation) | ❌ | **3/3 — rewritable-away** | |
| Bare ranges `a..b` as values | ❌ | only as index/slice args | no value representation outside `for` |

## Lowering — match patterns

| Feature | Status | Self-host need | Notes |
|---|---|---|---|
| Wildcard, variable bindings | ✅ | everywhere | aggregate bindings copy (value semantics) |
| Int / bool / char / byte / `null` literals | ✅ | everywhere | |
| Ranges `lo..hi` | ✅ | used | |
| Enum variants, single payload | ✅ | everywhere | tagged + niche |
| Enum variants, multi payload | ❌ | **2/2 — rewritable-away** (or implement with per-payload offsets) | |
| Or-patterns (non-binding) | ✅ | used | binding alternatives refuse |
| Struct / tuple destructuring patterns | ❌ | **0 sites — not needed** | keep refused until a use appears |
| Guards | ✅ | used | |

## Confirmed NOT needed (rewrite or defer indefinitely)

Measured near-zero in the self-host sources — implementing these buys
no self-hosting progress; a handful of call-site rewrites removes the
need entirely:

- struct/tuple destructuring patterns (0), `op_set_index` (0 — every
  indexed write in the sources is a place; dict sugar unused),
  named arguments (2), multi-payload variant patterns (2),
  `?.` null propagation (3), `??` coalesce (5), tuple literals (9),
  variadic *calls* (0 — declarations only), foreign aggregate
  signatures (0).

`??` and `?` stay on the roadmap anyway because they are wanted
language features (tickets 009/010), not because self-hosting needs
them at today's counts.

## Proposed milestone order (toward `main` lowering)

Typer and lowering interleave: an expression form should be *checked*
before (or with) the milestone that lowers it — lowering an unchecked
node reads a fresh-var type and guesses (see the unary entry in
docs/known-issues.md for the live instance of that failure).

1. **M7 — construction**: enum variant construction (`Some(x)`,
   `Color.Red`, `None`; niche form is a retype) **and** anonymous
   `.{ … }` literals verified end-to-end. ~1,700 measured sites — the
   single biggest unlock. Pair with the small `check_unary` typer fix.
2. **M8 — optional operators**: `a?` (op_try early return, ticket 009,
   through `TryResult`) and `a ?? b`. Small surface, high ergonomic
   value, and exercises M7's construction paths immediately.
3. **M9 — data segment**: string literals (6,700 sites), float
   literals, then interpolation (typer: `InterpolatedString` too).
4. **M10 — specialization**: feed the existing
   `SpecializationRegistry` — every generic call site with a concrete
   type-arg vector calls `ensure_specialization`, the clone re-checks
   (un-silencing generic-body diagnostics), and lowering walks
   `result.specializations` as ordinary monomorphic functions with
   instantiation-mangled symbols. Largest item; `List`/`Dict`/
   iterators/`getopts` all hang off it. Landing it also flips the
   transitional Var fallbacks (layout's 4-byte guess, `ty_to_ir`'s
   `i64` fold) into hard failures per the contract above.
5. **M11 — call completeness**: defaulted args, casts, unary/binary
   user-operator dispatch (`String ==`).
6. Then: defer (190 sites), globals/consts, closures + fn values,
   for-over-iterators (falls out of M10), array literals, range
   slicing, `#if` resolution, template expansion, match exhaustiveness
   and the other rejection-power gaps. The "not needed" list above
   stays refused until a real use appears.

## Dogfooding as language design

Self-hosting doubles as a syntax survey: patterns the compiler's own
sources repeat awkwardly are feature requests with measured demand.
Current observations (counts above):

- `is_some()` / `is_none()` followed by `unwrap()` is everywhere the
  checker and driver touch optionals — the shape Rust answers with
  `if let` / `let else`. Worth designing FLang's own form (works with
  `match` today, but a one-armed binding form would collapse hundreds
  of three-line dances). Related: ticket 010 (pattern grammar and
  optional flattening), ticket 009 (`?` early return).
- The `let x = opt; if x.is_none() { return … }; x.unwrap()` prologue
  is the same demand in statement form.

Record new observations here as self-hosting surfaces them; graduate
them to `docs/tickets/` once a design exists.

The order is a proposal, not a promise — reorder freely, but keep this
file in sync with what lands.
