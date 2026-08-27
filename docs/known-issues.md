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

### Checker leaks ~129 MB per cold check, ~24 MB per re-demand

**Status:** Open - reduced from 250 MB / 60 MB, residual unattributed
**Affected:** `lib/flang_typer/src/checker.f` and the demand path generally

Measured with the `FLANG_REDEMAND` probe (bootstrap/src/main.f):
`FLANG_REDEMAND=<n>` re-demands the analyzed project n times;
`FLANG_REDEMAND_EXIT` tears the unit down and reports `--mem` before
exiting, so live-at-exit is memory nothing owns. On the compiler corpus a
cold check leaves 129 MB unreachable and each re-demand adds ~24 MB. The
big one is fixed - the per-lookup visibility-set copies
(`current_visibility` / `fn_visibility`) were ~120 MB cold - along with
processed drain picks, resolved parked calls and overwritten generic
templates. The residual is spread across many small per-work-unit
allocations; attribution wants a counting-allocator variant that tags
allocations by call site. Irrelevant to one-shot builds (the process
exits); relevant to the LSP, where the per-re-demand share accumulates.

### Self-hosted: a call the reference rejects as ambiguous (E2011) resolves silently

**Status:** Open
**Affected:** `lib/flang_typer/src/checker.f` (overload scoring)

Two overloads differing only by a defaulted trailing parameter -
`fn f(self: &T) R` beside `fn f(self: &T, a: A? = null) S` - called as
`x.f()`: the reference reports E2011 (several overloads match equally
well); the self-hosted checker resolves without a diagnostic. Observed
when a `TypeCheckResult` method briefly had that shape: `flang-ref`
refused the tree, `flang build` checked it. In the observed case the
call's member accesses were left typed as open variables, and a
`--gate-a` run over that (error-state) tree reported cold-vs-warm
differences in those variables' levels - so checker parity here also
guards the incremental oracle's precondition that a comparable project
type-checks. Reproduce by adding such an overload pair and calling at
the shorter arity; the two compilers must agree on E2011.

### `tools/cst_explorer` no longer type-checks against the current parser AST

**Status:** Open
**Affected:** `tools/cst_explorer/src/ast_json.f`

The JSON emitter's `Expr`/`Stmt` matches lag the parser's AST: a
non-exhaustive match (missing the `Error` variant) and an `emit_expr`
call whose overload no longer exists. The tool is debug-only and nothing
in the build depends on it; regenerate the emitter's match arms against
`flang_parser.ast` when the tool is next needed.

### A Type Parameter in Value Position Bound Itself to `Type($X)` - RESOLVED

**Status:** Resolved - type parameters reify in value position
**Affected (was):** `lib/flang_typer/src/checker.f` (`check_identifier`), every generic body calling `size_of`/`align_of`

A bare type name used as a value is a reified type: `size_of(i32)` passes
`Type(i32)`. A type PARAMETER used the same way returned the raw parameter var
instead, because the environment binding was consulted before the reifying
path:

```
return self.engine.specialize(&binding.scheme)   // T -> the parameter var
```

`size_of(t: Type($T)) usize` then unified that var against `Type($X)`. With `T`
already concrete the unification fails and the documented `T -> Type(T)`
coercion fires, which is why this was invisible for most calls. With `T` still
free, unification succeeds first and binds the type parameter itself to
`Type($X)`.

`std.list`'s constructor is the carrier, since its body reads
`capacity * size_of(T)`:

```
pub fn list(capacity: usize, allocator: &Allocator? = null) List($T)
```

Any generic whose `T` was still open when it called `list` therefore came away
with `T = Type(X)`. `core.rtti.Type` is `struct(T) {}`, a struct with no
fields, so the resulting container sized its storage by zero and stored real
values into 0-byte slots. `std.iter`'s adapter chains hit this whenever their
element type was pinned only by what flowed through them:

```
to_0list__...FilterIter_...__ret_std__list__List_core__rtti__Type_u32   before
to_0list__...FilterIter_...__ret_std__list__List_u32                    after
```

Symptom was `tests/harness/stdlib/dict_iter_chain.f` corrupting the heap: one
unchanged binary exited 0, exited non-zero, segfaulted or hung across repeated
runs. Compilation was deterministic throughout - which of the two
specializations got built depended on the whole program, so adding an unrelated
function anywhere in the stdlib changed the odds, and any single-run bisection
blamed whatever had changed last.

**Fix:** `check_identifier` reifies a binding marked `is_type_param`, matching
what a bare concrete type name already did. `dict_iter_chain` went from 2 of 8
passing to 10 of 10. Regression test:
`tests/harness/generics/type_param_in_value_position.f`.

---

### `defer` Binds by Name, Not to the Value Live at the Statement

**Status:** Open — silently frees the wrong object, or silently drops the function
**Affected:** `lib/flang_driver/src/lower.f` (defer lowering, local slots by name)

A deferred call is resolved by NAME when the scope exits, against whatever the
name means at that point. Redeclaring the name in the same scope after the
`defer` therefore changes what the `defer` operates on:

```
pub type Tracked = struct { id: i32 }
pub fn deinit(self: &Tracked) { note("deinit", self.id) }

pub fn main() i32 {
    let x = Tracked { id = 1i32 }
    defer x.deinit()             // registered against id = 1
    let x = Tracked { id = 2i32 }
    note("body sees", x.id)
    return 0
}
```

```
body sees 2
deinit 2      <- must be `deinit 1`
```

The object live at the `defer` is never destroyed, and one that was never
registered is destroyed instead. On an owning type that is a leak plus a
double-free waiting for the second object's real cleanup. Nothing is reported.

When the redeclared type has no matching method the failure changes shape:
lowering cannot emit the deferred call and drops the ENTIRE function, so a
`main` written this way vanishes from the emitted C and only the linker
complains (`LNK1561: entry point must be defined`).

```
import std.string
pub type Rec = struct { tag: i32 }
pub fn main() i32 {
    let x = from_view("a")
    defer x.deinit()             // OwnedString has deinit
    let x = Rec { tag = 1i32 }   // Rec does not
    return x.tag - 1i32
}
```

Both need fixing, and they are separable:

1. **`defer` must capture the binding, not the name.** Bind the deferred
   receiver to the slot live at the `defer` statement. Shadowing across NESTED
   scopes already works (`tests/harness/scoping/scope_shadowing_allowed.f`); it
   is same-scope redeclaration after a `defer` that breaks.
2. **A function that cannot be lowered must be reported.** Silently omitting it
   and leaving the linker to notice is the same defect as the overload entry
   below - a build should never fail with the compiler having said nothing.

Also unspecified: whether same-scope `let x` twice is legal at all. `docs/spec.md`
covers shadowing only across nested scopes. Rejecting the redeclaration would
close the first defect without touching defer lowering.

---

### A `$F` Callback Parameter Is Pinned by Luck, Not by the Signature

**Status:** Open — needs a constraint on type signatures
**Affected:** `lib/flang_typer/src/checker.f` (overload resolution), every `$F` stdlib combinator

Combinators used to type their callback as `fn(T) $U`, which unified the
lambda's parameter with the container's element type straight from the
signature. RFC-014 changed them to a duck-typed `$F` so a callback could take
either a value or a reference:

```
-pub fn map(self: &List($T), f: fn(T) $U, allocator: &Allocator? = null) List(U)
+pub fn map(self: &List($T), f: $F, allocator: &Allocator? = null) List($U)
```

`$F` says nothing about `T`. Nothing constrains the lambda's parameter until
the instantiation's body re-check reaches `f(self[i])`, which is after the
lambda body has been checked. It usually works anyway, because resolving a
single-candidate call inside the body unifies the parameter as a side effect.
It stops working as soon as the body needs the parameter's type to choose:

```
import std.list
import std.string
import std.path            // as_view(&Path)
import std.string_builder  // as_view(&StringBuilder)

let vs = xs.map(fn(s) { s.as_view() })
// error[E2001]: cannot infer the lambda's parameter or return types
```

Remove either of the last two imports and the same line compiles - three
`as_view` overloads are visible instead of one, so no candidate can be picked
and the parameter is never pinned. Whether a lambda infers therefore depends on
what else is imported, which is not a property a caller can reason about.

Workaround: annotate the parameter (`fn(s: OwnedString) { ... }`).

The fix is a way for a signature to constrain `$F` - "F is callable with T" -
so the pin comes from the declaration rather than from resolution order, while
still admitting closures. Designed in `docs/tickets/019` §2; the property that
decides this bug is that a contract must PIN the lambda's parameter, not merely
check the callable after the fact. `scheme_specificity` already carries a
comment calling the specificity heuristic "a stand-in for a real constraint
system"; this is the same gap seen from the callback side.

Related: `docs/spec.md` §7.3 already records a weaker form of this - a value
pinned only through the instantiation cannot resolve a bare numeric literal
(`xs.fold(0i32, ...)` rather than `fold(0, ...)`). Overload choice is the
sharper case, because it fails on what is in scope rather than on the literal.

---

### Re-Analysis Retires Sources Instead of Freeing Them

**Status:** Open — deliberate, but unbounded over a long session
**Affected:** `lib/flang_analysis/src/analyze.f` (`reanalyze`, `AnalyzedProject.retired_sources`)

A `TypeCheckResult` holds string views into the sources it was checked from -
nominal FQNs and struct field names point into the module text, not into copies.
So re-parsing a module cannot free the buffer it replaces while any older result
is still alive; the older result would read freed memory. `reanalyze` therefore
moves replaced sources and ASTs to `retired_sources` / `retired_modules`, freed
only when the whole unit is dropped.

Correct, and invisible for a one-shot `flang --gate-a build`. Over an editor
session it is a leak proportional to the number of edits: every keystroke-driven
re-parse retires one more copy of the file.

The real fix is for a result to own its strings rather than borrow them, the
same move `TypeCheckResult.file_paths` already makes for paths (RFC-022 §9).
Until then, a caller that drops the previous result could retire nothing - but
nothing tracks that dependency today.

---

### A New Overload Can Silently Drop a Function From the Output

**Status:** Open — reproduced, then avoided rather than fixed
**Affected:** overload resolution (`lib/flang_typer/src/checker.f`), lowering

Adding this to `stdlib/std/list.f` compiled clean and passed every unit test,
then produced a compiler binary that would not link — `LNK1561: entry point
must be defined`:

```
pub fn list(count: usize, value: $T, allocator: &Allocator? = null) List(T) {
    let out: List(T) = list(count, allocator)   // <- also matches the new overload
    ...
}
```

The emitted C was missing `main` entirely: not misnamed, absent, while every
other function of the same module was emitted normally. Nothing was reported
at any stage.

The hazard is that `list(capacity, allocator)` also matches
`list(count, value)` with `value` bound to the allocator, because a bare type
variable in the last parameter accepts anything. The annotated return type
(`List(T)`) should decide it, and the wrong pick is not diagnosed as ambiguous.

Two separate defects, either of which would have caught it:

1. Resolution picks a candidate it should have rejected or reported as
   ambiguous.
2. Whatever went wrong downstream dropped a function silently. A function that
   cannot be lowered must be reported, never omitted from the output - the
   linker should not be what tells you.

Avoided for now by naming the constructor `filled` instead of overloading
`list`, which removes the second candidate. The underlying resolution bug is
untouched, and any similarly-shaped overload will hit it again.

---

### Library Import Cycles Are Unchecked

**Status:** Open — the rule is specified and currently holds, but nothing enforces it
**Affected:** `lib/flang_analysis/src/project.f` (manifest parsing), `lib/flang_analysis/src/analyze.f` (the BFS loader)

`docs/spec.md` §6 makes import cycles a **library**-level rule: modules inside
one library may import each other freely (a C# assembly / Java package), but
the library graph must be a DAG. Nothing checks the second half.

The check needs no source files at all - only the `[dependencies]` of each
`flang.toml`, which `project.f` already parses. Resolve the dependency graph
transitively and reject a back edge, naming both libraries.

Today's graph is acyclic:

```
flang_core    <- flang_parser <- flang_typer <- flang_analysis <- flang_driver
flang_codegen <- flang_driver
std           (no dependencies)
```

For the record, module-level cycles *within* a library are legal and load
bearing - removing them is not a goal. Three exist, each confined to one
library: `core.{rtti, slice, string}` (the prelude bootstrap - a bounds check
needs `panic`, `panic` needs formatting), `std.{dict, list, string,
string_builder, string_reader}` (the string/collection knot), and
`flang_typer.{checker, template_expand}`. A further seven `std` modules join
that cycle only through colocated `test {}` blocks importing `std.test`, which
in turn needs `list` and `string_builder`.

Consequence for RFC-022: because intra-library module cycles are permanent,
a plain import-topological demand order does not exist. The checker orders by
the topological sort of the *condensation* (the DAG of strongly-connected
components), FQN-lexicographic within a component - which degenerates to plain
topological order for the acyclic majority.

---

### Harness: Parallel Workers Share One C Build Directory

**Status:** Resolved — the self-hosted backend gives every link its own object directory
**Affected:** `test.cs` (16 parallel workers), the per-test C build under `tests/harness/`

A full `dotnet test.cs` reported one or two failures that passed when re-run
alone, and a different pair each time. The failure was always the C
toolchain, not the compiler: `LNK1104: cannot open file 'process.obj'`, or
an unresolved symbol from a stdlib `.obj` another worker was rewriting.
Every worker compiled the same stdlib translation units into the same
object files (MSVC's default is the process working directory), so two
tests building at once raced on them.

Resolution (`c_backend.f::objs_dir_for`): MSVC objects go to a per-target
`<output>.objs\` directory via `/Fo`, created before the compiler runs and
removed after the link unless `keep_temps`; incremental linking is off
(`/INCREMENTAL:NO`), so no `.ilk` is written either. Concurrent builds of
different targets no longer share any intermediate paths, and a build
leaves nothing next to the executable.

Not to be confused with `directives/if_directive_cross_target.f`, which
fails deterministically on Windows for an unrelated reason (see its own
entry).

---

### Reference: Niche-Option Method Receiver Read From a Local Copy Passes the Alloca

**Status:** Open (discovered 2026-08-21, twice, while building M11)
**Affected:** reference compiler C lowering
**Workaround in tree:** restructure the call site

Calling `.is_some()` / `.is_none()` on an `Option(&T)`-typed field of a
*by-value local* (typically a match-payload copy: `let r = rg.unwrap()`
then `r.start.is_some()`) passes the option's **alloca** (`T**`) where
the monomorphized method expects the niche VALUE (`T*`) — a C type
error (`incompatible pointer types`), so at least it is loud. Two M11
call sites hit it (`lower_index_arg`, `check_cast`'s anon-literal arm);
both were restructured (pass `&payload` into a helper taking a
reference, or replace the call with a `match`). Root-cause fix belongs
in the reference's receiver lowering.

---

### Reference + Self-Host: `for x in <fixed array>` Passed the Array's Storage Pointer as a Slice — RESOLVED

**Status:** Resolved 2026-08-22 (found converting index loops to iterators)
**Affected (was):** reference `HmAstLowering.LowerForLoop`; self-host `lower_for_iter`

The checker accepts `for s in ["i8", "i16"]` through `iter(&T[])` by array decay, but both lowerings handed `iter` the array's raw storage pointer - a `T*` where a `{ptr, len}` view was expected. In a standalone program the C compiler rejected the pointer mismatch; inside the bootstrap build it was SILENT wrong code (the self-host's `split_numeric_suffix` matched no suffix, so every suffixed literal in stage-1 lost its type - 49 E2001s in untouched files). Fixed by routing the iterable through the existing decay (`DecayIndexBase` / `lower_arg_adapted`). Harness: `iterators/for_over_fixed_array.f`. Lesson recorded in docs/self-host.md: the self-host's miscompiles surface as *checker errors in unrelated modules* of the next stage - bisect by the previous stage's input, not the failing file.

---

### Self-Host: Stage-1 Segfaults on the Full Project Build — RESOLVED

**Status:** Resolved 2026-08-22 — **stage-2 = stage-3 byte-identical
fixpoint reached.** Three stacked stage-1 miscompiles, found by running
the STAGE-2 binary under lldb (the crash was deterministic there; the
"stage-1 segfaults" of the original report was a stale stage-1 built
before the last M11 fixes):

1. **UFCS op_deref peel dropped at lowering.** `deref_retry` resolved
   `pat_buf.append(...)` through `Owned(StringBuilder)`'s `op_deref` but
   recorded nothing; `lower_receiver`'s "an aggregate's value IS its
   address" path then passed the Owned's address as `&StringBuilder`,
   shifting every field read by 8 (`sb.allocator` landed on `cap` = 16
   → `realloc` faulted at 0x18 inside `glob`). Now the chain records in
   `receiver_derefs` (per call node, drain-rewritten to specializations
   like every pick) and `lower_deref_receiver` calls each hop.
2. **Array-to-slice decay skipped for non-literal arguments.** A
   let-bound `[u8; 4]` passed to a `u8[]` parameter (`encode_char` in
   `append(char)`) handed over the raw array bytes as a `{ptr, len}`
   view — a wild pointer. `lower_arg_adapted` now builds the view at
   call arguments and value-form index receivers, mirroring the cast
   and literal decay sites.
3. **`parse_float` tipped DBL_MAX literals into infinity.** The
   digit-accumulation parser's 10^292 power loop rounded
   `1.7976931348623157e308` (the infinity-guard constant in
   `emit_float_const` and `format_f64_exp`) over into `+inf`, so
   stage-2's guards were `v > inf` and it emitted a bare `inf`
   identifier into stage-3's C. The guards are rewritten to
   `v * 0.5 == v` (no huge literal needed), and the parser applies
   scale in exact 10^22 chunks. Residual ceiling: a user literal
   within a few ulp of DBL_MAX may still parse as inf (documented at
   `parse_float`; upgrade to strtod-grade parsing to close).

Follow-up (same day): the EXPLICIT form `b.*` on a nominal was typed as
a fresh var by the self-host checker, so `pick(&b.*)` / `byval(b.*)`
silently took the wrapper's overload and `b.*.pick()` refused to lower.
`check_deref` now resolves `op_deref` (recorded as an operator on the
deref node) and lowering's `deref_address` calls it in value, place,
and receiver positions. Harness: `op_deref/op_deref_overload_positions.f`
pins all five positions against competing overloads.

Regression tests: `lower.f` "a UFCS receiver behind op_deref calls the
hop", "a generic op_deref wrapper instantiates…", "a let-bound array
argument decays…", "a DBL_MAX-magnitude literal parses finite".
Dict-iteration emission order turned out deterministic as-is — no
determinization was needed for the fixpoint.

---

### Self-Host: Explicit Enum Variant Values Are Ignored

**Status:** Open (noted 2026-08-21 while deriving comparisons from `op_cmp`)
**Affected:** self-host checker + lowering (parity gap)

`Ord` declares `Less = -1, Equal = 0, Greater = 1`, but the self-host
registry does not record variant values and lowering stores DECLARATION
INDICES as tags. Internally consistent (construction and tests agree),
but a parity gap with the reference: anything comparing tags across the
two compilers' outputs, or casting enums to ints expecting declared
values, diverges. The `op_cmp` derivation resolves Less/Equal/Greater
indices from the definition instead of assuming −1/0/1 for exactly this
reason.

---

### Self-Host: Const Init Order Is Declaration Order, Not Dependency Order

**Status:** Open ceiling (M11 globals design note)

`main` calls every surviving `__finit_*` in declaration order. A const
whose initializer reads another const's **value** (not address) may see
zeros if declared first. No such const exists in tree; topo-sort the
init calls when one appears. Address-of cross-references (the vtable
pattern) are order-independent by construction.

---

### Self-Host: Minimal RTTI — TypeInfo Name/Fields Are Zeroed; `project_info` Unintercepted

**Status:** Open (M11 scoped this deliberately)

`size_of(T)` / `align_of(T)` fold to layout constants at call sites;
`Type(T)` values materialize a TypeInfo with size, align, and kind
filled and everything else zeroed (name is an empty/null String —
printing it would crash). `project_info()` is not intercepted, so
stage-1's `--version` prints garbage-adjacent output. Fill name (an
interned string) when a consumer needs it; intercept `project_info`
like the reference does.

---

### Reference: A Statement-Position `match`/`if` Whose Arms All Diverge Emits Invalid C — RESOLVED

**Status:** Resolved 2026-08-20 (same day as discovery, while writing `flang_parser/comptime.f`)
**Affected (was):** reference compiler C lowering

A statement-position `match` or `if/else` where **every** arm returns leaves a merge block nothing jumps to; the implicit-return pass then gave that dead block a placeholder return — type-valid C only for scalar return types, so aggregate-returning functions produced `return;` in a non-void C function (or "assigning struct from int"). Fixed by `HmAstLowering.FinishBlocks`: unreachable blocks are dropped from the CFG before implicit returns are added (regression: `tests/harness/enums/match_all_arms_diverge_aggregate.f`). `comptime.f`'s evaluator was written in value-form matches to sidestep this; that style stays (it reads better), but the constraint is gone.

---

### Reference: Pending-Specialization Drain Assumed Resolution Never Enqueues — RESOLVED

**Status:** Resolved 2026-08-20 — `ResolvePendingSpecializations` iterated with `foreach` while `EnsureSpecialization`'s template-body re-checks could append new pendings ("Collection was modified" ICE), and its TypeVar skip was shallow, so a *nested* unresolved var (`Result(T, $E)` from a signature naming an unknown type, e.g. a missing `import std.result`) minted a unique spec key every round and the drain never converged (7+ minutes at 75% CPU). Now: index-based drain that also processes appends, deep `ContainsUnboundTypeVar` skip, and a 20k-iteration backstop that reports E2001 instead of spinning.

---

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

**Mitigated 2026-08-24:** `dotnet build.cs` now installs a *copy* of the stage-1 binary as `dist/<rid>/flang`, the default compiler. Driving a self-build with `dist/<rid>/flang` writes `bootstrap/build/flang` without touching the binary executing it, so a failed link no longer leaves you with no compiler. The in-place footgun still exists if you invoke `bootstrap/build/flang` directly.

---

### Self-Hosted Driver Cannot Build the Examples — RESOLVED (driver half)

**Status:** Three driver gaps fixed 2026-08-24; `examples/` went 2/11 → 5/11 self-hosted (reference: 9/11). The remaining four failures are lowering/typer gaps, not driver gaps — see the next entry.
**Affected (was):** `lib/flang_driver/src/{resolver,driver,compile}.f`, `lib/flang_typer/src/{checker,function_registry}.f`, `bootstrap/src/main.f`

Harness parity (551/0/16) is measured on single-file `flang build <file.f>`, which exercises none of the project-level driver work. The examples were the first thing that did, and they exposed three gaps:

**1 — `[imports].global` was parsed, then discarded.** `project.f` parsed the key into `Project.global_imports` (with a passing unit test) and nothing ever read the field; `git log -S global_imports` shows a consumer never existed. Fixed by carrying it through `ResolveCtx.global_imports` → `seed_globals` (loads the named modules, and diagnoses an unresolvable one) → `Checker.set_project_globals` → `build_visibility`, which injects them as implicit **private** imports into **project-origin modules only**, right beside the existing `core.prelude` auto-import. Project origin is tracked as a `List(bool)` parallel to the module list, recorded as the BFS pushes each module, so it survives a read failure shifting indices. Same scoping rule as the reference (`Compiler.cs`): the stdlib and dependencies stay isolated from per-project config. Fixes tree, typer-smoke.

**2 — companion `.c` files were never compiled or linked.** `build_program` globbed `<stdlib_root>/**/*.c` only, so a project's own native shim (`examples/snake/src/platform.c`) was silently dropped and the link failed on the missing symbol. Replaced with the reference's uniform rule (`Compiler.cs` step 6): every `<mod>.c` sitting beside a `<mod>.f` **in the module set** is linked, wherever it lives. `build_program` now takes the module file paths instead of a stdlib root. A `.c` the compiler itself emitted is skipped by sniffing `"Generated by"` in its first 200 bytes — required, because the harness writes `<test>.c` next to `<test>.f` and linking a previous build's output would duplicate every symbol in it. No stdlib `.c` lacks a sibling `.f`, so the narrower rule loses nothing.

**3 — `#foreign` declarations were not project-global.** `visibility_for` required `vis.visible.contains(m)` even for foreign functions, so a `#foreign pub fn` in a sibling `.f` needed an explicit import. A foreign declaration names a global link-time symbol and is not module-scoped at all; it now short-circuits to visible, matching `FunctionRegistry.cs` ("extern C symbols are globally linkable"). This is what produced snake's first errors — `examples/snake/src/main.f` never imports `platform`.

Verified after the change: harness **551/0/16** unchanged, stage-2 = stage-3 fixpoint still byte-identical, `test-all` unchanged at 5/6.

---

### Self-Hosted: Four Examples Failing on Lowering/Typer Gaps — 3 of 4 RESOLVED

**Status:** calc, wc, fq fixed 2026-08-24; csv remains, blocked on a FIR feature (next entry). `examples/` is now 8/11 self-hosted vs 9/11 reference.
**Affected (was):** `lib/flang_typer/src/checker.f`, `lib/flang_driver/src/lower.f`

**1 — an unannotated `const` was still an open type variable when bodies were checked (fixed wc AND fq).** `register_constant` gives an unannotated module-level constant a fresh variable in the signature pass, and `check_constant_init` only pins it during the body pass, in declaration order. A body checked earlier therefore saw an *open var* — and an open var unifies with every candidate in an overload probe at equal cost, so declaration order picked the winner. `stdin.reader()` resolved to `reader(&BufferedReader)` instead of `reader(&File)`; the resulting mismatch surfaced much later and was blamed on the const's own declaration (`E2002 expected BufferedReader, got File` at `stdlib/std/io/file.f:180`, the `stdin` declaration — nowhere near the call). Fixed with a phase 2.5 in `check_all`: every module's constant initializers are checked before any function body. Regression test: `tests/harness/const/const_pinned_before_bodies.f`.

Note the probe machinery itself was fine — `candidate_cost` correctly wraps its unifications in `push_checkpoint`/`rollback`. The bug was the *input* to the probe, not the probe.

**2 — a tuple sub-pattern inside a variant payload dropped its bindings (fixed calc).** `bind_pattern_var` recorded a node type for VARIABLE patterns only, while lowering reads *every* sub-pattern's type off its own node (`bind_variant_payload` → `node_ty(pattern_span(sub))`). A tuple sub-pattern (`Ok((value, consumed))`) had nothing recorded, hit lowering's `i32` fallback, `tuple_pattern_member` refused to see a tuple, and `bind_tuple_pattern` silently `continue`d past both elements — surfacing far away as "unbound name read `consumed`". Fixed by recording the expected type on every pattern node in `check_pattern`; kind-specific code may still refine it. `bind_tuple_pattern` now refuses loudly instead of skipping, so the same class of bug reports at its cause. Regression test: `tests/harness/patterns/tuple_in_variant_payload.f`.

**Diagnostics.** The skip report now names the symbol a refusal is about — `body refused (unbound name read \`consumed\`)` rather than a bare category — via `LowerCtx.blocked_subject`. All four of these were diagnosed off that one change.

`examples/chess-fen` and `examples/raylib` fail under the reference too — pre-existing and unrelated.

---

### Self-Host: `#foreign` and `#simd` Were Dropped From Struct Declarations — RESOLVED

**Status:** Resolved 2026-08-24
**Affected (was):** `lib/flang_typer/src/checker.f::register_struct_placeholder`

`register_struct_placeholder` hardcoded `is_simd = false, is_foreign = false`, and `resolve_struct_body` copied both forward unchanged, so a struct's directives never reached its `StructDef`. Every struct therefore took the `Repr.Auto` path (`layout.f::repr_of`), with two consequences:

- **`#foreign struct` was reordered** by descending alignment — precisely the layout the marker exists to opt out of (spec §2.4 / §10). `#foreign struct { a: u8, big: u64, b: u8 }` measured 16 bytes instead of C's 24.
- **`#simd struct` was not over-aligned.** `Vec128` emitted as `_Alignas(1)` while its companion `stdlib/std/simd.c` declares `__attribute__((aligned(16)))`.

Both are silent-wrong-bytes bugs at an FFI boundary rather than compile errors. They stayed hidden because the aggregates that actually crossed — raylib's `Rectangle`, `Vector2`, `Color`, and `Vec128` — have members of uniform alignment, which reorder to themselves; `Camera2D` likewise. The `agg_abi_safe` layout gate would have refused a mixed-alignment `#foreign` struct rather than miscompile it, so the failure mode was a spurious refusal, not corruption.

Fixed by reading the declaration's directives (`is_simd_directive` / `is_foreign_directive`). Regression test: `tests/harness/directives/foreign_struct_layout_lock.f`.

---

### Reference: Plain Structs Are Not Reordered (spec §2.4 unimplemented)

**Status:** Won't fix — the reference is slated for decommissioning once the self-hosted compiler is the implementation of record. Recorded so the divergence is not mistaken for a self-host bug.
**Affected:** `src/FLang.IR/TypeLayoutService.cs`

`docs/spec.md` §2.4 says a plain struct's layout is the compiler's to choose and that fields are reordered to minimise footprint. The self-hosted compiler implements this (`layout.f::repr_of` → `Repr.Auto`, descending alignment); the reference lays every struct out in declaration order.

```
type Wasteful = struct { a: u8, big: u64, b: u8 }
println(size_of(Wasteful))
```

| | result |
|---|---|
| reference | `24` — `a`, 7 pad, `big`, `b`, 7 pad |
| self-hosted | `16` — `big`, `a`, `b`, 6 tail pad |

Both are self-consistent, so neither miscompiles: a program built by one compiler agrees with itself everywhere, and §2.4 makes the layout unobservable by design. Two consequences to keep in mind while both compilers exist:

1. **`size_of` differs for identical source.** It is an answer about the build, per §2.4, but a surprising one to meet when comparing the two.
2. **The reference is accidentally permissive at the FFI boundary.** Because it does not reorder, passing a *plain* struct by value to a C function happens to work there — `#foreign fn f(m: Mixed)` with `Mixed { tag: i32, val: f64 }` returns the right answer under the reference and is refused by the self-hosted compiler (`agg_abi_safe`). That is the reference being lax, not the self-hosted compiler being strict: §2.4 never promised it, and §10's `#foreign` is the supported spelling. Harness tests therefore assert the `#foreign` half exactly and only an inequality for plain structs (`tests/harness/directives/foreign_struct_layout_lock.f`).

---

### Self-Host: Aggregate C Struct Names Were Neither Valid Nor Unique — RESOLVED

**Status:** Resolved 2026-08-24
**Affected (was):** `lib/flang_driver/src/lower.f::agg_c_name`

The mangler that turns a nominal's FQN into the C struct name for a by-value aggregate had two defects, both latent — no in-tree module path exercises either:

- **Invalid identifiers.** A byte outside `[A-Za-z0-9_.]` was escaped as `_x` followed by *the raw byte*, so a hyphen produced `_x-` — still not a C identifier. `append_module_path` had been fixed to emit `_x<hex>`; this one had not.
- **Colliding names.** `.` mapped to `_` while a literal `_` passed through, so `coll.a.b.T` and `coll.a.b_T` both mangled to `coll_a_b_T`. `IrModule.add_agg` dedupes by name, so the second struct would silently reuse the first's definition — a wrong-layout call across the C boundary, not a diagnostic.

Both fixed: `.` → `_` (unchanged, so `std.simd.Vec128` still spells `std_simd_Vec128` and matches `stdlib/std/simd.c` by hand), `_` → `_0` for injectivity, anything else → `_x<hex>` via the shared `append_hex_byte`. A literal `_` always becomes `_0`, so `_x` can only come from an escape.

Verified by construction: a `#foreign struct` in a project named `my-proj` now emits `my_x2dproj_main_Pt` (was `my_x-proj_main_Pt`) and links and runs against a hand-written C shim; the collision pair emits `coll_a_b_T` and `coll_a_b_0T` with their own distinct definitions.

**No harness test.** Reaching `agg_c_name` needs a `#foreign` struct crossing a boundary, which needs a companion `.c`, and `tests/harness/**` is gitignored except `*.f`. Covered by the scratch projects above and by `examples/raylib`.

---

### Foreign Signatures Cannot Carry Aggregates By Value — RESOLVED

**Status:** Resolved 2026-08-24. With this and the `[build.<os>]` wiring below, `examples/` is **11 of 11 under both compilers** (raylib needs `RAYLIB_PATH` set; it is an external dependency, not a compiler limit).
**Affected (was):** `lib/flang_codegen/src/{fir,c_backend}.f`, `lib/flang_driver/src/{lower,symbol_table}.f`

`#foreign pub fn v128_load(ptr: &u8) Vec128` could not be declared: `IrType` had no aggregate case. This backend models every aggregate as raw bytes plus offsets — a native call passes an address, an aggregate return uses an sret slot — so there was no type to write into the extern. `ty_lowerable` refused any foreign signature containing one, and every `std.simd` call reported `callee is not a callable value`.

**`IrType.Agg(AggType)` + `AggDef`.** The signature-level handle (`AggType`) carries only `{ name, size, align }`, so `IrType` stays a flat, freely-copyable value with no recursion. The *definition* (`AggDef`, held on `IrModule.aggs`) carries the member list, and the backend emits one `typedef struct` per entry ahead of the externs naming them. Nested aggregates are registered before their containers, so emitting in list order is already valid C.

**Members are faithful, not bytes.** The platform ABI classifies a struct by what its members *are*: on x86-64 SysV a `float` member puts its eightbyte in class SSE, so a byte-blob stand-in would claim GP registers and read garbage — silently, since it compiles and links. `vendor_raylib_Vector2` emits as `{ _Alignas(4) float _f0; float _f1; }`, and `Camera2D` as `{ Vector2 _f0; Vector2 _f1; float _f2; float _f3; }` with `Vector2` defined first.

**The gate is layout agreement, not member types** (`symbol_table.f::agg_abi_safe`, the single authority — the call site and the emitted definition read the same predicate, so they cannot disagree). An aggregate may cross only if laying its members out the way C will — declaration order, each at its own alignment, the first carrying the struct's `_Alignas` — reproduces the FLang layout exactly. It often does not: only a `#foreign struct` is `Repr.C`; every other struct is `Repr.Auto`, which orders fields by **descending alignment** (`layout.f`). `struct { tag: i32, val: f64 }` puts `val` at offset 0, so its bytes match no C declaration of the same members, and it is refused. Padding stays implicit deliberately — an explicit filler member would itself change the classification (a `char` in an eightbyte forces it to INTEGER).

**A refusal sinks the whole extern.** `foreign_from_sig` returns null if any parameter or return is an unspellable aggregate, rather than letting it degrade to `ptr`. Degrading would emit `extern double f(void*)` for a C function taking a struct by value: it compiles, links, and passes the wrong thing. No extern means the call refuses loudly instead.

**Verified by running, not by reading.** A companion-C round trip (`rect_scale(Rect{1.5,2.5,3,4}, 2.0)` → `3 5 6 8`) confirms a 4×`f32` struct survives both directions; the same harness proves `struct { i32, f64 }` now refuses at compile time instead of returning a denormal (`3.45846e-323` — the tag's bits read as a double) as it did before the layout gate. `examples/csv` output is byte-identical to the reference-built binary. Regression test: `tests/harness/directives/foreign_aggregate_byvalue.f`.

**Test coverage gap.** The float path has no harness test: it needs a hand-written companion `.c`, and `tests/harness/**` is gitignored except `*.f` — a committed `.c` there is indistinguishable from the generated `<test>.c`. It is covered by `examples/raylib` and by the scratch round trip above.

**Known rough edge, pre-existing:** FIR has no unsigned types, so a `u8` foreign parameter is declared `int8_t`. Same size and ABI, but a literal above 127 trips clang's `-Wconstant-conversion` under `-Werror`. Applies to every foreign scalar, not just aggregates.

---

### Self-Hosted Driver Ignored `[build.<os>]` — RESOLVED

**Status:** Resolved 2026-08-24
**Affected (was):** `bootstrap/src/main.f`, `lib/flang_driver/src/compile.f`, `lib/flang_codegen/src/c_backend.f`

Third instance of the same shape as `[imports].global`: `project.f` parsed `headers`/`libs`/`cflags`/`ldflags` into `PlatformConfig`, `BuildOptions` had `add_lib`/`add_ldflag`, and `c_backend.f` passed them to the linker — but nothing connected the two ends, so `examples/raylib` linked without `libraylib.a` and failed on `_GetFrameTime`. `build_program` now takes the host platform's libs and ldflags.

Two details the reference already handled:

- **`${VAR}` expansion.** `libs = ["${RAYLIB_PATH}/lib/libraylib.a"]` is expanded against the environment, and an undefined variable is an error naming every missing variable — not an empty string silently dropped from the link line. Expansion reads the environment, so it lives at the CLI edge (`main.f`) rather than inside the driver, which keeps `build_program` honest.
- **ldflags are split on whitespace.** `"-framework CoreVideo"` is one manifest string but must reach clang as two argv words; joined, clang rejects it with `unknown argument`. A path containing a space cannot be spelled this way — take a nested array in the manifest if one ever needs to be.

`headers` and `cflags` remain unconsumed: `headers` drives FFI binding generation from a C header, which the self-hosted compiler has no parser for. `examples/raylib` works because the reference generated `vendor/raylib.f` and the self-hosted compiler reuses it.

---

### Self-Hosted CLI Is Not At Feature Parity With the Reference

**Status:** Open — blocks `dist/<rid>/flang` from replacing `flang-ref` outright
**Affected:** `bootstrap/src/main.f` (argument parsing / command dispatch)

The self-hosted compiler reaches harness parity on **compilation** (551/0/16 through `build`, identical to the reference) but its CLI is a strict subset:

| Missing | Reference form |
|---------|----------------|
| `test` command | `flang test [path] [--name <substr>]` |
| bare-file form | `flang hello.f` (self-host needs `flang build hello.f`) |
| `-o <path>` | output path control |
| program name | identifies itself as `bootstrap`, not `flang` |

`--release` landed 2026-08-25 as `-r/--release`; the self-host also has
`-k/--keep-c` and `-t/--timings`, which the reference does not. Note that
self-hosted flags must precede the subcommand — `getopts` stops at the first
non-option argument.

Consequences today: `dotnet test-all.cs` is pinned to `dist/<rid>/flang-ref` because `flang test` does not exist self-hosted, and the README documents the reference-only forms separately. The harness (`dotnet test.cs`) is unaffected — it only ever invokes `build`.

---

### POSIX-Only Test Expectations on Windows — `std.path` RESOLVED

**Status:** `std.path` resolved 2026-08-25 (`dotnet test-all.cs` back to 5/6
on Windows); one harness test still POSIX-only
**Affected:** `tests/harness/directives/if_directive_divergence.f`

Anything that joins path components writes the NATIVE separator (`sep()` is
`\` on Windows), so an expectation spelled with `/` only holds on POSIX.
Three `stdlib/std/path.f` test blocks (`to_relative walks up and back down`,
`push appends a component and absolute input replaces`, `with_file_name
replaces only the last component`) failed that way; they now assert through
`assert_slash_eq`, which compares the `to_slash` form and so reads the same
on every platform. The library code was correct throughout.

`if_directive_divergence.f` has the same shape and still fails on Windows:
its `pick()` returns 1 under `#if platform.os == "windows"` and `main`
asserts 0. What the test is actually for is that an exhaustive `#if`/`else`
whose branches both return satisfies the missing-return check, which holds
whichever branch is live — the expectation just needs to stop naming one
platform's branch.

---

### Self-Host: No Dead-Code Elimination — Unreachable POSIX Foreigns Reach the Linker

**Status:** Open — one harness test fails on Windows (`directives/if_directive_cross_target.f`)
**Affected:** `lib/flang_driver/src/lower.f` (lowers every function in the module set), `stdlib/std/readline.f`

The reference compiler emits only what is reachable from `main`; the
self-hosted lowering emits every function of every module in the program.
Unreferenced code costs binary size, and any `#foreign` symbol in it must
resolve at link time even when nothing calls it. On Windows the POSIX-only
foreigns in `std.readline` (`tcgetattr`, `tcsetattr`) are therefore
unresolved externals in every build whose compile-time context is not
`windows`.

`std.terminal.get_terminal_size` used to be a third one; it now branches on
`#if platform.os == "windows"` and returns the 80x24 fallback there, which
is the shape the rest of the POSIX foreigns need too — guard the call, not
the declaration (an uncalled `extern` never reaches the linker).

Host-targeted builds are unaffected: `#if` prunes the POSIX branch on a
Windows host. Only a cross-target build (`--target-os linux` on Windows,
which still links with the host toolchain) drags them in.

Measured on the self-build (2026-08-25), with a demand-driven walk seeded
at `main` and the const initializers, pulling declarations and `#foreign`
externs in on reference: **874 of 4527 emitted functions (19%) are
unreachable**, worth 11% of the emitted C, 10% of the binary, and 16% of
harness wall time (123s -> 103s, every test compiles less stdlib). Lowering
time itself did *not* move — the dead functions are small. The
cross-target test passes with it, and the stage-2 = stage-3 fixpoint holds.

Two traps that walk hit, for whoever lands it: (1) an unregistered
declaration must not be indexed under its bare source name — a generic
`free(...)` template shadowed the `#foreign free`, so every allocator user
was dropped as a caller of an undefined symbol; only body-less
(variadic-foreign) declarations may fall back to the source name. (2)
`drop_callers_of_refused` only inspects `Call.callee` and `Store`d
`FuncRef`s, so a function address passed as a call *argument* keeps a
dangling reference alive. Deferred into the incremental/pull-based
compilation model the LSP work is introducing.

---

### `lib/flang_driver` `test {}` Blocks Call `lower_program` With a Stale Arity

**Status:** Open — `dotnet test-all.cs` is 5/6 green
**Affected:** `lib/flang_driver/src/lower.f:7109`, `lib/flang_driver/src/lower.f:7309`

`lower_program` gained a required `comptime_ctx: ComptimeCtx` parameter (RFC-021, `lib/flang_driver/src/lower.f:403`), but two colocated `test {}` blocks still call it with three arguments:

```
error[E2011]: No matching overload for `lower_program` with 3 argument(s)
```

The whole `lib/flang_driver` leg fails to compile, so none of its blocks run. The non-test caller (`lib/flang_driver/src/compile.f:44`) was updated; only the test blocks were missed. Pre-existing — unrelated to the compiler-layout change that surfaced it.

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

**Update 2026-08-24:** all three since closed — lambdas (RFC-014, 2026-08-20), array literals (M10/M11), and `?.` null propagation (checker + lowering, 2026-08-24). Every `Expr` variant is now visited; the remaining unvisited-subtree caveat is a generic template body that is never instantiated.

**Harness scoreboard (through the bootstrap).** The lit-style corpus runs through any compiler binary via `$FLANG` (see docs/architecture.md, "Execution mode"): `FLANG=bootstrap/build/flang dotnet test.cs`.

- *2026-07-03, post-mangling:* recorded as **131 passed / 385 failed / 14 skipped of 530**, with failures said to reach the run/compare stage and report wrong exit codes.
- *2026-08-16, re-baselined:* **15 passed / 501 failed / 14 skipped**. The 131 figure does **not** reproduce in this tree. The reference compiler is green over the same corpus (516 / 0 / 14), so the corpus and the C# pipeline are healthy; the collapse is entirely on the bootstrap side, and it is not a lowering regression. Two causes, both since diagnosed:
  1. `std.process` spawn fails for every program, so the bootstrap's C-compiler probe finds nothing and no build ever reaches the backend (see its own entry under Open Issues). This alone accounts for nearly all of it.
  2. Missing template sidecars (below) failed every compilation at type-check time with ~92 errors before that.

  Because cause 1 stops the backend outright, **the harness cannot currently measure lowering work through the bootstrap at all.** Fix spawn before treating any harness delta as a signal about codegen.

- *2026-08-24, post-`a?.b` push:* **411 passed / 140 failed / 16 skipped of 567** through stage-2 (the self-compiled binary), then a day of fixes on the failures (final number below). Two systemic bugs surfaced first:
  1. **Self-host C emission declared variadic libc functions fixed-arity.** `open` and `ioctl` are variadic (`int open(const char*, int, ...)`); the emitted `extern int32_t open(void*, int32_t, int32_t)` made calls pass the mode argument in a register while darwin-arm64's va_arg reads the stack — **files created by any self-host-compiled binary got garbage permission bits**, so fresh `.c` outputs randomly failed `clang` with `Permission denied`. The preamble now includes `<unistd.h>/<fcntl.h>/<sys/ioctl.h>` (Windows: `<io.h>/<fcntl.h>`) and suppresses `open`/`close`/`read`/`write`/`ioctl` externs, mirroring the reference (`c_backend.f`).
  2. **The lexer dropped integer suffixes on hex literals.** The `0x` branch returned before the shared suffix scan, so `0xffu8` lexed as `0xff` + identifier `u8` — the stray identifier refused the enclosing function at lowering ("unbound name read"). Fixed by routing the hex branch through `scan_int_suffix`.
- *Same day, from the same sweep:* variant payload subpatterns never tested (`Reading(0)` matched any `Reading`), or-/range-patterns had checker+lowering support but **no projector producer** (all E2115'd), nested `else if` joins recorded no type (aggregate arms truncated through an i32 block param), `let`-bound array→slice decay never fired (garbage slice length), `&[T; N]` receivers passed raw to Slice `op_index` (segfault), UFCS on rvalue receivers refused, `(&&T).x` refused, `arr.len` under a cast panicked the typer contract, and overload resolution let a bare literal pick a `String` overload. All fixed; see docs/self-host.md for the per-table notes.
- *End of the 2026-08-24 push:* **435 passed / 116 failed / 16 skipped** through stage-2, with the stage-2 = stage-3 fixpoint intact and the reference suite green over the same corpus (551 / 0 / 16). Of the 116: **61 are `COMPILE-ERROR` tests** (rejection power — the known long-term axis), and the 55 runtime/compile failures bucket into: RTTI name strings/fields (12), named arguments + variadic calls (9), `$sb"…"` interpolation forms needing named/defaulted args (6), warnings + `#if runtime.env` directives (6), user `op_call` dispatch (4), anonymous struct TYPES (4), `op_add`/`op_sub` arithmetic dispatch (2), struct/tuple destructuring patterns (2), member-through-`op_deref` field access (2), plus one-offs (recursive generic enums, generic-type-as-expression `size_of(Pair(i32))`, anon-shorthand `.{ x, y }`, `dict_iter_chain` lambdas, `struct_slice_field_init`). All fail loudly (check error or refusal-at-link), none silently.

Diagnostic coverage on *invalid* code is its own gap, distinct from the clean self-host typecheck: only a fraction of the `COMPILE-ERROR` tests see their expected code — e.g. `tests/harness/errors/error_char_literal_rejects_string.f` expects E2011, but the bootstrap type-checks the file clean and proceeds to codegen.

**Template sidecars are build artifacts, not checked-in files.** Earlier notes in this document describe `reader.generated.f` / `writer.generated.f` and friends as "checked-in". They are not: `.gitignore:130` ignores `*.generated.f` globally, and `git ls-files 'stdlib/**/*.generated.f'` returns nothing. They exist only because a previous reference-compiler build wrote them (`src/FLang.CLI/Compiler.cs:299`, best-effort). This is load-bearing for the bootstrap, which cannot expand `#interface` / `#implement` itself.

The failure mode is asymmetric and bites on a clean tree: the reference compiler expands only the modules an entry point actually imports, while the bootstrap's driver BFS seeds **every** stdlib source. So any stdlib module that nothing imports never gets a sidecar written, yet the bootstrap still loads it and fails on its unexpanded types. `stdlib/std/encoding/codec.f` (`#interface(Encoder, …)`, `#interface(Decoder, …)`) hit exactly this — 72 of the 92 errors — as did `std/io/file.f` (`#implement(File, Reader)`), with no `file.generated.f` on disk. Regenerating them all requires compiling a file that imports every stdlib module. **A fresh clone has zero sidecars and the bootstrap fails on everything.**

**Fix directions:** either drop `*.generated.f` from `.gitignore` for `stdlib/` and commit them (makes the bootstrap's input reproducible, at the cost of generated files in review), or make sidecar generation an explicit build step that walks the whole stdlib rather than a side effect of whatever happened to be imported. The durable answer is teaching the bootstrap to expand templates itself, which removes the dependency entirely.

**Update 2026-08-23 (RFC-021 phase 1):** the reference compiler no longer writes sidecars as a side effect — expansion is in memory and `.generated.f` appears only with `--emit-generated`. All sidecars were deleted from the tree the same day. **Closed later the same day by phase 4:** the self-host expands templates natively (`flang -g build` emits the files for debugging); a clean clone self-builds and the stage-2 = stage-3 fixpoint holds.

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

### Reference: Mutation Through an Indexed Receiver Chain Writes to a Temp Copy

**Status:** Open in the C# reference. The self-hosted compiler gets it right.
**Affected:** C# `HmAstLowering` UFCS receiver lowering when the receiver path contains an `[i]` hop; silent data loss

A `&Self` method called through a receiver path with one or more index hops mutates a temporary copy of the element, not the element in the list buffer. The call compiles and runs clean; the write is lost. Field-only hops are handled (see the resolved multi-hop UFCS entry); an index hop in the path reintroduces the spill.

```flang
type Block = struct { x: i32 }
fn set_x(self: &Block, v: i32) { self.x = v }
type Func = struct { blocks: List(Block) }
type Mod = struct { functions: List(Func) }

// m: Mod with one function holding one block, x == 0
m.functions[0].blocks[0].set_x(5)
let a = m.functions[0].blocks[0].x      // reference: 0, self-hosted: 5

let r = &m.functions[0].blocks[0]
r.set_x(7)
let b = m.functions[0].blocks[0].x      // 7 on both
```

Reads through the same chain are fine; only mutation is affected.

**Workaround:** bind the deepest element once with `&` and mutate through that reference.

**Fix direction:** lower an index expression in a receiver path as a place, the same way member access already is. A harness test pinning this fails the reference today, so it waits for the fix or for the reference's retirement.

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

**Future (agreed direction, 2026-08-20):** With the stdlib combinators now duck-typed (`f: $F`), context-directed pick by expected type no longer applies — a `$F` slot carries no signature. The agreed design is **instantiation-time resolution**: bind the slot to an unresolved overload-set and resolve it against concrete argument types at the instantiation's internal call site (the same machinery that pins unannotated lambda params through `$F`). See docs/tickets/019 §4. The by-ref wrinkle stands: `deinit` overloads take `&T` and combinators invoke value-mode, so this also depends on the argument-adaptation decision (ticket 019 §1).

---

### Template-Eager-Check Limits on Duck-Typed Callables

**Status:** Open (workarounds in tree)
**Affected:** Reference checker; generic bodies using `$F`-typed callables

Generic template bodies are checked eagerly at declaration, so operations
needing a *resolved* type fail on the result of a `$F` call even though
every instantiation would succeed: `!f(x)` ("No operator `!`"),
`op_cmp(key(a), key(b))` (ambiguous on metavars), tuple-field access on a
metavar-typed lambda parameter. Workarounds used by `std.list` /
`std.iter` / `std.sort`: pin with `let ok: bool = f(x)`; compare keys
with `<` instead of `op_cmp`. The self-hosted compiler is immune (it
validates template bodies only at instantiation). Deferring these checks
is ticket 019 §6.

Related inference-order consequence: a value pinned *only* through an
instantiation (e.g. `fold`'s seed with a duck-typed `f`) cannot resolve a
bare numeric literal — the E2001 sweep runs per body, before the pins the
instantiation would provide. Write `fold(0i32, …)`.

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

### Formatter: `always` separator mode does not force multiline

**Status:** Open (lib/flang_fmt)

`[fmt] trailing-comma = "always"` and `separators = "always"` are accepted and keep every separator, but do not yet rewrite a single-line construct into one element per line. They currently behave as `multiline`.

**Workaround:** Break the construct across lines by hand; the separator then appears.

---

### Formatter: wrap and join cover commas and and/or only

**Status:** Intentional first cut (lib/flang_fmt)

A line over `max-width` breaks after its last fitting list comma or before `and`/`or`; joining re-flows the same positions. Other continuation styles (`.`-method chains, arithmetic chains without commas) keep their authored breaks and can leave a long line long. Extending either side needs a guarantee that a newline at the new position cannot end a statement; the verify gate catches a bad break, but by refusing the whole file.

---

### Self-host: single-file builds load the whole stdlib, breaking cross-target links on Windows

**Status:** Open (pre-existing, exposed 2026-08-27)

The self-hosted compiler's single-file mode compiles every std module (61 modules for a bare `main`), not just the prelude's import closure; the reference loads imports only. Consequence: `tests/harness/directives/if_directive_cross_target.f` (`TARGET-OS: linux`) emits `std.readline`/`std.terminal` POSIX branches and fails to link on a Windows host (`tcgetattr`, `ioctl` unresolved). The reference compiler passes the same test. Unrelated to formatting: reproduced with fully unformatted sources.

**Fix direction:** restrict single-file module loading to the transitive import closure, or skip emission of functions in modules nothing imports.

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

### Self-Host: Lib-Mode Check Globbed `.generated.f` Sidecars as Separate Modules, Clobbering Visibility — RESOLVED

**Status:** Resolved (2026-08-20)
**Affected:** `flang_driver` project loading (`analyze_project` + project glob), any `kind = "lib"` project containing a template-expansion sidecar (e.g. `lib/flang_parser` with `token.generated.f`)

In lib-mode (`flang -c build` on a project whose sources are globbed as
entries), a `x.generated.f` sidecar was loaded **twice**: merged into
`x.f`'s module by `combine_with_sidecar`, and *also* as its own entry
from the source glob. Both parses map to the same module FQN
(`module_fqn` derives it from the path), so `build_visibility` stored
two entries under one key and the sidecar's import-less set won —
`visible_by_module["flang_parser.token"]` ended up holding only the
prelude, and every `std.*` call in token.f reported E2004
("unresolved function `or_global`/`free`"). Build-mode (BFS from an
entry point) never loads the sidecar as its own module, which is why
`bootstrap` self-checked clean while `flang -c build` inside
`lib/flang_parser` failed — even a comment-only sidecar triggered it.

**Fix:** `glob_sources` (project.f) now excludes `*.generated.f`
outright — sidecars are only ever folded into their origin module by
`combine_with_sidecar`. The equivalent local skip in `seed_stdlib`
(driver.f) became redundant and was removed; every source enumeration
(project entries, stdlib seeding) routes through the one filter.
Verified: `flang -c build` passes standalone in every lib project and
the bootstrap self-check still reports 98 modules, 0 errors. No
colocated unit test: `glob_sources` needs fixture files and the fs API
had no mkdir/remove at the time; the standalone lib-project checks are
the regression surface. (`mkdir`/`mkdir_p` landed 2026-08-25 — see the
entry below — so a fixture-based test is now possible; `remove` is still
missing, so the fixtures would have to be left on disk.)

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

**Fix:** a structural-specificity tie-break in overload scoring, in the
reference (`HmTypeChecker.Expressions.cs SignatureSpecificity`) and the
self-hosted checker (`resolve_overload`). Regression:
`tests/harness/stdlib/list_deinit_frees.f` asserts real dealloc counts.

**Follow-up (2026-08-20):** the tie-break was ranked *after* quantifier
count, so it only fired when var counts happened to tie (as in the deinit
pair, 1 var each). Any structured generic with more vars than a catch-all
still lost — `any(&Dict($K,$V), $F)` (3 vars) lost to std.iter's
`any($I, $F)` (2 vars), breaking every dict method call in a module that
imports both `std.dict` and `std.iter`. Specificity is now the **primary**
key in both compilers (specificity → cost → quantifier count → literal
preference → declaration order), and the self-hosted `resolve_overload` —
which had never actually gained the specificity key despite the entry
above — now has it (`scheme_specificity`/`ty_specificity` in checker.f).
Two guards make the key sound: only supplied positions are scored (a
defaulted param the call omits can't out-rank an exact shorter overload),
and only positions whose argument type is fully known are scored — an
argument still containing an unresolved var (unsuffixed literal,
half-inferred aggregate) unifies with anything at zero cost, so scoring
it steered `s[0]` to `op_index(String, Range(usize))` over
`op_index(String, usize)`. In the same pass, UFCS receiver adaptation
(value ↔ `&T`) moved *inside* resolution as a per-candidate alternate
receiver (+1 cost) in both compilers — the old adapted-retry second pass
let a catch-all matching the un-adapted receiver preempt a more specific
`&`-receiver method. Making list-element cleanup real for tuple-element
lists also exposed that the self-hosted `T → Type(T)` rtti coercion
rejected tuples (`size_of((A, B))` in `free($T[])` instantiations);
`coercion.f try_nominal_to_type` now accepts them, matching the
reference. Spec §Imports updated.
Regression: `tests/harness/generics/overload_structural_specificity.f`,
plus checker.f test "structural specificity outranks quantifier count".

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

## Self-host: `#inline` does not inline

The self-hosted pipeline parses and accepts the `#inline` directive but no pass expands or splices
the annotated function: it is emitted and called like any other. (The FIR shim inliner exists -
RFC-015, `shim_inliner.f` - but is not wired into `build_program`, and it selects by size, not by
the directive.) Observed 2026-08-27 via the profiler acceptance suite (`tools/profiler_check`): an
`#inline` function still appears in a `-p` profile with its own call counts. Cost today is
per-call overhead on functions the author asked to disappear; behavior is otherwise correct.

## Self-host: indexing a reference-typed struct field

**Open (2026-08-23).** `ctx.modules[i]` where `modules: &List(Module)` is a struct field lowers to a gep from the *field's address* with the element stride (`(uint8_t*)&ctx->modules + i * sizeof(Module)`): the `&List` pointer is never loaded and `op_index_ref` is never called. Indexing the same list through a local (`const mods = ctx.modules; mods[i]`) lowers correctly. Found in `template_expand.f:resolve_type_decl`; worked around there. Likely the value-form index receiver path in `lower_index_arg` treating a `&`-typed field step as the place itself (the sibling of the "`&`-typed path step geped into the field" fix of M11).

## Reference: file-private functions with identical signatures collide across modules

**Fixed (2026-08-23).** Every non-foreign, non-`main` function's C symbol is now module-qualified: the checker stamps `FunctionDeclarationNode.ModulePath` at signature collection and codegen mangles `SymbolBaseName` (`module.path.name`) everywhere (decls, calls, fn-pointer refs, iterator-protocol and operator dispatch, specializations). Original report: Two `fn` (non-pub) functions in different modules with the same name and parameter types emit ONE C symbol (`append_escaped__ref_struct_std_string_builder_StringBuilder__struct_core_string_String__ret_void`) — the mangle does not qualify private functions with their module path, and emission dedupes by symbol name, so one module's body silently replaces the other's. Found when `flang_parser/template.f`'s private `append_escaped` (string-literal escaping) replaced `flang_driver/symbol_table.f`'s private `append_escaped` (mangle underscore escaping) in the bootstrap build: every self-host spec symbol lost its `_0` escapes and the `size_of` intercept went dead. Worked around by renaming. Fix: include the module path in the reference's C name mangling for non-pub functions (the self-host's `symbol_table.f` already does).

## Self-host M12: return-only type parameters

**Fixed (2026-08-24).** A generic whose type parameter appears only in
the return type — `to_list(it: $I, …) List($T)`, `max(it: $I) $T?`,
`map(self: Option($T), f: $F) Option($U)` — has nothing at the call site
to pin it; the template BODY derives it. The self-host queues a
`PendingSpec` and drains it once inference has settled, which used to
break in two ways. Three changes closed them:

- **Shallow readiness** (`pending_ready`), reference parity: only a type
  that IS a bare var blocks instantiation. `List($T)` does not, so
  `to_list` instantiates and its body derives `$T` from the iterator it
  drives. The previous deep test refused and reported E2001
  (`stdlib/dict_iter_chain.f`).
- **`zonk_specializations`**, a final program-wide re-zonk of every
  stored specialization signature. A nested instantiation can finish
  before its CALLER's body pins a type argument it inherited
  (`list(0, allocator)` inside `to_list`), so its own end-of-`instantiate`
  re-key ran too early — and lowering mangles the C symbol from those
  types while `sig_lowerable` gates on them. The reference gets this for
  free by mangling at codegen.
- **Parked calls** (`PendingCall` / `resolve_pending_calls`). Between a
  return-only call and its drain, the still-open var could arbitrate an
  UNRELATED overload: `const mapped = opt.map(extract)` left `$U` free,
  and `println(mapped.unwrap())` then picked `println(u8)` by
  declaration order, so `map`'s instantiation reported E2071
  (`expected u8, got i32`) inside `stdlib/std/option.f`
  (`generics/option_map_enum_repro.f`). Now an exact overload tie broken
  by an argument that is a bare open var does not commit at all: the
  call parks, and `resolve_pending_calls` redoes it after the
  specialization drain, when the argument has its real type. A tie
  broken by an unsuffixed LITERAL still reports E2011 — a literal has no
  preferred type and nothing later settles it — and a parked call whose
  argument never settles reports E2011 too.

`drain_pending_specs` also runs to a fixpoint now: one pick's type
arguments can be settled by a later pick's instantiation.

Rejected on the way: **instantiating eagerly at the call**, which is
what the reference does. Re-entering the checker mid-expression nests a
generalisation level inside the caller's, and unrelated `xs.push(v)`
arguments across the stdlib start typing as `Type(?)`. Masking the
caller's scopes with an env barrier did not change that, so the cause is
the level nesting, not name resolution. Parking the *consumer* instead
of hurrying the *producer* reaches the same answer without touching
inference order.

## Self-host M12: `getenv` read past a non-terminated key

**Fixed (2026-08-24).** `std.env.env(key)` passed `key.ptr` straight to
`getenv`, which reads to the first NUL. That is correct only for string
LITERALS (interned with a terminator); a `String` view into a larger
buffer — a source file, a parsed line — made `getenv` read the rest of
the buffer and return null. `#if runtime.env["PATH"]` took exactly that
path (the key is a view into the source), so every compile-time
environment lookup answered "unset". `env` now copies the key into a
NUL-terminated stack buffer.

## Self-host M12: `if (a) op b` stopped at the closing paren

**Fixed (2026-08-24).** `parse_if_expr` / `parse_while_loop` /
`parse_if_directive_condition_into` treated a leading `(` as a HEADER
wrapper: they ate it, parsed one expression, and demanded `)` — so
`if (a or b) and c { … }` reported "unexpected token `and`". The paren
is an ordinary grouped sub-expression; all three now parse the
condition with `stop_at_brace` and let `parse_paren_expression` handle
it (which also restores `stop_at_brace` inside the parens, where `{` is
a struct literal again).

## Self-host M12: cross-target builds lowered the host's `#if` branch

**Fixed (2026-08-24).** `lower_program` hard-coded `comptime = host_ctx()`,
so a `--target-os linux` build type-CHECKED the linux branch of every
statement-level `#if` and LOWERED the macos one. The build's
`ComptimeCtx` is now threaded through `build_program` into `LowerCtx`.

## Self-host M12: negative enum tags lost their sign

**Fixed (2026-08-24).** `project_enum_variant` captured the integer
token of `Less = -1` and dropped the `-`, so `core.cmp.Ord` projected as
tags `1, 0, 1`. Nothing read `explicit_tag` before M12's duplicate-tag
check (E2048), which is how it surfaced. The projector now wraps a
negated tag in a `Unary(Neg)` expression.

## Self-hosted `flang build` failed if `build/` did not exist

**Fixed (2026-08-25).** `flang build` in a project whose `build/` directory
was absent stopped with `build failed: I/O error while writing build
artifacts (<name>)`. Type checking and codegen both completed first — only
the artifact write failed, and the message named no path, so it read like a
disk error.

Root cause was the gap noted under the `glob_sources` entry: `std.io.fs`
had no `mkdir`, so the driver could not create its own output directory.
`std.io.fs` now exposes `mkdir` (single level) and `mkdir_p` (recursive,
idempotent), backed by `__flang_fs_mkdir` in `fs.c` (`mkdir(2)` on POSIX,
`_mkdir` on Windows). `c_backend.compile` calls `ensure_parent_dir` for
both the `.c` path and the executable path before writing.

Two notes for anyone extending this:

- `FsError` gained an `AlreadyExists` variant (tag 7). The tag order is
  wired into `fs.c`; new variants must be appended, never inserted.
- `mkdir_p` treats an existing *file* at any prefix as `NotADirectory`
  rather than success, so a name collision cannot be mistaken for a
  usable directory.

## Self-host: `[v; N]` refuses a named-const length

**Status:** Open (found 2026-08-25)
**Affected:** self-hosted backend, any stdlib module with a sized scratch buffer

`let buf = [0u8; 4096]` lowers. `const CAP: usize = 4096` followed by
`let buf = [0u8; CAP]` refuses the entire enclosing body with
`body refused (unsupported construct)`, and every caller of that function
then fails to link with an undefined symbol.

Found by tidying three literals in `std.io.fs` into `FS_PATH_BUF_CAP`, which
silently dropped `mkdir_p`, `rename` and `with_c_path` from the build; the
first symptom was a linker error about `main`, several layers away from the
cause. The reference compiler accepts both forms, so `flang-ref` builds and
the colocated stdlib tests pass — only the self-hosted stage fails.

This had been costing coverage before anyone noticed: `read_all_inplace` in
`std.io.file` wrote `let buf = [0u8; PAGE_SIZE]` and had been on the refused
list for as long as the list has been printed. Spelling the length as a
literal during the std.io reorganization cleared it, and the self-hosted
compiler now refuses **no** bodies in the stdlib corpus (the `-v` skip list is
empty).

Workaround: spell the length as a literal. `std.io.fs` keeps the constant for
its bounds check and repeats `4096` in the array literals, with a comment
tying them together.

Two things worth fixing beyond the lowering itself: the refusal should name
the construct's source location, and a refused body whose symbol is
referenced should be a build error at that point rather than a link failure.

## `std.io.fs` return codes collided with `<unistd.h>`

**Fixed (2026-08-25).** `fs.c` defined `R_OK`/`R_EOF`/`R_ERR` as 0/1/2.
Adding `#include <unistd.h>` for `unlink`/`rmdir` pulled in POSIX's own
`R_OK` — the `access(2)` read-permission bit, value **4** — which redefined
the macro for every function below the include. Success was reported as
failure, so `mkdir` created the directory and then returned `NotFound`
(status 4 was not `FS_R_OK`, and the untouched `out_err` still read 0, which
is the `NotFound` tag).

The shim's own macros are now `FS_R_*`. The same rename was applied to the
FLang-side constants, since module-scope `const` shares one global namespace
across the whole program (`PATH_BUF_CAP` in `std.path` and `std.io.fs`
collided the same way earlier in the session).

Related: the `#ifndef ENAMETOOLONG` / `ENOSYS` / `ENOTEMPTY` fallbacks that
invented numeric values were removed. Those numbers differ per platform
(ENAMETOOLONG 36 on Linux, 63 on macOS; ENOSYS 38 vs 78; ENOTEMPTY 39 vs 66),
so a guessed constant either maps the wrong error or duplicates a real case
label. The switch now guards each label with `#ifdef` instead.

## Qualified enum variants do not resolve through a transitive import

**Status:** Open (found 2026-08-25)
**Affected:** module resolution, both compilers

A type declared in module `A` and re-exposed by importing `B` (which imports
`A`) is usable transitively in annotations and in match patterns, but *not* in
qualified variant position:

```flang
import b            // b imports a, which declares `Colour`
const c: Colour = pick()          // ok
c match { Red => ..., Blue => ... }   // ok
if c == Colour.Red { ... }        // error[E2004]: unknown identifier `Colour`
```

The three forms should agree. Until they do, a module that declares an enum
other modules re-expose has to be importable by callers, which is what forced
`FileKind` / `FileInfo` / `FsError` out of `std.io.internal.fs` and into the
public leaf module `std.io.types`: without that, using `FileKind.Dir` would
require importing an internal module.

Reproduced with a three-module fixture (`main -> mid -> leaf`); the annotation
and the match both resolve, only the qualified access fails.

## Lambdas: two capture-resolution bugs

**Status:** Open (found 2026-08-25)
**Affected:** closure construction, reference compiler (the self-hosted stage never gets that far)

Both surfaced while routing every path-taking syscall in
`std.io.internal.fs` through one `with_c_path` helper. Type checking passes in
both cases (`flang build --check` is clean); the failures are at closure
construction.

**1. A module-level `const` named inside a lambda is treated as a captured
local.**

```
error[E0000]: internal compiler error: Captured local `FS_PATH_BUF_CAP` not
found at closure construction site
```

Module constants are not locals and should never enter the capture set.

**2. A capture referenced inside a match ARM BODY does not resolve.** The same
capture in the match *scrutinee* is fine, which is what makes this confusing.
`?` lowers to a match, so `f(capture)?` fails the same way.

```flang
fn run(op: $F) $T { return op() }

fn scrutinee(x: i32) i32 {          // ok
    return run(fn() i32 {
        const o: i32? = Some(x)
        return o match { Some(v) => v, None => 0 }
    })
}

fn arm(x: i32) i32 {                // error[E3002]: Unresolved identifier `x`
    return run(fn() i32 {
        const o: i32? = Some(1)
        return o match { Some(v) => v + x, None => 0 }
    })
}
```

Neither depends on the lambda having parameters, on the generic returning
`Result($T, E)` versus a bare `$T`, or on the capture being a parameter versus
a local — all four combinations were tried.

Workarounds, both used in `raw_open` and `raw_realpath`: reference a capture
only from straight-line expressions and branch with `if ... { return Err(...) }`
instead of `?`; and use `buf.len` instead of a module constant. Lambdas that
capture nothing (`raw_opendir`, `raw_stat`, `raw_mkdir`, ...) use `?` freely.

---

### `Dict` Probing Divided Instead of Masking — RESOLVED

**Status:** Resolved 2026-08-25
**Affected:** `stdlib/std/dict.f` (every probe loop), `stdlib/core/hash.f`

`Dict` capacity is always a power of two, but every probe step computed
`(h + i) % self.cap` - a 64-bit hardware divide per step, on every lookup,
insert and removal. Integer keys also hashed through the generic FNV-1a byte
loop in `core/hash.f`, which walks `size_of(T)` bytes with a multiply each.

The checker is dict-bound: node types, resolved targets, resolved operators,
the FQN and name indexes, and (since RFC-022 phase 1) both id registries.

**Fix:** `probe_slot(h, i, cap)` masks with `cap - 1`; `ensure_capacity` carries
the power-of-two invariant it depends on. `core/hash.f` gained `u32` / `u64` /
`usize` / `i32` / `i64` overloads over SplitMix64's finalizer - one mix instead
of four to eight FNV rounds, and a better spread for the counter-like keys the
compiler actually uses (registry ids, `NodeId` span fingerprints, `VarId`).

Both change which slot a key lands in, so every `for entry in dict` iteration
order in the compiler shifted. Verified against the stage-2 = stage-3
byte-identical fixpoint, the harness, and the colocated suites.

**Measured:** three compilers - before RFC-022 phase 1, after it, and after this
fix - each checking the same fixed source snapshot (the 104-module compiler plus
stdlib), runs interleaved, six rounds. Medians: 911 ms, 913 ms, 823 ms. The
registries moving to `Dict` was free; this fix is about 10% off the whole check.

Interleave A/B compiler benchmarks on one input rather than measuring each tree
in turn. Sequential measurement of the same three binaries drifted far enough
(863 / 947 / 799) to invent a 10% regression that was not there.

---

### Conditions Were Not Parsed As Ordinary Expressions - RESOLVED

**Status:** Resolved 2026-08-25
**Affected:** `src/FLang.Frontend/Parser.cs` and `lib/flang_parser/src/parser.f`

An `if` / `while` / `for` header is keyword, expression, block. Both parsers got
that wrong in two different ways.

The reference special-cased a leading `(` as a "parenthesized condition": it ate
the parens, parsed the inside, then demanded the body brace. So a condition that
merely *started* with a group was rejected:

```flang
if (a + b) * 4 > 6 { ... }        // was error[E1002]: expected `OpenBrace`
while (a + 1) * 2 > 3 { ... }     // was error[E1002]: expected `OpenBrace`
```

Both parsers then mishandled the brace-suppression flag. `_stopAtBrace` /
`stop_at_brace` exists so the body brace is not read as a struct literal or a
block while the header is being parsed. That is ambiguous only at the header's
own nesting level - inside `(...)`, `[...]` or `{...}` a brace cannot be the
body brace, because the delimiter has to close first. Both parsers cleared the
flag in one or two places rather than on every descent, so a struct literal
anywhere else in a header failed:

```flang
if take(P { x = 1 }) > 0 { ... }        // was error: expected `CloseParenthesis`
if xs[take(P { x = 1 })] > 15 { ... }   // same
```

**Fix:** one entry point per compiler parses a header expression
(`ParseCondition` / `parse_condition_expression`) with no special case for a
leading paren, saving and restoring the flag instead of clearing it. A scope
guard suspends the flag for every delimited sub-parse - grouped and tuple
expressions, call arguments, array literals, index subscripts, struct and
anonymous-struct construction, block expressions, match arms, interpolation
holes. C# uses a `ref struct` with `using`; FLang uses
`suspend_brace_stop` / `restore_brace_stop` with `defer`.

Regression test: `tests/harness/control_flow/condition_is_expression.f`, which
also holds the line that a bare identifier iterable (`for v in xs {`) still does
not swallow the body brace as a struct literal.

---

### Self-Host: Type Names Resolve Transitively Through a Plain Import

**Status:** Open — self-host/reference divergence, self-host is wrong
**Affected:** `lib/flang_typer/src/visibility.f` / `nominal_registry.f` lookup path

`docs/spec.md` §6 is explicit: plain imports are non-transitive, and a symbol is
visible in M only if it is defined in M or is `pub` in a module reachable from M
via `import` plus the **`pub import`** transitive closure. The self-hosted typer
resolves a *type name* one hop further than that: a module that plainly imports
B can name a `pub type` that B itself plainly imported from C.

Found via `tests/harness/fs/stat_basic.f`, which named `FileKind` while
importing only `std.io.fs`. The reference rejected it (`Unknown type FileKind`,
with the "exists but is not visible" hint); the self-hosted compiler accepted
it. The stdlib was at fault too and is fixed — the io modules whose public API
names the shared vocabulary now `pub import std.io.types` — but the typer is
still more permissive than the spec, so a project can depend on visibility the
reference will reject.

Function lookups are not affected; this is the nominal/type path only. Enum
variants already require the declaring module to be imported directly, which is
why the divergence went unnoticed.

---

### Self-Host: Lowering Emits Every Function, Not Just Reachable Ones

**Status:** Open — blocks cross-target builds on a host with a different libc
**Affected:** `lib/flang_driver/src/lower.f`

The self-hosted driver lowers every function of every seeded module. The
reference emits only what `main` reaches. For a trivial program the gap is
145 lines of C against 65,703.

That is mostly a size and compile-time cost, but it is a hard failure for a
cross-target build. `seed_stdlib` seeds the whole stdlib regardless of imports,
so `flang --target-os linux build` on Windows lowers the POSIX branch of
`std.terminal::get_terminal_size` and `std.readline::enable_raw`, and the host
toolchain then cannot link `ioctl` / `tcgetattr` / `tcsetattr`. This is the only
remaining self-host harness failure:
`tests/harness/directives/if_directive_cross_target.f`.

**Fix:** a reachability pass over the call graph before emission - mark from the
roots (`main`, `#foreign`-exported functions, const init functions), sweep the
rest. `drop_callers_of_refused` in the same file is the same shape of fixpoint
over the call graph and is the place to model it on, but the marker has to
follow every reference to a symbol, not just `Call.callee` and
`Store(FuncRef)`: a missed reference drops a live function. RFC-022 §7 builds
the same reachability query in the checker for W1003; the two want the same
edges.

## Module-level `const` arrays never register

A file-scope `const XS: [i32; 3] = [1, 2, 3]` is accepted by the parser but
the constant never reaches the environment: every use site reports E3002
`Unresolved identifier`. Function-scope `const` arrays work, including
`for x in xs` iteration through the array's decay to a slice. Workaround:
declare the array inside the function that uses it.

## Reference: `for &x` over a local bound to `&List(T)` borrows the local, not the list

**Affected:** C# reference compiler only - the self-hosted compiler
lowers the same program correctly.

A by-reference for-loop whose iterable is a LOCAL holding a reference to
a list (`let lst = d.get_ref(k).unwrap()` then `for &x in lst`) lowers
the `iter_ref` call with the local's own address, so the callee receives
`List**` where it expects `List*` and iterates garbage. Depending on the
C compiler's warning flags this is either a C4047 compile failure
(levels of indirection) or, in the compiler's own stage-1 build, a clean
compile that segfaults at runtime.

A `&List` PARAMETER iterates correctly (`for &d in dst` where
`dst: &List(Diagnostic)`), as does a field expression rooted at a
reference (`for &d in entry.collect`). Only the plain local binding
mis-lowers. Until the reference compiler is fixed, compiler sources
avoid the shape: index (`for j in 0..lst.len`) or iterate by value.

Regression test (green under the self-hosted compiler; the reference
compiler trips it): `tests/harness/iterators/iter_ref_through_reference_local.f`.

## Self-hosted: mutation through a field chain that crosses a reference does not stick

The reference compiler's two-hop receiver bug (above) has a self-hosted
sibling. A mutating UFCS call whose receiver is a field path that either
starts at a LOCAL value struct (`eng.interner.tuple_of(...)`) or crosses a
reference-typed field (`ctx.result.interner.nominal_of(...)` where
`result: &TypeCheckResult`) receives a copy of the receiver struct, so
header mutations (a `List` len bump, a `Dict` rehash) land in the copy and
are lost. Reads work, which is what makes it silent: an interner reached
this way hands out node ids past the table it never grew, and the next
`node(id)` read panics `List: index out of bounds` far from the cause.

Two shapes hit during RFC-024 and both are worked around at the call site:

- `Engine` tests bind `let it = &eng.interner` and call through the
  reference (one hop).
- `LowerCtx` carries `it: &TypeInterner`, a DIRECT reference to
  `result.interner`, and every interning call in lowering goes through it.

A receiver that is a value-field chain rooted at a single reference
(`self.engine.interner...` from `self: &Checker`) works. Fix the lowering
of member-path receivers (the reference compiler's fix is the model), then
drop the `LowerCtx.it` field.

## Self-hosted: repeat array literal over 64 elements silently dropped the module - RESOLVED

**Status:** Resolved - fill loop instead of a count cap; a skipped
`main` is now a build error
**Affected:** `lib/flang_driver/src/lower.f` (array literal lowering)
and `lib/flang_driver/src/compile.f` (build driver)

A non-zero repeat literal (`[7; N]`, `[fill; N]` - the zero form was
always one memset) lowered as N unrolled stores and deliberately
refused above 64 elements through the subset gate, which skipped the
enclosing function and, transitively, every caller including `main`.
The build then failed at link with "entry point must be defined" and no
diagnostic. The reference compiler handled any length.

Two fixes:

- `lower_array_lit` emits one fill loop for any non-zero repeat (the
  induction variable rides a block parameter, the same shape
  `for i in a..b` lowers to), so the cap is gone; aggregate repeat
  values fill via memcpy in the same loop.
- `build_program` rejects a module whose `main` was skipped, printing
  the refusal chain (each skip note, following "calls undefined" links
  to the leaf) before the linker ever runs. Skipped functions from the
  project's own modules print a warning on every build, `-v` or not;
  only stdlib-frontier skips (symbols mangled from `std.*` / `core.*`)
  stay behind `-v`. Unreached skipped functions still link fine, which
  is the milestone design.

Regression test: `tests/harness/arrays/array_repeat_large.f` (constant
fill past the old cap, runtime fill at 4096, non-byte elements, zero
form).

## Enum construction left padding bytes uninitialized - RESOLVED

**Status:** Resolved - zero-fill at every aggregate construction site
**Affected:** `FLang.Semantics/HmAstLowering` (reference) and
`lib/flang_driver/src/lower.f` (self-hosted)

Struct construction zero-filled its alloca before the field stores, but
enum construction did not: both compilers alloca'd the slot and stored
only the tag and payload. The 4 padding bytes between the i32 tag and an
8-aligned payload, and the unused tail of smaller variants, kept stack
garbage. The generic byte-wise `hash` in `core.hash` folds every byte of
the value, so equal Option/enum values could hash differently depending
on what the stack held - a Dict keyed on such values could miss existing
keys and store duplicates. Field-wise consumers (match, `==` via
`op_eq`, `#derive(T, hash)`) never read the bytes and were unaffected.

In the reference compiler the closure-capture struct was already
zeroed; in the self-hosted compiler the nullary-variant and None paths
were zeroed but the payload-variant path, closure captures, and tuple
literals were not. All construction sites now go through a shared
zero-filling helper (`EmitZeroedAlloca` in the reference; explicit
memsets in `lower.f`). Spec 4.2 now states the guarantee. Regression
test: `tests/harness/enums/enum_padding_hash.f` (hashes an Option, a
payload variant, and a naked variant under two different stack fills).

## Self-hosted: repeated full analyses in one process degrade far beyond the leaked bytes

Running several `analyze_project` calls in one process - a fresh `AnalyzedProject` each time, full
stdlib module set, unit deinited between runs - slows down sharply per round: inside a `flang test`
runner process the fourth such analysis took minutes where a fresh process takes ~1-2 s. The known
per-cold-check leak (~129 MB, see the retirement/leak entry above) explains the retention but not a
>100x slowdown; candidate mechanisms are allocator behavior over a very large live heap and paging.
`FLANG_REDEMAND` is a different path (it reuses one `AnalyzedProject`) and does not degrade this
way. Matters for RFC-023: an LSP process runs many analyses over its lifetime. Observed 2026-08-27
while writing the W1004 tests in `lib/flang_analysis/src/unused.f`; those tests now analyse a
two-file fixture (`fixtures/leaf.f`) instead of the stdlib, which sidesteps it in the suite.

Prime suspect, from reading the code: under `runtime.testing`, `or_global` routes every allocation
through the test allocator, whose `dealloc` (`stdlib/std/allocator.f::test_dealloc`) walks an
intrusive linked list of ALL live allocations to find the entry to unlink - O(live) per free,
O(n^2) per teardown. With ~129 MB retained per prior round, by round four every free scans millions
of entries, which is exactly a >100x in-process slowdown that a fresh process does not show.
Unverified by measurement; `flang -p build` (the RFC-025 profiler) on a loop of
analyze+deinit rounds would confirm it in one run. Fix candidates: key live entries by pointer in a
`Dict`, or drop per-allocation tracking for size classes that dominate.

## Exact `String` overload lost to an implicit `String -> u8[]` coercion - RESOLVED

**Status:** Resolved - implicit-conversion count is now the primary overload ranking key (both checkers)
**Affected:** `FLang.Semantics/HmTypeChecker` and `lib/flang_typer/src/checker.f` overload scoring

With `fn write(file: &File, value: String) Result((), FileError)` beside the
Writer vtable shim `fn write(self: &File, data: u8[]) usize` (both in
`stdlib/std/io/file.f`), the call `write(&f, "text")` resolved to the `u8[]`
shim and silently returned `usize` instead of `Result`. Root cause: ranking
put structural specificity above coercion cost, and specificity is a node
count of the parameter type - `Slice(u8)` (2) outranked the bare nominal
`String` (1) - so the exact match lost before cost was consulted. Conversion
count now ranks first; specificity only orders candidates that matched
equally cleanly, which preserves the catch-all cases specificity exists for
(`deinit(&List($T))` vs `deinit(&$T)`, adapted-receiver overloads). The UFCS
receiver adaptation and omitted-default penalties are not conversions and
stay out of the primary key. Regression test:
`tests/harness/ufcs/overload_exact_over_coercion.f`; `file.f`'s tests are
back to positional calls.

## `flang test` dropped `test {}` blocks from any module with a generator invocation — RESOLVED

**Status:** Resolved — `testModules` built after template expansion
**Affected:** `FLang.CLI/Compiler.cs` (`flang test` block discovery)

`TemplateExpander.ExpandAll` replaces the `ModuleNode` of every module that
contains a `#generator(...)` invocation, but the set of test-eligible modules
was collected by node identity before expansion, so those modules' `test {}`
blocks were silently skipped - no error, just "fewer tests". In the stdlib
suite this had muted 66 tests (every module using `#interface`, `#implement`,
`#enum_utils`, or `#derive`, e.g. `encoding/json.f`, `io/reader.f`,
`io/file.f`). Membership is now recorded as entry-input source paths and
resolved to module nodes after expansion. The unmuting surfaced the rotted
`file.f` write-overload calls fixed via the named-argument workaround above.

## Reference: `as` cast fails when the operand's type is still an inference variable

**Status:** Open
**Affected:** `FLang.Semantics/HmTypeChecker` cast typing

`const f = v.unwrap()` (with `v: f64?`) followed by `f as i64` reports
E2002 "expected i64, got f64" on the cast expression itself, in both let and
argument position. The same cast on a local whose type was written out
(`const f: f64 = v.unwrap()` and then `f as i64`) compiles. The cast appears
to be typed against the operand's unresolved variable rather than its solved
type, so a cast whose operand comes straight out of a generic call mis-checks.
Workaround: pin the operand with an annotated binding before casting -
`lib/flang_lsp/src/server.f::get_i64` does this. Repro shape:

    fn take(v: f64?) i64? {
        const f = v.unwrap()
        const whole: i64 = f as i64   // E2002 until f is annotated
        return Some(whole)
    }

## `decode_char` truncated codepoints above U+00FF - RESOLVED

**Status:** Resolved - continuation bytes widened to u32 before shifting
**Affected:** `stdlib/std/encoding/utf8.f`

The multi-byte branches shifted `u8` operands (`(s[0] & 0x1F) << 6`), so the
shift happened in 8-bit arithmetic: every 3-byte codepoint and most 2-byte
codepoints decoded wrong, and 4-byte sequences decoded to 0 (widths were
right, values were not). The module had no tests; it does now, covering all
four widths, an encode/decode round-trip, and invalid-lead-byte recovery.

## Self-hosted: E2121 literal shift counts are checked only when the operand type is already pinned

**Status:** Open (parity gap, narrow)
**Affected:** `lib/flang_typer/src/checker.f` (`shift`)

The reference validates literal shift counts post-inference
(`ValidatePostInference`), so `let x = 1 << 40` caught later as `u8` still
reports E2121. The self-hosted checker validates at the shift node and skips
when the left operand is still an open variable there, because threading a
new pending list through the per-slot literal sweep and its replay bookkeeping
(`lit_tys`, `literal_flagged`) was judged not worth it for that shape. The
divergence: a shift whose left operand is itself an unsuffixed literal (or an
unpinned generic) that later resolves to a too-narrow type errors under
`flang-ref` and passes under `flang build`. Shifts on typed operands - the
class that produced the `decode_char` truncation - are caught by both.
