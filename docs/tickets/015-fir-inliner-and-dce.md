# RFC-015: FIR-level inliner + post-inline DCE

**Type:** Compiler (optimizations)
**Status:** Proposed (skeleton — needs further specification)
**Depends on:** Nothing structural; complements RFC-014 (closures) but ships independently.

## Summary

Add a FIR-level inlining pass and a post-inline dead-function elimination pass to `IrOptimizer`. Eager monomorphization already gives the compiler the entire concrete call graph; the missing piece is folding small / single-caller / closure-shaped functions into their callers and dropping the originals when they become unused.

This is the architectural piece that makes FLang's eager-monomorphization story pay off in binary size and runtime performance — without it, every closure shape and every adapter specialization becomes a distinct C function, even when the body is one expression called from one place.

## Motivation

After RFC-014, code like

```
for i in arr.filter(|x| x % 2 == 0).map(|x| x * 2) {
    println(i)
}
```

monomorphizes into ~5 specialization layers (closure op_call, FilterIter::next, MapIter::next, ListIter::next, the loop). Each is small (1–5 IR statements) and called from exactly one site. Without inlining, every layer is its own C function and the inner loop becomes a chain of indirect-via-direct-call hops.

With FIR-level inlining + DCE, the same code lowers to a single flat loop in `main` — indistinguishable from a hand-written one. The synthesized closure functions, the adapter `next()` implementations, and the wrapper iterator types all disappear from the C output.

FLang has structural advantages over Rust here:

- **Whole-program FIR is available.** No separate compilation; every function's body is local to the optimizer.
- **No virtual dispatch.** Every call has a `ResolvedTarget` known at FIR-construction time. Indirect calls only appear when the user explicitly writes `fn(T) Ret`.
- **Eager monomorphization gives the call graph for free.** `EnsureSpecialization` could maintain caller-counts as a side effect.

## Design (skeleton — needs further specification)

### Pipeline

Insert two new passes into `IrOptimizer`'s lifecycle:

```
... existing passes (DSE, ...) ...
inline_pass         (NEW)
dce_unused_fns      (NEW)
... existing passes ...
```

The optimizer iterates until no pass reports changes (existing convention); inline + DCE participate in that loop. Cap at 10 iterations as today.

### Inlining heuristic (initial — refine with measurement)

For each FIR function `f`:
- Track `caller_count` and `f.size_in_ir` (sum of basic block instruction counts).
- Inline at every call site of `f` when `f.size_in_ir * max(caller_count - 1, 1) < BUDGET` for some budget (e.g. 64 IR instructions — needs measurement).
- Always inline single-caller functions whose body is non-recursive.
- Never inline:
  - Recursive functions (would loop).
  - `#foreign` functions.
  - Functions explicitly marked `#noinline` (new attribute, see "Open questions").

### DCE rules

After each inline pass, walk reachability:
- **Roots**: `pub` functions, `main`, every function referenced from a `#foreign` site, every test entry point when running tests, every variant of a `pub type`.
- Any FIR function not reachable from a root is removed before C emission.

This DCE pass is independent of inlining — it also drops functions that became unused via other optimizations (e.g. constant folding eliminating a branch).

### Pass structure

```
fn inline_pass(module: &mut FIR) -> bool {
    let cg = build_call_graph(module);
    let mut changed = false;
    for f in cg.topological_order() {
        if !should_inline(f, &cg) { continue; }
        for site in cg.callers_of(f).clone() {
            inline_at_site(module, site, f);
            changed = true;
        }
        cg.update_after_inline(f);
    }
    changed
}

fn dce_unused_fns(module: &mut FIR) -> bool {
    let roots = collect_roots(module);
    let reachable = walk_reachability(module, roots);
    let dropped = module.functions.retain(|f| reachable.contains(f.id));
    dropped > 0
}
```

The inliner mechanics — cloning basic blocks, renaming SSA values, fixing up phis (FLang uses phi-via-alloca which simplifies this), splicing into the caller — are standard. References:
- LLVM's `InlineFunction` (the canonical reference).
- GCC's `inline-walk.cc`.
- Cranelift's inliner (closer to FIR's structural simplicity).

### Caller-count maintenance

Two paths to keep `caller_count` accurate:

1. **Recompute per pass**: `build_call_graph` from scratch each time. O(modules · functions · calls). Simple, fine for v1.
2. **Maintain incrementally**: `EnsureSpecialization` increments on registration; FIR mutations adjust. Faster but more invasive.

**Recommendation**: ship with (1). Profile after; switch to (2) if call-graph construction dominates.

## Where this matters

The inliner unblocks zero-cost abstractions across:

- **Iterator chains** (the canonical case). Every adapter's `next()` is small and single-caller.
- **`Owned(T)` / `Rc(T)` wrapper methods**. `op_deref`, `transfer`, etc. are small wrappers that should fold into their callers.
- **`op_*` operator dispatch**. `op_eq`, `op_cmp`, `op_index_ref` — small bodies, called from generated comparison and indexing sites.
- **Closures (RFC-014)**. Synthesized `op_call` functions are almost always tiny and single-caller.

## Out of scope

- **Outlining** (the inverse: deduplicating layout-equivalent specializations into a single shared function). Worth it only if measurement after this RFC shows specific functions duplicated where one shared copy would do. Rust calls this *polymorphization*; defer until measured pressure.
- **Cross-module inlining decisions based on profile data**. Static heuristic only in v1.
- **`#inline(always)` / `#inline(never)`** attributes for fine-grained user control. Add when needed; default heuristic should cover the common case.
- **Inlining at the C backend level**. The C compiler's `-O2` does its own inlining; this RFC is about FIR-level inlining, which has access to FLang-level structure (op_call, op_deref chains) the C backend doesn't.

## Open questions

1. **Inline budget tuning.** What's the right `BUDGET` constant? Likely 32–128 IR instructions; needs measurement on a representative codebase (probably the `examples/` tree once they exercise more closures).
2. **`#noinline` attribute.** Useful for debugging and for hot loops where the user wants the call boundary preserved. Add at the same time as `#inline(always)` or defer?
3. **Order with existing passes.** Should inlining run before or after DSE? Before is correct for closures (inline reveals dead allocas); after is correct for general code (DSE simplifies what the inliner sees). Likely needs both — pre-pass and post-pass — within the optimizer's fixpoint loop.
4. **Specialization-emit-then-DCE vs. lazy specialization.** Currently `EnsureSpecialization` always emits the body. An alternative is "register the spec but don't emit until reachability is confirmed." More invasive, larger change, but skips work for specs that DCE would drop. Probably defer; let the simple path land first.
5. **Phi handling under inlining.** FIR's phi-via-alloca lowering simplifies but doesn't eliminate the work. Verify the inliner correctly merges allocas across the inlined body when the callee's locals collide names with the caller's.
6. **Diagnostics when inlining changes warning/error reports.** A warning that fired in the original function may no longer be generated if the function gets inlined and folded. Likely fine — diagnostics happen at type-check time before this pass — but worth a check.

## Implementation phases

1. **DCE only** (smaller, lower risk). Run reachability from roots; drop unreachable functions. Immediate win for any code with unused specializations.
2. **Single-caller inlining**. Restrict to `caller_count == 1` cases. Trivial heuristic, always-correct. Catches the common iterator-chain case.
3. **Heuristic inlining with budget**. Generalize to multi-caller inlining gated by size × callers.
4. **Tuning + measurement**. Profile the budget on real code; adjust.

Each phase is shippable independently. Phase 1 is a clear win regardless of phase 2; phase 2 covers the canonical zero-cost-abstraction story; phase 3 is the polish.

## What this RFC does not specify

This is a skeleton. Before implementation, the following need concrete specification:

- The exact FIR transformation rules for inlining (block cloning, alloca merging, control-flow splicing).
- The exact reachability rules for DCE roots (what counts as a "test entry point" — see `--test` flag in `RunTests`; what about `#export`-style attributes if added later).
- The interaction with debug info / source maps when inlining collapses multiple FIR functions into one.
- The benchmark suite for measuring inline budget impact.

The intent is to expand this RFC iteratively as implementation reveals constraints. Treat the current document as the architectural sketch; the file's scope expands when each phase lands.

## Tests

To be defined per phase. At minimum:

- **DCE**: a test where a `pub fn` is never called and has no `#foreign` consumer; verify it doesn't appear in emitted C (use `--emit-c` and grep).
- **Single-caller inline**: a test where `wrapper(x)` calls `inner(x)`, `wrapper` is called once; verify `inner` is gone from C output.
- **Iterator chain end-to-end**: the canonical `arr.filter(...).map(...)` loop; verify the C output is a single flat loop with no FilterIter/MapIter functions.
- **Recursion guard**: recursive function with a single caller — verify it's not inlined (would loop).
- **Negative**: large function called from many sites — verify it's NOT inlined (budget exceeded), single shared copy emitted.
