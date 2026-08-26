# RFC-024: Interned types - `Ty` becomes a handle

**Type:** Compiler mechanism (typer)
**Status:** Proposed
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
 1  TypeInterner + TyId, alongside the tree. Construct-and-intern, resolve on
    read. Nothing else changes shape. Gate A green, fixpoint green.
 2  InferenceResults.node_types and the overlay tables hold TyId. Biggest
    memory win, smallest blast radius.
 3  Engine internals over TyId - unify, resolve, zonk, substitute.
 4  Checker signatures (128 mention Ty).
 5  Driver - lower.f (78), layout.f (21), symbol_table.f (11).
 6  Delete the tree representation.
```

Phase 2 sits before phase 3 deliberately: it banks most of the 461 MB while the
engine still speaks trees, so the win is measurable before the invasive part
starts. RFC-022 phase 0 is the precedent - the body/collection split was
inferred rather than measured, and was wrong on both counts.

Surface, counted 2026-08-26: 320 signatures mention `Ty`, 316 match arms bind
its variants, 173 sites construct one. Four files carry most of it, and
`checker.f` alone is 128 signatures.

## Out of scope

- Interning `NominalDef` bodies. They hold `Field` lists whose names view the
  source, which is a separate lifetime question.
- Making the table outlive a demand. See open question 2.
- Hash-consing anything that is not a type.

## Open questions

1. **Does interning pay for itself in time?** Construction becomes a hash plus
   a lookup instead of a `malloc`. Almost certainly a win at 98.9% duplication,
   and `equals` gets much cheaper, but RFC-022 phase 0 is the precedent for
   measuring before believing. Phase 1 reports both.
2. **Per-check, or persistent across demands?** RFC-022 5a strips nominal
   bodies when it carries declarations to the next demand, because a body names
   engine variables and the engine does not survive. A zonked body names no
   bound variables, so an interned zonked body could carry, which is what would
   make 5b (`nominal_body`) tractable. Whether the table can outlive the engine
   that filled it is the question 5b turns on.
3. **`Record` field names.** A record's key includes its field names, which are
   `String` views into module sources. The table then inherits the lifetime
   constraint on sources that RFC-022 5a documents for nominal FQNs. Interning
   the names alongside would remove it.
