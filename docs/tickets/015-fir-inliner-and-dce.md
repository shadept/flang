# RFC-015: FIR optimization pipeline (inliner + DCE + cleanup passes)

**Type:** Compiler (optimizations)
**Status:** Proposed — design captured, no code yet
**Depends on:** Nothing structural. Complements every frontend feature that monomorphises into many small functions (closures, iterator adapters, `op_*` overloads).

This RFC replaces the C#-IR-era skeleton with a FIR-era plan informed by what implementing the C# compiler taught us.

---

## 1. Why FIR-level optimization at all

The C compiler will do most classical optimizations at `-O2`. FIR-level passes earn their keep when one of these is true:

- **They shrink C output.** Smaller `.c` files compile faster downstream and are dramatically more readable when debugging.
- **They fire at `-O0`.** Debug builds get nothing from the C compiler; whatever FIR cleans up is what the user actually sees.
- **They're cheap in SSA but expensive after C re-parsing.** The C compiler has to rediscover dominance, alias-free locals, and SSA from textual C. FIR already has them.
- **They expose follow-on opportunities the C compiler can't see post-lowering.** Pre-lowering structure (mutator shims, vtable indirection, byte-buffer storage of structs) gets erased by lowering — once that information is gone, the C compiler can't act on it.

We **don't** do register allocation, instruction selection, vectorization, scheduling, strength reduction, or anything else that needs target knowledge. Stay in the lane where SSA + block-params + 7-type IR is a structural advantage.

---

## 2. Pass tiers

### Tier 1 — must-have, all cheap, all unlock each other

| Pass | What it does | Why it's tier-1 |
|------|--------------|-----------------|
| Constant folding | `iadd 3, 5 → 8`, `icmp.eq 1, 2 → 0`, `trunc.i32 0x…AABBCCDD → 0xAABBCCDD`, etc. | One-pass walk in SSA; frees up branch folding and DCE. |
| Branch folding | `br_if 0, then, else → br else`; `br_if 1, then, else → br then`. Sweep unreachable blocks after. | Without this, constant-folded conditions still emit `if (0)` in C. |
| DCE | Drop any value-producing instruction with zero uses and no side effects. | SSA makes this trivial; runs to fixed point. |
| Copy propagation through trivial block params | When a block param has one predecessor edge always passing the same SSA value, replace uses of the param with the source. | Cleans the residue of empty-block-fusion and inlining. |
| Empty-block fusion | A block whose only instruction is `br target(args)` forwarding its params one-for-one gets dissolved. | Cleans up `defer` / match-join residue. |
| `gep` coalescing | `%q = gep %p, 4; %r = gep %q, 8 → %r = gep %p, 12`. | Trivial; cleans nested struct field access. |
| Memory-intrinsic cleanup | `memcpy x, y, 0` / `memset x, _, 0` → drop. `memcpy x, x, n` → drop. `memcpy` of small constant size → unrolled scalar copies. | The C compiler does this at `-O2`; FIR does it for `-O0` and to shrink output. |

### Tier 2 — high payoff, medium effort, where FIR earns its biggest wins

| Pass | What it does | Why |
|------|--------------|-----|
| **Inliner** | See §3. Collapse small/single-caller functions into their callers. | FLang's scoped-mutability rules force a wrapper-function call for every "ask another scope to mutate this for me" mutation. Without inlining, the program is a tree of trivial wrappers around `gep`+`store`. With inlining, the wrappers cease to exist. This is **structural elimination of code that should never have been distinct functions at runtime**, not a perf tweak. |
| `stack_slot` promotion (mem2reg / SROA) | Promote non-escaping stack slots whose accesses are whole-slot typed `load`/`store` of the same type back to plain SSA values. | FIR aggregate lowering generates many `stack_slot` + `load`/`store` chains. Promoting them shrinks C output 2–3× and removes memcpy noise that even `-O2` doesn't always undo cleanly. Inlining unlocks this — most "escaping" slots stop escaping once mutator shims vanish. |
| Dead store elimination on non-escaping slots | Same escape analysis as mem2reg; drop stores whose value is never read before being overwritten. | Free once the escape analysis exists. |
| Load-after-store forwarding | Within a block (or along a dominator path), `store v, p; ...; load p → v` provided nothing aliases `p`. | Mostly subsumed by mem2reg, but catches partial-slot cases mem2reg refuses. |

### Tier 3 — defer until measurement says they matter

| Pass | Why deferred |
|------|--------------|
| Heavy inlining (large bodies, multi-callsite duplication) | The C compiler does this well at `-O1+`. The Tier-2 inliner already catches the shim-wrapper case that matters. |
| SCCP | Combines const-fold + branch-fold + dataflow. More work; only pays off when constants flow through control flow. |
| GVN | Match identical computations across blocks. Heavyweight; unlikely to fire much until generics monomorphise into similar functions in large quantities. |
| LICM | The C compiler is great at this. Only do FIR-level LICM if profiling shows specific patterns the C compiler misses. |
| Tail-call optimization | Add only when needed for a specific feature (e.g. effect handlers, CPS). |

### Pass ordering

```
1. shim_inliner               (Tier 2 — the FLang-structural win)
2. fixed-point loop, cap 10:
     constant_fold
     branch_fold
     dce
     copy_prop
     empty_block_fusion
     gep_coalesce
     memintrinsic_cleanup
3. mem2reg                    (most escapes are gone now)
4. dse_non_escaping
5. load_store_forward
6. fixed-point loop again     (mem2reg always leaves cleanup work)
7. general inliner            (Tier 3 — optional)
8. fixed-point loop once more
9. dead_function_elimination
```

The shim inliner runs **before** the cleanup loop because it's what makes the cleanup loop see through opaque calls. mem2reg runs **after** the cleanup loop because by then most addresses-of-stack-slots flow through visible `gep` + `load`/`store` chains. Dead-function elimination runs **last** because earlier passes inline call sites and only the final reachability walk knows which functions still have referencers.

---

## 3. The inliner — detailed design

### 3.1 Why this isn't a generic perf optimization

FLang's scoped-mutability rules mean every "mutate a struct from a scope that's not your own" call is a wrapper of the shape:

```flang
pub fn add_function(self: &Module, f: Function) {
    self.functions.push(f)
}
```

— a 2-instruction FIR body. The caller pays for argument passing; the callee body does nothing except offset arithmetic. Without inlining, every mutation site emits:

```c
void add_function(void* self, void* f) {
    void* v0 = (void*)((char*)self + 0);
    List_Function_push(v0, f);
}
// ...
add_function(((void*)g_m), v_some_function);
```

Every project that adopts this pattern (and they all will, given the "Field-List `.push()` Silently No-Ops" known issue forces it) multiplies the call count. The C compiler will inline at `-O2`, but:

- `-O0` keeps all of it — debug builds become unreadable.
- Even at `-O2`, the C compiler sees fully-marshalled function-call bytes and has to undo our pass-by-pointer encoding before optimizing further.
- mem2reg cannot promote a stack-local struct as long as a mutator function takes its address opaquely. Inlining the mutator turns "address escapes to a call" into "address feeds a visible `gep` + `store`" — and now the slot is provably non-escaping.

So inlining isn't a Tier-3 optional optimization for FLang. It's the structural step that lets the rest of the pipeline see what's actually happening.

### 3.2 What we learned from the C# inliner (`src/FLang.IR/InliningPass.cs`)

Real lessons worth keeping:

1. **Function-reference scans must include global initializers.** They shipped without this and hit it: the global allocator vtable holds function pointers as struct fields. After inlining a vtable function's only direct callers, dead-function elimination would delete the function, leaving the vtable pointing at nothing. Any DCE that respects function references must scan every site a function can be referenced from — calls, function-ref operands, **and** structured global init payloads. For FIR today this is moot (`init_bytes: u8[]?` can't encode function pointers), but the moment that gap is closed, this codepath has to land too.

2. **An iteration cap is worth having.** C# uses 10. They presumably hit *something* pathological that justified the cap; free safety net regardless.

3. **The size threshold has to be empirical, not principled.** C#'s `MaxInlineInstructions = 15` isn't justified anywhere in code — it's been ground against real FLang code and the compiler self-hosts. Start from 15 (known-good lower bound on the FLang corpus), instrument the inliner to log when it bails because of size, tune from data.

4. **Avoid cross-pass identifier collisions by construction.** Their `_inlineCounter` is process-static because `IrOptimizer` re-invokes the inliner within a module and a per-`Run` counter would let two splices of the same callee at different call sites collide on `_inl0_` prefixes. The FIR equivalent is `Function.next_value_id` — by construction monotonic across runs. Lesson: **don't design an ID scheme that depends on caller discipline to stay collision-free; make the IR enforce freshness.**

What's a self-inflicted wound of the C# IR, *not* a lesson:

- **The single-basic-block restriction on inlinable callees.** SSA + block params makes multi-block splice cheap. C# restricted to single-block because their goto-style CFG made label renaming and ret-to-merge rewriting painful. FIR should not inherit that restriction — `Result`-style wrappers (`if err { return Err(...) }` then happy path) are multi-block by definition and exactly the kind of small shim we want to inline.
- **The `__test_` caller exclusion.** A workaround for an AddressOf remapping bug specific to their named-local IR. FIR doesn't have AddressOf as a concept; this bug class doesn't exist for us.
- **Function-scoped substitution map.** Their cross-block flow happens through named locals, not block-arg edges, so removing a `call` in block N could dangle a use in block N+1. FIR's SSA + block-params routes every cross-block flow through an explicit `br target(args)` edge — splice substitutions stay local to the splice.
- **Name-based param binding with `Remap` fallback for "same name, different object identity".** Positional SSA binding doesn't need any of it.

Gaps in the C# version that aren't principled choices, just "we didn't bother":

- **No single-callsite bonus.** Worth measuring whether functions called exactly once and slightly over the size threshold are common enough to justify a separate rule. Decide from data.
- **No shape-based bonus.** Same — measure whether pure `gep + (call|load|store) + ret` shapes routinely exceed the size threshold. If they don't, the size threshold catches them anyway.

### 3.3 Design

#### Eligibility

A callee is inlinable when:
- It's not the entry point (`name != "main"`).
- It's not in any call-graph SCC (Tarjan run once per inliner pass — covers self-recursion and mutual recursion uniformly).
- Its body is ≤ `N` instructions total across all blocks. Start `N = 15`; instrument and tune.
- Every call in its body is direct (no foreign, no indirect).

A caller is eligible when:
- It's not the entry point. (Matches C# precedent; revisit if measurement shows the entry point benefits.)

#### Splice mechanics

**Single-block callee** (the common shim case):

1. Bind `callee.params[i].id → caller's call.args[i]` operand (positional).
2. For every other SSA id in the callee, allocate a fresh id via `caller.fresh_value_id()` and record the mapping.
3. Inline the callee's instructions in-place, replacing the call. Rewrite operands through the id map.
4. `Ret(v)`: the (remapped) `v` operand becomes the call's replacement value. Update every later use of the call's result.
5. `Ret(None)`: drop. Void call has no result to remap.

**Multi-block callee** (the `Result`-style early-return case — genuine divergence from C#):

1. Split the caller's containing block at the call site:
   - Pre-call instructions stay in the original block (call it `A`).
   - Post-call instructions + original terminator move to a new block `A'` with a single block param `(result: ret_ty)` — no param when the callee is void.
2. Clone every callee block with a fresh label and fresh SSA ids. Bind params as above.
3. `A`'s new terminator becomes `br <cloned-callee-entry>`.
4. In cloned callee blocks: `Ret(v) → br A'(v)`, `Ret(None) → br A'`.
5. Replace the call's result with `A'`'s new param everywhere downstream.

The mechanics are bounded by the SSA invariants we already maintain. Validation (§6) catches splice mistakes.

#### Fixed-point loop

```
for pass in 0..10 {
    let scc = compute_scc(module.functions)
    let inlinable = module.functions.filter(eligible_callee, scc)
    if inlinable.is_empty() { break }
    let any_inlined = false
    for caller in module.functions where eligible_caller(caller) {
        any_inlined |= inline_calls_in(caller, inlinable)
    }
    if !any_inlined { break }
}
```

The loop converges leaves-first naturally: once a leaf is inlined into its callers, its callers may exceed the size threshold and drop out of `inlinable` on the next pass. No explicit topological sort needed.

---

## 4. Dead-function elimination

After the inliner loop has converged, walk reachability:

A function `f` is **live** when any of:
- `f.name == "main"` (the entry point).
- Some other live function contains a `Call` or `CallIndirect` targeting `f`.
- Some other live function contains a `FuncRef(f.name)` operand.
- (Future) Some global initializer contains a `GlobalInit::PtrTo(f.name, _)` — currently unreachable because FIR `Global.init_bytes: u8[]?` can't encode function pointers; **add this branch the moment that gap is closed** (the C# pipeline learned this the hard way).
- The function is exported as a `#foreign`-callable entry from FIR (when/if FIR grows that concept).

Drop every other function before C emission.

DCE also runs as a standalone pass — it picks up functions that became unused via non-inliner optimizations (e.g. constant folding eliminating a branch that was the only caller of some helper).

---

## 5. Pass interactions worth calling out

- **Inliner before mem2reg, always.** mem2reg's escape analysis is much stronger once shim calls are gone. Running mem2reg first wastes most of its passes on slots whose addresses still escape into opaque calls.
- **Cleanup loop between inliner and mem2reg.** The inliner produces dead instructions, redundant gep chains, and empty merge blocks. The cleanup loop normalises before mem2reg's escape analysis runs.
- **DCE everywhere.** Cheap, runs every pass.
- **Branch folding before empty-block-fusion.** Folding a `br_if` to unconditional `br` can make a successor block empty; fusion picks it up next iteration.
- **Constant folding inside the cleanup loop, not just at the start.** Inlining propagates constants through call sites; folding has to revisit.

---

## 6. Validator (debug builds of the compiler)

A `validate(module: &Module) -> Result((), ValidationError)` pass that runs after every optimization pass when the compiler itself is built in debug mode. Checks:

- **SSA validity** — every SSA id has exactly one definition, and every use is dominated by its definition.
- **Type agreement** — every instruction's operand types match the slots they're consumed in. Block-arg types match the target block's param types.
- **Terminator presence** — every block ends in exactly one terminator (`Br`, `BrIf`, `Ret`, `Unreachable`). No falling off the end.
- **Branch target resolution** — every `BlockTarget.label` resolves to a block in the same function. Arg count matches param count.
- **Foreign / direct call distinction** — `call @name` resolves to a defined function or a declared foreign decl. Variadic flag is consistent.

The inliner is the single most likely pass to corrupt the module silently. The C# pipeline didn't have a validator and paid for it (`__test_` caller exclusion is one consequence — they hit a corruption case during testing and worked around it rather than fixing it). For FIR, this is the place to spend ~200 LOC up front; every later pass becomes safer to write.

Validation is off in release builds of the compiler — it's a developer tool, not a runtime cost users pay.

---

## 7. Out of scope for this RFC

- **Outlining** (the inverse: deduplicating layout-equivalent specializations into a single shared function). Worth it only if measurement after this RFC shows specific functions duplicated where one shared copy would do. Rust calls this *polymorphization*; defer until measured pressure.
- **Cross-module inlining decisions based on profile data.** Static heuristic only.
- **`#inline(always)` / `#inline(never)` attributes** for fine-grained user control. Add when needed; the default heuristic should cover the common case. The shim case is unconditional enough that an attribute isn't load-bearing.
- **Inlining at the C backend level.** The C compiler's `-O2` does its own inlining; this RFC is FIR-level, with access to FLang-level structure the C backend doesn't see.
- **Tier-2 passes beyond the inliner (mem2reg, DSE, load-store forwarding).** Listed in §2 for context but each warrants its own RFC or follow-up.
- **Tier-3 passes (SCCP, GVN, LICM, tail-call opt).** Defer until measurement justifies them.

---

## 8. Open questions

1. **Initial size threshold.** Start at 15. The instrumentation point logs bail reasons; count bails-by-size against bails-by-other-reason on a representative build. Move the threshold by ±5 if the size-bail bucket dominates.
2. **Single-callsite bonus.** Measure: count functions with exactly one caller that exceed the size threshold. If that set is large and dominated by shim shapes, add the bonus; otherwise skip.
3. **Caller-eligibility for the entry point.** C# excludes `main` as a caller. Verify by experiment whether inlining into `main` corrupts anything in FIR (it shouldn't — but the C# precedent suggests there's a reason that wasn't documented).
4. **Validator cost in release builds of the compiler.** ~200 LOC, hot path on every pass; expected to be cheap but verify before defaulting it on. If too slow, gate on `DEBUG` and rely on tests.
5. **Multi-block inliner correctness under nested `Unreachable`.** Spell out behavior: if a cloned callee block ends in `Unreachable`, does it stay `Unreachable` or get rewritten to `br A'(undef)`? Probably stay — `Unreachable` means UB, no need to keep the merge well-formed from that path.
6. **Interaction with debug info / `#line` directives.** When the inliner splices, line directives in the inlined body should track to the callee's source spans, not the caller's. Both backends (C-emit `#line`, future LLVM DI) need this. Out of scope for the inliner itself but flagged here so it's not forgotten.

---

## 9. Implementation phases

Each phase is shippable independently and unlocks the next. Ship in order.

| Phase | Scope | Validation |
|-------|-------|------------|
| **0** | `validate(module)` — the verifier. Run after every existing FIR construction site. | Self-test against the current `tools/fir_test` and `tools/codegen_demo` modules. Catches anything pre-existing. |
| **1** | DCE of dead instructions (the easy half) + dead-function elimination. No inliner. Includes the global-init-scan branch (currently inert, but wired). | A test where a `pub fn` is never called — verify it's absent from emitted C. |
| **2** | Tier-1 cleanup loop: const-fold, branch-fold, copy-prop, empty-block-fusion, gep-coalesce, memintrinsic-cleanup. | Property tests on hand-built FIR: each pass is a no-op on already-canonical input. |
| **3** | **Shim inliner, single-block callees only.** Catches the mutator-wrapper case. The 80/20 win. | Test: a hand-built FIR module with `add_function(self, f) { self.list.push(f) }` — verify the wrapper is gone from C output and the call site emits a direct push. |
| **4** | **Shim inliner, multi-block callees.** Adds `Result`-style early-return support. | Test: `add_entry(...) Result(_, _)` wrapper with one early `return Err(...)` — verify inlining produces correct CFG. |
| **5** | mem2reg / SROA on non-escaping `stack_slot`s. | Test: hand-built FIR with a non-escaping stack slot — verify it's eliminated, scalar uses survive. |
| **6** | DSE on non-escaping slots, load-store forwarding. | Falls out of the same escape analysis. |
| **7+** | Measurement, threshold tuning, Tier-3 decisions. | Real-program benchmarks (bootstrap compiler self-build time, generated C line count on `examples/`). |

---

## 10. References

- C# inliner today: `src/FLang.IR/InliningPass.cs` — the named-local-IR predecessor.
- C# dead-function elimination: same file, `EliminateDeadFunctions`.
- LLVM `InlineFunction`: the canonical multi-block-splice reference.
- Cranelift inliner: closer to FIR's structural simplicity than LLVM.
- FIR design: `docs/fir.md`.
- Related: RFC-014 (callable types and closures) — adds many small `op_call` functions that the inliner will need to handle.
