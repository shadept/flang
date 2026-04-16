using FLang.IR.Instructions;

namespace FLang.IR;

/// <summary>
/// Orchestrates the full IR optimization pipeline between AST lowering and
/// C codegen. Owns the cascade loop: callers just invoke <see cref="Run"/>
/// and get back a fully-optimized module. Adding, removing, or reordering
/// passes is transparent to callers.
///
/// This is also the natural place to gate passes on future compiler flags
/// (e.g. `--O0` / `--O2` / debug-friendly builds): add a config argument
/// here, consult it before calling each pass.
///
/// ## Fixed-point strategy
///
/// Individual passes are single-pass and do NOT iterate internally.
/// Cascading eliminations (one pass's output exposes more work for another)
/// are handled by the loop inside <see cref="Run"/>, which re-invokes the
/// pipeline until no pass reports change (capped by
/// <see cref="MaxIterations"/> as a safety net). This keeps each pass cheap
/// and predictable; the only cost is one extra module-wide iteration per
/// cascade level. In practice the IR we emit rarely cascades more than a
/// few levels.
///
/// Within one call to <see cref="OptimizeFunction"/> we do run DCE twice —
/// once before DSE (so DSE sees a cleaned graph and doesn't treat orphan
/// loads as alloca reads) and once after (to sweep the orphans DSE exposes).
/// Each is a single pass, not a fixpoint.
/// </summary>
public static class IrOptimizer
{
    /// <summary>
    /// Safety cap on the outer cascade loop. A well-behaved pipeline settles
    /// in 2–3 iterations; anything near this cap indicates a pass oscillating.
    /// </summary>
    private const int MaxIterations = 10;

    /// <summary>
    /// Runs the optimization pipeline — inliner + per-function passes —
    /// repeatedly until no pass reports change. Returns when the module
    /// is stable (or after <see cref="MaxIterations"/> iterations).
    /// </summary>
    public static void Run(IrModule module)
    {
        for (int i = 0; i < MaxIterations; i++)
        {
            // Optimize BEFORE inline. Rationale: the inliner's heuristic is
            // based on raw instruction count against a fixed threshold. A
            // function sitting just over the threshold but containing dead
            // stores, unused allocas, or forwardable loads will be inlined
            // iff we simplify it first. Opt-then-inline also saves cascade
            // iterations — the shrunk form reaches the inliner the same
            // round it was produced, rather than the next outer iteration.
            bool optChanged = false;
            foreach (var fn in module.Functions)
                optChanged |= OptimizeFunction(fn);

            int fnCountBefore = module.Functions.Count;
            InliningPass.Run(module);
            bool inlineChanged = module.Functions.Count != fnCountBefore;

            if (!inlineChanged && !optChanged) break;
        }
    }

    private static bool OptimizeFunction(IrFunction fn)
    {
        var substitutions = new Dictionary<Value, Value>();
        var dead = new HashSet<Instruction>();
        bool changed = false;

        changed |= PeepholeOptimizer.Run(fn, substitutions, dead);
        changed |= DeadCodeElimination.Run(fn, substitutions, dead);
        changed |= DeadStoreElimination.Run(fn, substitutions, dead);
        // Second DCE sweep catches what DSE just exposed (orphan GEPs/loads
        // feeding the now-dead stores). Single pass; the outer cascade
        // loop handles any deeper cascade on the next iteration.
        changed |= DeadCodeElimination.Run(fn, substitutions, dead);

        if (changed)
            Rebuild(fn, substitutions, dead);

        return changed;
    }

    private static void Rebuild(
        IrFunction fn,
        Dictionary<Value, Value> substitutions,
        HashSet<Instruction> dead)
    {
        if (substitutions.Count == 0 && dead.Count == 0) return;

        foreach (var block in fn.BasicBlocks)
        {
            var newInstructions = new List<Instruction>(block.Instructions.Count);
            foreach (var inst in block.Instructions)
            {
                if (dead.Contains(inst)) continue;
                newInstructions.Add(IrInstructionHelpers.RewriteOperands(inst, substitutions));
            }
            block.Instructions.Clear();
            block.Instructions.AddRange(newInstructions);
        }
    }
}
