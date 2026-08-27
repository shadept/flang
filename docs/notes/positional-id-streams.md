# Positional id streams: edit blast radius and the per-module namespace fix

Analysis for a later performance pass on the incremental checker (RFC-022 5f /
RFC-023 territory). Written while landing 5e, where the cost of the current
scheme became visible. Nothing here blocks correctness; it bounds editor-session
latency.

## Two identity schemes live in the checker

**Keyed identity - already gap-tolerant.** Declarations are identified by
stable key, not by position: a surviving declaration reclaims its previous id
by FQN (retire-and-reclaim, `recycled`), a new declaration mints past every
existing id instead of renumbering its neighbors, a removed one leaves a hole.
`NominalId`, function ids and `SpecId` all follow this. A mid-file insertion
renumbers nothing. This is the piece-table lesson applied to registries:
position is not identity.

**Positional identity - the unsolved half.** Three global monotone counters
number things in demand order:

- engine variables (`Engine.var_counter`)
- synthesized nodes (`Checker.next_synth`)
- lambda/closure ordinals (`Checker.next_lambda`), from which closure
  environment FQNs (`<module>.__Closure_<n>`) and C symbols
  (`__flang_closure_call_<n>`) are minted

Carried caches hold absolute values from these streams: a signature cache's
constant variable, a body cache's burned ranges, a specialization's baked
closure symbols. Each cache therefore anchors on the exact counter positions
its pass once ran at (`vars_at_start` and friends) and refuses to replay from
anywhere else - correctly, since a shifted stream would alias someone else's
ids and collide symbols.

## Consequence: blast radius is the demand-order suffix

An edit that changes how many things module M mints - nearly every real body
edit - shifts the stream position of every module AFTER M in demand order.
Their anchors fail and their slots re-run once to re-anchor. Editing a
low-order module (core.string, std.list) re-checks most of the tree behind it.

Gate A does not see this: it re-demands unchanged text, where mint counts are
identical and every anchor holds. The anchors were built to catch a shift, not
to survive one. No measurement of the real cost exists yet because there is no
editor loop driving real edits; the per-phase timings only cover the
unchanged-text replay path.

## Candidate fix: per-module id namespaces

Number positionally WITHIN a module, identify the module by key:

- variables become `(module, local ordinal)`, or equivalently each module slot
  restarts a local counter
- closure symbols mangle from `(module FQN, ordinal within module)` - and for
  template-body lambdas `(spec key, ordinal within body)` - instead of a
  global counter

Then an upstream edit shifts nothing downstream: anchors become module-local,
a slot's validity no longer depends on every earlier slot's mint count, and
the burn/anchor machinery the specialization reuse carries (own-burn
accounting, the stream-position probe) mostly dissolves. Blast radius drops
from "the demand-order suffix" to "the edited module plus true dependents".

## Cost and sequencing

This re-plumbs identity through the checker AND lowering: symbol mangling,
every cache's validity check, `result_diff`'s comparisons, and the fixpoint's
emission-order guarantees all read the current scheme. It is the same shape of
change as the keyed-tables-with-per-module-eviction work already slated for
5f/RFC-023, and should ride with it, not precede it.

Do it measurement-first: land the LSP, instrument how many slots re-run per
keystroke-shaped edit in a real session, and size the win before paying the
re-plumb. If the numbers say downstream re-runs are cheap enough (slots replay
in ~1 ms each once bodies are cached), the fix may never be worth it.
