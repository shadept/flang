using FLang.IR.Instructions;

namespace FLang.IR;

/// <summary>
/// Local, sliding-window IR rewrites. Contains only patterns whose validity
/// can be decided by looking at an instruction and its immediate neighbours
/// within a single basic block:
///
///  - Store-load forwarding: a load from a pointer just written to resolves
///    to the stored value.
///  - Copy fusion: combine load+store or GEP+load/store pairs into the
///    fused <see cref="CopyInstruction"/>, <see cref="CopyFromOffsetInstruction"/>,
///    and <see cref="CopyToOffsetInstruction"/> forms when the intermediate
///    value has a single use.
///
/// Function-wide work (dead code elimination, dead store elimination, final
/// rebuild) lives in dedicated passes driven by <see cref="IrOptimizer"/>.
///
/// Returns true if any pattern matched; the orchestrator uses this to decide
/// whether another optimization iteration is worth running.
/// </summary>
public static class PeepholeOptimizer
{
    public static bool Run(
        IrFunction fn,
        Dictionary<Value, Value> substitutions,
        HashSet<Instruction> dead)
    {
        int subsBefore = substitutions.Count;
        int deadBefore = dead.Count;

        foreach (var block in fn.BasicBlocks)
            StoreLoadForwarding(block, substitutions, dead);

        var useCounts = BuildUseCounts(fn, substitutions, dead);
        foreach (var block in fn.BasicBlocks)
            CopyFusion(block, substitutions, dead, useCounts);

        return substitutions.Count != subsBefore || dead.Count != deadBefore;
    }

    // ── Store-load forwarding ────────────────────────────────────────────

    private static void StoreLoadForwarding(
        BasicBlock block,
        Dictionary<Value, Value> substitutions,
        HashSet<Instruction> dead)
    {
        var pointerStore = new Dictionary<Value, Value>();

        foreach (var inst in block.Instructions)
        {
            switch (inst)
            {
                case StorePointerInstruction sp:
                    {
                        var ptr = IrInstructionHelpers.Resolve(substitutions, sp.Pointer);
                        var val = IrInstructionHelpers.Resolve(substitutions, sp.Value);
                        // Conservative: any store might alias other tracked pointers
                        // (e.g., storing to a GEP of an alloca invalidates the alloca's entry).
                        // Clear all, then record this store.
                        pointerStore.Clear();
                        pointerStore[ptr] = val;
                        break;
                    }

                case LoadInstruction load:
                    {
                        var ptr = IrInstructionHelpers.Resolve(substitutions, load.Pointer);
                        if (pointerStore.TryGetValue(ptr, out var stored)
                            && TypesMatch(stored.IrType, load.Result.IrType))
                        {
                            substitutions[load.Result] = stored;
                            dead.Add(inst);
                        }
                        break;
                    }

                case CallInstruction:
                case IndirectCallInstruction:
                    // Conservative: callee may write through pointer args
                    pointerStore.Clear();
                    break;
            }
        }
    }

    private static bool TypesMatch(IrType? a, IrType? b)
    {
        if (a is null || b is null) return false;
        return a == b;
    }

    // ── Copy fusion ──────────────────────────────────────────────────────

    private static Dictionary<Value, int> BuildUseCounts(
        IrFunction fn,
        Dictionary<Value, Value> substitutions,
        HashSet<Instruction> dead)
    {
        var useCounts = new Dictionary<Value, int>();
        foreach (var block in fn.BasicBlocks)
        {
            foreach (var inst in block.Instructions)
            {
                if (dead.Contains(inst)) continue;
                foreach (var op in IrInstructionHelpers.GetOperands(inst))
                {
                    var resolved = IrInstructionHelpers.Resolve(substitutions, op);
                    useCounts.TryGetValue(resolved, out int count);
                    useCounts[resolved] = count + 1;
                }
            }
        }
        return useCounts;
    }

    private static void CopyFusion(
        BasicBlock block,
        Dictionary<Value, Value> substitutions,
        HashSet<Instruction> dead,
        Dictionary<Value, int> useCounts)
    {
        var instructions = block.Instructions;
        for (int i = 0; i < instructions.Count - 1; i++)
        {
            var producer = instructions[i];
            if (dead.Contains(producer)) continue;

            // Find next non-dead instruction
            int j = i + 1;
            while (j < instructions.Count && dead.Contains(instructions[j]))
                j++;
            if (j >= instructions.Count) break;

            var consumer = instructions[j];
            if (dead.Contains(consumer)) continue;

            // Pattern 1: Load + StorePointer -> Copy
            if (producer is LoadInstruction load && consumer is StorePointerInstruction store)
            {
                var resolvedStoreVal = IrInstructionHelpers.Resolve(substitutions, store.Value);
                if (resolvedStoreVal == load.Result)
                {
                    useCounts.TryGetValue(load.Result, out int uses);
                    if (uses == 1)
                    {
                        var srcPtr = IrInstructionHelpers.Resolve(substitutions, load.Pointer);
                        var dstPtr = IrInstructionHelpers.Resolve(substitutions, store.Pointer);
                        var valueType = load.Result.IrType ?? TypeLayoutService.IrI32;
                        var copy = new CopyInstruction(load.Span, srcPtr, dstPtr, valueType);
                        instructions[i] = copy;
                        dead.Add(consumer);
                        continue;
                    }
                }
            }

            // Pattern 2: GEP + Load -> CopyFromOffset
            if (producer is GetElementPtrInstruction gep1 && consumer is LoadInstruction load2)
            {
                var resolvedLoadPtr = IrInstructionHelpers.Resolve(substitutions, load2.Pointer);
                if (resolvedLoadPtr == gep1.Result)
                {
                    useCounts.TryGetValue(gep1.Result, out int uses);
                    if (uses == 1)
                    {
                        var basePtr = IrInstructionHelpers.Resolve(substitutions, gep1.BasePointer);
                        var offset = IrInstructionHelpers.Resolve(substitutions, gep1.ByteOffset);
                        var copyFrom = new CopyFromOffsetInstruction(gep1.Span, basePtr, offset, load2.Result);
                        instructions[i] = copyFrom;
                        dead.Add(consumer);
                        continue;
                    }
                }
            }

            // Pattern 3: GEP + StorePointer -> CopyToOffset
            if (producer is GetElementPtrInstruction gep2 && consumer is StorePointerInstruction store2)
            {
                var resolvedStorePtr = IrInstructionHelpers.Resolve(substitutions, store2.Pointer);
                if (resolvedStorePtr == gep2.Result)
                {
                    useCounts.TryGetValue(gep2.Result, out int uses);
                    if (uses == 1)
                    {
                        var basePtr = IrInstructionHelpers.Resolve(substitutions, gep2.BasePointer);
                        var offset = IrInstructionHelpers.Resolve(substitutions, gep2.ByteOffset);
                        var val = IrInstructionHelpers.Resolve(substitutions, store2.Value);
                        // Determine the value type from the GEP result (pointer to field)
                        var valueType = gep2.Result.IrType is IrPointer p ? p.Pointee : store2.Value.IrType ?? TypeLayoutService.IrI32;
                        var copyTo = new CopyToOffsetInstruction(gep2.Span, val, basePtr, offset, valueType);
                        instructions[i] = copyTo;
                        dead.Add(consumer);
                        continue;
                    }
                }
            }
        }
    }
}
