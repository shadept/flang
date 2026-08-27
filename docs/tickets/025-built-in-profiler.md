# RFC-025: Built-in profiler

**Type:** Compiler + runtime feature
**Status:** Phase 1 implemented (self-hosted compiler; see `docs/architecture.md` § Profiler)
**Depends on:** RFC-015 (FIR optimization pipeline)
**Related:** RFC-023 (LSP: long-lived processes need phase-scoped profiling)

## Summary

`flang build --profile` produces a binary that measures itself: every FLang
function call is timed into a call-tree trie, and at exit the process writes

1. a flat table (calls, self, inclusive, ns/call) to stderr, and
2. a folded-stack file (`FLANG_PROFILE_OUT=prof.folded`) that loads directly
   into speedscope / inferno / flamegraph.pl as a flamegraph.

Instrumentation is a FIR pass that runs after the shim inliner, so a profile
build executes the same inlining decisions as a normal build. Memory profiling
(allocation churn, then live-bytes attribution) reuses the same trie in later
phases.

## Motivation

Profiling today is manual: sprinkle `std.time.Stopwatch` and prints, rebuild,
repeat. The cost of asking "where does the time go" is high enough that it
rarely gets asked, and pathologies survive for months (the test allocator's
O(live) dealloc scan, Dict growth patterns, the repeated-`analyze_project`
degradation).

> All compilers written from now on should be designed to provide all
> programmers with feedback indicating what parts of their programs are
> costing the most. (Knuth, Structured Programming with go to Statements)

The compiler owns every lowering step down to C, so it can instrument
programs with no external tooling, on every platform the C backend targets.

## Design

### Pipeline placement

Instrumentation must observe, not perturb. Each compilation step in order:

1. **`#inline` functions**: expanded before FIR. Never instrumented; their
   cost lands in the caller, matching real execution.
2. **FIR shim inliner** (`shim_inliner.f`): runs first, on the uninstrumented
   module. Its size budget (`MAX_INLINE_INSTRS`) therefore sees identical
   input in profile and normal builds, and makes identical decisions.
   Functions it erases are gone before instrumentation exists; their cost
   attributes to the caller, which is where it actually runs.
3. **Instrumentation pass** (new, runs only under `--profile`): assigns every
   remaining function a dense `u32` id, emits a static name table, inserts
   `call __flang_prof_enter(id)` at entry and `call __flang_prof_exit()`
   before every `ret`. Plain FIR call instructions; the C backend needs no
   changes.
4. **C compiler**: `--profile` implies the same optimization flags as
   `--release`, so codegen quality matches the build being modeled. The
   probes themselves are `static inline` functions in the emitted runtime
   header: no call frame, and the C compiler still sees small bodies.
   Residual skew (opaque clock reads inhibit some code motion) is the
   irreducible cost of any instrumenting profiler; calibration (below)
   removes the fixed per-call component from the report.

Foreign calls (`memcpy`, libc shims) are opaque: their time attributes to the
calling function's self time.

### Runtime: call-tree trie

One static structure serves both reports. Nodes live in a preallocated flat
pool addressed by `u32` index:

```c
typedef struct {           // 32 bytes, hot fields first
    uint32_t func_id;
    uint32_t first_child;  // index into pool, 0 = none
    uint32_t next_sibling;
    uint32_t parent;
    uint64_t calls;
    uint64_t total_ticks;  // inclusive; self derived at dump
} ProfNode;
```

Shadow stack of `{node: u32, t_enter: u64}` frames, fixed depth. A global
`current` node index is the position in the tree.

**Enter**: find the child of `current` matching `func_id` by walking the
sibling list, move the hit to the front of the list (repeated callees then
hit on the first compare), or bump-allocate a new node from the pool. Then
read the clock, push `{child, t}`, `calls++`, `current = child`. The clock is
read AFTER the lookup so lookup cost lands in the parent's self time, where
calibration subtracts it.

**Exit**: read the clock FIRST, `node.total_ticks += now - t_enter`, pop,
`current = parent`.

**Nothing else happens at runtime.** Self time is derived at dump as
`total - sum(children.total)`. Per-function aggregation (the flat table) is a
dump-time sum over nodes sharing a `func_id`.

### Making it fast

- **Raw cycle counter, not the OS clock.** `__rdtsc()` on x86-64,
  `cntvct_el0` on aarch64, fallback to `__flang_monotonic_ns` elsewhere.
  Ticks are stored raw; the ticks-to-ns ratio is measured once against the
  monotonic clock (start vs dump) and applied at dump time. Invariant TSC is
  assumed (universal on supported hardware).
- **No allocation on the hot path** except first visit of a call edge (bump
  pointer into the static pool). No locks (single-threaded runtime; a second
  thread gets its own trie + TLS `current` when threads land).
- **Move-to-front sibling lists** make the common lookup one compare.
- Expected cost: two unserialized `rdtsc` reads plus a handful of ALU ops,
  roughly 15-25 ns per call pair. Negligible for anything over ~1 us; for
  tiny hot functions the calibrated subtraction keeps the numbers honest.

**Calibration**: at startup, run N enter/exit pairs against a scratch node,
derive the fixed cost per pair, subtract `calls * cost` from each node's self
time at dump (clamped at 0). Without this, probe overhead masquerades as
self time in small-function-heavy code.

**Capacity**: node pool and stack depth are fixed (defaults: 64Ki nodes,
8Ki frames; `FLANG_PROFILE_NODES` / `FLANG_PROFILE_DEPTH` override). Pool
exhaustion routes new edges into a per-parent sink node; stack overflow
counts depth past the cap and skips timing until it unwinds. Both are
reported in the dump header so truncation is never silent.

### Output

- **Flat table** (stderr, at `atexit` or explicit `std.profile.dump()`):
  sorted by self time; columns calls, self ms, incl ms, ns/call, name.
- **Folded stacks** (`FLANG_PROFILE_OUT=path`): one line per trie node,
  `main;analyze_project;infer_body 12345` with self time as the count.
  Standard format; speedscope.app renders it as a flamegraph with zero
  tooling on our side.
- `std.profile` module: `dump()`, `reset()` (re-zero the trie between phases;
  an LSP profiles one request at a time), no-ops in unprofiled builds.

## Memory profiling (planned, not in phase 1)

Attribution context is free once the trie exists: `current` IS the call
stack.

**Phase 2, churn**: `__flang_prof_alloc(size)` charges `allocs` and
`alloc_bytes` counters on the current node (+16 bytes per node). Hooked at
the allocator choke point: profile builds route `global_allocator` (and the
test allocator) through the hook; the libc shims are the backstop for
allocations that bypass the Allocator interface. Dump gains an
allocated-bytes folded file (`prof.mem.folded`): a churn flamegraph. This
tier has no per-allocation state and would already have caught Dict
rehash/growth pathologies and the test-allocator scan pressure.

**Phase 3, live bytes**: tag each allocation with the trie node that made it
(header prefix or side table keyed by pointer); frees decrement that node's
`live_bytes`. Dump: live-bytes flamegraph at any point in time, i.e. leak
and retention attribution by call stack. Costs per-allocation space and a
lookup on free; opt-in via a separate flag if the overhead warrants it.

## Phases

1. DONE: FIR instrumentation pass (`lib/flang_codegen/src/instrument.f`),
   `--profile` / `-p` driver flag (implies `--release`), C runtime
   (`stdlib/std/profile.c`: trie, calibration, rdtsc), flat table + folded
   output, `std.profile`. Deviations from the design above: the probes are
   plain extern functions in profile.c rather than `static inline` in an
   emitted header (calibration absorbs the extra call cost; revisit if the
   fixed overhead matters), the flat table's inclusive column counts
   recursion-outermost nodes only (nested levels of the same function
   already sit inside the outer span), and the shim inliner is not yet
   wired into `build_program`, so today the pass simply follows lowering -
   the run-after-every-transform rule stands whenever passes land there.
   Profiling the compiler's own self-build forced two more runtime
   decisions: recursion collapses onto the open node at enter time (a
   recursive checker otherwise mints one path per depth level - 13M+
   paths for one self-build - exhausting any pool and making folded
   output quadratic in depth), and the folded file keeps the
   heaviest paths under a byte budget (FLANG_PROFILE_MAX_MB, default 32)
   so it can never outgrow what a flamegraph viewer loads, written in
   first-entry order so time-ordered views read left to right. Reports print
   display names (`module.path.name(&Type,u32)`, built at symbol
   assignment and carried on `IrModule.displays`), not mangled symbols;
   and `-p` instruments the application only (stdlib bills to callers,
   like foreigns), with `-P`/`--profile-all` widening to everything.
2. Allocation churn counters + memory flamegraph.
3. Live-bytes tagging (leak attribution).

## Open questions

1. Recursion: natural trie growth (each depth a fresh path) vs collapsing
   back-edges. Natural growth is simpler and speedscope copes; deep
   recursion eats pool nodes. Default: natural growth, revisit if pool
   exhaustion shows up in practice.
2. Should `flang test --profile` aggregate per-test (reset around each test
   block) or whole-process? Whole-process is phase 1; per-test needs harness
   cooperation.
3. Exact `--profile` x `--release` interaction: implied, or orthogonal flags
   with implied as default?
