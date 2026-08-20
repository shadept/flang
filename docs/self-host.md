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
(`flang_typer/src/specialization.f`) produces fully-type-checked
concrete instantiations, and lowering consumes those like any
monomorphic function. Since M10 this is enforced, not aspirational:
`layout.f` **panics** on a `Var` (no more 4-byte guess), `ty_to_ir`
**panics** on a `Var` (no more `i64` fold), and the one place a `Var`
node type can still legitimately appear (a `let` bound to a construct
the checker does not cover, e.g. an array literal with a non-literal
repeat count) refuses the function through the subset gate instead of
reaching either. A `Var` at a width decision is a compiler bug and
fails loudly.

The same contract has a *nominal* half that is not honored yet: a
concrete instantiation like `Pair(i64)` reaches lowering with concrete
type arguments, but the registry stores one var-bearing definition per
generic type, so `layout.f` re-substitutes (`subst`, `field_ty`,
`variant_payload_ty`) on every field/payload query — machinery that by
the contract's own logic belongs typer-side. It is also a standing bug
surface: forgetting one substitution site reads a field at the type
parameter's placeholder width (the M6 "generic field reads at
substituted width" fix was exactly that). M10 fed the
specialization pass for *functions* but kept layout's per-query
substitution for nominal instantiations; interning pre-substituted
nominals (layout as pure lookup) remains open.

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
| Type inference (HM) | ⚠️ | 0 errors self-checking compiler + stdlib (98 modules) *including every instantiated generic body* (M10); 1 expression form (`a?.b`) is still unvisited and rejection power lags the reference — see the type-checking section below |
| AST → FIR lowering | ⚠️ | the subset below; everything outside refuses, never miscompiles |
| C backend (FIR → C99 → exe) | ✅ | for all FIR the lowering emits; links stdlib C runtime sidecars |
| Full self-build | ❌ | every lowered function compiles (840 C functions after RFC-014 lambdas + fn values/indirect calls landed, 2026-08-20); `main` still drops transitively — defaulted-argument calls (M11) and the `__flang_strlen` runtime shim are the frontier |
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
| Literals, identifiers, blocks, binary ops | ✅ | everywhere | M10: a suffixed numeric literal IS its suffix type (previously ignored!); an unsuffixed one is context-resolved, and one nothing ever pins is E2001 in a post-inference sweep (reference parity). Shift counts unify with the shifted operand |
| Calls: overloads, defaults window, UFCS (+`op_deref` peel), fn-field + indirect | ✅ | everywhere | named-argument calls fall back to a fresh var |
| Enum variant construction (incl. payloads) | ✅ | ~1550/60+ (`Some` 645, `Enum.Variant(...)` 475, `None` 243, `Ok`/`Err` 185) | recorded as `RtEnumVariant` for lowering |
| Struct literals, member access (substituted generic fields) | ✅ | everywhere | named generic literal without args is E2019 |
| `if`/`match` joins (order-independent, `Never` identity) | ✅ | everywhere | E2074/E2075 |
| Assignment, address-of, deref, casts, tuples, ranges, indexing | ✅ | `as` casts: 845/75 | index operator pick recorded with `is_ref_form`. M10: a BARE numeric literal cast operand takes the target type (`0xFFFF_FFFF as u64` is a u64 constant); tuple projection `t.0` types as the element |
| Unary ops (`-x`, `!x`, `~x`) | ✅ | `!` 191/28, `~` 35/12, neg ~5 | M7: `!` unifies with bool; `-`/`~` type as their operand. Numeric-ness of `-`/`~` not yet *enforced* (rejection-power gap); no `op_neg`/`op_not`/`op_bnot` dispatch to user types (M11, with binary — zero in-tree users today) |
| Lambdas / closures (RFC-014) | ✅ | 23/5 | landed 2026-08-20, no-clone: `check_lambda` checks the literal's body in place (captured names resolve through their outer scopes; no `self.x` rewrite). Unannotated params mint fresh vars pinned by context — including *through* a `$F` slot: `process_pending` admits signatures whose vars sit inside `Func` types, the instantiation's body re-check pins them at the indirect call, and the spec re-keys under its settled signature (`rekey`; twins that settle identical dedup at emission by symbol). Non-capturing → `LambdaInfo` (overlay-scoped: one record per instantiation) typed as a bare `fn`; capturing → synthesized env-struct nominal + entry in the global `closures` dispatch table, typed as the anonymous nominal. E2111 (closure into bare-fn slot, as an overload-failure hint), E2112 (assign to capture), E2113 (transitive nested captures) all report |
| Array literals `[a, b]`, `[v; N]` | ⚠️ | ~52/9 | M10: checked — elements unify, the node types as `[T; len]`, declared `u8[N]` lengths evaluate (previously 0!). A non-literal repeat count (`[0u8; PAGE_SIZE]`) stays an unconstrained var and the enclosing `let` refuses at lowering |
| Interpolated strings `$"…"` | ✅ | 60/15 | M9: the reference's StringBuilder desugar, synthesized as real AST under collision-free synthetic node ids and checked through ordinary overload resolution (`append` picks recorded per part; format specs route to the spec-taking overload). The block is stored in `result.desugars`; lowering replays it. Stdlib- and import-dependent by design (`import std.string_builder`) |
| `a?` (op_try), `a ?? b` | ✅ | `?` 28/13 · `??` 5/4 | M8: `?` resolves `op_try`, requires `TryResult(T, R)`, unifies `R` with the enclosing return (E2090/E2092); `??` has the reference's two built-in Option shapes (unwrap and chain) |
| `a?.b` | ❌ | 3/3 — rewritable-away | unvisited subtree |
| Specialization (eager monomorphization of generic fns) | ✅ | everywhere (`List`/`Dict`) | M10, **no AST clone**: node ids are span fingerprints, so instantiations of one template share every node id — each instantiation re-checks the ORIGINAL body with `$T` names bound to concrete types, recording into a private `InferenceResults` overlay (`Specialization.overlay`). Committed generic picks (calls, operators, `op_try`, indexing) become `PendingSpec`s; each body scope drains its own pendings after inference settles (register-before-check breaks self-recursion; depth cap 64 diagnoses runaway chains; un-inferable type args are E2001 at the call site). Function lookups during a re-check see the template module's imports UNIONED with the caller chain's (`fn_visibility`) — the deliberate loaded-context rule that lets `hash()` resolve for `Dict`; nominal/variant lookups do NOT widen (a caller's `Decl.Type(...)` variant must not capture `Type(T)`). Generic template bodies are otherwise **never validated** — errors surface per instantiation |
| Templates (`#interface`, `#derive`, …) expanded natively | ❌ | every `.generated.f` sidecar | relies on sidecars from a reference-compiler run |
| `#if` compile-time conditionals evaluated | ✅ | 27/10 (incl. `file.f::open_flags`, in `main`'s graph) | landed 2026-08-20: conditions parse as real FLang expressions (`parse_expression` + `stop_at_brace`, paren-free `#if cond {` canonical), evaluated strictly (`flang_parser.comptime`: E2116 unknown name, E2117 non-bool, E2118 operand misuse — reference parity); only the active branch is checked; divergence = active branch's. Decl-level flattens once post-projection (`flatten_module_decls`, active decls spliced via `Module.set_decls`). `--target-os`/`--target-arch` override the context (threaded `ResolveCtx.comptime` → `Checker.comptime`/`LowerCtx.comptime`) |

An unvisited subtree (`a?.b`) types as an unconstrained
fresh var: the code around it may still check clean while errors
inside it go unreported — the checker's biggest soundness caveat. The
same applies to a generic template body that is never instantiated:
per the M10 model it is never validated at all.

### Rejection power (does invalid code get diagnosed?)

| Check | Status | Notes |
|---|---|---|
| Type mismatches through unification (incl. coercion rules) | ✅ | |
| Overload/arity failures (E2011/E2004) | ✅ | everywhere since M10 — instantiated bodies check with concrete types, so the old generic-body silencing is gone |
| Unresolved unsuffixed literals (E2001) | ✅ | M10 post-inference sweep, reference parity |
| Un-inferable generic type arguments (E2001) | ✅ | M10 — at the call span; the reference silently skips and fails later at link |
| Anonymous-literal field mismatches | ✅ | M10 — `resolve_anon_literals` unifies each `.{ f = v }` initializer against the nominal's declared field type once the literal's var settles |
| Type parameters shadow nominals | ✅ | M10 — a project type named `E`/`T`/`K` no longer captures `$E` in stdlib signatures (`Binding.is_type_param`) |
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
| Specialized instantiations (from `result.specializations`) | ✅ | everywhere (`List`/`Dict`/iterators) | M10: `lower_specializations` re-lowers the template's declaration once per concrete signature, reading node types/targets/operators through the instantiation's overlay (`LowerCtx.overlay`, consulted before the program tables). Symbols mangle from the concrete parameter types plus a `__ret_` token (return-only-polymorphic templates differ in nothing else; the suffix also keeps specs distinct from same-parameter monomorphic overloads). Call sites route through `RtSpecialized`; operator sites through `ResolvedOperator.spec_id`. 457 specializations emit in the self-build |
| Defaulted params at call sites | ❌ | ~500 decl sites; omitted at most calls | needs default-expr materialization from callee scope |
| Named arguments | ❌ | **2/1 — rewritable-away** | checker leaves the call unresolved |
| Variadic calls | ❌ | declarations only (printf family is fixed-arity overloads) — likely avoidable | needs per-argument types at the call site |
| Function values / indirect calls / fn-typed fields | ✅ | fn-typed fields in checker/backend dispatch | landed with lambdas: a function NAME in value position decays to `Operand.FuncRef`; a fn-typed callee value emits `CallIndirect` (params/sret mirror direct calls); a closure-typed callee (local, param, or struct field — the checker records the callee member-access node's type for the classification) dispatches directly to its `op_call` symbol with the value's address prepended |
| Lambdas / closures | ✅ | 23/5 | literal sites enqueue `PendingLambda` (with the active overlay) and emit after the main walk — non-capturing as a plain function, capturing as an `op_call` whose leading param is the env pointer and whose captured names bind to `gep`s into it (no copy; captures are read-only). The literal itself is a `FuncRef` or a stack-built env struct |
| Global `const` declarations | ❌ | 101/17 | `read_binding` covers locals only |
| `test` blocks (self-host `flang test`) | ❌ | dev workflow, not `main`'s graph | bootstrap CLI has no `test` subcommand |
| Template directives (`#enum_utils`, `#derive`, `#interface`, …) | ⚠️ | every sidecar | not expanded; checked-in `.generated.f` sidecars stand in |
| `#if` compile-time conditionals | ✅ | 27/10 | statement-level splices the active branch's statements at `lower_stmt`; decl-level is already flattened before lowering. The `comptime.f` evaluator itself joins the M11 emission frontier (`String ==` dispatch), like most of the checker |

## Lowering — statements

| Feature | Status | Self-host need | Notes |
|---|---|---|---|
| `let` (annotated, inferred, uninitialized zero-init) | ✅ | everywhere | value semantics with copy-elision for fresh temporaries |
| Assignment (locals, fields, derefs, indexed places) | ✅ | everywhere (incl. all 172 `x[i] = v` sites — every one is ref-form or built-in, a place) | value-form `op_index` targets refuse; see `op_set_index` below |
| `return` | ✅ | everywhere | incl. sret copies |
| `if` / `else` (stmt + expr) | ✅ | everywhere | block-parameter joins |
| `while`, `loop`, `break`, `continue` | ✅ | everywhere | |
| `for` over integer ranges | ✅ | everywhere | induction var as block param |
| `for` over iterators (iterator protocol) | ❌ | 25/19 | M10 supplies the monomorphized `next()`; the checker-side protocol resolution is what remains (loop vars currently type as fresh vars — see the `symbol_table.f` annotation workaround) |
| `defer` | ✅ | 190/20 | M9: per-function schedule + per-scope marks (the reference's model). Fires LIFO on scope exit; `return` / `break` / `continue` / `?` emit down to their target depth without popping; `return` evaluates its value first (spec 4.1). A block's trailing aggregate value is copied out before its own defers fire. Escapes from inside a deferred expression (`defer { return }`, `?` in defer - E2091) refuse |

## Lowering — expressions

| Feature | Status | Self-host need | Notes |
|---|---|---|---|
| Int / bool / char / byte literals | ✅ | everywhere | chars decode escapes + UTF-8 |
| `null` | ✅ | everywhere | niche → null ptr; tagged Option → zeroed buffer (None = tag 0) |
| Float literals | ✅ | 115/11 | M9: digit-accumulation parser (exact for real-source literals); the C backend emits constants as exact C99 hex-float literals (`format_f64_hex` / the `a` spec), never a truncated decimal. A literal whose node type stays an unresolved var refuses |
| String literals | ✅ | ~6700 (largest count in the codebase) | M9: decoded bytes interned program-wide into null-terminated data-segment globals (keyed by raw text); each use builds a `String {ptr,len}` view into a stack slot via the struct's real layout. A literal whose node type is not `String` refuses |
| String interpolation `$"…"` | ✅ | 60/15 | M9: lowering replays the checker-recorded desugar block (`result.desugars`) - ctor at full arity, appends, deferred `deinit`, `to_string`. M10 unblocked the builder's generic internals; remaining refusals in the chain are M11 items (defaulted-arg calls inside the stdlib) |
| Arithmetic / bitwise / comparison / short-circuit on primitives | ✅ | everywhere | |
| Unary ops | ✅ | `!` 191/28 | M7: operands are checked now, so the width/float reads are real (`-x` on f64 emits `fneg`) |
| Operators dispatching to user `op_*` fns (aggregate operands) | ❌ | String `==` everywhere | checker records `ResolvedOperator` only on index nodes today |
| Struct literals (concrete, incl. explicit generic args) | ✅ | everywhere | `Pair { … }` without args is E2019 |
| Anonymous `.{ … }` literals | ✅ | **192/50** | typed via nominal coercion; M10 adds the deferred field pass (`resolve_anon_literals`) so initializers actually unify against the nominal's field types — mismatches report, unsuffixed numeric fields pin |
| Member access (nested paths, place + value) | ✅ | everywhere | generic fields load at substituted widths |
| Address-of `&x`, dereference `p.*` | ✅ | everywhere | |
| Direct calls, UFCS, overloads | ✅ | everywhere | |
| Enum variant construction (`Some(x)`, `Color.Red`, `None`) | ✅ | ~1550/60+ | M7: tagged form builds tag-then-payload into a fresh slot; niche `Option(&T)` is a retype (`None` = null ptr, `Some(p)` = its payload ptr). Multi-payload construction refuses (2 sites, matching the pattern side) |
| Indexing: `op_index_ref` / `op_index` / built-in | ✅ | everywhere | |
| `op_set_index` (value-form indexed assignment) | ❌ | **0 sites in `main`'s graph** — all 172 `x[i] = v` sites are places (arrays/slices via the built-in path, `List` via `op_index_ref`); dict sugar `d[k] = v` is unused (`.set(...)` throughout) | keep refused until a use appears |
| Range slicing `xs[a..b]` on built-in bases | ❌ | 105/21 | needs bounds-clamped Slice construction |
| `match` | ✅ | everywhere | see patterns below |
| Casts `x as T` | ❌ | 845/75 | conversion matrix unwritten (FIR has the instructions) |
| Array literals `[a, b]` | ❌ | ~52/9 | element layout + slot construction |
| Tuple literals `(a, b)` | ❌ | 9/6 — small; rewritable to structs if cheaper | |
| `a?` (op_try early return) | ✅ | 28/13 | M8 machinery + M10 specialization: a generic `op_try` now instantiates and the caller lowers against its specialization (test: "postfix ? through a generic op_try lowers via its specialization") |
| `a ?? b` (coalesce) | ✅ | 5/4 | M8: built-in Option branch, short-circuit right side; niche and tagged, unwrap and chain forms |
| `a?.b` (null propagation) | ❌ | **3/3 — rewritable-away** | |
| Bare ranges `a..b` as values | ❌ | only as index/slice args | no value representation outside `for` |

## Lowering — match patterns

| Feature | Status | Self-host need | Notes |
|---|---|---|---|
| Wildcard, variable bindings | ✅ | everywhere | aggregate bindings copy (value semantics) |
| Int / bool / char / byte / float / `null` literals | ✅ | everywhere | float patterns compare with ordered fcmp (M9); string patterns refuse — comparing one is a `String ==` call, which operator dispatch does not record yet |
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

1. ~~**M7 — construction**~~ ✅ landed 2026-08-19: enum variant
   construction (call / bare identifier / qualified member; niche form
   is a retype), anonymous `.{ … }` literals verified end-to-end, and
   the `check_unary` typer fix. Self-check stayed at 0 errors with the
   unary operand subtrees newly visited.
2. ~~**M8 — optional operators**~~ ✅ landed 2026-08-19: `a?` checks
   and lowers through the recorded `op_try` pick (generic impls refuse
   until M10, like every generic call); `a ?? b` checks and lowers
   fully. Self-check stayed at 0 errors with both subtrees visited.
3. ~~**M9 — data segment**~~ ✅ landed 2026-08-19: string literals
   (interned into null-terminated data-segment globals, `{ptr,len}`
   view built per use — 565 globals in the self-build), float literals
   (parser + exact bit-pattern C emission), `defer` (full scope-exit
   schedule, all escape edges), and string interpolation via the
   reference's check-time StringBuilder desugar (synthesized AST under
   synthetic node ids, stored in `result.desugars`, replayed by
   lowering; the desugar synthesizes the ctor at full arity so it needs
   no defaulted-argument materialization). Also fixed along the way:
   the projector dropped `{x:04}` format specs (never attached to the
   hole). Self-check stayed at 0 errors — all 60 in-tree interpolation
   sites resolve their desugars against the real stdlib.
4. ~~**M10 — specialization**~~ ✅ landed 2026-08-20, WITHOUT the
   clone the original plan assumed: node ids are span fingerprints, so
   a clone would collide with its template anyway. Instead each
   concrete signature re-checks the ORIGINAL template body into a
   private `InferenceResults` overlay, and lowering re-lowers the
   template once per overlay under a `params + __ret_` mangled symbol.
   Committed generic picks (calls / operators / `op_try` / indexing)
   queue `PendingSpec`s; every body scope drains its own queue after
   its inference settles, so nested generic calls instantiate
   transitively (register-before-check breaks self-recursion). Function
   lookups union the caller chain's imports (the `hash()`-for-`Dict`
   loaded-context rule, first instantiation wins per signature);
   nominal/variant lookups deliberately do not. The transitional Var
   fallbacks (layout's 4-byte guess, `ty_to_ir`'s `i64` fold) are now
   hard failures. Landing it surfaced and fixed a stack of latent
   checker gaps: literal suffixes were IGNORED (`0u32` typed as a
   fresh var), declared array lengths resolved to 0, anonymous-literal
   fields never unified, shifts left their count unchecked, bare-
   literal cast operands never pinned, tuple projection `t.0` was
   untyped, type parameters did not shadow nominals (a project enum
   named `E` poisoned `Result(T, E)` program-wide), and stdlib
   `FilterIter.next` dropped non-matching heads instead of advancing.
   Self-check: 0 errors across all 98 modules with every instantiated
   generic body validated; the self-build emitted 759 C functions (457
   specializations) at M10's landing, all of which compile — `main`
   still drops on M11 features (defaulted-argument calls) plus the
   `__flang_strlen` shim.
5. **RFC-014 lambdas + fn values** (landed 2026-08-20): `check_lambda`
   with in-place bodies (no clone), capture frames, closure-nominal
   synthesis + a global dispatch table, E2111/E2112/E2113; lowering
   emits enqueued lambda bodies post-walk, `CallIndirect` for fn-typed
   callees, `FuncRef` decay for function names, and direct `op_call`
   dispatch for closure values and fields. Specialization now admits
   callable-slot vars (pinned by the instantiation's body re-check,
   re-keyed on settle, twins deduped by symbol) — this is what lets
   unannotated lambdas flow through `$F`. Self-build: still 0 check
   errors; 840 C functions emit.
6. **M11 — call completeness**: defaulted args, casts, unary/binary
   user-operator dispatch (`String ==`).
7. Then: globals/consts, for-over-iterators
   (M10 supplies the specializations; the checker still needs to
   resolve the `iter()`/`next()` protocol instead of typing the loop
   var as a fresh var), array-literal lowering, range slicing,
   template expansion, match exhaustiveness and the other
   rejection-power gaps. The "not needed" list above
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
