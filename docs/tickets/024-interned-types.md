# RFC-024: Interned types - `Ty` becomes a handle

**Type:** Compiler mechanism (typer)
**Status:** Implemented 2026-08-26
**Depends on:** None
**Relates to:** RFC-022 (demand-driven checker) - 5b inherits what this settles

## Summary

`Ty` stops being a tree of heap-allocated values and becomes a `TyId` into one
interned table.

1. **One node per distinct type.** The compiler stores 95,633 node types drawn
   from 1,092 shapes; interning stores the 1,092.
2. **Copying a type is copying 4 bytes.** The question of who owns a `Ty`'s
   argument list stops being asked, because a `TyId` owns nothing.
3. **One owner, one teardown.** The table frees its two arrays. No per-node
   `deinit`, no reference counting, no clone-on-produce discipline.
4. **Equality is an integer compare.** `equals` is a structural walk today, and
   it runs on every unification and every overload score.

## Motivation

Measured 2026-08-26 on `bootstrap/` (106 modules), `flang --mem --check build`:

| | |
|---|---|
| result tables (backing arrays, overlays included) | 43 MB |
| inference engine (bindings, levels, union-find) | 5 MB |
| **everything else** | **~461 MB** |
| live allocations at exit | 1,120,798 (1,557,778 made, 436,980 freed) |
| process peak RSS | 536 MB |

The 461 MB is not in the tables. It is in the values the tables point at: a
`List(Ty)` per tuple, record, function parameter list and parameterised
nominal, and a heap box per `Ref`, array element and function return. Nothing
frees them, because `Ty` has no `deinit` and no single owner. A
`Dict(NodeId, Ty)` that frees its bucket array is the last reference to every
list its entries held - see the test in `type.f`.

**95,633 stored, 1,092 distinct.** `zonk` rebuilds a fresh tree per node, so
98.9% of that heap is duplicate shapes.

Two other numbers shape the design:

- **A re-demand adds 292 MB and never gives it back**, so an editing session
  grows without bound. RFC-022 5a made re-demands cheap in time; they are not
  cheap in memory.
- **Nothing mutates a `Ty` field in place.** A scan for assignment to `.ty`,
  `.elem`, `.ret`, `.args` and `.params` across `lib/` finds zero. The
  representation is already treated as immutable, which is the precondition
  interning needs and the reason this is tractable at all.

## Design

### 1. What a `Ty` becomes

```
  pub type TyId = u32
```

A handle into the table. `Void`, `Never`, `Error` and the 14 primitives take
fixed ids assigned when the table is built, so the common cases never hash.

### 2. The table

```
  TypeInterner
    nodes:    List(TyNode)        // by TyId
    children: List(TyId)          // one flat array, sliced by node
    by_key:   Dict(String, TyId)  // canonical rendering -> id
```

`TyNode` mirrors today's `Ty` with `TyId` children instead of `Ty` values, and
a `(start, len)` window into `children` instead of a `List` per node. That is
where the memory goes: 1,092 nodes and one child array, rather than 95,633
trees of small allocations.

`by_key` hashes the canonical rendering `specialization.key_for` already
computes for specialization identity, so the key function exists and is already
trusted to separate same-named types from different modules.

### 3. Variables

`TyVar` carries `id` and `level`, but `equals` ignores `level` and
`engine.levels` is authoritative for it: the rep's level is the partition-wide
minimum, which is what `resolve_var` reads. So a `Var` node keys on `VarId`
alone and the level stays in the engine.

Interning does not make a type containing a variable stable. The variable's
binding lives in the union-find and changes as inference proceeds, so resolving
or zonking such a type yields a different id. Nothing is mutated; a new node is
interned. That is the contract the tree representation has today.

### 4. Ownership

The table owns every node and every child slot. `deinit` frees two lists. There
is nothing else to free and nothing that can be freed twice.

The three alternatives each fail on that last point:

- **`&Ty`**, today: no owner, so nothing is freed.
- **`Rc(Ty)`**: needs a refcount bump per copy. A plain copy does not bump one
  (measured), so it needs `clone` at every produce site *and* a deep copy of
  every owned list, since two containers holding one `Tuple(List(Ty))` both
  free it. That is an allocation per `resolve`.
- **An arena**: frees everything at once, but answers the ownership question by
  refusing to ask it, and orphans globally-allocated strings held inside
  arena-allocated containers.

### 5. Determinism

Ids are handed out in first-intern order, which demand order fixes (RFC-022
section 3), the same way it fixes nominal and specialization ids.

`result_diff` compares types by canonical `format` rendering rather than by id,
so Gate A does not see the id space change. The stage-2 = stage-3 fixpoint does
see anything that reaches emission, so a phase that changes which ids reach
lowering has to keep the fixpoint green by construction.

### 6. What the result ships

`TypeCheckResult` carries the interner. `node_types` becomes
`Dict(NodeId, TyId)`: 4 bytes per value instead of a `Ty` struct, with the
table shared rather than a tree copied per entry. Lowering, layout and codegen
resolve through the table instead of walking a tree.

## Gates

**The existing gates carry most of the load.** Gate A (RFC-022) compares two
results entry by entry and renders types canonically, so it catches a wrong id
without caring which id it is. The stage fixpoint catches emission-order drift.
The harness catches semantics.

**New: a memory gate.** `flang --mem` already reports `node types: N stored, D
distinct`. After interning the type heap is bounded by `D`, not `N`. Assert
that the interner's node count equals the distinct count, and that it does not
grow across a re-demand.

**Green after each phase, not at the end.** The rule RFC-022 section 5 works
under.

## Implementation phases

```
 0  DONE: baseline measured - the Motivation table above
 1  DONE 2026-08-26: TypeInterner + TyId, alongside the tree
 2  DONE 2026-08-26: node_types and the overlay tables hold TyId
 3  DONE 2026-08-26: engine internals over the interner
 4  DONE 2026-08-26: checker over TyNode
 5  DONE 2026-08-26: driver - lower.f, layout.f, symbol_table.f
 6  DONE 2026-08-26: tree representation deleted
```

**Landed 2026-08-26, all phases.** `Ty` IS the handle: `pub type Ty = u32`
in type.f, so the 320 signatures kept their spelling and only construction
sites, match arms and payload reads changed. The engine owns the
`TypeInterner` and `check_all` moves it into the `TypeCheckResult` whose
tables share it; consumers match on `TyNode` through the table.
`substitution.f` and the tree `Ty` enum (with `equals` and the tree
`format`) are deleted - `a == b` on handles is type equality, and rendering
is `interner.format` off the node graph.

Three deviations from the design above, found by implementation:

- **A `Var` node keys on (id, level), not id alone.** Section 3's premise
  that the engine's `levels` table is the only level reader is false:
  `generalize`'s free-variable walk reads levels off the zonked tree. A var
  whose partition level moved must intern as a fresh node or `free_vars`
  quantifies against a stale level. The identity key renders as
  `?id@level`; the diagnostic rendering stays `?id`.
- **The empty tuple and `Void` keep distinct ids.** `equals` treated them
  as one type by convention, but consumers match them as different shapes;
  unification keeps the convention explicitly.
- **A `ground` bit per node.** `zonk` is the identity on a subtree citing
  no vars, which is the common case by far; without the bit every zonk
  walks its whole shape.

## Measured outcome

Same setup as the Motivation table (`bootstrap/`, 106 modules,
`flang --mem --check build`):

| | before | after |
|---|---|---|
| live at exit | 536 MB | 490 MB |
| handed out in total | - | 970 MB |
| allocations made | 1,557,778 | 1,145,357 |
| node_types backing | 9 MB | 4 MB |
| interner | - | 205,333 nodes |
| typecheck (`-t`, 3 runs) | ~823 ms (RFC-022 phase-1 median) | ~641 ms |

Two corrections to the Motivation:

- **The 461 MB was not primarily the stored type trees.** Interning every
  final-zonk product (phase 1) moved live-at-exit by ~3 MB; the full
  conversion, which also stops the engine's transient trees (zonk inside
  coercion probes, `substitute` per instantiation, `mk_*` per signature),
  reclaimed ~46 MB. The remaining ~420 MB of the "everything else" row is
  outside the type representation - ASTs, sources, and per-check tables -
  and needs its own attribution pass before another memory RFC.
- **The interner holds live shapes, not just final ones.** Inference
  interns as it works, so var-citing shapes (one node per distinct
  (id, level), plus every compound citing one) dominate the node count:
  205k nodes against 1,091 distinct final shapes. That is the working set
  the trees used to be, now owned and freed by the table.

The memory gate as specified (interner nodes == distinct stored count)
does not hold under live interning and was not added; `--mem` prints the
node count next to the stored/distinct counts instead. The per-demand
table also makes "does not grow across a re-demand" moot until open
question 2 lands.

Verification: Gate A green (106 modules, 96,991 node types identical),
`test-all` 7/7, harness sequential 563/1/16 (the documented cross-target
link failure), stage-2 = stage-3 byte-identical (16,231,433 bytes of C).

One compiler bug surfaced and is worked around: mutation through a field
chain that crosses a reference (or starts at a local value struct) does
not stick - see docs/known-issues.md, "Self-hosted: mutation through a
field chain".

## Out of scope

- Interning `NominalDef` bodies. They hold `Field` lists whose names view the
  source, which is a separate lifetime question.
- Making the table outlive a demand. See open question 2.
- Hash-consing anything that is not a type.

## Open questions

1. ~~Does interning pay for itself in time?~~ **Answered: yes.** ~641 ms
   against the ~823 ms RFC-022 phase-1 median on the same corpus - handle
   equality, the ground-bit zonk shortcut, and no per-probe tree
   allocation outweigh the key hashing.
2. ~~Per-check, or persistent across demands?~~ **Transferred to RFC-022
   5b** - it is that phase's question, not this ticket's: the mechanism
   (an interned zonked body carries, because it names no engine
   variables) exists; whether the table outlives the engine is 5b's
   design decision.
3. ~~`Record` field names.~~ **Transferred to RFC-022 5b** with question
   2 - the source-lifetime constraint on record keys only starts to bite
   when the table is made to outlive a demand.
