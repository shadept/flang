# RFC-022: Demand-driven checker - declaration-level queries, incremental invalidation

**Type:** Compiler mechanism (typer)
**Status:** Proposed
**Depends on:** None
**Blocks:** RFC-023 (language server)
**Relates to:** ADR-0006 §4 (Jai message-loop shape - scoped to template
reactions, NOT to checker scheduling; see Design §8)

## Summary

`check_all` becomes a demand-driven graph of memoized queries at declaration
granularity, replacing six whole-program phases plus three global drains.

1. **Pull, not push.** `type_of(decl)` computes its dependencies recursively and
   caches. `flang build` demands everything; the LSP demands one module's closure.
2. **Declaration-level work units.** Bodies are 64% of a check and are the
   natural unit - a body is independently checkable once signatures exist.
3. **Lazy bodies.** A body nothing demanded is never checked. This is what makes
   editing this repo cheap; wholesale re-check is 8.8s.
4. **Invalidation is a revision bump** on the changed module. O(1). Stale entries
   recompute on next demand.
5. **Diagnostics are owned by the query that produced them**, cached and
   invalidated with it.
6. **W1003 unused-function** makes total demand a checked invariant rather than a
   trusted one.

## Motivation

Measured 2026-08-25, `flang -t --check build`, warm, median of three
(`CheckPhases`, phase 0 of this ticket):

| phase | `bootstrap/` (104 modules) | `examples/snake` / trivial file |
|---|---|---|
| read + parse | 611 ms (6%) | 185 ms (19%) |
| collect (visibility + nominal names) | 10 ms (0%) | ~0 ms |
| templates (generator expansion) | 61 ms (0%) | ~0 ms |
| nominals + signatures | 534 ms (6%) | 86 ms (9%) |
| constants | 6 ms (0%) | ~0 ms |
| **bodies** | **5642 ms (64%)** | **425 ms (45%)** |
| **specialize** (drains + pending calls) | **1494 ms (16%)** | **105 ms (11%)** |
| zonk (global final substitution) | 426 ms (4%) | 93 ms (10%) |
| **total** | **8797 ms** | **935 ms** |

Peak RSS: 486 MB for `bootstrap/`, 123 MB stdlib-only.

The collect row is two phases; 5a split them, so `CheckPhases` reports
`visibility_ns` and `collect_ns` separately and `-t` prints both. Visibility is
the larger half and still runs in full on every demand.



`examples/snake` and a trivial single file are indistinguishable - both are
stdlib-bound, because `seed_stdlib` seeds the whole tree regardless of imports.

Three readings that shape the design:

- **Parsing is 6-8%. Checking is 93%.** Caching that stops at the parse tier is
  worth 6-8%.
- **Bodies plus specialization are 80%.** Bodies are the obvious target;
  specialization at 16% is the harder one, because `drain_pending_specs` /
  `resolve_pending_calls` are exactly the program-wide fixpoints §2 has to
  decompose.
- **The pre-body barrier is ~611 ms on `bootstrap/`, ~86 ms on a small project.**
  That is the floor on "time until any type is available" under laziness, and it
  is small enough that per-module collection laziness is not needed.

Three structural facts make the current shape unusable for an editor:

- `check_all` runs only when the whole module set has **zero** parse errors
  (`checked = count_errors(&diagnostics) == 0`). One transient syntax error
  anywhere kills type information workspace-wide.
- `analyze_project` reads every module with `read_text(path)`. Open unsaved
  buffers are invisible.
- Results are all-or-nothing: registries are moved out and side tables reset on
  return, so there is no mid-flight state to query.

## Design

### 1. Query taxonomy

Coarse queries are per module, expensive ones per declaration.

```
  module_ast(module)              parse + project             -> Module
  nominal_names(module)           declared type names         -> [NominalId]
  nominal_body(decl)              fields / variants resolved  -> NominalDef
  signature(decl)                 collected scheme            -> FunctionScheme
  const_value(decl)               checked initializer         -> Ty + value
  body(decl)                      HM inference over one body  -> node types + edges
  specialization(template, args)  one instantiation           -> Specialization
  validate(project)               quiescence-only sweeps      -> diagnostics
```

Every query returns `(result, diagnostics)`. Diagnostics live and die with the
cache entry - see §5.

### 2. Phase barriers become dependency edges

Today's ordering is a correctness invariant, not incidental. Each barrier maps to
an explicit edge. Getting one wrong does not fail loudly; it reintroduces the
order-dependent bugs the phases exist to prevent.

| today's barrier | becomes |
|---|---|
| all type names registered before any body resolves | `nominal_body(d)` depends on `nominal_names(m)` for every m in scope |
| templates expanded before nominal resolution | `nominal_names(m)` depends on `expand(m)` |
| all signatures before any body | `body(d)` depends on `signature(x)` for every x it resolves |
| constants pinned before bodies observe them | `body(d)` depends on `const_value(c)` per const read |
| `zonk_specializations` program-wide | `specialization` re-zonks on demand, not on a final sweep |
| `validate_literals` (E2001) post-inference | `validate(project)` depends on the whole demanded set |

`validate(project)` runs only at quiescence and invalidates on any change. E2001
and any other whole-program sweep live there.

### 3. Determinism

Demand order is deterministic: **module import-topological, then declaration
source order**. Same rule RFC-021 fixes for the template worklist.

**Amended 2026-08-25.** A plain import-topological order does not exist. Import
cycles are a library-level rule (`docs/spec.md` §6): modules inside one library
may import each other freely, and three such cycles are load bearing -
`core.{rtti, slice, string}`, `std.{dict, list, string, string_builder,
string_reader}`, and `flang_typer.{checker, template_expand}`. A 5-module
strongly-connected component has no topological order.

So the order is the topological sort of the **condensation** - the DAG of
strongly-connected components - with components entered in FQN-lexicographic
order and modules ordered the same way inside one. For the acyclic majority
this *is* plain topological order; it only differs where the alternative was
undefined. Nothing here changes if the cycles are ever broken: every component
becomes a singleton and the rule degenerates.

The barriers §2 replaces are also what makes those cycles work today -
`collect_nominal_names` over every module before `resolve_nominal_bodies` over
any is what lets `core.string` and `core.slice` name each other. A query that
recursively demands its imports re-enters itself on any of the three cycles, so
the graph needs in-progress marking, and a re-entrant demand has to see the
placeholder the outer call already registered rather than recurse. That is the
same two-phase split, expressed as a cycle rule instead of a global barrier.

Emission order feeds the stage-2 = stage-3 byte-identical fixpoint. Lowering
currently iterates `specializations` positionally; after §4 it iterates in id
order, which preserves the fixpoint by construction.

### 4. Stable ids (prerequisite)

```
  NominalId          = self.defs.len    dense index into List(NominalDef)
  Specialization.id  = self.specs.len   dense index into List(Specialization)
```

Both are baked into other modules' results - every `Ty.Nominal(NominalRef{id})`
in every `node_types` cites one. Evicting a module renumbers everything after it.

Fix: monotone counters, dict-backed storage, tombstone on eviction. Consumers
that iterate positionally (lowering's one-function-per-specialization emission,
the `instantiated_types` RTTI table) iterate in id order instead.

Nothing else in the track can be tested until this lands.

**Landed 2026-08-25.** Both registries key their storage by id
(`Dict(NominalId, NominalDef)` / `Dict(u32, Specialization)`) off a `next_id`
counter, with `find` reporting a hole, `evict` retiring an id, and `len`
counting live entries. `TypeCheckResult.specializations` is the registry itself
rather than a moved-out `List`, so lowering and `symbol_builder` walk
`0..next_id` and skip holes - emission order is still first-need order. Moving
the whole registry also stops the old `by_key` dict being abandoned on the way
out of `check_all`.

Cost: none measurable. Three compilers - before this phase, after it, and after
the `Dict` fix below - each checked the same fixed source snapshot (the
104-module compiler plus stdlib), runs interleaved, six rounds. Medians: 911 ms,
913 ms, 823 ms. Moving `nominals.get(id)` from a list index to a hash probe is
free at this scale.

Putting a dict on that path is what prompted a look at `Dict` itself, which
probed with `%` on a power-of-two capacity and hashed integer keys through
FNV-1a over their bytes. Masking instead of dividing, plus integer `hash`
overloads, landed alongside this phase and took about 10% off the whole check -
it speeds up every dict in the checker, not just the registries. See the `Dict`
entry in `docs/known-issues.md`.

A dense `List` with tombstones would also have kept ids stable, but it grows
without bound in an editor session, where every re-check retires a module's
worth of ids.

### 5. Diagnostics ownership

A diagnostic belongs to the query that produced it and is cached with it. A cache
hit replays the cached diagnostics; invalidation drops result and diagnostics
together.

A global sink deduplicated by `(code, span)` was rejected: it survives cache hits
but not invalidation - nothing tells the sink which entries came from the query
being recomputed, so fixed errors never clear. Tagging sink entries by owner is
this design with a different storage layout.

Consequences:

- **Diagnostics are partial by construction.** A module with nothing demanded has
  *no* diagnostics, which is not the same as clean. Consumers must track the
  distinction. A module's diagnostics publish only once its own total demand
  settles.
- **Demand order is not source order.** Sort by `(file_id, start)` before
  publishing; the harness matches diagnostics textually.

### 6. Laziness and demand roots

| consumer | demand set |
|---|---|
| `flang build` / `flang test` | every declaration of every project module (total) |
| LSP foreground | open module's closure |
| LSP background | total project demand, at quiescence |

`flang build` must demand unreachable project functions too - they are still code
that must compile. Reachability is a separate graph query (§7), not a substitute
for total demand.

`checkTests`: the LSP checks `test {}` bodies, `flang build` does not - matching
the reference (`HmTypeChecker.Declarations.cs:426`), so test specializations stay
out of lowering.

### 7. W1003 unused function

New warning. Reachability over the resolution edges the checker already records -
`resolved_targets` (`RtFunction` / `RtSpecialized`), `ResolvedOperator.function_id`,
specializations. Because dispatch is recorded rather than name-matched, protocol
calls (`op_eq` from `Dict`, `iter`/`next` from a for-loop, `deinit`, operator
overloads) never false-positive.

Scope: the current project's own modules only. `analyze_project` already computes
`project_origin: List(bool)`.

Roots:

- always: `main`, `test {}` blocks, `#foreign`-exported functions
- `kind = "lib"`: every `pub fn` is a root (it is the API)
- `kind = "exe"`: `pub` is **not** a root - every function must be reachable from
  `main`

Rules: overloads are per-declaration, not per-name - one overload used does not
excuse its siblings. A `_`-prefixed name suppresses, matching W1001.

Needs a `docs/error-codes.md` entry and `NO-COMPILE-WARNING` harness tests from
day one; unused-detection is the classic source of false positives and the repo
has that metadata precisely as a regression guard.

### 8. What stays push

ADR-0006 §4's Jai message-loop shape is scoped to **template reactions over
checked declarations**, not to checker scheduling. The two compose: reactions
stay push and fire at quiescence, emit declarations additively, which dirty the
pull graph, which re-settles. Fixpoint preserved.

### 9. Data gaps closed here, not worked around downstream

| gap | consequence today |
|---|---|
| `Field` is `{name, ty}` - no `decl_span` | cannot jump to a field declaration |
| `VariantDef` is `{name, payloads}` - no `decl_span` | cannot jump to an enum variant |
| `NodeId` is a lossy fingerprint (start 32b, length 16b, file 16b, clamped) | cannot invert to a span; `RtLocal(NodeId)` is unresolvable without a map |
| `file_id -> path` lives in `AnalyzedProject`, not `TypeCheckResult` | result is not self-describing |

Add `decl_span` to `Field` and `VariantDef`, a `NodeId -> SourceSpan` map to the
result, and move `file_id -> path` into `TypeCheckResult`.

**Landed 2026-08-25.** `Field` and `VariantDef` each carry a `decl_span`,
taken from the AST declaration and `none_span()` for the fields the checker
synthesizes (closure captures). Both are metadata: `equals` and `format`
ignore them, so a record type still compares and keys the same way, and
`specialization.key_for` is untouched.

Every id the checker mints now goes through one helper, `checker.node_of`,
which records `(id, span)` in `InferenceResults.spans` on the way through and
lands as `TypeCheckResult.spans`. Inverting the fingerprint arithmetically
was rejected: the encoding clamps a span past 64 KB or a file past 65535, so
a decode is right for most nodes and silently wrong for the rest, and a
consumer cannot tell which it got. `get_span` reads the table.

`TypeCheckResult.file_paths` holds an owned copy of the per-file-id path
list `check_all` already received, so a span in the snapshot names its file
without the `AnalyzedProject` that produced it; `path_of` maps a `file_id`,
reporting unknown for the negative synthetic ids (`none_span`'s -1, the
checker's -2) and for a result checked without paths.

Gate A compares both new tables - `spans` entry by entry, `file_paths`
positionally, since file ids index it. Green across `bootstrap/`, every
`lib/*` and every `examples/*` that type-checks.

Cost: about +3.5% on a check. Two compilers - one recording spans, one with
`record_span` stubbed out - checked `bootstrap/` interleaved, six rounds
each. Medians 1019 ms and 985 ms. That is the price of one dict write per
minted id, and it buys the only exact inverse of the fingerprint.

### 10. Source overrides

`analyze_project` takes an override map (path -> buffer) instead of always
calling `read_text`. The LSP passes open buffers; `flang build` passes none.

**Landed 2026-08-25.** `analyze_project` gained an optional
`overrides: &Dict(String, String)?` ahead of its allocator, and the BFS reads
through `read_source(path, overrides)` rather than `read_text(path)`. A named
path yields a copy of the supplied buffer - the project owns whatever the AST
views into, and the override's storage stays the caller's. An unnamed path
falls through to disk unchanged, so `flang build` behaves exactly as before.

Keys are the forward-slash paths `resolver.normalize_sep` produces, which is
what the BFS queue holds. A caller that spells a key any other way misses
silently and gets the file on disk; there is no diagnostic for an override
nothing matched, because the loader never learns which paths a caller
expected to hit. Worth revisiting when the LSP is the one supplying them.

## Gates

The existing gates do not test any of this. The 551 harness tests and the
stage-2/stage-3 fixpoint both run **cold** - a graph that never reuses a cache
entry passes all of them.

**Gate A - equivalence.** For each module M in a project: dirty M, re-demand,
assert the resulting `TypeCheckResult` is identical to a cold `analyze_project`.
Compare `node_types`, `resolved_targets`, `resolved_ops`, specializations entry
by entry. Run across the 104-module compiler and the examples. This is the
incremental analogue of the stage fixpoint and the only thing that catches a
stale entry surviving an invalidation.

Written **before** the conversion starts, so each phase is verified as it moves.

**Landed 2026-08-25.** `lib/flang_typer/src/result_diff.f` holds the comparison
(`diff_results` -> `ResultDiff`); `flang --gate-a build` runs it. Types compare
by their canonical `format` rendering - the identity `key_for` already hashes on
- and ids compare by value, so a renumbered nominal is a difference even when
both ids name the same declaration. Dict tables need only equal sizes plus
one-directional containment.

Covered entry by entry: `nominals`, `specializations`, `node_types`,
`resolved_targets`, `resolved_ops`, `instantiated_types`. Covered by size only:
`functions`, `lambdas`, `closures`, `desugars`, `default_args`, `arg_lists`,
`receiver_derefs` - their values are AST pointers or nested lists, and a
renderer for each belongs with the phase that makes one of them incremental. A
size mismatch is still a hard failure; an entry that goes stale in place is what
those seven cannot see yet.

Before 5a the second pass was a full re-analysis, so what the gate proved was
determinism, which nothing else did: the harness and the fixpoint both run cold
and single-pass, and dict iteration order feeds emission order. Since 5a it
dirties modules and re-demands, so it tests invalidation as intended.

Green across `bootstrap/` (106 modules, 94478 node types, 2228 specializations,
411 nominals), every `lib/*`, and every `examples/*` that type-checks
(`examples/raylib` needs the raylib headers). 1.8 s on the compiler.

Three modules are dirtied per run - first, middle and last in demand order -
not each module in turn: a pass per module is one check each, and a check is
the whole 8.8 s. The middle and first entries are what put a recycled
declaration below other modules' ids instead of above them all, which is where
a re-registration that renumbered would show. The per-module sweep becomes
affordable once bodies are memoized (5d) and a dirtied module re-checks in a
fraction of a cold pass; run by hand at 5a it reported zero divergence over
every module of `bootstrap/` (106), `lib/flang_typer` (92) and
`examples/snake` (62).

**5a landed 2026-08-26 (`module_ast` half).** `analyze_project` builds an
`AnalyzedProject` that can be re-checked in place: `reanalyze(unit, ctx, dirty)`
re-reads and re-parses only the modules named in `dirty`, reusing every other
module's AST, then re-runs the checker. `flang --gate-a build` now dirties
modules and re-demands instead of analysing twice, which is what makes the gate
test invalidation at all.

On the compiler: **parse 127 ms cold, 11 ms re-demanded** - 11 modules of 106.
The gate prints both numbers, because reuse is otherwise invisible: the check
half still runs in full, so a cache that silently re-parsed everything would
produce an identical result and pass. Total analysis time is unchanged, as
expected - parsing is 6-8% of a check, and `nominal_body` onwards are still
eager.

Two constraints the conversion turned up, both found by the gate rather than by
reasoning:

- **A module that received generated declarations cannot be reused.** Expansion
  appends the chunk's decls into the origin module's AST, so a reused AST would
  stack a second copy on the next expansion. Those origins are always re-parsed
  (10 of the 11 above).
- **A result holds string views into the sources it was checked from** -
  nominal FQNs, field names - so a re-parse cannot free the buffer it replaces
  while an older result is still alive. Replaced sources are retired, not
  freed. The first version freed them and the gate reported nominals whose
  field names had decayed into fragments of unrelated text, which is exactly
  the failure mode it exists to catch.
- **Diagnostics split by tier.** `AnalyzedProject.parse_diags` holds what the
  parse tier produced - a module's parse errors, plus the load failures that
  have no module; `diagnostics` is that list replayed plus the current check's,
  rebuilt on every demand rather than appended to. The check half is still
  whole-program, so its diagnostics have no owner finer than the project and
  are regenerated entire. Neither tier has a per-module owner yet, which is why
  a project the parse tier reported anything about re-parses in full. §5's
  per-query ownership is what narrows that, at 5b and after.

  Until the split, `reanalyze` read the published list to decide staleness, so
  one warning anywhere re-parsed every module *and* published every diagnostic
  twice. Gate A caught the second half of that the moment it was pointed at a
  project with a warning in it - the count comparison is not decoration.

**5a completed 2026-08-26 (`nominal_names`).** `AnalyzedProject` owns the
`Checker`, and `begin_demand` readies it for the next demand instead of a
fresh one being built per check. Carried across: the declared type names and
the alias bodies keyed beside them. Dropped: everything a check computes.

What can carry is bounded by the engine. A resolved body names type variables
of the engine that inferred it, and that engine does not outlive its check -
so `placeholders_below` hands the next demand the declarations stripped back
to what collection produces (identity, visibility, span, directive flags) and
`resolve_nominal_bodies` fills them in again. Making bodies carry too is 5b,
and it is the engine's lifetime that phase has to solve, not the registry's.

Two mechanisms the conversion needed, both of them what phase 1's stable ids
were for:

- **A mark between the declared ids and the minted ones.** Generated
  declarations, anonymous record types and closure environments are all
  registered as nominals, by phases that still run in full - and their
  contents name engine variables. `Checker.declared_mark` is where the
  collection pass ended; only ids below it carry, and the ids above are minted
  again in the same order, so they land on the same definitions.
- **Retire, then re-register at the same id.** A module being collected again
  has its declarations taken out of the registry first, each id remembered
  against its FQN, and a declaration that survives goes back at the id it had.
  Without it a re-collected module's types would be renumbered above every
  other module's and Gate A would report a difference for each. Retirement is
  one pass over the registry for the whole set, not one per module: it is
  keyed by id and by FQN, and nothing indexes it by module.

An added declaration mints its id past the mark rather than in its module's
place, so the id sequence after a structural edit is not the one a cold check
produces. That is the wanted behaviour: numbering the new declaration where a
cold check would puts it ahead of every declaration below it in the file and
renumbers all of them, and an id-keyed table cannot survive that. The two runs
agree on every declaration; they disagree only on the numbering of what the
edit added.

What it costs is the oracle. Gate A asserts equality with a cold result, ids by
value, so it can only ever run over unchanged text - which is what it does.
Testing a real edit needs a comparison that reads through the ids, and the
demand-order rule alone will not supply one. Covered instead by
`analyze.f`'s `an edit adds, removes and leaves declarations alone`: it inserts
a declaration between two others, removes one, and names a removed type,
asserting each time that the declarations the edit did not touch answer to the
ids they already had. That is the property an id-keyed cache needs, and it is
the one a cold check does not have.

Measured on the compiler with three modules dirtied of 106: **collect 252 us
cold, 58 us re-demanded**. `CheckPhases.collect_ns` used to cover
`build_visibility` as well, which runs in full every demand and is the larger
half; the two are timed apart now (`visibility_ns`), or the reuse would have
read as 777 us against 567 us. Total analysis time is unchanged, as expected -
collection is 0.03% of a check.

**5b landed 2026-08-26 (`nominal_body`).** Resolved nominal bodies carry
across demands: a module the demand did not re-parse skips
`resolve_nominal_bodies` entirely, and its cached collect/resolve
diagnostics are replayed in the loop positions the passes would have
emitted them (the first piece of section 5's per-query diagnostic
ownership - it also fixes 5a's silent loss of a carried module's
collection diagnostics).

The two questions RFC-024 transferred here are answered:

- **(i) The table outlives a demand.** A carried body's `Ty` handles index
  the interner, so the table becomes one per project. Ownership stays
  linear rather than shared - FLang has no way to share a mutable struct
  across the moves `AnalyzedProject` makes - by threading the table
  forward: `check_all` ships it inside the `TypeCheckResult` exactly as
  before, and the next demand adopts it back out of that result
  (`take_interner` / `adopt_interner`), appends, and ships it with its own
  result. The table only grows, so an earlier snapshot's handles stay
  valid; `result_diff` renders both sides through the right-hand result's
  table for the same reason. Variable ids are reused across demands (the
  engine restarts at zero), so re-demands intern almost nothing new -
  var-citing nodes land on the nodes the previous demand made.
- **(ii) Record keys stay source views**, safe under the retirement rule
  the registry already relies on: `analyze.f` retires replaced sources
  rather than freeing them, and now retires each replaced
  `TypeCheckResult` the same way (`retired_results`, freed at unit
  teardown - which also ends the old behaviour of leaking the previous
  result on every re-demand).

What carrying a body requires is that every id it cites stays valid, so
the id-stability machinery phase 1 and 5a built extends to every
population the registry holds. The registry carries WHOLE
(`carried_copy`, a deep copy with bodies), `next_id` never rewinds, and
`recycled` becomes the single reclamation ledger: declared names (5a,
unchanged), generated chunk declarations (their origins are always
re-collected, so retirement already covers them), anonymous records
(their intern map and key buffers carry, so a re-encountered shape reuses
its id without touching `recycled`), and closure environments (rebuilt by
every body pass - `check_all` retires their ids on the way out,
remembered against their synthesized FQNs, and the next pass's
identically-ordered lambdas reclaim them). `declared_mark` is gone; the
mark-and-drop scheme it anchored is subsumed by retire-and-reclaim.

A carried body is valid only while the name set it resolved against holds
still. Three invalidation triggers fall back to resolving every body from
source, exactly a cold check: a name added (`register_collected` had no
retired id to reclaim), a name removed (a module retirement nothing
claimed), an alias changed. Alias change compares canonical spellings of
the retiring modules' alias bodies across re-collection
(`render_alias_body`); a body with no canonical spelling - an array
length that is neither a literal nor a named constant - conservatively
counts as changed. Verified by a checker test that edits an alias in one
module and asserts the dependent module's carried body re-resolves and
errors.

Two stand-ins keep a skipping demand observably identical to a cold one,
both found by Gate A rather than by reasoning: a skipped module still
mints its type parameters' fresh variables (anonymous-record keys render
variable ids, so anything downstream keyed by one depends on the engine's
variable stream) and their span nodes (the result's span table holds one
entry per minted id, and the gate compares it entry by entry).

Measured on the compiler with three modules dirtied of 106: **nominal
bodies 14.6 ms cold, 1.1 ms re-demanded**; the gate prints the pair.
Collection and parse reuse carry over from 5a unchanged. Signatures are
timed apart now (`signatures_ns`) so the bodies number is the phase this
step made incremental, not the pair.

Memory, same corpus (`--mem`): the interner holds **213,001 nodes after a
re-demand - exactly the cold count** - variable ids restart per engine, so
a re-demand's var-citing shapes land on the nodes the previous demand
made, and the "table does not grow across a re-demand" property RFC-024
had to defer now holds. A gate run (one re-demand) retains 668 MB against
458 MB cold: +210 MB per re-demand, down from the +292 MB RFC-024
measured, with the shared table and the retired-result bookkeeping
accounting for the difference. The bulk of the remaining retention is the
replaced result's body-tier tables, which is 5d's territory.

**5c landed 2026-08-26 (`signature` / `const_value`).** Function schemes
and constant types carry across demands: a module the demand did not
re-parse skips `collect_signatures` entirely, under the same validity
conditions as the carried nominal bodies (no name added or removed, no
alias changed - the pass resolves types against the same registries).

The function registry joins the carried set whole
(`function_registry.carried_copy`), and with it the id-keyed side tables
a scheme drags along: instantiation templates, declared parameter lists
(both AST views into kept modules), and deprecations. Id stability takes
a different mechanism than the nominals' FQN ledger, because overloads
make names non-unique and candidate ORDER inside one name is part of
resolution (scoring ties break by position): a re-running module's
entries are retired in place (`retire_module` - same slot, same id,
invisible to lookup), and its re-registrations reclaim the first retired
slot with a matching name and module, which pairs declarations by source
order. Retirements still unclaimed after the pass are removed
declarations; `purge_retired` drops them and their side-table entries,
and their ids are never reused.

What the pass records BESIDES its registrations is cached per module and
replayed on a skip (`ModuleSigCache`): the cached diagnostics (E2103,
E2070, deprecation warnings), the spans and node types of default-value
expressions (harvested from the demand's final zonked table, so the
facts are concrete), and the count of engine variables the pass minted -
burned on replay (`Engine.burn_var`, counter only: the carried table
already holds the nodes those variables named, and the pass minted them
at its own level, so interning again at the replay's level would grow
the table with orphan nodes). The burn is what keeps an unannotated
constant's carried variable naming the slot the constants pass binds,
and every later phase's variable stream identical to a cold check's.

A module whose pass produced anything beyond node types, spans and
resolved literals is not cacheable and re-runs every demand: a call or
operator in a default value (its resolved targets and possible generic
pick would need replaying into tables rebuilt per demand), a lambda, an
anonymous literal, an interpolation, or a literal still unresolved at
harvest (its E2001 re-emits per demand). Detected by watermarking every
such table around the module's pass. In this corpus the only defaults
beyond literals are `std.csv`'s `csv_options()` calls, so the fallback
is per-module and nearly never taken.

The cache is also anchored to its position in the variable stream
(`vars_at_start`): the carried handles are absolute ids, so a skip is
valid only while the module's burn starts where its pass once started.
An edit that changes an earlier module's signature-tier variable count
(a default literal added, a `$T` removed, an unannotated constant)
shifts every later position; without the check, a later module's
carried constant variable lands on whatever now owns its old id - an
earlier module's pinned default literal, say - and the constants pass
binds the wrong slot: a spurious mismatch when the types differ, a
silently borrowed pin when they happen to agree. The affected modules
re-run once and their caches re-anchor; modules before the edit skip
as usual. The skip decision therefore happens at each module's turn in
demand order, where the counter's value IS the module's start
position, and retirement moved inline with it - sound because a
module's registrations only ever collide with its own old entries
(constants are FQN-scoped, E2103 is same-module). Pinned by the
checker test "an upstream shift in the variable stream re-anchors a
carried constant", which fails without the check.

`const_value` needed no cache: registration carries with the signature
tier (the constants `FqnMap` is evicted per re-running module, like the
aliases), but phase 2.5 - checking every initializer - stays eager. It
is ~0.1% of a check, and re-running it is what keeps every exotic
initializer (a call, a generic pick, an anonymous literal) observably
cold-identical, including the binding of carried constant variables.

Gate A grew the oracle for it: the function registry is now compared
entry by entry (id, flags, rendered signature, overload order), where
before it was two size rows. One behavioural note: a re-running module's
default-value calls resolve against the full carried registry, where a
cold check's phase 2 sees only the modules before it in demand order.
Gate A found no divergence across the corpus - a default whose overload
choice depends on a later module's registrations is the pathological
case, and arguably the cold order-dependence is the bug.

Measured on the compiler with three modules dirtied of 106:
**signatures 108.3 ms cold, 16.2 ms re-demanded** (medians of five; the
gate prints the pair). Parse, collect and nominal-body reuse carry over
unchanged. Memory: the interner holds the cold count after a re-demand -
`burn_var` is what keeps the "table does not grow across a re-demand"
property 5b established, where interning burned variables at the
replay's level cost ~700 orphan nodes per re-demand in the first cut.

The conversion also surfaced a reference-compiler bug - `for &x` over a
local bound to `&List(T)` passes the local's own address to `iter_ref` -
which segfaulted the stage-1 compiler until the loop was indexed. Entry
in `docs/known-issues.md`; regression pinned at
`tests/harness/iterators/iter_ref_through_reference_local.f` (the
self-hosted compiler lowers it correctly).

**5d step 0 landed 2026-08-27 (per-module settlement slots).** Phase 3.5's
program-wide passes moved inside the phase 3 loop: a module's slot is its
bodies, then - over what those bodies parked - anonymous literals, overloaded
names in value position, the specialization drain, the parked calls, a second
drain, and the E2001/E2102/E2029 sweep of the literals the slot minted. The
literals minted before any slot (signature defaults, constant initializers)
sweep after every slot, because a body can be what pins an unannotated
constant's variable.

This is the enabler for the body cache, and the insight that makes 5d
tractable. Everything settlement assigns in encounter order - specialization
ids, closure-environment nominals and symbols (`next_lambda`), synthesized
nodes (`next_synth`), the RTTI list, engine variables minted inside
instantiations - was assigned in the order of one program-wide fixpoint over
every module's picks at once. A skipped module's replayed picks are concrete
(their engine bindings died with the demand that made them), so they are ready
in the fixpoint's first pass where a cold check's defer, and every
encounter-ordered assignment downstream of the reordering diverges from cold:
renumbered closure nominals, shifted RTTI positions, different spec ids. Gate A
compares all of those by value. Scoping settlement to one module at a time
removes the interleaving instead of trying to reproduce it: slot order is
demand order, so each assignment is decided per module, and a skipped module
can replay its whole slot in place.

Per-slot settlement is sound because bodies never share inference variables: a
body's variables entangle only with its own parked work and the instantiations
its own picks force. A later slot reuses an earlier slot's specialization by
key without re-checking its body, so no later activity can pin an earlier
slot's variables. Module-level constants are the one cross-body channel, and
phase 2.5 pins them before any slot runs - the exception is an unannotated
constant whose initializer leaves its variable open for a body to pin, which
5d must detect (an open constant variable after phase 2.5) and answer with the
global fallback, since a skipped body's pinning unification would be lost.

Observable changes, both deterministic: specialization ids and RTTI positions
now follow module order rather than global-fixpoint order (a pick that
deferred behind another module's instantiation no longer does), and E2001-tier
diagnostics interleave per slot with the pre-body ones last. Fixpoint,
harness, lib tests and Gate A (bootstrap, flang_typer, snake) all green.

**5d landed 2026-08-27 (`body`).** A per-module body cache
(`ModuleBodyCache`), replayed at the module's slot. Measured on the compiler
with three modules dirtied of 107: **bodies 1580 ms cold, 138 ms re-demanded**
(medians of three; the gate prints the pair, plus a `settle` pair for the
drains - 357 ms cold, 307 ms re-demanded, mostly re-instantiation, which is
5e's target). As landed:

- The capture window covers the slot through `resolve_fn_name_values`: every
  result-table recording (`InferenceResults` collects the KEYS while capture
  is on; values are harvested from the finished tables once the demand's final
  zonk has run, because the raw recordings cite engine bindings that die with
  the demand), the closure-environment registrations (recovered through the
  lambda table at harvest), the slot's diagnostics (a fourth tier in
  `ModuleNomDiags`), and the vars/synth/lambda counters at slot start plus
  their burns. An instantiation's overlay never captures - it is a different
  `InferenceResults` whose flag is off.
- The drains are NOT captured as facts: top-level `process_pending` logs each
  pick at process time - process-time zonks, in process order - and a replayed
  slot re-runs them in that order. Re-instantiation re-checks template bodies
  live, which re-pins the module's burned variables exactly as the cold drain
  did, so a pick whose binds were still open at its cold process time re-runs
  with the same openness (the openness decides resolution paths inside the
  template body, and with it what lands in the overlay versus the program
  tables). A slot whose drain reported an uninferable pick (E2001) is
  uncacheable - an unprocessed pick leaves no log entry to replay.
- Parked calls replay from copies zonked to the window's end;
  `resolve_pending_calls` and the second drain run live, regenerating their
  recordings, materializations and diagnostics. Slots end SEALED either way:
  parked work settlement could not resolve is abandoned, not handed to the
  next module's slot, which is what keeps a slot's cache self-contained.
- Pending literals never replay: the harvest re-runs the window's
  E2001/E2102/E2029 verdicts against the final types (`literal_flagged`, pure
  in text and type) and any that would diagnose marks the module uncacheable.
  Pending anons and fn-names do not replay either - their unifications bound
  dead variables, and their observable output (interned anon nominals,
  resolved targets) is carried registry state plus captured facts.
- Validity: the 5b `bodies_carry` conditions, plus a signature-tier
  fingerprint over the re-run modules - no scheme changed (compared at
  reclaim in the function registry, interned handles making it a field
  compare), no function added or purged, no constant added, removed or
  re-typed, no default value's source text changed (texts cached per module
  in `ModuleSigCache`; a scheme compare cannot see a value change), no
  resolved nominal definition changed (fingerprints snapshotted before
  retirement) - plus the per-module stream anchors (vars/synth/lambda at slot
  start), plus no module-level constant variable still open after phase 2.5
  (a body can be what pins one, and a skipped body's pinning is lost). Any
  global trigger re-runs every body, exactly a cold check.
- Retention: replayed desugar blocks, synth strings and default/argument
  expression lists live in earlier demands' results, which `analyze.f`
  retires instead of freeing - the body caches extend that dependence.

Verified: fixpoint, full harness (566/1/16 - the one is the documented
Windows cross-target link), typer 92/92 (five new 5d regressions: slot
replay of closures and specializations, body-tier diagnostic replay from the
cache, a changed field type re-running carried bodies, an upstream variable-
stream shift re-anchoring, a changed default value flagging the demand),
analysis 22/22, Gate A across `bootstrap/`, `lib/flang_typer` and every
`examples/*` that type-checks, plus the per-module sweep over `bootstrap/`
(each of the 107 modules dirtied in turn, one process per module -
`FLANG_GATE_DIRTY` selects the module by demand-order index or path).

Memory (`--mem`, compiler corpus): 503 MB cold (up ~45 MB - the caches), and
a gate run (one re-demand) initially retained +117 MB per re-demand, down
from 5b's +210 MB. Attacked further on 2026-08-27 (see the retirement note
below): now +38 MB per re-demand, and cold peak dropped 505 -> 384 MB.

**Retired results slim down (landed 2026-08-27).** What a replayed slot
actually cites from an earlier demand's result is its `synth_strings`
buffers (RtConst FQNs, desugared-AST name views) - the desugar blocks are
leaked global boxes, the carried registries own their FQN storage
(`register_at` re-fixes each def onto it), and the caches copy everything
else. So `slim_retire` frees a retired result's tables at retirement and
keeps the husk; `keep_retired_results` opts back into whole retention for a
caller that reads a pre-copy after the re-demand (gate A sets it).
Generation-stamping was rejected: a never-edited module's cache cites the
FIRST demand's result forever, so nothing would ever age out - slimming
works because the forever-cited part is kilobytes.

The probe that measured it stays: `FLANG_REDEMAND=<n>` re-demands the
project n times after analysis (`FLANG_REDEMAND_CLEAN` with an empty dirty
set, `FLANG_REDEMAND_EXIT` tears the unit down and reports before exit, so
live-at-exit is pure leakage). It split the +117 into ~43 MB of husk tables
(freed by slimming), ~14 MB of legitimate retention (retired sources and
ASTs of the always-re-parsed generator origins, husks), and ~60 MB of plain
leaks - and found the same leaks cold: 250 MB of a cold check's 503 was
unreachable after teardown. The dominant leak was the visibility set:
`current_visibility`/`fn_visibility` copy the module's visible-module set
per lookup - every named type, identifier, call and operator resolution -
and no checker call site freed it (the registry tests always did). Eighteen
`defer vis.visible.deinit()` later, plus freeing processed drain picks,
resolved parked calls and overwritten generic templates: cold leak 250 ->
129 MB, per-demand leak 60 -> ~24 MB. The residual is many small
per-work-unit drops; hunting it further wants an allocation-site-tagging
counting allocator, not more guesswork - see docs/known-issues.md.

**Where the remaining warm cost sits (measured 2026-08-27).** Dirtying a
single small module instead of the default three leaves warm bodies at
~110 ms - the replay floor, not re-inference: every demand builds a fresh
result, so replay is ~300k dict writes (plus fact copies) at near-dict
speed. Presizing the demand's tables to the previous result's sizes
(`table_caps` / `presize_tables`, landed) bought roughly nothing
(reallocs 1042k before, 1044k after) - rehash growth was never the cost.
Getting the replay floor under ~50 ms means not rebuilding the tables
per demand: keyed tables with per-module eviction, which is where
5f/RFC-023 head anyway.

**Pending literals retire with their slot (landed 2026-08-27).**
`pending_literals` used to keep every unsuffixed literal for the whole
check, resolved or not - 7291 entries on the compiler - and
`is_literal_var` linear-scans the list per open-var argument per
overload candidate: 2114 scans, 8.0M resolve steps, quadratic in program
size. A literal's verdict is final once its slot's sweep has run
(nothing after a slot can pin its literals), so `seal_slot` now
truncates the slot's entries, leaving only the preamble (signature
defaults and constant initializers, swept at 3.6) plus the running
slot's own - which is also what moved the flagged-literal cacheability
check from harvest to slot end. Measured: **bodies 1500 -> 920 ms cold,
138 -> ~100 ms re-demanded** - the scan was ~40% of cold bodies, not the
5-10% first estimated (each step is a union-find resolve plus an
interner node fetch).

**5e landed 2026-08-27 (`specialization`).** The specialization registry
carries across demands the way the type table does: `check_all` ships it inside
the result, and the next demand adopts it back (`result.f::take_specs` into
`checker.f::adopt_specs`; a gate-A caller that still reads the previous result
gets a deep copy via `carried_copy` and the original stays). Ids gained a
nominal type (`SpecId`) and a demand generation stamps every entry a demand
registers, replaces or reuses. As landed:

- **A carried entry is REUSED - the template body never re-checked - when its
  pick lands on it** (by final key, or by call site through the hint lists
  below) **and a probe passes.** Reuse replays what the frame once did to
  global state: burns the counters the frame minted itself
  (`own_var_burn`/`own_synth_burn`/`own_lambda_burn` - nested instantiations
  subtract out and burn their own), re-registers its closure environments from
  cached `ClosureFact`s (their symbols bake counter values, which is why the
  entry also anchors at `vars_at`/`synth_at`/`lambda_at` like the module
  caches), and touches its deps transitively. The probe (`spec_probe`)
  simulates exactly that walk without
  committing: entry reusable, template not stale, anchors match at every
  position the walk would reach, every dep transitively so - a trial set
  handles self-recursive generics. Its answer to open question 1:
  `specialization(template, args)` is a pure cached query for the picks whose
  instantiated signature (params, return, every tp bind) is CONCRETE at
  process time, and those are nearly all of them once the slot has settled;
  the rest stay a live per-slot fixpoint.
- **A pick that lands on an entry it cannot reuse re-instantiates IN PLACE** -
  same id, fresh overlay (`replace_at`), previous dep list handed to the frame
  as hints - so the ids other modules' caches bake stay pointing at the right
  entry. Non-reusable means: the frame emitted a diagnostic or parked a call
  (both must regenerate live per demand), its drain minted a literal the sweep
  flagged (marked coarsely per slot at seal time), its final signature never
  settled concrete, or its template's module was re-parsed this demand
  (`mark_stale_specs` - the body can change without the scheme changing).
- **Hints bridge the provisional-key gap.** A non-concrete pick's provisional
  key renders variable ids and can never match a carried entry's re-keyed
  final key, so resolution falls back to the call site: each module's cache
  stores its slot's `(span, function_id, id)` resolutions (`spec_sites`), and
  an in-place re-instantiation's frame carries its previous incarnation's dep
  list for the nested picks. Aligned streams make the span the stable
  identity.
- **Eviction is mark-and-sweep, answering open question 2**: no owner-set or
  refcount. Every resolution stamps the demand generation; `sweep` (end of
  phase 3) evicts what the demand never touched. A touched entry's deps are
  touched with it, so eviction only removes whole undemanded subgraphs and no
  live dep list cites a hole. A global invalidation (`!slots_carry`) resets
  the registry whole and numbering restarts at zero, exactly a cold check.
- The conversion surfaced a self-host bug worth naming: growing a container
  through a LOCAL struct's field (`out.by_key.set(...)` on a local `out`
  before returning it) silently mutates a copy - the two-field-hop hazard the
  checker's visibility code already documents. `carried_copy` and `deep_copy`
  fill locals and wrap at the end.

Measured on the compiler with three modules dirtied of 107 (idle machine,
medians of three): **settle 299 ms cold, 8 ms re-demanded** - down from 5d's
307 ms warm, which was almost entirely re-instantiation. Bodies stay at ~85 ms
warm (the replay floor); warm bodies+settle together drop from ~440 ms to
~95 ms. Memory (`FLANG_REDEMAND` probe, compiler corpus): **+26 MB retained
per re-demand, down from 5d's +38 MB** - retired results no longer hold a
spec registry each (the one registry moves forward), which more than pays for
the per-entry cache facts. Verified: fixpoint (stage 2 = stage 3
byte-identical), full harness, typer 99/99 (seven new 5e regressions: an
edited template body re-instantiates, a template-body diagnostic and an
uninferable template literal re-emit per demand, a reused entry replays its
closure environment, id stability across a clean re-demand, a removed call
site sweeps its entry, and the registry deep copy holds every entry under its
key), analysis 22/22, gate A across `bootstrap/`, `lib/flang_typer` and every
`examples/*` that type-checks, plus the per-module sweep over `bootstrap/`
(each of the 107 modules dirtied in turn, one process per module - zero
divergence).

**5f landed 2026-08-27 (`validate(project)`).** Smaller than its billing,
because 5d step 0 and 5e already absorbed the sweeps it was named for:

- `validate_literals` needed no code change - it has been per-slot since 5d
  step 0, each slot's literals swept and retired at its seal. What remains
  program-wide is phase 3.6 over the preamble range (signature defaults and
  constant initializers), and that re-runs per demand BY DESIGN: the constants
  phase is eager (5c) and re-parks them, and a body can be what pins an
  unannotated constant's variable, so the preamble sweep after the last slot
  IS `validate(project)` - the quiescence-only remnant of section 2's table.
- `zonk_specializations` is now scoped to the entries the demand instantiated
  (`harvested` is false exactly for those): a carried entry was zonked by the
  demand that made it, and a reuse requires a concrete final signature, so
  there is nothing left to resolve. The whole-program pass over 2708 carried
  signatures - and its per-entry list churn - drops to the fresh few.

Warm phase profile after 5e+5f (compiler corpus, `FLANG_REDEMAND=1 -t`):
typecheck **126 ms** warm - bodies 71 (the replay floor), signatures 15, zonk
9, specialize 8, templates 8, parse 14. The remaining floor is the per-demand
table rebuild (replay writes plus the final node-type re-intern), which is
RFC-023's keyed-tables-with-per-module-eviction work, not a sweep to retire.
Open question 4 (positional id streams, `docs/notes/positional-id-streams.md`)
rides with it.

Verified: fixpoint (a cold check takes no new path - every entry is fresh, so
the skip never fires), typer 99/99, analysis 22/22, gate A on `bootstrap/`
(three runs) and `lib/flang_typer`, plus the per-module sweep over
`bootstrap/`.

**Gate B - laziness.** Run the harness with lazy demand enabled and assert zero
diff in reported diagnostics against eager demand. Guards the M12 rejection
parity against silent regression. Nearly free once W1003 exists, since that
warning already forces total project demand.

**Landed 2026-08-27 (phase 6).** Lazy demand is per-module and default-on in
the CLI. `check_all` takes a `demanded` mask; a module outside it has no body
slot at all - no node types, no diagnostics, no specializations of its own.
Everything before phase 3 still runs for it: nominal registration must stay
program-wide (type names resolve leniently across imports), and its signatures
and constants are what a demanded body resolves against. The mask
(`analyze.f::demand_mask`) is the project's own modules, `core.prelude` and the
`[imports].global` modules, closed transitively over import edges - the
visibility rules guarantee nothing outside that closure can be named from
inside it. Constants (phase 2.5) stay eager for every module, so preamble
literal verdicts are demand-independent.

Lowering skips undemanded modules - except their `#foreign` declarations,
which name globally-linkable symbols any body may call without an import - and
skips specializations whose template lives in an undemanded module (they exist
only on behalf of undemanded preamble work; emitting one would reference
unlowered functions). `--eager` restores total demand; `flang --gate-b build`
analyses both ways and requires the published diagnostic lists identical.

Measured: `examples/snake` check drops 935 -> ~105 ms total (bodies 425 -> 20
ms; 29 of 62 slots skipped). `bootstrap/` skips 16 of 108 slots - its closure
is nearly the whole tree, so bodies only drop 923 -> 895 ms. The stage-2 =
stage-3 fixpoint holds under lazy demand (both stages skip identically), and
the full harness is green through it.

**W1003 landed 2026-08-27** (`flang_analysis/src/unused.f`), opt-in:
`-W`/`--warn-unused` on a build, and meant to be on by default in the LSP
(RFC-023), where `test {}` bodies are checked and their edges are real. A
build's demand never checks test bodies, so under `-W` every non-`pub`
function of a test-bearing module is rooted conservatively
(`tests_checked = false`) - a helper whose sole purpose is its tests must
never warn. Reachability runs over `resolved_targets`, `resolved_ops`,
receiver-deref chains and each specialization's overlay, with sites attributed
to their enclosing function by span containment (per-file binary search over
declaration spans); a site with no such home - a constant initializer, a
synthesized node - roots its target instead. Registry-driven: the function
nodes come from the carried function registry (name, module, `pub`, foreign
flag, decl span), so generated declarations (chunk file ids) and synthesized
lambda hosts fall out naturally. First run over the tree found two genuinely
dead functions (`bootstrap/src/frontend.f::render_diagnostics`,
`flang_parser/src/projector.f::find_node`), both deleted; every `lib/*` and
example is otherwise clean under `-W`.

W1004 (unused import) landed beside it under the same flag and the same
conservative skips, aggregating the identical evidence per importing file - an
`import M` warns when no recorded edge from the file lands in M or its
`pub import` closure. Its first sweep removed 26 dead imports tree-wide. See
`docs/error-codes.md` and architecture.md; not itself an RFC-022 deliverable.

**Existing gates stay green throughout:** 563/1/16 harness run sequentially
(the one failure is the documented Windows cross-target link,
`directives/if_directive_cross_target.f`; a parallel run adds flaky C-compiler
object contention on top), stage-2 = stage-3 byte-identical, 11/11 examples.

## Implementation phases

```
 0  DONE 2026-08-25: CheckPhases on TypeCheckResult, -t/--timings on the CLI;
    numbers in Motivation above
 1  DONE 2026-08-25: stable ids + tombstones; lowering iterates by id
 2  DONE 2026-08-25: Gate A harness (cold vs dirty-and-redemand equivalence)
 3  DONE 2026-08-25: data gaps - decl_spans on Field/VariantDef,
    NodeId->span, file_id->path
 4  DONE 2026-08-25: source-override map on analyze_project
 5  convert phase by phase, Gate A green after each:
      5a  DONE 2026-08-26: module_ast, then nominal_names on a Checker that
          outlives one check
      5b  DONE 2026-08-26: nominal_body carries; the type table outlives a
          demand (RFC-024 open questions 2 and 3 answered below)
      5c  DONE 2026-08-26: signature carries (function registry, templates,
          constant types); constants phase stays eager by design
      5d  DONE 2026-08-27: per-module settlement slots, then the body cache -
          a kept module's slot replays instead of running
      5e  DONE 2026-08-27: the specialization registry carries; a validated
          entry is reused without its body re-check, the rest re-instantiate
          in place; mark-and-sweep eviction (the drains survive, but scoped
          per slot since 5d step 0 and mostly skipped on a warm demand)
      5f  DONE 2026-08-27: validate(project) - the literal sweep was already
          per-slot since 5d step 0 (the preamble range at 3.6 is the
          quiescence remnant, re-parked per demand by the eager constants
          phase); zonk_specializations scoped to the demand's fresh entries.
          The remaining warm floor is the per-demand table rebuild - RFC-023's
          keyed tables, not a sweep
 6  DONE 2026-08-27: lazy demand (default-on in the CLI, --eager opts out),
    W1003 unused-function (opt-in via --warn-unused; LSP is the primary
    consumer), gate B (--gate-b: lazy vs eager diagnostic parity)
```

Phase 0 landed first for a reason: the body/collection split was inferred, not
measured, and it decides how long a consumer waits before any type is available.
It corrected two assumptions - bodies are 64% rather than 93%, and specialization
at 16% is a second target, not a rounding error.

## Out of scope

- On-disk persistence of analysis. Deferred; RFC-023 builds the pointer-free
  index seam a later cache would store.
- Threading the checker.
- ~~Splitting `flang_driver` into analysis and build halves.~~ **Done
  2026-08-25**, as a prerequisite for 5a: the query cache and the module store
  needed a coherent home, and a 10306-line `flang_driver` was not one. The
  analysis half moved out to `flang_analysis` (`analyze.f` - renamed from
  `driver.f` - plus `resolver.f` and `project.f`, 1291 lines); `flang_driver`
  keeps lowering and the build (`lower.f`, `symbol_table.f`, `layout.f`,
  `compile.f`) and now depends on `flang_analysis`. Exactly the 11 import lines
  this entry predicted. `compile.f` had to move with lowering rather than stay
  with analysis: the lowering `test {}` blocks build fixtures through
  `analyze_source_set`, so leaving it behind would have closed a library cycle.
- Frozen stdlib prefix as a distinct mechanism - subsumed by per-module
  invalidation.

## Open questions

1. ~~Whether `specialization(template, args)` can be a pure query, or needs a
   bounded fixpoint of its own inside the graph.~~ **Answered at 5e:** both,
   split by concreteness at process time. A pick whose instantiated signature
   is concrete is a pure cached query (reused across demands with counter
   burns and closure replay); a pick still citing open variables pins caller
   state through the body re-check and stays a live per-slot fixpoint. The
   concrete case is nearly all of them once a slot has settled.
2. ~~Specializations have no owning module, so eviction needs an owner-set or
   refcount.~~ **Answered at 5e:** neither - mark-and-sweep per demand. Every
   resolution stamps the demand generation and `sweep` evicts the untouched;
   touched entries touch their deps transitively, so only whole undemanded
   subgraphs ever go.
3. Whether generic template bodies gain any validation. Today they are never
   checked except per instantiation; a pull graph does not change that, but it
   makes "never demanded" and "demanded and clean" newly distinguishable.
4. The positional counter streams (engine variables, synthesized nodes,
   lambda/closure ordinals) make an edit's blast radius the demand-order
   suffix: a module whose mint count changes shifts every later module's
   stream anchors, and those slots re-run once to re-anchor. Gate A never sees
   it - unchanged text mints identical counts. Candidate fix: per-module id
   namespaces, which would also dissolve most of 5e's burn/anchor machinery.
   Same shape of change as 5f/RFC-023's keyed tables; measure in a real editor
   session first. Analysis: `docs/notes/positional-id-streams.md`.
