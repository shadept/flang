using FLang.IR.Instructions;

namespace FLang.IR;

/// <summary>
/// Removes side-effect-free instructions whose result has zero remaining
/// uses. Single pass — does NOT iterate to a fixed point. Cascading
/// eliminations (an instruction whose only user we just killed) are
/// handled by the driver loop in <see cref="IrOptimizer"/>, which re-runs
/// the whole pipeline until no pass reports change.
///
/// Keeping this pass single-pass is a deliberate trade: it may take more
/// outer iterations to reach a fixed point, but each call has predictable
/// O(fn) cost and the code stays simple.
/// </summary>
public static class DeadCodeElimination
{
    public static bool Run(
        IrFunction fn,
        Dictionary<Value, Value> substitutions,
        HashSet<Instruction> dead)
    {
        int deadBefore = dead.Count;

        // AddressOfInstruction references variables by string name, not by Value.
        // Collect these names so DCE doesn't remove the defining instructions —
        // the C emitter will still need the named local.
        var addressOfTargets = new HashSet<string>();
        foreach (var block in fn.BasicBlocks)
            foreach (var inst in block.Instructions)
                if (!dead.Contains(inst) && inst is AddressOfInstruction ao)
                    addressOfTargets.Add(ao.VariableName);

        // Identity is name-keyed for LocalValues — see the note on DeadStoreElimination
        // for why: a LocalValue produced by one instruction may be a separate object
        // instance from the LocalValue used downstream, even though both refer to the
        // same SSA name (e.g. an empty array literal returns `new LocalValue(allocaName,
        // IrArray)` while the alloca's Result is `LocalValue(allocaName, IrPointer)` —
        // reference equality misses the use entirely and the alloca is wrongly DCE'd).
        // Constants and other non-Local values fall back to reference identity.
        static object KeyOf(Value v) => v is LocalValue && v.Name is { } n ? n : v;

        // Count uses across all blocks
        var useCounts = new Dictionary<object, int>();
        foreach (var block in fn.BasicBlocks)
        {
            foreach (var inst in block.Instructions)
            {
                if (dead.Contains(inst)) continue;
                foreach (var op in IrInstructionHelpers.GetOperands(inst))
                {
                    var resolved = IrInstructionHelpers.Resolve(substitutions, op);
                    var key = KeyOf(resolved);
                    useCounts.TryGetValue(key, out int count);
                    useCounts[key] = count + 1;
                }
            }
        }

        // Remove instructions with 0-use results and no side effects
        foreach (var block in fn.BasicBlocks)
        {
            foreach (var inst in block.Instructions)
            {
                if (dead.Contains(inst)) continue;
                if (!IsSideEffectFree(inst)) continue;

                var result = IrInstructionHelpers.GetResult(inst);
                if (result == null) continue;

                var resolvedResult = IrInstructionHelpers.Resolve(substitutions, result);
                useCounts.TryGetValue(KeyOf(resolvedResult), out int uses);
                if (uses != 0) continue;

                // Protect variables referenced by AddressOf instructions
                if (resolvedResult.Name != null && addressOfTargets.Contains(resolvedResult.Name))
                    continue;

                dead.Add(inst);
            }
        }

        return dead.Count != deadBefore;
    }

    private static bool IsSideEffectFree(Instruction inst) => inst is
        AllocaInstruction or LoadInstruction or CastInstruction or
        BinaryInstruction or UnaryInstruction or GetElementPtrInstruction or
        AddressOfInstruction or CopyFromOffsetInstruction;
}
