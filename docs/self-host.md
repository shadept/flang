# Self-Host Status — Feature Coverage

The single source of truth for what the self-hosted compiler
(`bootstrap` + `lib/flang_*`) can and cannot do, per pipeline stage.

**Harness parity (2026-08-24, M12): REACHED.** The stage-2 self-hosted
compiler passes **551 / 567** — every test the reference passes, with
the same 16 skips — up from 435 at the start of the M12 push. The
stage-2 = stage-3 fixpoint holds and the reference suite is unchanged
at 551 / 0 / 16.
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
| Type inference (HM) | ⚠️ | 0 errors self-checking compiler + stdlib (99 modules) *including every instantiated generic body* (M10); every `Expr` form is now visited (`a?.b` closed 2026-08-24) but rejection power lags the reference — see the type-checking section below |
| AST → FIR lowering | ✅* | M11 landed 2026-08-21: everything `main`'s graph needs lowers — 3593 functions emit, 15 refusals remain, all off the entry path (SIMD-intrinsic csv internals, `read_all_inplace`, `readline`); refusal (never miscompile) still guards those |
| C backend (FIR → C99 → exe) | ✅ | for all FIR the lowering emits; links stdlib C runtime sidecars |
| Full self-build | ✅ | stage-1 (2026-08-21), then stage-2 and stage-3 (2026-08-22): every stage builds the full 99-module project. `-v` prints the per-function skip report with reasons |
| Building non-compiler projects | ✅ | **PARITY 2026-08-24: 11 of 11 `examples/` build, same as the reference**, up from 2 at the start of the day (raylib needs `RAYLIB_PATH`, an external dependency both compilers share). Four driver gaps (`[imports].global` reaches the checker as an implicit private import on project modules; companion `.c` files link by the reference's uniform rule; `#foreign` declarations are globally linkable; `[build.<os>]` libs/ldflags reach the linker, with `${VAR}` expansion and whitespace-split flags), two typer/lowering fixes (constants pinned before bodies; tuple sub-patterns record a node type), symbol mangling made total over non-identifier module paths, and `IrType.Agg` — by-value aggregates across a C boundary with faithful member types, gated on FLang-vs-C layout agreement |
| Stage-2 = stage-3 fixpoint | ✅ | **REACHED 2026-08-22**: stage-2's and stage-3's emitted C are byte-identical (`cmp` clean; dict iteration order was already deterministic). Unlocked by fixing three stacked stage-1 miscompiles — the unrecorded UFCS op_deref peel, missing array-decay at call arguments, and `parse_float` rounding DBL_MAX literals to inf — see docs/known-issues.md §"Stage-1 Segfaults". **Windows/MSVC 2026-08-25**: same fixpoint, after teaching the C backend three portability rules the Unix toolchains had let slide — no cast to an aggregate type, no zero-length slot array, `/experimental:c11atomics` alongside `/std:c11` |

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
| Calls: overloads, defaults window, UFCS (+`op_deref` peel), fn-field + indirect | ✅ | everywhere | M12: NAMED arguments resolve — each name selects its parameter per candidate (`named_param_slots`), counts toward the arity window, and commits against that parameter; the complete parameter-ordered argument list is recorded for lowering (`materialize_arg_list` → `results.arg_lists`) |
| Variadic calls (`f(..xs: T)`) | ✅ | 4 harness tests | M12: a declared `..xs: T` parameter IS a `Slice(T)` (`param_ty`), surplus positional arguments unify with its element type, and the call site records them packed into one synthesized array literal that decays to the slice |
| User `op_call` dispatch (`c(args)`) | ✅ | RFC-014 | M12: a value of nominal type resolves against the visible `op_call` overloads with itself as the receiver, peeling `op_deref` hops when the type wraps another that declares one. Recorded like a UFCS call; the (possibly empty) receiver chain on the call node is what tells lowering the CALLEE is the receiver |
| Member access through `op_deref` | ✅ | RFC smart pointers | M12: `w.x` peels the same `op_deref` chain UFCS calls do (`member_deref_retry`), recorded on the member node so lowering calls each hop instead of geping into the wrapper's layout |
| Anonymous struct TYPES (`struct { x: i32 }` in type position) | ✅ | 4 harness tests | M12: interned as a synthesized nominal keyed by its exact structure (`anon_struct_ty`), so layout / member access / lowering all take the ordinary nominal path. The registry FQN is a counter — the structural key carries `{`, `:` and `,`, which no C mangling survives. An unpinned `.{ x, y }` literal settles on the same interning |
| Enum variant construction (incl. payloads) | ✅ | ~1550/60+ (`Some` 645, `Enum.Variant(...)` 475, `None` 243, `Ok`/`Err` 185) | recorded as `RtEnumVariant` for lowering |
| Struct literals, member access (substituted generic fields) | ✅ | everywhere | named generic literal without args is E2019 |
| `if`/`match` joins (order-independent, `Never` identity) | ✅ | everywhere | E2074/E2075. 2026-08-24: a chained `else if` (a bare `&IfExpr`, not an `Expr`) now RECORDS its joined type — unrecorded, lowering's `node_ty` defaulted the nested join to i32 and truncated aggregate arm values through the block param (`Ord`-returning if-chains miscompiled) |
| Assignment, address-of, deref, casts, tuples, ranges, indexing | ✅ | `as` casts: 845/75 | index operator pick recorded with `is_ref_form`. M10: a BARE numeric literal cast operand takes the target type (`0xFFFF_FFFF as u64` is a u64 constant); tuple projection `t.0` types as the element |
| Unary ops (`-x`, `!x`, `~x`) | ✅ | `!` 191/28, `~` 35/12, neg ~5 | M7: `!` unifies with bool; `-`/`~` type as their operand. Numeric-ness of `-`/`~` not yet *enforced* (rejection-power gap); no `op_neg`/`op_not`/`op_bnot` dispatch to user types (M11, with binary — zero in-tree users today) |
| Lambdas / closures (RFC-014) | ✅ | 23/5 | landed 2026-08-20, no-clone: `check_lambda` checks the literal's body in place (captured names resolve through their outer scopes; no `self.x` rewrite). Unannotated params mint fresh vars pinned by context — including *through* a `$F` slot: `process_pending` admits signatures whose vars sit inside `Func` types, the instantiation's body re-check pins them at the indirect call, and the spec re-keys under its settled signature (`rekey`; twins that settle identical dedup at emission by symbol). Non-capturing → `LambdaInfo` (overlay-scoped: one record per instantiation) typed as a bare `fn`; capturing → synthesized env-struct nominal + entry in the global `closures` dispatch table, typed as the anonymous nominal. E2111 (closure into bare-fn slot, as an overload-failure hint), E2112 (assign to capture), E2113 (transitive nested captures) all report |
| Array literals `[a, b]`, `[v; N]` | ⚠️ | ~52/9 | M10: checked — elements unify, the node types as `[T; len]`, declared `u8[N]` lengths evaluate (previously 0!). A non-literal repeat count (`[0u8; PAGE_SIZE]`) stays an unconstrained var and the enclosing `let` refuses at lowering. M11: `.{ … } as T` pins the anonymous literal to the cast target (previously the var never settled); bare STATEMENT arm bodies (`X => return v`) project as single-statement blocks (previously `Expr.Error`, silently unlowerable) |
| Interpolated strings `$"…"` | ✅ | 60/15 | M9: the reference's StringBuilder desugar, synthesized as real AST under collision-free synthetic node ids and checked through ordinary overload resolution (`append` picks recorded per part; format specs route to the spec-taking overload). The block is stored in `result.desugars`; lowering replays it. Stdlib- and import-dependent by design (`import std.string_builder`) |
| `a?` (op_try), `a ?? b` | ✅ | `?` 28/13 · `??` 5/4 | M8: `?` resolves `op_try`, requires `TryResult(T, R)`, unifies `R` with the enclosing return (E2090/E2092); `??` has the reference's two built-in Option shapes (unwrap and chain) |
| Arithmetic operators over nominals (`op_add`, `op_sub`, …) | ✅ | 0 in-tree, 2 harness tests | M12: the arithmetic half of the comparison ladder — `a + b` over two nominals dispatches to the user's `op_add`/`op_sub`/`op_mul`/`op_div`/`op_mod`/bitwise/shift function and records it as a `ResolvedOperator`, exactly as comparisons do. Primitives keep the hardware path |
| Reified types as values (`size_of(Point)`, `get_kind(i32)`) | ✅ | 31 + 8 + 26 sites | M12: a TYPE NAME in expression position types as `Type(T)` directly (`reified_type_of`) rather than as the bare type plus a coercion, so `Type($T)` parameters bind `$T` and lowering knows to build a TypeInfo instead of reading a binding. `Pair(i32)` in expression position reifies the instantiation |
| Comparison operators over nominals | ✅ | String `==` everywhere | M11: the reference's ladder — primitives builtin, payload-less enum `==`/`!=` as tag compare, direct `op_eq`/`op_lt`/…, `!=` as negated `op_eq` (and vice versa), the rest derived from `op_cmp` — recorded as `ResolvedOperator` on the binary node. String literal PATTERNS record an `op_eq` pick on the pattern node the same way |
| For-over-iterators (protocol) | ✅ | 25/19 | M11: `iter(&Iterable) → State` then `next(&State) → Option(T)` resolved like operators (self-iterators returning `&State` probe the unwrapped shapes second, reference parity); the `iter` pick records on the body-block node, `next` on the for node; the loop var is `T` |
| Overloaded fn names as values | ✅ | `owned(v, deinit)`, `.map(deinit)` | M11, ticket 019 §4: a multi-candidate name in value position parks a fresh var; once context pins its Func shape, `resolve_fn_name_values` (drained per body scope, before the spec drain) picks the overload by those parameter types and records `RtFunction`/`RtSpecialized` |
| Reified types (`Type(T)`, `size_of`) | ✅ | 31 + 8 + 26 sites | M11: `Type(T)` values ARE TypeInfo — `struct_field_lookup` redirects `Type` field access to TypeInfo's definition, so `ty.size` types as usize instead of a fresh var. M12 fills the whole record (see the lowering row) |
| `a?.b` | ✅ | 0 (rewritten away) — input programs use it | 2026-08-24: Option receiver, field lookup on the inner struct (substituted), types as `Option(field)` with RFC-010 flattening (an Option field passes through unwrapped) |
| Specialization (eager monomorphization of generic fns) | ✅ | everywhere (`List`/`Dict`) | M12 closes return-only type parameters (`to_list(it: $I) List($T)`): readiness is SHALLOW (reference parity) - only a type that IS a bare var blocks, so the template instantiates and its body derives `$T`; every stored signature is re-zonked program-wide at the end (`zonk_specializations`) for nested instantiations that finished before their caller pinned the var; each body scope drains to a FIXPOINT; and a call whose overload tie would be broken by a still-open argument PARKS (`PendingCall`) instead of committing, redone after the drain. Instantiation still happens at the drain rather than at the call - eager instantiation nests a generalisation level inside the caller's and was rejected (docs/known-issues.md). M10, **no AST clone**: node ids are span fingerprints, so instantiations of one template share every node id — each instantiation re-checks the ORIGINAL body with `$T` names bound to concrete types, recording into a private `InferenceResults` overlay (`Specialization.overlay`). Committed generic picks (calls, operators, `op_try`, indexing) become `PendingSpec`s; each body scope drains its own pendings after inference settles (register-before-check breaks self-recursion; depth cap 64 diagnoses runaway chains; un-inferable type args are E2001 at the call site). Function lookups during a re-check see the template module's imports UNIONED with the caller chain's (`fn_visibility`) — the deliberate loaded-context rule that lets `hash()` resolve for `Dict`; nominal/variant lookups do NOT widen (a caller's `Decl.Type(...)` variant must not capture `Type(T)`). Generic template bodies are otherwise **never validated** — errors surface per instantiation |
| Templates (`#interface`, `#derive`, …) expanded natively | ✅ | every stdlib generator | 2026-08-23 (RFC-021 phase 4): `flang_parser/template.f` parses bodies, `comptime.f` evaluates (one evaluator with `#if`), `flang_typer/template_expand.f` runs the worklist between collect and resolve; generated decls append to the origin module. No sidecars anywhere; `-g/--emit-generated` writes them for debugging only |
| `#if` compile-time conditionals evaluated | ✅ | 27/10 (incl. `file.f::open_flags`, in `main`'s graph) | landed 2026-08-20: conditions parse as real FLang expressions (`parse_expression` + `stop_at_brace`, paren-free `#if cond {` canonical), evaluated strictly (`flang_parser.comptime`: E2116 unknown name, E2117 non-bool, E2118 operand misuse — reference parity); only the active branch is checked; divergence = active branch's. Decl-level flattens once post-projection (`flatten_module_decls`, active decls spliced via `Module.set_decls`). `--target-os`/`--target-arch` override the context (threaded `ResolveCtx.comptime` → `Checker.comptime`/`LowerCtx.comptime`) |

Every `Expr` form is now visited. The remaining unvisited-subtree
caveat is a generic template body that is never instantiated: per the
M10 model it is never validated at all.

### Rejection power (does invalid code get diagnosed?)

| Check | Status | Notes |
|---|---|---|
| Type mismatches through unification (incl. coercion rules) | ✅ | |
| Overload/arity failures (E2011/E2004) | ✅ | everywhere since M10 — instantiated bodies check with concrete types, so the old generic-body silencing is gone |
| Unresolved unsuffixed literals (E2001) | ✅ | M10 post-inference sweep, reference parity |
| Literal candidate sets in overload resolution | ✅ | 2026-08-24: an open literal var no longer unifies with ANY candidate param — `ikind(10)` against `{String, i64}` picked String by declaration order. `probe_candidate` rejects a pending-literal arg against a concrete non-primitive param (primitives, open vars, and Option-wrap stay legal) |
| Un-inferable generic type arguments (E2001) | ✅ | M10 — at the call span; the reference silently skips and fails later at link |
| Anonymous-literal field mismatches | ✅ | M10 — `resolve_anon_literals` unifies each `.{ f = v }` initializer against the nominal's declared field type once the literal's var settles |
| Type parameters shadow nominals | ✅ | M10 — a project type named `E`/`T`/`K` no longer captures `$E` in stdlib signatures (`Binding.is_type_param`) |
| Match checking (E2030 non-enum, E2031 non-exhaustive, E2032 payload arity, E2037 unknown variant) | ✅ | M12: `check_match_coverage` collects the covered variants per arm (a bare identifier covers the variant it names, otherwise it is a catch-all), guarded arms never count, and a concrete non-enum scrutinee with a variant-shaped pattern is E2030. A top-level bare identifier over an enum scrutinee that is not one of its variants is E2037 (`is_sub` keeps payload bindings out of that rule) |
| Declaration duplicates (E2005 global const, E2076 field, E2034 variant, E2048 tag, E2103 overload) | ✅ | M12. Same-scope LOCAL re-declaration is the reference's warning instead (W1002) |
| `const` rules (E2038 assign, E2039 no-init) and scoped mutability (E2114) | ✅ | M12: a struct's fields are writable only in the module that declares it |
| Missing return (E2049) | ✅ | M12: mirrors the reference's `HasReturnOrImplicitReturn` — an explicit `return`, an `if`/`match` whose every arm returns, a trailing expression, or a bare `loop` |
| Types (E2012 deref, E2014 field, E2017 no `op_*`, E2018 non-struct literal, E2020 cast, E2026 empty array, E2029 literal range, E2035 recursive, E2036 alias cycle, E2040 `&temporary`, E2047 naked-enum payload, E2070 default value, E2102 literal constraint, E2104 bare generic) | ✅ | M12 |
| Iterator protocol (E2021 no `iter`, E2023 no `next`, E2025 wrong `next` return) | ✅ | M12 |
| Dual index-operator forms on one type (E2077) | ✅ | M12: reported when BOTH forms match one `(Self, Idx)`; the ref form still wins deterministically |
| `?` inside a `defer` (E2091) | ✅ | M12: `defer_depth` on the checker |
| Ambiguous overloads decided by an unsuffixed literal (E2011) | ✅ | M12: an exact tie on every ranking key where the two candidates differ concretely at a literal argument's position. The same tie broken by a still-OPEN type instead parks the call and redoes it after the specialization drain - only a call whose argument never settles reports |
| Function types match exactly (E2011) | ✅ | M12: `unify_func` no longer runs the coercion ladder inside parameter/return positions — `fn(i32) i32` is not a `fn(i64) i64` |
| Parser-level (E1001 detached `#simd`/`#foreign`, E1004 array length, E1006/E1007 `break`/`continue` outside a loop, E1010 `for` parens, E1020 `$` prefix, E1024 unterminated interpolation, E1050/E1051 removed `struct`/`enum` declaration syntax) | ✅ | M12 |
| Deprecation warnings (W2001 types, W2002 functions) | ✅ | M12: `#deprecated` reaches the registries and fires at every use site |
| Non-place assignment target (`f() = 1`) | ❌ | lowering refuses the function instead — loud but imprecise |
| Harness `COMPILE-ERROR` corpus parity | ✅ | M12: all 61 expected-error tests pass through stage-2 |

The narrative history behind these lives in docs/known-issues.md
§"Bootstrap Self-Host: Remaining Typer Gaps"; this table is the
current-state summary.

## Lowering — declarations and signatures

| Feature | Status | Self-host need | Notes |
|---|---|---|---|
| Free functions, scalar params/returns | ✅ | everywhere | |
| Aggregate params/returns (structs, enums, tuples, arrays, String, slices) | ✅ | everywhere | by-pointer, callee copies; returns via trailing sret buffer |
| `&T?` / niche `Option(&T)` params and returns | ✅ | everywhere (allocators) | classified scalar `ptr` |
| Foreign (`#foreign`) scalar signatures | ✅ | everywhere | variadic declared but not callable. M11: `never` returns declare as void (`exit`); the pointer-niche `&T?` is a spellable nullable pointer (`malloc`), in both the extern and the symbol-table gate |
| Foreign aggregate signatures | ❌ | 0 in `main`'s graph | byte-buffer aggregates have no C ABI spelling for externs |
| Generic templates skipped (never lowered) | ✅ | by design | `declares_generic` — correct end-state behavior, templates have no single layout |
| Specialized instantiations (from `result.specializations`) | ✅ | everywhere (`List`/`Dict`/iterators) | M10: `lower_specializations` re-lowers the template's declaration once per concrete signature, reading node types/targets/operators through the instantiation's overlay (`LowerCtx.overlay`, consulted before the program tables). Symbols mangle from the concrete parameter types plus a `__ret_` token (return-only-polymorphic templates differ in nothing else; the suffix also keeps specs distinct from same-parameter monomorphic overloads). Call sites route through `RtSpecialized`; operator sites through `ResolvedOperator.spec_id`. 457 specializations emit in the self-build |
| Defaulted params at call sites | ✅ | ~500 decl sites | M11: `materialize_default_args` — the checker checks the callee declaration's own default exprs at the call site (shallow shared AST, no clone; node ids are span fingerprints), unifies them against the winner's instantiated params, and records the omitted tail in `results.default_args` keyed by the call node; lowering appends them after the explicit args. Bails (call refuses) on `$T`-typed defaults, the variadic tail, and depth > 16 |
| Named arguments | ✅ | 2/1 + 10 harness tests | M12: the checker records the COMPLETE parameter-ordered argument list on the call node (`results.arg_lists`); lowering emits it verbatim in place of `call.args`. A named call with no record refuses — the reorder is never guessed |
| Variadic calls | ✅ | 4 harness tests | M12: the surplus arguments arrive as one synthesized array literal in that same list and decay to the callee's `Slice(T)`. Only FOREIGN variadics stay uncallable (C varargs have no FLang signature to check against) |
| User `op_call` on a value | ✅ | RFC-014 | M12: the checker's receiver-chain record on a call whose callee is not a member access means "the callee IS the receiver" — lowering prepends it (through the op_deref hops when there are any) exactly like UFCS |
| Function values / indirect calls / fn-typed fields | ✅ | fn-typed fields in checker/backend dispatch | landed with lambdas: a function NAME in value position decays to `Operand.FuncRef`; a fn-typed callee value emits `CallIndirect` (params/sret mirror direct calls); a closure-typed callee (local, param, or struct field — the checker records the callee member-access node's type for the classification) dispatches directly to its `op_call` symbol with the value's address prepended |
| Lambdas / closures | ✅ | 23/5 | literal sites enqueue `PendingLambda` (with the active overlay) and emit after the main walk — non-capturing as a plain function, capturing as an `op_call` whose leading param is the env pointer and whose captured names bind to `gep`s into it (no copy; captures are read-only). The literal itself is a `FuncRef` or a stack-built env struct |
| Global `const` declarations | ✅ | 101/17 | M11: each const becomes an aligned zeroed byte global plus a synthesized `__finit_*` function lowering its initializer (so vtables of fn pointers and cross-global addresses need no static-initializer support); `main` calls every SURVIVING init first, wired AFTER the drop pass, which also poisons any reader of a const whose init died (`reads … whose initializer was dropped`) — absent, never silently zero. Reads resolve through `RtConst(fqn)` targets the checker records on both the decl and every read |
| `test` blocks (self-host `flang test`) | ❌ | dev workflow, not `main`'s graph | bootstrap CLI has no `test` subcommand |
| UFCS receiver adaptation | ✅ | everywhere | M11: the receiver is adapted to the winner's first-parameter shape by MEMORY type (binding/field declared types — node types are rewritten by the checker's adaptation, so they cannot arbitrate): value→`&prim` passes the place's address, `&prim`→value loads through, same-representation prims (`usize` vs `u64` — declaration order arbitrates equal picks) interchange. Pushing the raw value against an adapted pick was a silent scalar miscompile. Stage-2 fixpoint (2026-08-22): a receiver that resolved through `op_deref` hops records the chain (`receiver_derefs`, per call node, hops drain-rewritten to specializations) and `lower_deref_receiver` calls each hop — the aggregate "value IS its address" shortcut passed `&Owned(StringBuilder)` as `&StringBuilder`, the stage-2 segfault. Call arguments (and value-form index receivers) also adapt array→slice decay now (`lower_arg_adapted`). 2026-08-24: a TEMPORARY receiver (`n.double().add_five()`) spills into a fresh slot and passes its address instead of refusing; `lower_arg_adapted` also decays `&[T; N]` (its value is already the elements' base); `let` initializers adapt too (`let xs: i32[] = [...]` bound raw array bytes as a slice — garbage length) |
| Template directives (`#enum_utils`, `#derive`, `#interface`, …) | ✅ | every stdlib generator | expanded natively (RFC-021 phase 4, 2026-08-23) |
| `#if` compile-time conditionals | ✅ | 27/10 | statement-level splices the active branch's statements at `lower_stmt`; decl-level is already flattened before lowering. M12: lowering uses the BUILD's compile-time context, not the host's — a `--target-os` build was checking the target's branch and lowering the host's. The `comptime.f` evaluator itself joins the M11 emission frontier (`String ==` dispatch), like most of the checker |

## Lowering — statements

| Feature | Status | Self-host need | Notes |
|---|---|---|---|
| `let` (annotated, inferred, uninitialized zero-init) | ✅ | everywhere | value semantics with copy-elision for fresh temporaries |
| Assignment (locals, fields, derefs, indexed places) | ✅ | everywhere (incl. all 172 `x[i] = v` sites — every one is ref-form or built-in, a place) | value-form `op_index` targets refuse; see `op_set_index` below |
| `return` | ✅ | everywhere | incl. sret copies |
| `if` / `else` (stmt + expr) | ✅ | everywhere | block-parameter joins |
| `while`, `loop`, `break`, `continue` | ✅ | everywhere | |
| `for` over integer ranges | ✅ | everywhere | induction var as block param |
| `for` over iterators (iterator protocol) | ✅ | ~125/40 (99 index loops converted to `for x in xs` / `xs.iter_ref()` on 2026-08-22) | M11: `iter` called once, `next(&state)` per iteration with the Option's discriminant (or niche pointer) as the loop test; the payload copies into the loop variable's own slot per iteration (value semantics). Self-iterator states (`iter → &State`) pass unchanged; verified end-to-end (`for x in xs` sums correctly). A fixed-array iterable decays to the slice view `iter(&T[])` takes (`lower_arg_adapted`; the reference had the same gap - docs/known-issues.md) |
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
| Operators dispatching to user `op_*` fns (aggregate operands) | ✅ | String `==` everywhere | M11: comparison dispatch lands (`lower_operator_binary`) with negation and `op_cmp`-derivation — the Ord tag test resolves Less/Equal/Greater INDICES from the definition, because this lowering stores declaration indices as tags (explicit variant values like `Less = -1` are not honored — docs/known-issues.md). Payload-less enum `==`/`!=` is a builtin tag compare. M12: ARITHMETIC dispatch (`op_add`/`op_sub`/`op_mul`/`op_div`/`op_mod`/bitwise/shifts) lands through the same seam |
| Struct literals (concrete, incl. explicit generic args) | ✅ | everywhere | `Pair { … }` without args is E2019. M12: the slot is ZERO-FILLED before the field stores, so a partial `.{ x = 10 }` leaves the rest at 0 rather than at stack garbage; a field initializer decays array→slice like a call argument does |
| Anonymous struct TYPES (`struct { … }` in type position) | ✅ | 4 harness tests | M12: interned as a synthesized nominal, so every downstream consumer is the ordinary nominal path |
| Anonymous `.{ … }` literals | ✅ | **192/50** | typed via nominal coercion; M10 adds the deferred field pass (`resolve_anon_literals`) so initializers actually unify against the nominal's field types — mismatches report, unsuffixed numeric fields pin. M12: a literal NOTHING pins becomes its own interned record type, and a member access on one reads the parked field types before that settles (`pending_anon_field`) |
| Member access through `op_deref` | ✅ | RFC smart pointers | M12: `deref_member_field` calls every recorded hop on the receiver's address, then geps into the innermost struct |
| Reified `Type(T)` values (full `core.rtti.TypeInfo`) | ✅ | 12 harness tests | M12: `build_typeinfo` materialises the whole record at the use site — name, size, align, kind, type params / args, struct fields (name, offset, nested TypeInfo), enum variants, and a function type's params + return. Depth-capped at 3 so a recursive type bottoms out; `type_args` is `&TypeInfo[]`, so the pointer is always written (a null there would make `.len` read through address 0) |
| Member access (nested paths, place + value) | ✅ | everywhere | generic fields load at substituted widths. 2026-08-24: auto-deref recurses — `(&&T).x` peels every reference hop in both checker and lowering (depth−1 loads through); `arr.len`/`arr.ptr` on fixed arrays now CHECK as usize/`&elem` (previously fresh vars — a cast operand var panicked `ty_to_ir`) |
| Address-of `&x`, dereference `p.*` | ✅ | everywhere | `x.*` on a nominal dispatches its `op_deref` (2026-08-22): the checker records the pick as an operator on the deref node and types it as `T`; lowering's `deref_address` calls it in every position - value, place (`&b.*`, assignment), and UFCS receiver (`b.*.m()`). Previously the node typed as a fresh var and free-call arguments silently picked the wrong overload (harness: `op_deref/op_deref_overload_positions.f`) |
| Direct calls, UFCS, overloads | ✅ | everywhere | |
| Enum variant construction (`Some(x)`, `Color.Red`, `None`) | ✅ | ~1550/60+ | M7: tagged form builds tag-then-payload into a fresh slot; niche `Option(&T)` is a retype (`None` = null ptr, `Some(p)` = its payload ptr). Multi-payload construction refuses (2 sites, matching the pattern side) |
| Indexing: `op_index_ref` / `op_index` / built-in | ✅ | everywhere | |
| `op_set_index` (value-form indexed assignment) | ❌ | **0 sites in `main`'s graph** — all 172 `x[i] = v` sites are places (arrays/slices via the built-in path, `List` via `op_index_ref`); dict sugar `d[k] = v` is unused (`.set(...)` throughout) | keep refused until a use appears |
| Range slicing `xs[a..b]` on built-in bases | ✅ | 105/21 | M11: the checker routes builtin-base range indexing through the stdlib's clamping `op_index($T[], Range(usize))` overloads (String already went via user_index), so lowering is an ordinary operator call; `a..b` in value position builds the `Range(T)` struct. PARTIAL ranges (`a..`, `..b`, `..`) complete against the receiver in `lower_index_arg`: start 0, end the receiver's length |
| `match` | ✅ | everywhere | see patterns below |
| Casts `x as T` | ✅ | 845/75 | M11: trunc / sign-directed extension (source signedness picks zext/sext), fp↔int by the non-float side's sign, fp widths, ptr↔int, ptr↔ptr no-op, repr-compatible aggregate retypes, `[T; N] as T[]` decay (builds the `{ptr,len}` view), tagged-enum ↔ int through the I32 discriminant. `x as bool` refuses (needs C's `!= 0`, zero sites). The backend spells i64::MIN as `(-…807LL - 1)` |
| Array literals `[a, b]`, `[v; N]` | ✅ | ~52/9 | M11: stride-addressed element stores into a slot; the zero-repeat form is one memset (non-zero repeats unroll, refused above 64 — no in-tree user); a decay-coerced literal wraps the fresh array in a Slice view. `arr.len` is the constant length; `arr.ptr` the array's address. **`N` must be an integer literal** — a named module const (`[0u8; CAP]`) refuses the whole body (2026-08-25) |
| Tuple literals `(a, b)` | ✅ | 9/6 (+ std.conv return tuples) | M11: element stores at the tuple layout's offsets; `t.0` projection geps through `member_field`; the empty tuple is unit. A unit `()` variant payload (`Ok(())`) stores and binds nothing |
| `a?` (op_try early return) | ✅ | 28/13 | M8 machinery + M10 specialization: a generic `op_try` now instantiates and the caller lowers against its specialization (test: "postfix ? through a generic op_try lowers via its specialization") |
| `a ?? b` (coalesce) | ✅ | 5/4 | M8: built-in Option branch, short-circuit right side; niche and tagged, unwrap and chain forms |
| `a?.b` (null propagation) | ✅ | 0 (rewritten away) — input programs use it | 2026-08-24: tag branch, field projected out of the payload, wrapped in `Some` (or passed through when the checker flattened); niche results load/null the field pointer directly |
| Bare ranges `a..b` as values | ✅ | index/slice args | M11 `lower_range_value`; bare PARTIAL ranges outside index position still refuse (no bound to default from) |

## Lowering — match patterns

| Feature | Status | Self-host need | Notes |
|---|---|---|---|
| Wildcard, variable bindings | ✅ | everywhere | aggregate bindings copy (value semantics) |
| Int / bool / char / byte / float / `null` literals | ✅ | everywhere | float patterns compare with ordered fcmp (M9); string patterns refuse — comparing one is a `String ==` call, which operator dispatch does not record yet |
| Ranges `lo..hi` | ✅ | used | 2026-08-24: the PROJECTOR now actually produces `Pattern.Range` (`a..b`, `a..=b`, `..b`, `a..` with single-literal bounds) — before this every range pattern projected as `Error` and E2115'd; the checker/lowering support had no producer |
| Enum variants, single payload | ✅ | everywhere | tagged + niche. 2026-08-24: refutable payload SUBPATTERNS (`Reading(0)`, `Ok(None)`) now actually test — `variant_test` ANDs each subpattern's test at the declared payload type; before, `Reading(0)` matched any `Reading` (tag-only test, subpattern silently treated as a binding). String subpatterns inside payloads refuse (`payload_test_safe`) — an `op_eq` call on wrong-tag bytes is not a masked load |
| Enum variants, multi payload | ✅ | `OptArg(c, val)` in getopt + 2 | M11: `variant_payload_offsets` (shared payload offset + the variant's struct-like internal layout) drives both construction and pattern binding |
| Or-patterns (non-binding) | ✅ | used | 2026-08-24: projector produces `Pattern.Or` (top-level `\|` split); bare-variant alternatives (`Red \| Green`) no longer misclassify as bindings. Binding alternatives still refuse |
| Struct / tuple destructuring patterns | ✅ | 0 in-tree, 2 harness tests | M12: the projector produces `Pattern.Struct` / `Pattern.Tuple` (a `..` rest marker inside braces is no longer mistaken for a range), the checker constrains every sub-pattern against the field / element type, and lowering ANDs each sub-pattern's test at the field's own address and binds through it |
| Guards | ✅ | used | |

## Confirmed NOT needed (rewrite or defer indefinitely)

Measured near-zero in the self-host sources — implementing these buys
no self-hosting progress; a handful of call-site rewrites removes the
need entirely:

- foreign aggregate signatures (0), `x as bool` (0).

`?.` null propagation left this list on 2026-08-24: its 3 sites had
been rewritten away, but a *working* compiler must accept input
programs that use it — it is implemented, not avoided. Struct/tuple
destructuring patterns, named arguments and variadic *calls* left it on
2026-08-24 (M12) for the same reason: near-zero in-tree use says
nothing about what an input program is allowed to write.

The 15 remaining refusals (2026-08-21, all off `main`'s path): the
csv SIMD internals (`v128_*` intrinsic calls), `read_all_inplace`,
`readline`'s `read_key`, and their transitive callers.

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
5. ~~**RFC-014 lambdas + fn values**~~ ✅ (landed 2026-08-20): `check_lambda`
   with in-place bodies (no clone), capture frames, closure-nominal
   synthesis + a global dispatch table, E2111/E2112/E2113; lowering
   emits enqueued lambda bodies post-walk, `CallIndirect` for fn-typed
   callees, `FuncRef` decay for function names, and direct `op_call`
   dispatch for closure values and fields. Specialization now admits
   callable-slot vars (pinned by the instantiation's body re-check,
   re-keyed on settle, twins deduped by symbol) — this is what lets
   unannotated lambdas flow through `$F`. Self-build: still 0 check
   errors; 840 C functions emit.
6. ~~**M11 — self-build completeness**~~ ✅ landed 2026-08-21, one
   long push: defaulted-argument materialization, the cast matrix,
   comparison-operator dispatch (String `==` + string patterns),
   module consts as runtime-initialized globals, range slicing (via
   the stdlib overloads) with partial-range completion, array and
   tuple literals + `t.N` projection + array decay, multi-payload
   variants, for-over-iterators, overloaded-fn-names-as-values
   (ticket 019 §4), minimal RTTI (`size_of`/`align_of` layout folding;
   `Type(T)` values as TypeInfo), `&temporary` spill, and a stack of
   latent miscompiles the new coverage exposed: pointer arithmetic was
   UNSCALED (byte-stepping `List(i32)`), a `&`-typed path step geped
   into the field instead of following the pointer
   (`allocator.vtable.alloc` called the vtable's address), adapted
   UFCS receivers passed raw values at the wrong indirection, and
   bare-statement match arms (`X => return v`) projected as
   `Expr.Error`. Also: the `-v` build now prints a skip report with
   per-function refusal REASONS — the debugging loop for everything
   above.
7. ~~**Stage-2 correctness**~~ ✅ landed 2026-08-22: **the stage-2 =
   stage-3 byte-identical fixpoint is reached.** The "scale-triggered
   stage-1 segfault" was three stacked miscompiles, none actually
   scale-triggered (the nondeterminism was a stale binary): the UFCS
   `op_deref` peel resolved by `deref_retry` but never recorded for
   lowering (receivers through `Owned(T)` read every field 8 bytes
   off), array→slice decay never firing for non-literal call arguments
   (a let-bound `[u8; 4]` handed to `u8[]` as raw bytes), and
   `parse_float` rounding the DBL_MAX infinity-guard literals in
   `emit_float_const`/`format_f64_exp` over into `+inf` (stage-2 then
   emitted a bare `inf` identifier into stage-3's C). Fixes: the
   `receiver_derefs` table (checker records the hop chain per call
   node, the M10 drain rewrites generic hops to specializations,
   `lower_deref_receiver` calls them), `lower_arg_adapted` (decay views
   at call arguments and value-form index receivers), infinity guards
   rewritten to `v * 0.5 == v`, and chunked 10^22 scale application in
   `parse_float`. Dict-iteration emission order was already
   deterministic — no determinization needed.
8. ~~**Post-fixpoint: template expansion**~~ ✅ landed 2026-08-23
   (RFC-021 phase 4). The self-host expands `#define` bodies natively:
   structured generator args/params in the parser, the template body
   parser + text engine in `flang_parser/template.f`, the unified
   compile-time evaluator (`comptime.f` — `#if` directives and template
   expressions share `ct_eval`, `CtValue` carries the `core.rtti`
   introspection shapes), and the expansion worklist in
   `flang_typer/template_expand.f` (parking for cross-module type deps,
   §7 readable-output normalizer, E2119 depth cap). Sidecar loading is
   deleted; a clean clone self-builds. `op_set_index` dispatch landed
   with it (`d[k] = v` — the expander's own code uses it). The
   stage-2 = stage-3 fixpoint was re-verified after the change, with the
   reference's C mangling now module-qualifying every function (a
   private-fn symbol collision was silently merging same-signature
   functions across modules).
9. **Next**: match exhaustiveness and the other rejection-power gaps,
   `project_info()` interception, real RTTI (name strings, fields).
   The "not needed" list above stays refused until a real use appears.

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
