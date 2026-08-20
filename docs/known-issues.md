# Known Issues & Technical Debt

This document tracks known bugs, limitations, and technical debt in the FLang compiler.

---

## How to Add Items

When you discover a bug or limitation:

1. Add it to the appropriate section
2. Include: Status, Affected components, Problem description, Solution, Related tests
3. Update when fixed (remove or move to bottom)

---

### Bootstrap Segfaulted Type-Checking a `struct` Declaration — RESOLVED

**Status:** Resolved — `HmAstLowering` lexical-scope fix
**Affected:** `FLang.Semantics/HmAstLowering` block lowering (the C# reference compiler that builds the bootstrap)

The bootstrap crashed type-checking any source containing a `struct` declaration (enums were fine). The fault was **not** in the FLang typer. `HmAstLowering` kept a single flat name→slot map (`_locals`) with no lexical scoping, so a `let` inside a block permanently overwrote any outer binding of the same name. `resolve_struct_body` (`lib/flang_typer/src/checker.f`) binds the nominal id as `let id = …`, then shadows it with `let id = …` inside the generics loop; the post-loop `nominals.get(id)` then read the loop-local slot, which is uninitialised when the struct has no generics (the loop never runs) → out-of-bounds index → segfault. Enums were immune only because `resolve_enum_body` names its loop-local `vid`. The reference compiler's own type-check never reproduced it because it doesn't run the FLang typer.

**Fix:** `LowerBlock` now opens a lexical scope and, on exit, undoes the `let`/`const` bindings it introduced, restoring any shadowed outer binding. Copy-on-write parameter promotions and pattern bindings deliberately stay function-scoped. Regression test: `tests/harness/scoping/shadow_let_in_loop_body.f`.

---

### Struct Field Reads Through the Bootstrap — RESOLVED

**Status:** Resolved — minimal struct/member typing + lowering in the bootstrap
**Affected:** bootstrap `flang_typer` (struct-literal / member typing) and `flang_driver` AST->FIR lowering

Once the type-check segfault was gone, a bootstrap-built `let p = Pt { x = 7, y = 4 } return p.x` returned `0`. This was **not** a wrong-offset miscompile: struct-literal and member-access expressions were simply unbuilt. The bootstrap typer left both as fresh inference variables (`check_expr_kind`), and the M1 lowering stubbed both to `IntConst(0)`, so the whole body folded to `return 0`.

**Fix (minimal M4):**
- Typer (`lib/flang_typer/src/checker.f`): `check_struct_lit` resolves the literal's named type to its nominal and unifies each initializer against the declared field type; `check_member` returns a struct field's declared type, and falls back to a fresh var for non-struct receivers so UFCS bases are untouched (generic field substitution lands with generics).
- Lowering (`lib/flang_driver/src/lower.f`): a struct literal allocates a stack slot and stores each field at its `layout.struct_layout` offset (aggregate fields copy their bytes, scalars store by value); member access geps to the field offset and loads. A struct value is its slot pointer — FIR addresses aggregates by pointer — so nested `a.b.c` chains geps without an intermediate copy.

**Verified:** bootstrap-built first / non-first / arithmetic reads, plus 3-field and out-of-order-init structs, return the right values. Store and load both take offsets from the shared `layout.f`, so they always agree. Regression tests: `tests/harness/structs/struct_field_return_first.f` and `struct_field_return_nonfirst.f` (reference compiler), and a lowering block in `lib/flang_driver/src/lower.f`.

**Still milestone-gated:** struct-typed parameters and returns skip the lowering signature gate (`type_expr_to_ir` accepts only primitives), so a function that takes or returns a struct by value is type-checked but not lowered yet; field assignment, pattern destructuring, and `&struct.field` arrive with later milestones.

**Reference compiler:** the companion `(void*)(0 + 0)` const-fold symptom does not reproduce in the current tree. `HmAstLowering.LowerMemberAccess` always spills a struct value to an alloca and loads at the field's byte offset; the minimal repro and its variants (non-first field in a return, in arithmetic, off a call result, 3-field structs) all compile and run, and the full struct harness passes. Pinned by the two new harness tests above.

---

### Bootstrap Typer Resolved Type Bodies Per-Module (cross-module `unknown type`) — RESOLVED

**Status:** Resolved — split name registration from body resolution in `check_all`
**Affected:** bootstrap `flang_typer` nominal collection (`lib/flang_typer/src/checker.f`)

Running the bootstrap on any stdlib-using project (including itself) reported `unknown type` for cross-module types — `String`, `Allocator`, `SourceSpan`, `Module`, `TypeCheckResult`, `Token`, and more. `check_all` called `collect_nominals` once per module, and that routine registered the module's type *names* **and** resolved their *bodies* before moving to the next module. So a struct field or enum payload that named a type from a not-yet-processed module (e.g. `core.rtti`'s `ParamInfo { name: String }`, processed before `core.string`) failed to resolve, even though the top-level comment claimed all names were registered first.

**Fix:** `collect_nominals` is split into `collect_nominal_names` and `resolve_nominal_bodies`; `check_all` runs the first across every module, then the second across every module, so a body resolves against the complete name set regardless of module order. Verified: a full bootstrap-on-itself run now type-checks 79 modules and every cross-module struct/enum type resolves. Covered by the existing `flang_typer` / `flang_driver` `test {}` suites.

---

### Implicit `T -> Option(T)` Coercion — REMOVED (RESOLVED)

**Status:** Resolved 2026-08-18 — the coercion and its `[lang].implicit_option_wrap` flag are gone; see [ADR-0005](adr/0005-remove-implicit-option-wrapping.md)

The wrap could not be one rule in one place: it had to fire *during*
unification, so checker after checker grew private knowledge of it (the C#
`PreBindOptionTypeVar` at three join sites, the self-hosted
`prebind_option_payload` / `unify_expected` payload case / engine guard, a
`UnifyInternal` literal branch that silently bypassed the migration flag).
Every such site was a place the feature could be forgotten, and the failure
mode was silence.

**Removed:** `OptionWrappingCoercionRule` and its registration,
`PreBindOptionTypeVar`, the `UnifyInternal` constrained-literal branch, the
whole `ImplicitOptionWrap` / `LangSection` plumbing (flag, loader, manifest
section), and the self-hosted typer's `try_option_wrapping`,
`prebind_option_payload` / `try_prebind`, `option_payload`, and
`unify_expected` payload special case.

**Migrated:** ~800 sites to explicit `Some(...)` across `stdlib/` (including
generics only instantiated by the harness), the `#enum_utils` `from_string`
template, the self-host compiler (`lib/`, `bootstrap/`), harness tests,
examples, and tools. Two compiler fixes fell out: lowering now recognizes
`Some(x)` for niche-optimized `Option(&T)` as variant construction (a retype),
and the string-interpolation desugar wraps an `&alloc` builder argument in
`Some(...)` itself. Tests asserting the old wrap were inverted to pin the new
semantics (bare `T` against `T?` is an error), in both the C# harness and the
self-hosted typer suite — the latter now registers a real `core.option` module
in its fixtures so the assertions are no longer vacuous.

---

## Open Issues

### Self-Host: Unary Expressions Are Never Type-Checked (and Lower on a Fallback) — RESOLVED

**Status:** Resolved 2026-08-19 (M7) — `checker.f::check_unary` visits the operand and types the node (`!` unifies both sides with `bool`; `-`/`~` type as their operand), so `lower_unary`'s width/float reads are now real and `-x` on an `f64` emits `fneg`. Numeric-ness of `-`/`~` operands is still not *enforced* (an eventual rejection-power item, tracked in docs/self-host.md), but the silent-wrong-code path is gone. Self-check stayed at 0 errors across the 98 modules with the operand subtrees newly visited.

---

### Reference: Coexisting `Dict(u32, Ty)` and `Dict(u32, List(Ty))` ICE at Lowering — RESOLVED

**Status:** Resolved 2026-08-19 — same root cause as the stdlib/std ICE entry below (the re-lower fan-out re-queuing registry templates); repro compiles and runs correctly now. The `symbol_table.f` workaround (`by_fn_params`/`by_fn_ret` split) has been collapsed back into one `Dict(u32, FnSig)`, which now compiles through the reference compiler as the fix's in-tree proof.
**Affected (was):** reference compiler generic specialization (same family as the resolved "Same-Named Types ... Collided In Generic Specialization" entry)

A module whose one struct holds both a `Dict(u32, Ty)` and a `Dict(u32, List(Ty))` field dies at reference-compiler lowering with `internal: unresolved type variable ?N reached lowering` — reported against an unrelated function (the first one in the file that touches any `Dict.get`). Each instantiation compiles fine alone; only the pair trips it. A `Dict` whose value type is a struct that itself carries a `List` (e.g. `Dict(u32, FnSig)` with `FnSig = { params: List(Ty), ret: Ty }`) hits the same ICE.

**Workaround:** `SymbolTable` stores the return type as a singleton `List(Ty)` so both dicts share one instantiation. Once fixed, collapse `by_fn_params`/`by_fn_ret` back into one `Dict(u32, FnSig)`.

---

### Reference: Dict Field of a By-Value Local Loses Writes

**Status:** Open — silent wrong code
**Affected:** reference compiler place lowering (ADR-0003 family)

```flang
type Table = struct { by_a: Dict(u32, String), by_b: Dict(u64, u32) }
fn lookup(self: &Table, k: u32) String? { return self.by_a.get(k) }
// in a test:
let t = Table { by_a = dict(), by_b = dict() }
t.by_a.set(1u32, "x")
t.lookup(1u32).is_some()   // false - the set through the local's field did not stick
```

A single dict as a plain local works; the write is lost when the dict is a field of a by-value local struct (with more than one dict field) and later read through a `&self` method. The self-host sources avoid the shape (dicts are built as locals and moved into structs on return), so nothing in-tree currently miscompiles — but it is a trap.

---

### Bootstrap `build` Overwrites Its Own Binary

**Status:** Open — annoyance
**Affected:** `bootstrap/src/main.f::build_project`

The bootstrap project's output path is `build/flang` — the same path the running compiler was loaded from, and the same `build/flang.c` the reference stage-0 writes. A failed self-host link therefore deletes the stage-1 binary, and inspecting the two compilers' emitted C requires copying one aside first. Stage the self-host output under a distinct name (`build/flang-stage2`) or a separate directory.

---

### `flang test` on `stdlib/std` ICEs in Lowering — RESOLVED

**Status:** Resolved 2026-08-19 — `test-all` is 6/6 green for the first time.
**Affected (was):** `src/FLang.IR/TypeLayoutService.cs`; `stdlib/std/path.c`

Two independent bugs, the second unmasked by fixing the first:

1. **`TypeLayoutService`'s deferred re-lower queue re-lowered generic
   *templates*.** The original suspicion (`FixUpCoercedArguments` not firing,
   dual module origins) was wrong — the fixup worked; the throw came from
   `EnsureTypeTableExists`'s layout walk draining the re-lower queue. Two
   defects fed it: (a) the size-change fan-out re-queued consumers via
   `LookupNominalType(name)`, which returns the registry **template** (raw
   type-param vars in its fields) while keeping the concrete instantiation's
   cache key; and (b) `LowerNominal` built its substitution from the
   *resolved* template params, so while inference had them temporarily bound
   (json.f checking `Dict(OwnedString, JsonValue)` binds the shared template
   vars) the subst came out empty and layout silently leaned on live engine
   bindings — which had rolled back by drain time, leaving `?3` to throw.
   Fixed by matching template params raw and by snapshotting the concrete
   nominal each cache entry was lowered from (`_loweredNominals`) so the
   fan-out re-queues that, never the template. Also fixes the "Coexisting
   `Dict(u32, Ty)` and `Dict(u32, List(Ty))`" entry above — same root cause.

2. **`path.c` returned POSIX's `R_OK` (4) as its success code.** The sidecar
   `#define`d `R_OK 0` and then included `<unistd.h>`, which redefines `R_OK`
   to 4 (the `access()` read bit) — every successful `__flang_path_getcwd`
   returned 4 and read as an error. Renamed to `PATH_R_OK`/`PATH_R_ERR`,
   the prefixed convention process.c already documents for this exact trap.

---

### Composite Structs Duplicate the Allocator Pointer Per Child Container

**Status:** Future work — noted 2026-08-19, explicitly not a priority
**Affected:** any struct composing several allocator-carrying containers — `UnionFind` (nodes Dict + undo Stack of Lists + own field), `Engine`, `Checker`, and every similar composite

Header-owned allocators mean a composite stores the same `&Allocator?` once
per child container plus once for itself — `UnionFind` carries four copies of
one pointer. Today this is the accepted trade (8 niche-packed bytes per
header, and each container frees against exactly the allocator that fed it,
no cross-field invariants), but the duplication is conceptual debt that grows
with every composite.

**Direction chosen when this gets picked up:** combine the arena-owning-parent
pattern with Zig-style explicit parameters — the composite stores a *single*
allocator (or owns an arena over the caller's), its child containers store
none, and the allocator is passed as an argument to the children's allocating
methods (`nodes.set(alloc, k, v)`, `undo.push(alloc, frame)`). One stored
pointer, still fully explicit at every allocating call, and bulk-lifetime
composites get one-shot deinit via the arena. Requires parameter-taking
variants of the container APIs (or a parallel "unmanaged" container flavor),
so it is an stdlib API design piece, not a local refactor. `Projector`
already demonstrates the arena half of the pattern.

---

### Higher-Order Stdlib Functions Cannot Thread an Allocator Into the Callback

**Status:** Open — design decision needed before the combinator set grows
**Affected:** `stdlib/std/list.f` (`flat_map` today; any future `group_by`, `partition_map`, `permutations`, `combinations`)

A callback that returns a container has to allocate it, and the caller has no
way to say where from. `List.flat_map` therefore does one allocation and one
free per element for values that are pure scratch — nothing outlives the
iteration that produced it. For small results that allocator traffic is the
entire cost of the call.

The same shape will dominate anything built on top: `permutations` and
`combinations` produce many short-lived intermediate sequences, so the
allocation pattern matters more there than in `flat_map` itself.

**Options, none chosen:**

1. **Thread an allocator into the callback** — `f: fn(T, &Allocator) List(U)`,
   with a temporary arena created once per call and reset at the end.
   Intermediates become bump allocations reclaimed in one shot. Costs: every
   callback signature grows an argument, and the arena's lifetime becomes part
   of the contract.
2. **Let the callback append into the output** — `f: fn(T, &List(U))`. No
   intermediates at all, which is strictly the least work, but the callback
   stops being a pure function and cannot be reused as a mapper.
3. **Keep the current shape** and accept the traffic where results are large
   enough that the copy dominates anyway.

Worth settling before the utility set grows, since the choice sets the
convention every later combinator follows.



### TEMPORARY: Lowering Refuses Functions It Cannot Fully Lower

**Status:** Deliberate scaffold — scheduled for removal, not a design feature
**Affected:** `lib/flang_driver/src/lower.f` (`unlowerable`, `LowerCtx.blocked`), `lib/flang_codegen/src/fir.f` (`IrModule.skipped`)

Lowering covers a subset of FLang. Every construct outside it used to lower to
a placeholder zero, so the function was still emitted, linked, and run — and
silently computed the wrong answer. `defer` statements were dropped outright,
and a `for` over a non-range iterable vanished.

Now `unlowerable(ctx)` marks the function and `lower_function` refuses to emit
it, recording the symbol in `IrModule.skipped`. A missing function fails loudly
at link time; a wrong one never fails at all.

**This is a crutch for the milestone period.** The end state is that every
construct either lowers or produces a diagnostic — never a quietly dropped
function.

**Removal condition.** When `lower_expr` and `lower_stmt` no longer need a
catch-all placeholder arm (every `Expr` and `Stmt` variant lowers), delete:
`unlowerable`, `LowerCtx.blocked`, the skip branch in `lower_function`,
`IrModule.skipped`, the `was_skipped` test helper, and every call site. The
tests that assert refusal (`a caller of an out-of-subset callee is refused…`,
`a for over a non-range iterable refuses the function`, and the two
unrepresentable-pattern tests) go with them.

**Interim gap:** the skip is not yet surfaced to the user. `IrModule.skipped`
is populated but no driver diagnostic reads it, so today the failure appears as
a link error naming a mangled symbol rather than a message naming the
unsupported construct. That should be wired up before the scaffold outlives
this milestone series.



### Same-Named Types From Different Modules Collided In Generic Specialization — RESOLVED

**Status:** Resolved — specialization keys use the FQN; self-hosted compiler was never affected
**Affected:** `src/FLang.Semantics/HmTypeChecker.Specialization.cs`

Two modules may each declare a `pub type Thing`. Instantiating the same generic
over both — e.g. `Option(Thing)` — produced **one** specialization for what are
two distinct types. The second call site silently reused the function specialized
over the first module's type.

**Root cause.** `AppendTypeSpecKey` keyed nominals by `NominalType.ShortName`, and
fell through to `sb.Append(type)` for structural types — whose `ToString()` also
renders nominals by short name, so `&a.Thing` and `&b.Thing` collided too. IR
struct C names are FQN-derived (`TypeLayoutService` keys the layout cache by
`nt.Name`), so the emitted call named a symbol nothing defined.

The failure surfaced far from the cause: `E3002 Unknown call target 'unwrap'`
reported against `stdlib/core/prelude.f:1:1` rather than the offending type,
declaration, or call site. Nothing in the message named either type.

Hit while adding assignment lowering: `lib/flang_driver/src/lower.f` declared a
private `Binding` while `lib/flang_typer/src/env.f` exports a `pub type Binding`.

**Fix.** `AppendTypeSpecKey` now appends `nt.Name` (the FQN) and recurses through
`ReferenceType`, `ArrayType` and `FunctionType` instead of relying on `ToString()`.
Pinned by `tests/harness/generics/generic_specialization_same_type_name.f`,
verified to fail on the pre-fix compiler.

**The self-hosted compiler never had this bug.** `specialization.f::key_for`
formats types via `type.f::format`, and `format_nominal` emits the nominal's
*registry id* (`#7`), which is unique per declaration; `lower.f::nominal_name`
likewise uses the declaration's FQN. Two `test {}` blocks in `specialization.f`
now pin both halves — distinct ids give distinct keys, the same id reuses one.

### Optional-of-Reference Field Read Off a By-Value Struct Emits a Double Pointer

**Status:** Open — caught by the C compiler, not silent
**Affected:** `src/FLang.Semantics/HmAstLowering.cs`

An `Option(&T)` is represented as the bare (nullable) pointer, so `is_none`/`unwrap`
take a `T*`. Reading such a field off a struct held **by value** passes the field's
address instead of its contents — `T**` where `T*` is expected. The same field read
through a `&Struct` parameter is fine.

```flang
type Holder = struct { e: &i32? }

fn by_value(h: Holder) bool { return h.e.is_none() }   // C error: int32_t** vs int32_t*
fn by_ref(h: &Holder) bool { return h.e.is_none() }    // fine
```

The lowering unconditionally materializes the by-value struct into a slot and hands
back the field's address — correct for an aggregate field, wrong for one whose
representation is already a pointer.

**Impact is contained:** clang rejects the generated C with
`incompatible pointer types ... dereference with *`, so this fails the build rather
than miscompiling. Workaround is to keep the struct behind a reference; `lower_for`
in `lib/flang_driver/src/lower.f` splits into `lower_for_range(… rng: &RangeExpr)`
for exactly this reason.

### C# Backend Re-Derives Link Symbols At Codegen Instead Of Consuming Them

**Status:** Open — specified deviation, migration in ADR 0004
**Affected:** `src/FLang.Codegen.C/HmCCodeGenerator.cs`, `src/FLang.IR/IrModule.cs`, `src/FLang.Semantics/HmAstLowering.cs`

`docs/spec.md` §7.1.1 makes lowering responsible for assigning link symbols so backends stay overload- and mangling-independent. The self-hosted compiler complies (`lower.f::mangle_symbol` + `SymbolTable`; `c_backend.f` emits `c.callee` verbatim). The C# compiler does not: the IR carries unmangled names and `HmCCodeGenerator` re-encodes the signature at emit time, separately at the definition (`MangleFunctionName(IrFunction)`) and at every call site.

**Concrete hazard.** The two derivations read different inputs. The definition mangles from `fn.Params`, skipping the sret parameter when `fn.UsesReturnSlot`. The call site mangles from `call.CalleeIrParamTypes`, which is only assigned `if (calleeParamTypes != null)` (`BasicBlock.cs:171,185`) and otherwise **falls back to argument types**, defaulting untyped arguments to `i32`. Parameter and argument types diverge precisely where FLang inserts a coercion; when they do, the call names a symbol nothing defines and the build fails at C link time, far from the cause. Currently latent — the harness is green — but latent by luck, not by construction.

**Related smell.** A third identity scheme already exists: `IrFunction.SemanticKey` / `CallInstruction.CalleeSemanticKey` (`name|params|ret`), invented so `InliningPass` could match callers to callees. It solves the same problem as the mangled symbol in a different encoding, because the IR carries no authoritative function identity.

Full analysis and a five-step migration in `docs/adr/0004-symbol-assignment-belongs-to-lowering.md`.

### Mutation Through a Multi-Hop UFCS Receiver Was Silently Dropped — RESOLVED

**Status:** Resolved — `HmAstLowering` lowers a member-access receiver as an lvalue
**Affected:** C# `HmAstLowering` UFCS receiver lowering; found while building the M2 symbol table

A method call whose receiver was a **two-or-more-hop field path** passed a copy instead of a reference, so the callee's mutations were discarded. It compiled clean and emitted no diagnostic — the "silently-wrong code" failure mode.

```flang
type Counter = struct { n: i32 }
fn incr(self: &Counter) { self.n = self.n + 1 }

type Mid   = struct { c: Counter }
type Outer = struct { mid: Mid }

fn via1(self: &Mid)   { self.c.incr() }        // one hop  — worked
fn via2(self: &Outer) { self.mid.c.incr() }    // two hops — silent no-op
```

Scope was narrower than it first appeared: nested *assignment* (`self.mid.inner.n = …`) was always correct, because assignment goes through `LowerLValue`, which recurses and keeps the address chain. Only the **UFCS receiver** path was wrong.

**Cause:** the receiver branch lowered its target with `LowerExpression(memberReceiver.Target)`. For a nested path the target is itself a member access, and `LowerMemberAccess` spills the intermediate struct to a temporary alloca and loads it. The following `EmitGEP` then addressed that copy. With a one-hop receiver the target is a plain identifier already held as a pointer, which is why depth one always worked.

**Fix:** lower a member-access target as an lvalue (`LowerLValue(...) ?? LowerExpression(...)`), matching what assignment and index-base lowering already do. The recursion is deliberately **not** applied to identifier targets: `_locals` stores a parameter's slot address, so `LowerLValue` on a bare identifier yields one pointer level too many (`&&T`) — the first attempt at this fix did exactly that and broke the one-hop case plus the whole stdlib with `Allocator**` vs `Allocator*` C errors. `LowerLValue`'s pointer-level bookkeeping lives on its member-access branch, so only that branch is used.

**Regression test:** `tests/harness/ufcs/ufcs_nested_receiver_mutates.f` pins one-, two-, and three-hop receivers together so the depths cannot diverge again. Full harness: 517 passed / 0 failed / 14 skipped of 531.

**Note:** the M2 `SymbolBuilder` workaround (flat dicts rather than a nested `SymbolTable`) is no longer strictly required, but is kept — it is simpler than the nested form regardless.

### `dotnet test-all.cs` Fails Type-Checking `core/range.f` (E2071 Cyclic Type) — RESOLVED

**Status:** Resolved 2026-08-18 — obsoleted by the removal of the implicit wrap (ADR-0005): `range.f::next` says `return Some(val)` and the coercion class this bug lived in no longer exists. The `stdlib/std` leg of `test-all` was then blocked by the lowering ICE entry above until 2026-08-19; `test-all` is 6/6 green now.
**Affected:** C# `HmTypeChecker` occurs-check / optional inference

`flang test` in `stdlib/std` fails to compile with:

```
error[E2071]: Cyclic type: Option(?4844) contains ?4844
  --> stdlib/core/range.f:46:12
```

on the `return val` of:

```flang
pub fn next(it: &RangeIterator($T)) T? {
    if it.current >= it.end { return null }
    let val = it.current
    it.current = it.current + 1
    return val               // E2071
}
```

Returning a bare `T` from a function declared `T?` makes the checker unify `?X` with `Option(?X)` and trip the occurs check, instead of applying the `T → Option(T)` wrapping coercion. This is the same class the self-host typer hit and fixed on its side — see ADR 0002 (optional wrapping as a directional coercion) and `checker.f::unify_expected`, which tries the payload interpretation first. The C# checker needs the equivalent: in return position against a declared `Option(T)`, attempt the payload interpretation before unifying the value against the optional itself.

The C# harness (`dotnet test.cs`, 517 passed / 0 failed / 14 skipped of 531) does not cover this — it is only reachable through the colocated stdlib `test {}` blocks. Confirmed pre-existing by rebuilding from the committed `HmAstLowering.cs` and reproducing.

### `std.process` Spawn Fails For Every Program — Blocks The Bootstrap's C Backend

**Status:** Open — blocks all end-to-end measurement through the bootstrap
**Affected:** `stdlib/std/process.f::spawn` / `stdlib/std/process.c::__flang_proc_spawn`, and through them `lib/flang_codegen/src/c_backend.f`'s compiler probe

Any `Command.spawn()` returns `Err(ProcessError.NotFound)`, including for an absolute path to a binary that exists (`/usr/bin/clang`). Reproduced with a *reference-compiled* binary, so this is not a bootstrap-codegen issue. It is also not the sandbox: it reproduces with sandboxing disabled.

Consequence: `c_backend`'s probe calls `can_spawn("clang")` / `cc` / `gcc` / `xcrun`, every one fails, and the bootstrap reports `no C compiler found` for every build. **The self-hosted compiler currently cannot produce a binary on this machine**, which is why the harness-through-bootstrap score collapsed (see the corrected scoreboard below) — the failures are not compile errors or wrong exit codes, they are the backend never running.

**Diagnosis so far:** `PROC_NOT_FOUND` is `0` (`process.c:22`) and `ProcessError.NotFound` is the first enum variant, also `0`. `process.f::spawn` initialises `err_code: i32 = 0` and only reads it when the C call returns non-zero. So a C path that returns `R_ERR` *without* writing `*out_err` — or an out-parameter that never makes it back across the call — is indistinguishable from a genuine `NotFound`. Every error path in `process.c` does assign `*out_err`, which points at the write-back across the 15-argument foreign call rather than at the process logic.

**Next step:** confirm whether `*out_err` reaches the caller — have the C side write a sentinel (e.g. `99`) at entry and see whether `spawn` reports it. If the sentinel is lost, this is a foreign-call ABI bug for pointer out-parameters at high argument counts, not a `std.process` bug. Either way `spawn` should not conflate "unset" with `NotFound`: give `ProcessError` a non-zero first variant, or have the C side initialise `*out_err` at entry.


### `as` Cast Mis-Typed When the Operand Comes From a Generic Function Result

**Status:** Open — workaround: avoid casting a generic call's result directly
**Affected:** C# `HmTypeChecker` cast inference

`let n: u32 = idx as u32` fails with `E2002: expected u32, got usize` when `idx` was bound from a generic function's instantiated return (e.g. `Option(usize).unwrap()`); the cast expression is typed as its operand type instead of the target. Casting a plain local (loop index, parameter) works. Minimal repro:

```flang
import std.option

fn pick() usize? { return Some(3usize) }

fn main() i32 {
    let v: usize? = pick()
    let idx = v.unwrap()
    let n: u32 = idx as u32   // E2002 expected u32, got usize
    return n as i32
}
```

**Workaround applied:** `lib/flang_typer/src/checker.f::construct_variant` tracks the variant index as `u32` from the loop variable instead of casting an unwrapped `usize?`.
**Solution:** in cast inference, resolve the operand type before deciding the cast result; the target type must win for primitive casts regardless of where the operand type came from.

### Bootstrap Self-Host: Remaining Typer Gaps

**Status:** Was recorded as typechecking CLEAN (0 errors, 97 modules). **Re-measured 2026-08-16: 2 errors**, both in the bootstrap's own `src/main.f` — `no matching overload for output_path_for with 1 argument(s)` and `... build_single_file with 5 argument(s)`, for functions defined lower in that same file. Confirmed pre-existing at `ac9c7e5` by rebuilding the bootstrap from the committed `lower.f` and reproducing them, so this is not fallout from the M2 lowering work. The reference compiler checks the same project clean, so it is a bootstrap typer gap. Both call sites take an argument from `argv[rest]` — an `Index` expression, which `check_expr_kind` does not handle and types as an unconstrained fresh var, which is the likely reason overload resolution finds no match. That makes this an early, concrete instance of the coverage gap recorded below rather than a separate bug.
**Affected:** bootstrap `flang_typer` type resolution and expression checking

With cross-module nominal resolution fixed, a full self-host run still fails on distinct, unported typer features (counts from one run): ~~**type aliases** (`type VarId = u32`, `NodeId`, `NominalId`, `Level`) are registered as neither struct nor enum, so `resolve_named` cannot find them (~130 `unknown type`)~~ (fixed: see below); ~~the builtin **`void`/`never`** type names are not mapped to `Ty.Void`/`Ty.Never` (~7)~~ (fixed: `resolve_named` now maps both); ~~**qualified enum-value access** (`Ord.Less`) is not typed, surfacing as `unknown identifier` (~700 after the fixes below)~~ (fixed for payload-less variants: see below); and ~~the `std.io.reader`/`writer` modules live in `*.generated.f` files that `import std.io.reader` does not resolve to (the residual ~24 `unknown type` for `Writer`/`Reader`)~~ (fixed: see below). ~~The next milestones are **payload-carrying variant construction** (`Expr.Identifier(...)`, `Ty.Nominal(...)`, `Ok(...)`/`Err(...)`/`Some(...)`) and **module-level constants** — both still surfacing as `unknown identifier`.~~ (both fixed: see below).

**Resolved in this pass — self-host typecheck reaches zero errors (344 → 0).** Six groups, in landing order:

- **Payload-carrying variant construction** (`checker.f::construct_variant`, ~290 errors): `Enum.Variant(args)` and bare `Variant(args)` calls now construct — fresh type args per enum param, payload types substituted, each argument unified against its payload; the variant target is recorded as `RtEnumVariant` for lowering. Bare payload-less variants (`None`) resolve in identifier position. Locals and functions win over variant names; `NominalRegistry.lookup_variant` scans visible enums by variant name + arity.
- **Unit-argument calls** (`Ok(())`, 4 errors): expression-position `()` parsed to a `TupleType` CST node the projector's `is_expr_kind` dropped, so `Ok(())` projected as a zero-argument call. `parse_paren_expression` now emits the tuple-expression kind, and the checker types `()` as `void` (`check_tuple_lit`).
- **Module-level constants** (~30 errors): `const NAME` declarations register their annotated type (or a fresh var) in the signature pass, initializers unify in the body pass, and identifiers resolve through the shared FQN-with-visibility lookup (`fqn_map.f` — the generic map that also carries alias bodies; fixing its instantiation surfaced and fixed a C# ICE: `CloneExpression` had no case for interpolated strings, so any generic fn containing `$"..."` failed to specialize).
- **Type names in value position** (~8 errors): a bare type name (`size_of(ArenaPage)`, `size_of(u8)`) types as the named type itself, and a nominal called with type arguments (`Entry(K, V)`, `Type(T)`) yields the instantiated nominal; the existing `Type(T)` lift coercion applies at use sites. New coercions: `char → u8` (bootstrap-lenient: fires for all char values, not just literals) and `Type(T) → TypeInfo` (for `core.rtti.type_of`).
- **Optional-context unification** (`checker.f::unify_expected`, 4 errors incl. two occurs-check failures): a value flowing into `T?` (let-annotation or return) first tries the payload interpretation, so a generic param or call-result inference var is wrapped rather than absorbed into the Option (which poisoned later uses or tripped the occurs check on `return val` in `fn(...) T?`).
- **Whole-stdlib loading + lenient type resolution**: the driver BFS now seeds every stdlib source (mirroring the C# `SourceGlobber`), and `resolve_named` resolves registered-but-not-imported types instead of erroring (the reference compiler resolves type names program-wide; `core.io` references `StringBuilder` without importing it). Identifier visibility stays import-strict. Non-`pub` `#foreign` fns are visible wherever their module is (they name global link-time symbols; mirrors the earlier C#-side fix).

~~**Next blocker (lowering, not typing):** `lower_program` merges all modules' functions under bare names, so same-named fns from different modules (`rollback` in `inference_engine` vs `union_find`) collide in the generated C (`error C2084: function already has a body`). Needs FQN-based symbol mangling — the cut explicitly deferred when multi-module lowering landed.~~ (fixed: see below). ~~**Next blocker (lowering semantics):** the merged program now compiles and links — a self-host `build` emits a `flang.exe` — but every out-of-M1-subset expression (calls, control flow, match, indexing) still lowers to a placeholder zero.~~ (M2 landed: see below. M3 landed control flow — comparisons, short-circuit `and`/`or`, `if`, `while`/`loop`/`for`-over-range, `break`/`continue`. M4 landed assignment, address-of and dereference, which made every local a slotted place. Match and indexing remain placeholders — M5 — plus the FIR `Global` pointer-initializer work below.)

**Resolved in this pass — M2, direct and UFCS call lowering.** `lower_expr` now has a `Call` arm. Lowering re-resolves nothing: the checker already settled the overload, the UFCS receiver, and defaults, and records the winner on the call node as `RtFunction(id)`, so `lower_call` maps that id to a symbol and emits the arguments in order. A member-access callee contributes its receiver as argument 0 (UFCS); named-argument calls, variant constructors, and indirect calls carry no `RtFunction` and stay placeholders.

The ordinal fragility flagged when mangling landed is gone. Symbols are no longer assigned during the definition walk — a **pre-pass** (`SymbolBuilder`) assigns every callable function its symbol up front, keyed by `FunctionScheme.id`, and both definitions and call sites read that one table. Definitions find their id by fingerprinting the decl span (`node_id_of`), which is what the checker registers as `decl_span`. Table membership doubles as the callability gate: a function whose signature is outside the lowerable subset is simply absent, so calls to it fall back to a placeholder instead of naming a symbol the module never defines. That keeps the merged module link-clean by construction rather than by coincidence.

Two companion fixes: body-less declarations now reach the module as `ForeignDecl`s (`add_foreign` existed and the backend emitted them, but **lowering never called it** — so any call to `printf` would have emitted undeclared C); and the lowering walk now threads a single `LowerCtx` (checker result + symbol table + allocator) instead of three separate parameters, giving M3's loop labels and M5's arm state somewhere to live.

Covered by six `test {}` blocks in `lower.f`, including one pinning that a call site names the *same* ordinal-suffixed symbol its definition was given (`f__2`) and that the symbol is defined in the module. Not yet lowered: variadic callees (the variadic tail needs per-argument types the call site doesn't carry), and `&expr` arguments, which still lower to a placeholder zero.

**This is unverified end-to-end.** The harness cannot exercise it while `std.process` spawn is broken (see Open Issues) — the bootstrap never reaches its backend, so M2 is currently proven only by unit tests against the FIR, not by running a produced binary.

**Resolved in this pass — real function-call resolution (self-host --check back to 0 errors, now with calls checked).** `check_call` no longer falls back to a fresh var: after the variant / type-instantiation attempts (precedence unchanged), it resolves **direct calls** against `FunctionRegistry` overloads, **UFCS calls** (receiver prepended as first argument, retried with the receiver adapted value↔`&T`, then through a bounded `op_deref` peel chain — the `Owned(T)` dispatch pattern), **Func-typed field calls** (`self.alloc_fn(...)` vtable dispatch; field types now substitute the instance's type args), and **indirect calls** through Func-typed bindings (an unbound callee is constrained to a fn type so lambda-typed locals infer). Winners are committed via `engine.specialize` + per-arg `unify` and recorded as `RtFunction(id)` on the call node for M2 lowering; failures report E2011/E2004. Overload choice mirrors the C# `ResolveOverload(WithDefaults)`: each candidate probes inside an engine checkpoint that rolls back, arity accepts `[required, total]` (`FunctionScheme` now carries the trailing-default count and variadic flag), preference is fewer quantified vars, then coercion cost (omitted defaults cost extra), then registration order. Turning calls real exposed and fixed seven latent bugs (64 self-host errors → 0): **void functions discard their trailing expression's value**; **statement-context ifs never require branch agreement** and no-else ifs are `void` (mirrors `InferIfAsStatement`); the **`T → Option(T)` coercion no longer fires into an unbound payload var** (it let `unwrap(Option($T))` swallow `Result` receivers — the C# rule requires payload equality); the missing **`Slice(u8) → String` reverse view cast** (the C# engine applies rules in both directions); **coercion inputs are zonked** so rules see through bound vars; **struct field reads substitute the instance's type args** (a `List(usize).ptr` read used to bind the definition's shared `T` globally); and **cast expressions are typed** (`x as &u8` yields the target type). One stdlib bug: `std.dict` counted only live entries in its load factor, so delete-heavy churn (the engine's checkpoint rollbacks) filled the table with tombstones and panicked — a `dead` counter now triggers the rehash (regression `test {}` in `dict.f`). Sidecar loading now merges **every** checked-in `.generated.f` (previously `#interface` origins only), so `#implement` expansions like `reader(&File)` resolve. Deliberate cuts, all silent (no false errors): **named-argument calls** keep the fresh-var fallback; **variadic surplus args** are not element-checked; **receivers left unbound by unchecked constructs** (match expressions) skip UFCS arbitration instead of letting the first overload bind them; **generic bodies** silence resolution failures (the reference checker re-checks them per specialization — deferred with the generics milestone); **op_deref chains are not recorded** for lowering. Covered by seven call-resolution `test {}` blocks in `checker.f`.

**Resolved in this pass — FQN symbol mangling (link-clean merged module).** `lower_program` now takes the project's module FQNs (parallel to `modules`, from `AnalyzedProject.fqns`) and `lower.f::mangle_symbol` derives each function's C symbol: dots become double underscores and the module path prefixes the name (`flang_typer.checker` fn `deinit` → `flang_typer__checker__deinit`). `main` and `#foreign` fns keep their bare names (entry wiring / real C symbols); M2 call lowering must derive callee symbols through the same helper. Three companion fixes were needed before the probe linked: (1) *same-module overload sets* share one mangled name, so `lower.f::disambiguate` appends an ordinal to every repeat within one lowering walk (`std__allocator__deinit__2`) — positional, so M2 call sites will need a scheme-keyed mapping; (2) the C backend emits each *foreign declaration* at most once — merged modules re-declare the same symbol, and `core.io`'s many `printf` overloads all map to one; (3) two placeholder-arithmetic C errors: out-of-subset types now fold to `i64` instead of `ptr` (a pointer operand inside a float op is invalid C), and division by a literal-zero (placeholder) divisor lowers to a placeholder value instead of a constant `0 % 0` C rejects. Covered by `test {}` blocks in `lower.f` and `c_backend.f`.

**Resolved in this pass — M5 completed: indexing, plus four bugs it uncovered (self-host `--check` 12 errors → 0).**

*Indexing, typing.* `check_index` mirrors the reference checker's order: built-in array and slice indexing is tried **before** the user operators, because `String` and `Slice(u8)` coerce to each other in both directions and `op_index(String, Range)` would otherwise capture `Slice(u8)[range]`. A user type then dispatches to one of two mutually exclusive shapes — ref-form `op_index_ref(&Self, Idx) &T` (a place: read, write, `&x[i]`) or value-form `op_index(Self|&Self, Idx) T` (a computed read) — and the winner is recorded on the node with `is_ref_form`. `check_range` types `a..b` as `Range(T)`, partial ranges included: the bound that is written fixes the element, `..` leaves it free, and whether a missing bound can be supplied is the index site's problem, not the type's. Operator lookup probes before it resolves, since `resolve_overload` commits its unifications and reports mismatches — a losing shape would pollute the substitution and emit a diagnostic the caller is about to supersede.

*Indexing, lowering.* Three paths, picked by what the checker recorded: a ref-form operator call (whose result IS the element's address, so one call serves value, assignment and address-of), a value-form call (a temporary, and therefore not a place — `lower_place` returns null and an indexed assignment refuses the function), and built-in `base + i * stride` for arrays and slices, where a slice's base pointer is loaded out of its `ptr` field at the layout's offset rather than an assumed zero. Range slicing over a built-in base is refused: it needs a `Slice` built with bounds clamped against the base's length, and a guess would emit an unclamped view that reads past the end.

*Four bugs this surfaced, all pre-existing and all in the "would have miscompiled" class:*

1. **Branch joins were order-dependent.** `check_match` unified each arm into one fixed var and `check_if` returned the *then* branch's type, so `X(v) => v, else => null` typed clean and `else => null, X(v) => v` did not. Both now go through `join_types`, which tries coercion in **both** directions and returns the *joined* type, with a pre-bind step for `T` against `Option($V)` (the `T → Option(T)` rule requires payload equality and will not bind a free payload itself — correct in argument position, wrong in a join, which is the one place where picking the payload IS the intended answer). `Never` is the join's identity, so a diverging arm stays out of it and a fully diverging `match` types as `Never` rather than needing the `void` special case the C# checker requires — the self-hosted checker has a bottom type and the reference one does not. New codes: **E2074** (if/else), **E2075** (match arms).
2. **A call could name a function that was never emitted.** A symbol is assigned when the *signature* lowers, but the body is refused separately and later, so `lower_call` could emit a call to a refused function — a link error that takes the whole program down instead of the one function that cannot be built. `drop_callers_of_refused` now runs to a fixpoint after lowering: any function calling an undefined symbol joins `skipped`, which strands its own callers, and so on. It is the counterpart across the call graph of `blocked` within a body.
3. **Generic function bodies were being lowered with guessed layouts.** `fn op_index_ref(list: &List($T), …)` passes the scalar signature gate — a `$T` behind a reference is just a pointer — so its body lowered, and `layout_of` sized the unresolved `T` as 4 bytes (`Var(_) => lay(4, 4)`, the same invent-a-plausible-value pattern removed from the C# side). Every field offset past that point was wrong. Generic declarations are now refused up front by `declares_generic`, which walks the signature for `$T` at any depth; monomorphization is a later milestone, and until then the definition is simply absent and rule 2 takes its callers with it.
4. **Void functions returned their trailing expression's value.** `self.f = v` in trailing position yields `lower_assignment`'s unit placeholder, which became `return 0` in a `void` C function. A void function now discards the trailing value — the expression is still emitted, for its effects. The checker has had the mirror of this rule since M2.

*Where the self-host build stands.* `--check` is clean over 97 modules and the backend now emits a nearly-complete `flang.c` for the compiler itself. What remains is **22 C errors, all in foreign-declaration fidelity** — the emitted prototypes for libc symbols (`memset`, `memmove`, `printf`, `strlen`) conflict with the system headers the preamble includes, plus one unresolved type name. That is a distinct workstream from lowering: the front end is producing the calls correctly and the declarations are wrong.

*Still out of subset after M5:* range slicing over a built-in base; `op_set_index`, so a value-form index stays unassignable; and aggregate parameters and returns — which is what still refuses the stdlib's own `String` and `Slice` indexing operators, since both take their receiver by value.

**Coverage boundary — what "0 errors" measures.** Re-measured 2026-08-18, after M5: the boundary has moved a long way, and the caveat is now much narrower than it was.

- `check_expr_kind` (`checker.f`) handles **20 of 24** `Expr` variants (M7 added `Unary`; M8 added `Coalesce` and `Try`; M9 added `InterpolatedString` — the reference's full StringBuilder desugar, synthesized as AST under synthetic node ids, checked through ordinary overload resolution, and stored in `result.desugars` for lowering to replay). The `_ => fresh_var()` catch-all still returns without recursing, so the subtree under an unhandled node is never visited. Unhandled: `Lambda`, `ArrayLit`, `NullPropagation`, `Error`. Two interpolation-specific caveats: a diagnostic raised on a *synthesized* node (e.g. `string_builder` unresolved because `std.string_builder` isn't imported) carries a synthetic span and renders without a real source location, and `?` inside a `defer` is not rejected as E2091 (lowering refuses the function instead).
- `check_stmt` handles **all 10** `Stmt` variants — `For`, `While`, `Loop` and `Defer` bodies are walked, and `check_stmt` reports divergence so a `return` inside a branch does not drag a block's type to `void`.
- `check_binary` really unifies its operands (pointer arithmetic deliberately excepted, where the operands must *not* unify), so `1 + "hello"` is rejected.
- `check_assignment` unifies right into left. A non-place left side (`f() = 1`) is still not rejected here; lowering refuses the function instead, so the failure is loud but the diagnostic is imprecise.
- `check_index` resolves built-in array/slice indexing and user `op_index_ref` / `op_index`, and records the pick. It does not report **E2077** (a type declaring both operator forms), which would need a non-committing probe of the losing shape; the winner is the same either way, only the diagnostic is missing.

What that leaves: lambdas, array literals and `?.` are the remaining unvisited subtrees (M8 closed `?` and `??`; M9 closed interpolation via the full desugar). Declarations, signatures, the call graph, control flow, assignment, `match`, indexing, unary and the optional operators are all genuinely checked.

**Harness scoreboard (through the bootstrap).** The lit-style corpus runs through any compiler binary via `$FLANG` (see docs/architecture.md, "Execution mode"): `FLANG=bootstrap/build/flang dotnet test.cs`.

- *2026-07-03, post-mangling:* recorded as **131 passed / 385 failed / 14 skipped of 530**, with failures said to reach the run/compare stage and report wrong exit codes.
- *2026-08-16, re-baselined:* **15 passed / 501 failed / 14 skipped**. The 131 figure does **not** reproduce in this tree. The reference compiler is green over the same corpus (516 / 0 / 14), so the corpus and the C# pipeline are healthy; the collapse is entirely on the bootstrap side, and it is not a lowering regression. Two causes, both since diagnosed:
  1. `std.process` spawn fails for every program, so the bootstrap's C-compiler probe finds nothing and no build ever reaches the backend (see its own entry under Open Issues). This alone accounts for nearly all of it.
  2. Missing template sidecars (below) failed every compilation at type-check time with ~92 errors before that.

  Because cause 1 stops the backend outright, **the harness cannot currently measure lowering work through the bootstrap at all.** Fix spawn before treating any harness delta as a signal about codegen.

Diagnostic coverage on *invalid* code is its own gap, distinct from the clean self-host typecheck: only a fraction of the `COMPILE-ERROR` tests see their expected code — e.g. `tests/harness/errors/error_char_literal_rejects_string.f` expects E2011, but the bootstrap type-checks the file clean and proceeds to codegen.

**Template sidecars are build artifacts, not checked-in files.** Earlier notes in this document describe `reader.generated.f` / `writer.generated.f` and friends as "checked-in". They are not: `.gitignore:130` ignores `*.generated.f` globally, and `git ls-files 'stdlib/**/*.generated.f'` returns nothing. They exist only because a previous reference-compiler build wrote them (`src/FLang.CLI/Compiler.cs:299`, best-effort). This is load-bearing for the bootstrap, which cannot expand `#interface` / `#implement` itself.

The failure mode is asymmetric and bites on a clean tree: the reference compiler expands only the modules an entry point actually imports, while the bootstrap's driver BFS seeds **every** stdlib source. So any stdlib module that nothing imports never gets a sidecar written, yet the bootstrap still loads it and fails on its unexpanded types. `stdlib/std/encoding/codec.f` (`#interface(Encoder, …)`, `#interface(Decoder, …)`) hit exactly this — 72 of the 92 errors — as did `std/io/file.f` (`#implement(File, Reader)`), with no `file.generated.f` on disk. Regenerating them all requires compiling a file that imports every stdlib module. **A fresh clone has zero sidecars and the bootstrap fails on everything.**

**Fix directions:** either drop `*.generated.f` from `.gitignore` for `stdlib/` and commit them (makes the bootstrap's input reproducible, at the cost of generated files in review), or make sidecar generation an explicit build step that walks the whole stdlib rather than a side effect of whatever happened to be imported. The durable answer is teaching the bootstrap to expand templates itself, which removes the dependency entirely.

**Resolved in this pass — non-generic type aliases.** `type VarId = u32`, `NodeId`, `NominalId`, `Level` and friends were registered as neither struct nor enum, so `resolve_named` could not find them (~130 `unknown type`). A new alias registry (since folded into the generic `lib/flang_typer/src/fqn_map.f`) is populated during the name-registration pass (`collect_one_name`) and expanded lazily in `resolve_named` — after the primitive and nominal lookups, reusing nominal-lookup visibility — so alias chains and cross-module targets resolve regardless of declaration order. Self-host `unknown type` dropped 156 -> 24 and the total error count 1205 -> 1073 (the residual 24 are all the `Writer`/`Reader` `*.generated.f` issue above). Covered by a cross-module `test {}` in `checker.f` plus the existing `flang_typer` / `flang_driver` suites. Generic aliases (`type Result(T, E) = ...`) and alias-cycle detection remain follow-ups.

**Resolved in this pass — template-generated stdlib modules.** `std.io.reader` / `std.io.writer` define their core `Reader` / `Writer` structs through a `#interface(...)` template the bootstrap can't expand; the expansion lives in a checked-in `reader.generated.f` / `writer.generated.f` that was never loaded, so the templates' own references to those types failed (~24 `unknown type`). `flang_driver`'s import BFS now folds a `.generated.f` sidecar into its origin module (`combine_with_sidecar` in `driver.f`) — ~~but only when the sidecar declares a type, so `#interface` expansions (which provide a referenced struct) merge while function-only expansions (`#enum_utils`, `#derive`) stay out, keeping this independent of the enum-value-access gap~~ (superseded: every sidecar merges now that calls resolve — see the call-resolution entry above). Folding into one module rather than a second module under the same FQN preserves the origin's single import scope (a duplicate-FQN module would clobber it in `build_visibility`); `resolver.f`'s `generated_sidecar` finds the file and `module_fqn` now strips a trailing `.generated.f` so a generated path still classifies under its origin module. Self-host `unknown type` dropped 25 -> 1 (the remaining one is a pre-existing `core.io` import gap), `Writer`/`Reader` to 0, total errors 1073 -> 1050, with E2004 flat. Covered by `module_fqn` / `generated_sidecar` `test {}` blocks in `resolver.f`. Mirrors the C# `TemplateExpander`, which registers generated content under its origin module path while `SourceGlobber` excludes `*.generated.f` (its in-memory expansion is the source of truth, not the on-disk file).

**Resolved in this pass — qualified payload-less enum-variant access.** `Ord.Less` parses as a `MemberAccess` whose receiver is `Identifier("Ord")`; `check_member` checked that receiver as a value first, and since a type name has no value binding it reported `unknown identifier` (~700 of the run's errors) before any variant logic ran. `check_member` now consults `enum_variant_access` first: a bare receiver that resolves (under current visibility) to a `NomEnum` whose `member` names a payload-less variant yields the enum's nominal type, mirroring the C# `InferMemberAccess` -> `ResolveEnumVariantAccess` fast path. Self-host total errors dropped 1050 -> 344 (E2004 1041 -> 335), the `unknown identifier` reports for `Ord` to 0, other error codes flat. Lowering stays the M-placeholder: nothing reads an enum value back until `match` (M5), so there is no runnable program to miscompile yet. Covered by a `test {}` in `checker.f`. **Follow-ups:** payload-carrying variant construction (`Expr.Identifier(id)`, `Ty.Nominal(...)`, `Ok`/`Err`/`Some`), unqualified bare-variant shorthand, and match-arm typing — the residual E2004s — plus module-level constants.

### Anonymous Struct in `Ok(...)`/`Some(...)` Doesn't Coerce to a Nominal Payload

### Anonymous Struct in `Ok(...)`/`Some(...)` Doesn't Coerce to a Nominal Payload

**Status:** Open — worked around at the call site
**Affected:** C# codegen (generic instantiation); surfaced building `bootstrap` against `std.io.fs.glob`

Returning `Ok(.{ ... })` from a function whose declared return is `Result(Nominal, E)` makes the compiler instantiate `Result(<anon record>, E)` and then fail to convert it to `Result(Nominal, E)` in generated C (`error C2440`). The fix is to name the nominal at the return site — `Ok(Nominal { ... })`.

**Workaround applied:** `stdlib/std/io/fs.f` `glob` returns `Ok(GlobIter { ... })`.
**Solution:** in codegen, coerce an anonymous-record payload to the nominal type argument of the enclosing generic call (the same anon→nominal coercion already applied to fn-field args).

### Bootstrap and C# Compilers Disagree on Auto Struct Layout

**Status:** Open — intentional, bootstrap leads
**Affected:** struct memory layout; bootstrap `flang_driver.layout` vs C# `FLang.IR.TypeLayoutService`

Per spec §2.4, the default (`auto`) struct representation lets the compiler reorder fields by descending alignment to minimise size. The bootstrap layout (`lib/flang_driver/src/layout.f`) implements this; the C# reference compiler still lays every struct out in declaration order (C-order). So a non-`#foreign` struct gets different field offsets and total size from the two toolchains.

Safe for self-host (stage2 and stage3 are both bootstrap-compiled, so they agree) and for the harness-via-bootstrap path (all code in a run is bootstrap-compiled). It only bites if C#-compiled and bootstrap-compiled objects of the same struct are linked together. `#foreign` structs (`Repr.C`) lay out identically in both.

**Solution:** port the auto-layout algorithm into `TypeLayoutService` (place fields by descending alignment, offsets keyed by declaration index) so the two converge.

### Unqualified Enum Variants Shadow Same-Named Types

**Status:** Open — workaround via renaming the type
**Affected:** name resolution; surfaces when a top-level type and a variant of another enum share a name

FLang lets you write a variant in shorthand form (no enum prefix) when the type is inferred from context — `Some(v)`, `NodeChild(n)`, etc. The resolver picks up bare `X` as an unqualified variant lookup whenever some in-scope enum has a variant called `X`. When a top-level **type** also named `X` exists, the variant wins and the type is shadowed: `X.Y` is parsed as "the `Y` member of the variant value `X`", not "the `Y` variant of the type `X`".

**Reproducer (current AST + CST):**

```flang
// flang_parser.cst:
pub type NodeKind = enum { ..., Directive, ... }

// flang_parser.ast:
pub type DeclAttribute = enum { Foreign, Inline, ... }
// (was `pub type Directive` — renamed precisely to dodge this issue)
```

With the original name `Directive`, `Directive.Inline` errored as `No variant Inline on enum NodeKind`, because `Directive` resolved to `NodeKind.Directive` first. Same shape with the AST's old `Literal` enum vs `Pattern.Literal` variant.

**Workaround (active):** rename the type when it would collide. `Directive` → `DeclAttribute`, `Literal` → `LiteralValue` in `lib/flang_parser/src/ast.f`.

**Fix direction:** replace the unqualified-variant shorthand with a leading-dot syntax — `.Some(v)` instead of `Some(v)` — modelled on `.{ ... }` for context-inferred struct literals. Bare names then always mean identifiers or types; `.Variant` always means "the named variant of whatever enum the context expects." Requires parser support for `.Ident` as a primary expression, resolver changes to drop unqualified-variant lookup, formatter emission, and a mechanical migration of every match arm + shorthand construction across stdlib / lib / tools / bootstrap / tests. Track as its own RFC before scheduling.

---

### RFC-010 Follow-ups

**Status:** Phases 1–5 and Phase 7 of [RFC-010](tickets/010-pattern-grammar-and-optional-flattening.md) landed. Phase 6 (proper Maranget-style exhaustiveness) deferred.

**What works:** or-patterns (`A | B | C`), guard clauses (`pat if cond`), tuple destructuring (`(a, b)`), struct destructuring (`Type { x, y, .. }`), range patterns (`a..b`, `a..=b`, `a..`, `..b`, `..=b` — `..=` is a pattern-only token), and `?.` flattening (chained `Option(Option(_))` projections collapse to `Option(_)`).

**What's deferred:**

1. **Maranget exhaustiveness.** The existing exhaustiveness check is still ad-hoc — it tracks variant names for enum scrutinees and treats any catch-all (`_` / `else` / variable / or-pattern containing one) as full coverage. New pattern forms don't yet feed a unified coverage matrix:
    - **Tuple/struct scrutinees** are not exhaustiveness-checked. A non-enum match without a catch-all silently runs no body when no arm matches (zero-init result). Pre-existing gap, not made worse by RFC-010.
    - **Range patterns** don't tile the integer domain. `n match { ..0 => …, 0 => …, 1.. => … }` over `i32` requires a `_` arm even though the ranges fully cover the domain.
    - **Or-patterns** don't distribute coverage across alternatives for non-enum scrutinees.
   Phase 6 is the right place to fix all of these together — Maranget's "useful clauses" matrix algorithm gives a uniform answer for variants, ranges, tuples, structs, and or-patterns. Until then, prefer explicit catch-all arms.
2. **Variable bindings in or-pattern alternatives** (`Some(x) | Other(x)`) — rejected with **E2105** until lowering grows binding-slot allocation. The non-binding cases (`Red | Green | Blue`, `1 | 2 | 3`, range alternatives) work today.

---

### RFC-014 Phase 2 Follow-ups

**Status:** Phase 1 (`op_call`) and Phase 2 (capturing lambdas, by-value) landed. Single-level capturing closures synthesise an anonymous `__Closure_N` struct holding captures by value, and an `op_call(self: &__Closure_N, ...)` body with capture references projected through `self`. Tests in `tests/harness/closures/`. Coercion of capturing closures into bare `fn(...) ret` slots is rejected with **E2111**; assignment to a captured name from inside the body is rejected with **E2112** (capture is by value, so the write would only mutate the closure's own field, which is misleading).

**Resolved — captured callables called inside the closure body.** A capturing closure whose captured variable was itself a callable (a fn value or another closure) type-checked but miscompiled: the body emitted a direct call to the captured name (`g(x)` → undeclared C function) instead of projecting through the env. Two combined causes in the checker: `TryIndirectCall` looked the callee up via `Scopes.Lookup`, bypassing `InferIdentifier`'s crossed-frame capture recording (a callable used *only* in call position was never captured, so the lambda lowered as non-capturing), and `RewriteCaptureRefsExpr` rewrote identifier/argument positions but never a call's `FunctionName`. Fixed by sharing the capture-recording (`RecordCrossedFrameCaptures`) with `TryIndirectCall` and rewriting bare calls to captured callables into the field-call `self.g(x)` — `TryFieldCall` then calls fn-pointer fields indirectly and dispatches closure-typed fields through `op_call`. Also covers a `$F` param captured by a lambda inside a generic fn (exercised per-specialization). Tests: `tests/harness/closures/closure_capture_fn_value.f`, `closure_capture_closure.f`, `closure_capture_generic_fn_param.f`.

**What's deferred:**

1. **Nested capturing closures (E2113).** A closure that captures a name an enclosing closure also captures requires transitive-capture lowering (the inner closure pulls its env field from the outer's env field). Today this is rejected up-front with E2113. Closures nested inside non-capturing closures (or whose captures don't overlap with the outer closure's) work fine.
2. **Capture-by-reference (`&local`).** RFC §"Out of scope". Initial implementation captures only by value; explicit `&local` capture syntax + lifetime story is a follow-up.
3. **Stdlib follow-ups.** Adding `box(allocator, callable)` to `std.owned` is unblocked by Phase 2 but tracked separately. ~~The generic-over-callable iterator change requires call resolution to handle `f(args)` where `f`'s type is a TypeVar bound to a closure NominalType~~ — done: `std.iter` adapters are generic over the callable and call `self.f(x)` directly. Field-position dispatch (`h.f(args)` where the field's type defines `op_call`) is wired in `TryFieldCall`, which rewrites to UFCS `op_call(&h.f, args...)` before the E2011 "not a function" error (test: `tests/harness/closures/closure_field_call.f`).

---

### Field-List `.push()` Silently No-Ops Through Some Access Paths

**Status:** Open
**Affected:** any caller mutating a nested `List` field through `obj.field.list.push(…)` or through a value-struct local — silent data loss

`List.push(self: &List(T), v: T)` mutates through a `&List` receiver. When the receiver expression chains through one or more struct field accesses, FLang sometimes resolves the chain as a temporary rvalue rather than an lvalue, so `push` mutates a copy that immediately disappears. The call compiles, runs, and is observable as a no-op at runtime.

Two reproducers, both from `lib/flang_codegen` builder development:

```flang
// (A) Local value struct, one level: m is `Module` by value.
let m = module()
m.functions.push(some_function())   // m.functions.len stays 0
```

```flang
// (B) Reference struct, two levels: self is `&FunctionBuilder`.
fn block_internal(self: &FunctionBuilder, ...) BlockBuilder {
    ...
    self.func.blocks.push(new_block)   // self.func.blocks.len stays 0
}
```

The matching one-level pattern through a reference works fine — `self.words.push(0u64)` in `stdlib/std/bitset.f` and `self.__args.push(...)` in `stdlib/std/process.f` are exercised by tests.

**Workaround:** define a small mutator on the defining type and call that. The method-call form preserves the place-ness:

```flang
// in fir.f, where Module is defined:
pub fn add_function(self: &Module, f: Function) {
    self.functions.push(f)
}

// caller — now mutates correctly:
m.add_function(some_function())
```

`lib/flang_codegen/src/fir.f` uses this pattern (`add_block`, `add_function`, `add_foreign`, `add_global`, `set_terminator`, `fresh_value_id`) so the builder in `builder.f` never has to reach into nested fields.

**Fix direction:** in lowering, audit the desugaring of `expr.field.method(...)` where `method` takes `&Self`. The compiler needs to thread the place through every intermediate field access, not materialise an rvalue copy at any step. Likely candidate: the auto-`&` insertion in UFCS / method-call lowering only fires on the outermost receiver, not on each intermediate field access. Worth a focused repro test (`tests/harness/...`) before fixing.

---

### `match` on Value-Type Optional Doesn't Yield Ref Bindings

**Status:** Open (low priority — workarounds exist for current consumers)
**Affected:** any future wrapper that wants `&T` access into an inline `Option(T)` field where `T` is a value type

When a `match` arm binds a payload, the binding is always **by value**. `match self.field { Some(v) => &v, … }` over a struct field of type `Option(T)` gives a stack-temp pointer, not a pointer into the field — verified by mutation test.

**Workaround:** `Owned(T)` originally hit this when the RFC spec'd `value: T?`; the production design switched to `value: &T?` (niche-optimized to a nullable pointer), where the payload IS a `&T` and `Some(p) => p` works without ref-binding. Generalizes: any wrapper that needs `&T` access should store `&T?` rather than `T?`. For container types that own internal heap (`StringBuilder`, `List`, `Dict`), use the `take(&self) T` pattern instead — defer + take handles transfer without needing to wrap.

**If we ever need it:** Rust-style default binding modes (when scrutinee descends through `&`, flip pattern bindings to ByRef) is the principled fix. ~2 days in `HmTypeChecker.CheckPattern` + pattern lowering. Not currently blocking anything, so deferred.

---

### RFC-007 Follow-ups

**Status:** Phase 5 of [RFC-007](tickets/007-option-as-enum.md) deferred
**Affected:** `stdlib/core/option.f`, `src/FLang.IR/TypeLayoutService.cs`

`Option` is now a tagged enum (`enum(T) { None, Some(T) }`) with niche layout for `Option(&T)` preserved. Field-access shims (`opt.has_value` / `opt.value`) have been removed; the stdlib and tests now use `match` / `is_some()` / `unwrap()` / `unwrap_or()` / `?.` exclusively. Remaining items:

1. **None-tag depends on declaration order.** Today `None` is declared first in `stdlib/core/option.f` so it gets discriminant `0` and zero-initialized memory means `None`. A more robust fix is to teach the layout to assign Option's `None` tag deterministically regardless of source order — folded into the planned bare-enum niche optimization (§"Niche Optimization for `Option(BareEnum)`" below).
2. **Niche optimization for bare-enum payloads.** RFC-007 §Out-of-scope and the existing item below still apply: `Option(BareEnum)` should collapse to a single tag word once we shift discriminants to start at 1.

---

### Bootstrap Lexer Can't Reach `$(args)"..."` / `$ident"..."` From `tokenize()`

**Status:** Open
**Affected:** `lib/flang_parser/src/lexer.f`, bootstrap parser

`mark_next_string_interp()` requires the parser to call it between tokens. The current bootstrap parser drains `tokenize()` into a `List(Token)` upfront, so the hook is unreachable and only the inline `$"..."` form is recognised. The other two forms fall back to `Dollar + (group / identifier) + StringLiteral`. The bootstrap parser (`lib/flang_parser/src/parser.f`, v0.3.0) handles the fallback shape directly: a `$` token followed by an identifier or a balanced `(...)` then `StringLiteral` lands in an `InterpolatedStringExpr` CST node, just without the structured hole/segment children.

**Fix direction:** drive `next_token()` from the parser instead of pre-tokenising.

---

### Nested `$"..."` Leaks the Inner OwnedString

**Status:** Open
**Affected:** String interpolation (RFC-004) desugar

`$"outer {$"inner"} end"` desugars the inner interp to a `string_builder().to_string()` expression whose result — an `OwnedString` temporary — is passed to the outer `append`. The temporary's buffer is never reclaimed because FLang has no value-destructor (Drop) mechanism today. Output is correct; memory is not. Same shape as any `sb.append(from_view(...))` call.

**Workaround:** bind the inner to a `let` with explicit `defer deinit()`, or use form 3 (`$sb"..."`) to write directly into an outer builder.

**Fix direction:** either (a) have the outer desugar allocate with a scope-tied allocator and skip per-temporary frees, or (b) introduce destructors for `OwnedString` (wider language change).

**Test:** `tests/harness/interpolation/nested_interp.f` (pins output, not memory).

---

### Overloaded Functions Can't Be Used As First-Class Values

**Status:** Open
**Affected:** Type inference when a bare function name is passed as a `fn(...)` value

`op_cmp` is overloaded across many types. Passing it as a function-typed argument — e.g. `_quicksort_range(s, 0, s.len, op_cmp)` — fails because overload resolution has no expected type at the point the name is taken as a value, and the compiler picks the first registered overload (typically `op_cmp(String, String)`) regardless of context.

**Workaround:** Wrap in an inline lambda: `fn(a: T, b: T) Ord { return op_cmp(a, b) }`. This defers overload resolution until the call site, where T is concrete. The `std.sort` wrappers (`sort(s)`, `quicksort(s)`, etc.) use this pattern internally.

**Concrete case (2026-08-20):** `self.__cwd.map(deinit)` for `__cwd: OwnedString?` ICEs at lowering ("unresolved type variable reached lowering") — `deinit` has ~40 overloads and nothing picks `deinit(&OwnedString)` from `map`'s `fn(T) $U` parameter. Functions as values are a first-class feature of the language; overload resolution here is a compiler bug, not a design limit — the expected parameter type names the overload unambiguously. The rewritten site uses `Option.deinit` instead (`self.__cwd.deinit()`), which is the better idiom regardless.

**Future:** Context-directed overload resolution — when a bare function name is coerced to a `fn(...)` type, pick the overload whose signature unifies with the expected type (and report ambiguity when several do). Note the by-ref wrinkle: most `deinit` overloads take `&T` while combinators like `map` pass `T` by value, so the fix needs either reference-adapting decay or an explicit rule that `fn(T)` slots do not accept `fn(&T)` candidates.

---

### Generic Parameter Binding Order Not Tracked

**Status:** Deferred
**Affected:** Type inference for generic function calls

`$T` syntax distinguishes binding sites (`$T`) from use sites (`T`), but both become `GenericParameterType("T")` in the type system — the distinction is lost after parsing.

**Current workaround:** Anonymous struct arguments are deferred during overload resolution, and TypeVars are accepted as wildcards during generic binding. Handles the common case.

**Future:** Track `IsBindingSite` on `GenericParameterType` to enable proper two-pass type inference based on binding order.

---

### Foreign Function Argument Type Checking Bypassed

**Status:** Open
**Affected:** TypeChecker — foreign function calls

Calls to `#foreign fn` may bypass strict argument type checking, allowing implicit narrowing (e.g., passing `usize` to `i32` param) without error. Normal functions correctly reject this with E2011.

**Workaround:** Ensure `#foreign fn` declarations match the types you intend to pass, or explicitly cast arguments.

---

### `&[T; N]` Indexing (RESOLVED)

`fn first(xs: &[i32; 4]) i32 { return xs[0usize] }` type-checked and then failed to compile, for two independent reasons — both fixed 2026-08-18, with `tests/harness/places/index_ref_to_array.f` pinning them.

1. **`&[T; N]` lowered to `T**`.** A reference wrapped the array's IR type, but an array value is *already* the address of its storage (`IrArray` lowers to `T*`, and an array alloca yields `T*`), so every caller passed `T*` to a parameter declared `T**`. `ReferenceType(ArrayType)` now lowers to `IrPointer(elementType)`.

   The cost of that is real and worth knowing: the IR type no longer carries `N`. Anything needing the length of such a value reads it off the semantic type instead — today that is `HmAstLowering.DecayIndexBase`.

2. **Index operators never applied argument coercions.** `xs[i]` on an array resolves, through the array-decay coercion, to `op_index(Slice(T), usize)` — but `LowerIndex` and `LowerIndexAddress` build their call directly rather than through the argument lowering that materializes coercions, so the decay was type-checked and never emitted. The raw pointer went straight into a parameter expecting a `Slice`. Both paths now run their arguments through `CoerceOperatorArgs`.

Both surfaced as C compile errors rather than wrong answers, and only because C is typed: the same two gaps between same-width types would have been silent.

### Array-to-Slice Coercion in Struct Construction

**Status:** Open (1 SKIP test)
**Affected:** C codegen — struct field initialization

Assigning `[T; N]` to a `T[]` slice field in a struct literal passes type checking but fails at C compilation — the coercion is not emitted for struct field initializers.

**Workaround:** Pass the array through a function accepting `T[]`:

```flang
fn make_wrapper(data: u8[]) Wrapper {
    return Wrapper { data = data, pos = 0 }
}
```

**Test:** `tests/harness/structs/struct_slice_field_init.f` (SKIP)

---

### Unsuffixed Numeric Literals and Overload Order

**Status:** FIXED 2026-08-18, in two parts — the candidate set stops arbitrary types, and preferred-type tie-breaking stops declaration order deciding within the set.

```flang
let l = list(4)
l.push(10)
println($"{l[0usize]}")     // prints a control character, not `10`
```

`l` infers as `List(char)`. The element type is decided by `append`, not by anything the programmer wrote: `std.string_builder` declares `append(&StringBuilder, char)` before `append(&StringBuilder, usize)`, the two tie on every ranking key for an unbound argument, and ties fall through to declaration order. `l.push(10i32)` or `let l: List(i32) = list(4)` both give the right answer.

**Mechanism.** `InferIntegerLiteral` gives an unsuffixed integer a bare `FreshVar()` — no primitive candidate set at all. A char literal in the same position gets `FreshConstrainedVar(["u8", "char"])`, and the comment there says exactly why ("so it can't unify with arbitrary types (e.g. String) during overload resolution"). The unsuffixed integer path never got the same treatment, so `10` will unify with `char`, `String`, or anything else a candidate happens to take.

**Why the obvious fix is not enough.** Constraining the literal to the integer primitives closes the `String` class of leak but not this one: `let c: char = 65`, `let f: f64 = 1` and `let f: f32 = 2` are all legal today and work by plain unification, so `char` and the floats would have to stay in the candidate set — and `char` in the set is what lets `append(char)` win.

**Partly fixed 2026-08-18.** The literal now carries a candidate set, which closes the "binds to an arbitrary type" half. The declaration-order half is still open.

**Fixed — literals are constrained.** Both unsuffixed integer and unsuffixed float literals now get `FreshConstrainedVar` instead of a bare `FreshVar`. `ValidatePostInference` was *already* checking exactly this rule (E2102 / E2001); enforcing it at unification time is what stops a wrong overload being **selected**, rather than complaining once the choice is committed — and the post-hoc check only ever looked at `PrimitiveType`, so it could not see `String` at all.

The float case was the worse of the two: `3.14` bound to `String` type-checked clean and failed only at the C compiler, because `double*` and `String*` differ. Between two same-width types it would have compiled and produced garbage.

This needed one change in `InferenceEngine.UnifyInternal` first. A constrained var meeting anything that was not a `PrimitiveType` reported a mismatch immediately, so a constrained literal could never reach the `T -> Option(T)` wrapping rule — TypeVar binding runs before the coercion rules and never gave them a turn. `fn f() f64? { return 3.14 }` became a type error. A constrained var meeting `Option(T)` now recurses on the payload, which is the right reading: the constraint describes what the *literal* becomes, and the literal becomes the payload, not the Option. `Option(String)` is still rejected, one level in. Without that fix the integer constraint failed 88 of 535 harness tests; with it, 0.

Constraint violations found during unification now report **E2102**, matching the code the post-inference check already used for the same rule, rather than the generic E2002.

Covered by `tests/harness/basics/literal_candidate_sets.f`.

**Also fixed — ties within the candidate set no longer fall to declaration order.** The first attempt at this rejected *every* tie that would bind an unbound argument differently, and failed 89 of 535 tests. That rule was wrong, not the principle: it conflated two cases.

A **char literal** ties between `char` and `u8`, but it has a *preferred* type — `char` is what `'a'` means and `u8` is the alternative. That tie is resolvable, and `tests/harness/basics/char_literal_overload_order.f` pins it.

An **unsuffixed integer or float** has no preferred type, because FLang does not default literals. A tie between two members of its candidate set is genuinely undetermined, and picking the first-declared silently decides a type the program never states.

`TieVerdict` now distinguishes them: a preferred type settles the tie (and wins regardless of declaration order, which the char test only ever passed by luck of ordering); no preferred type reports E2011. **0 of 536 tests fail.**

One trap in wiring this: calls whose candidates have no named args, defaults, or variadics take a **fast path** through `ResolveOverload` rather than `ResolveOverloadWithDefaults`. Putting the check in only one of them silently misses most direct calls.

Covered by `tests/harness/errors/error_e2011_undetermined_literal.f`.

Both halves are now closed: a literal cannot be given a type outside its candidate set, and cannot have a type inside the set chosen for it by declaration order.

### Error Code Inconsistencies

**Status:** Minor
**Affected:** Error reporting

1. **E3006/E3007:** `break`/`continue` outside loop is now caught during parsing (E1006/E1007). E3006/E3007 remain in lowering as safety net but should be deprecated once parser validation is proven reliable.
2. **E2015:** Used for both "intrinsic requires one type argument" and "missing field in struct construction". E2019 (documented for missing fields) is never emitted.

---

### `#foreign` Directive Doesn't Manage C Includes

**Status:** Open
**Affected:** C codegen preamble, `#foreign fn` declarations

Foreign function declarations (`#foreign fn`) rely on the C codegen preamble (`HmCCodeGenerator.cs`) having the right `#include` headers. When a new foreign function needs a header not already included (e.g., `ioctl` needs `<sys/ioctl.h>`), the codegen preamble must be manually updated.

**Future:** Allow `#foreign` to specify required C headers, or auto-detect them from a mapping table.

---

### Inlined Helper Function Stack Variable Codegen

**Status:** Open
**Affected:** C codegen — function inlining with local arrays

Non-pub helper functions using `let buf: [u8; 1] = [0; 1]` followed by vtable dispatch generate C code referencing undeclared `alloca_1` identifiers.

**Workaround:** Use `let byte = b; w.write(slice_from_raw_parts(&byte, 1))` instead of local array pattern.

---

### Inlined Address-of-Parameter Codegen (RESOLVED)

**Status:** Resolved — `InliningPass` no longer inlines functions that take the address of their own parameter
**Affected:** C codegen — function inlining when the inlinee takes `&param`

Same family as the stack-variable bug above: a non-pub helper that took the address of its own parameter (`fn f64_bits(v: f64) u64 { let p = &v ... }`) inlined into C that still referenced the parameter by its original name (`double* _inl1701_addr_2 = &v;` with no `v` in scope) — the inliner substituted the parameter's uses but not the address-of. Substituting the caller's argument variable instead would have been an aliasing bug: parameters are by-value copies, so a write through the pointer must never reach the caller's local.

**Fix (reference compiler):** `InliningPass.TakesAddressOfParameter` excludes such functions from the inlineable set — the call stays a call, which is correct in every case. This is the conservative fix for the C# pipeline only; materializing a fresh named copy at the inline site is its upgrade path if these ever matter for performance. Tests: `tests/harness/references/address_of_param.f` (language feature: read + write through `&param`, copy semantics observed) and `tests/harness/optimization/inline_address_of_param.f` (the inline-eligible shape that miscompiled).

**Self-hosted compiler — intended design (already in place, not the bail-out):** lowering spills every parameter to a stack slot at function entry (`lower.f`), so `&param` is just the slot's address — there is no by-name address-of in FIR to dangle. The shim inliner (`shim_inliner.f`) clones the spill slot and its store with fresh SSA ids when splicing, so the callee's by-value copy travels with the inlined body and writes through the pointer can never reach the caller's variable. Unnecessary spill copies (parameters whose address never escapes) are the later optimization pipeline's job — mem2reg/peephole after inlining deletes them (RFC-015); lowering never needs to special-case this. Pinned by `shim_inliner.f` test "splicing a body that writes through its spilled parameter keeps value semantics".

---

## Deferred Features

### Lazy Combinator Set Over Slices and Iterators

**Status:** Future work — shape decided, not implemented
**Affected:** `stdlib/std/list.f`, `stdlib/core/slice.f`, `stdlib/std/iter.f`

`List` has an eager set (`map`, `flat_map`, `filter`, `remove`, `fold`,
`fold_right`, `drop_first`) that allocates a new list per step. The same
operations over slices and iterators would return **iterators**, giving a lazy
set that fuses a chain into one pass with no intermediate containers — which is
also an answer to the allocator traffic recorded under Open Issues.

**Decision — the eager set lives on `List`, the lazy set on `Slice` and
`Iterator`, and `xs.iter()` is the explicit entry into the lazy world.**

**Rule: no implicit conversion from `List` to `Iterator`.** Entering the lazy
world is always written out. The sole exception is the `for` loop, which
iterates a list directly — that is exactly what a `for` loop does, so nothing
is being hidden there.

This is what makes the apparent ambiguity — a `List` where `xs.map(f)` could
mean either set — impossible rather than merely unlikely. With no conversion,
a `List` receiver has exactly **one** candidate: the `List` overload. The
`Slice` and `Iterator` overloads are not applicable, so there is no contest to
resolve and no reliance on return-type disambiguation (which overload
resolution cannot do anyway).

The constraint holds today by construction. The engine's coercion ladder is
`integer widening`, `float widening`, `char → u8`, `option wrapping`,
`string ↔ byte slice`, `array decay` (`[T; N]` → slice), `slice → reference`,
and `nominal → Type`. None of them produce a `Slice` or an `Iterator` from a
`List`; `as_slice()` and `iter()` are both explicit calls. This entry records
that as intentional, so no one adds such a rule later for convenience.

**Invariants to hold:**

1. Do not add an implicit `List → Iterator` (or `List → Slice`) coercion.
2. Do not define a lazy variant with a `List` receiver. Two overloads differing
   only in return type is the one case overload resolution cannot settle.

**Not scheduled.** The compiler sticks to `List` and the eager set: it is the
main consumer, it works over lists throughout, and iterator machinery would
enlarge the subset that has to lower before self-hosting completes.

---

### FFI Pointer Returns and Casts

**Status:** Not implemented
**Affected:** Foreign calls returning pointers, `as` casts for FFI types

Call result locals from `#foreign fn` are still typed as `int` in generated C. Full `as` cast support needed for memory tests.

**Tests blocked:**

- `tests/harness/memory/malloc_free.f`
- `tests/harness/memory/memcpy_basic.f`
- `tests/harness/memory/memset_basic.f`

---

### Bounds Checking on Arrays

**Status:** Partial

Slices (`T[]`) have runtime bounds checking via `op_index` in `core/slice.f`. Built-in array (`[T; N]`) indexing uses unchecked pointer arithmetic.

**Future:** Emit bounds checks for array indexing, add `--no-bounds-check` flag for release builds.

---

## Temporary Limitations

### Import Statements Must Be At Top of File

**Status:** Open (parser limitation)

The parser only accepts `import` statements (including `pub import`) before any declarations. Cannot place imports closer to where they're used or before test blocks at the bottom of a file.

**Workaround:** Place all imports at the top.

---

### Minimal I/O (`core/io.f`) Uses C stdio

**Status:** Intentional stopgap

`print`/`println` use C `printf` with `"%.*s"`. Embedded NUL bytes truncate output.

**Future:** Replace with `std/io/fmt.f` using `fwrite` in Milestone 19.

---

## Future Architectural Changes

### Generic Instantiation: AST Cloning vs Side Table

**Status:** Technical debt

Currently deep-clones function body AST for each generic instantiation so each has independent `CallExpressionNode.ResolvedTarget`. Works but is wasteful.

**Proposed:** Replace with a side table `Dictionary<(CallExpressionNode, SpecializationKey), FunctionDeclarationNode>` to keep AST immutable.

**Related:** `TypeChecker.CloneStatements()`, `TypeChecker.CloneExpression()`, `EnsureSpecialization()`

---

### Move to SSA Form

**Status:** Post-self-hosting consideration

FIR uses named local variables (not SSA). Would simplify optimizations. Keep current design until self-hosting.

---

### FIR `Global` Can't Encode Pointer Initializers — Blocks Self-Hosting

**Status:** Open — required before the self-hosted compiler can compile its own stdlib
**Affected:** `lib/flang_codegen/src/fir.f::Global`, every backend that consumes it

FIR's `Global` carries `init_bytes: u8[]?` — a flat byte image of the static buffer's initial value. That works for primitive constants and value structs (`Point { x = 3, y = 4 }` → 8 bytes, read back through `gep` + `load.i32`). It does **not** work the moment a global aggregate contains a pointer to another symbol: addresses aren't known until link time, so the frontend has no byte image to serialise.

This is the cost of FIR being type-erased on aggregates (`docs/fir.md`: "Aggregates… are byte buffers"). The C# pipeline doesn't have this gap because its IR globals are **typed** (`GlobalValue` carrying `StructConstantValue` / `ArrayConstantValue` / `FunctionReferenceValue`), and `HmCCodeGenerator.EmitGlobalValue` lowers them to C99 designated initializers — `static struct stdout_File stdout = { .path = { (uint8_t*)"<stdout>", 8 }, ... };`. Pointer fields fall out for free as `&g_other` / `(void*)"…"` etc.

**Concrete stdlib code that hits this today** (not hypothetical — these are already on disk and the self-hosted backend cannot reproduce them):

- `stdlib/std/io/file.f` — `pub const stdin / stdout / stderr` are `File` structs whose `path: String` field is a `(ptr, len)` pair pointing at a literal byte buffer.
- `stdlib/std/allocator.f` — the global allocator is a struct holding vtable function-pointers.
- Any `#interface` vtable wired up as a `pub const` (Reader / Writer impls baked in at compile time).

**Two viable directions:**

1. **Runtime init function (simpler, no FIR change).** Frontend lowers `pub const stdout = …` into:
   - A zero-filled `Global { name="stdout", init_bytes=None }`.
   - Statements appended to a generated `__flang_init_globals` FIR function that writes pointer fields via `store.ptr @stdout_path_buf, gep(@stdout, 0)`.
   - The C backend's main wrapper calls `__flang_init_globals()` before user code.

   Cost: a one-time pass at startup; trivial. Loses the "true const" guarantee (memory is mutable until init runs), but `const` semantics live in the frontend type system, not FIR.

2. **Structured init payload on `Global` (matches C# pipeline).** Replace `init_bytes: u8[]?` with:

   ```flang
   pub type GlobalInit = enum {
       Bytes(u8[])               // raw bytes at offset
       PtrTo(String, i64)        // address of named global/function + offset
       ZeroFill(u64)             // skip N bytes
   }
   pub type Global = struct {
       ...
       init: List(GlobalInit)?   // ordered, sums to `size`
   }
   ```

   C backend emits these as designated-initialized struct literals — same shape the C# codegen produces today. LLVM/Cranelift backends emit relocations directly. Preserves true static init but pushes structural knowledge back into FIR (mild violation of the "FIR is type-erased on aggregates" principle, but only at the global-boundary).

Approach 1 is the cheaper bridge; approach 2 is the structurally cleaner long-term answer. Either way the self-hosted stdlib needs one of them before `pub const stdout` can survive the trip through `flang_codegen.c_backend`.

---

### `flang_codegen.c_backend` Hard-Codes FLang's Runtime Preamble

**Status:** Open — known design wart
**Affected:** `lib/flang_codegen/src/c_backend.f::emit_preamble`

The C backend emits an unconditional runtime block at the top of every translation unit: `__flang_argc` / `__flang_argv` globals plus the three `__flang_get_argc` / `__flang_get_arg` / `__flang_getenv` accessor functions that `stdlib/std/env.f` declares as foreigns. The FIR function named `main` is then rewritten to capture argv into those globals.

This bakes one specific language's runtime contract into a library that's supposed to be reusable by any FLang-implemented language. The preamble (and what counts as "the entry point") will change as FLang evolves, and any other frontend targeting FIR is forced to inherit FLang's choices.

**Proposal:** push the preamble out of the backend. Options:
- Add a `preamble: String?` (or `extra_includes: List(String)`, `runtime_decls: String?`) field to `BuildOptions` so callers inject whatever C glue their language needs.
- Or take a closure / strategy object that the backend invokes during emission with the module in hand, letting the frontend decide based on what the module actually uses.
- Either way: the entry-point rewriting (`is_entry_point` check, argv capture prologue) should also move into a caller-provided hook, since "what is main and how does it start" is a language decision.

Until this lands, anyone reusing `flang_codegen.c_backend` inherits FLang's runtime conventions whether they want to or not.

---

### Niche Optimization for `Option(BareEnum)`

**Status:** Not implemented
**Affected:** `TypeLayoutService` — Option layout for payload-less enum types

Today only `Option(&T)` has a niche-based layout (null pointer encodes `None`). Every other `Option(T)` — including `Option(E)` where `E` is a payload-less enum — uses the full `{ has_value: bool, value: T }` struct.

**Proposal:** when `E` is a bare enum (no variants have payloads), shift discriminants to start at 1 instead of 0 so tag 0 can represent `None`. `Option(E)` collapses to a single enum-sized word. Matches the nullable-pointer trick from `Option(&T)`.

**Impact:** discriminant values of bare enums change. FFI code must continue to map between C integer codes and FLang variants *by name* — never cast raw discriminants. This is now documented in spec.md §2.5 and §2.7.

**Related:** `TypeLayoutService.LowerNominal` (where `Option(&T)` niche lives), `HmTypeChecker.Declarations.cs` `nextTag` assignment.

---

### M10 Fallout: Latent Checker Gaps Surfaced by Specialization — RESOLVED

**Status:** Resolved (2026-08-20, with M10)
**Affected:** `lib/flang_typer/src/checker.f`, `stdlib/std/iter.f`

Un-silencing generic bodies (every instantiation re-checks with concrete
types) and hard-failing on `Var` at lowering exposed a stack of latent
bugs that had been hiding behind fresh-var fallbacks. All fixed with M10:

- **Literal suffixes were ignored.** `0u32` typed as a bare fresh var
  resolved only by context; `let x = 0u32` with no further use was
  silently untyped (and lowered at a guessed width). Suffixed literals
  now ARE their suffix type; unsuffixed literals that nothing pins are
  E2001 in a post-inference sweep (reference parity).
- **Declared array lengths resolved to 0.** `array_length_of` was a
  stub; `entries: u8[16384]` sized to 0, visible the moment array
  literals got real `[T; N]` types.
- **Anonymous-literal fields never unified.** `.{ len = 0, ... }`
  checked its initializers but never constrained them against the
  nominal's field types; mismatches passed and unsuffixed fields stayed
  unpinned. `resolve_anon_literals` now runs per body scope, before
  that scope's specialization drain.
- **Shift counts were unchecked.** `x << 13` returned `lhs` without
  visiting the count; now shifts unify like arithmetic (reference
  parity).
- **Type parameters did not shadow nominals.** `resolve_named` tried
  the program-wide nominal fallback before the env, so a project type
  named `E` captured `$E` in `stdlib`'s `Result(T, E)` declaration and
  poisoned every `Err(...)` in the program. `Binding.is_type_param` now
  marks `$T` bindings and they win first (regression test: "a generic
  member call inside a partially-fixed generic instantiates").
- **`FilterIter.next` dropped non-matching heads.** It tested only the
  single next element (`Option.filter`), so `[1,2,3]` filtered to evens
  looked empty. It now advances until a match or exhaustion; this made
  `declares_generic` (via `List.any`) misreport nested-generic
  signatures as concrete, which is how it was found.

### Self-Host: Loaded-Context Overload Resolution in Instantiated Bodies

**Status:** By design (documented), sharp edge worth knowing
**Affected:** `checker.f` `fn_visibility` / `instantiate`

A template body under instantiation resolves FUNCTION lookups against
its own module's imports unioned with the caller chain's — that is what
lets `Dict`'s internals call a `hash()` overload only the call site
imports. Consequences:

- The FIRST instantiation of a given concrete signature fixes the
  winning targets for every later call site with the same signature,
  whatever those sites can see. Deliberate; inherently
  caller-dependent.
- The union applies to function lookups only. Nominal/variant lookups
  stay on the template module's own visibility — widening them let the
  projector's `Decl.Type(TypeDecl)` variant capture `Type(T)` inside
  `std.allocator.box` (expected `TypeDecl`, got `Expr` — found the hard
  way).

### Self-Host: `unify_either` Accepts Mixed bool/int Arithmetic

**Status:** Open (rejection-power gap, pre-existing)
**Affected:** `checker.f` coercion ladder (`try_integer_widening`)

`fn f(x: i32) i32 { return x + true }` checks clean: `bool` widens to
any integer in the coercion ladder, so `unify_either` accepts the
operands. The reference rejects it. Discovered while writing M10 tests
(an instantiated body with `x + true` was expected to error and did
not); the M10 test switched to an unresolved-function body instead.

### Self-Host: Non-Literal Array Repeat Counts Refuse

**Status:** Open (subset gap)
**Affected:** `checker.f` `check_array_literal`, `lower.f` `lower_let`

`[0u8; PAGE_SIZE]` (const-named count) cannot be sized without a
const-eval pass, so the literal stays an unconstrained var and the
enclosing `let` refuses the function at lowering (the one sanctioned
`Var`-at-lowering shape — it routes to the subset gate, not a guessed
width). Literal counts (`[0u8; 4096]`, underscores allowed) work.
`std.io.file.read_all_inplace` is the in-tree instance.

### Self-Host: For-Over-Iterator Loop Variables Are Untyped

**Status:** Open (checker gap; M10 removed the other half)
**Affected:** `checker.f` `check_for` / `check_iterable_element`

A `for x in xs` over a non-range iterable types `x` as an unconstrained
fresh var — the iterator protocol (`iter()`/`next()`) is not resolved
checker-side yet, even though M10 can now instantiate the generic
`next()`. Downstream uses of `x` that would pin literals fail (E2001);
`symbol_table.f` carries one annotation workaround
(`let overloads: List(FunctionScheme) = entry.value`). Fix is protocol
resolution in `check_iterable_element`, which also unlocks
for-over-iterator lowering.

---

### Container `deinit` Was Silently a No-Op Everywhere — RESOLVED

**Status:** Resolved (2026-08-20)
**Affected:** overload resolution (both compilers), every `List`/`Dict`/`Set`/`Deque` cleanup in the language

`xs.deinit()` on any container resolved to the universal no-op fallback
`deinit(&$T)` (core/deinit.f), not the container's own overload: both
candidates carry exactly one quantified var at zero cost, and the tie
fell to declaration order — the prelude registers first, so the fallback
won every time. Container cleanup throughout the language was dead code;
nothing ever freed. Found via a go-to-definition oddity (the LSP linked
`label_storage.deinit()` to the generic fallback) and confirmed with a
tracking-allocator probe: 0 deallocs, everything leaked.

**Fix:** a structural-specificity tie-break in overload scoring (fewer
quantified vars → lower cost → **more concrete parameter structure** →
literal preference → declaration order), in the reference
(`HmTypeChecker.Expressions.cs SignatureSpecificity`) and the self-hosted
checker (`resolve_overload`). Regression:
`tests/harness/stdlib/list_deinit_frees.f` asserts real dealloc counts.

**Fallout fixed in the same pass** — cleanup becoming real exposed a
stack of latent memory bugs, all of the same few shapes:

- *Copy-then-deinit*: `let a = xs[i]; a.deinit()` (or dict-iteration
  copies) frees the buffer while the stored element still points at it;
  the container's own cascade then double-frees. Every such hand loop
  was deleted — containers cascade (see spec §4).
- *Read-copy-modify-`set`*: `Dict.set` deinits the overwritten value, so
  re-storing a modified COPY of it froze/double-freed
  (`FunctionRegistry.register`); update in place via `get_ref` instead.
  The engine's prim-constraint overwrite now removes-then-sets so undo
  frames keep the old buffer alive.
- *Arena-backed AST*: every nested AST list carries an allocator pointer
  into a stack-local arena view that does not survive the `Module` being
  moved; `Module.deinit` is now arena-bulk-free only. The general
  allocator-identity problem remains open (see "Composite Structs
  Duplicate the Allocator Pointer Per Child Container").
- *Reference lowering, defer + aggregate return*: with a `defer` before
  a `return` of a coerced aggregate (an `__anon_*` record standing in
  for a nominal), the return value materialized into a temp of the
  VALUE's C type but stored through a pointer cast to the DECLARED
  type — a C type error. `StorePointerInstruction` emission now puns
  aggregate stores through the value's type (layouts are identical by
  the coercion contract).

`deinit` is now contractually idempotent (spec §4) and `Option(T)` has
its own cascading `deinit`. `flang test` keeps its temp artifacts when
the test runner exits on a signal, which is how the fallout was
debugged.
