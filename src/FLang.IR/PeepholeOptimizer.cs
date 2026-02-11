using FLang.IR.Instructions;

namespace FLang.IR;

/// <summary>
/// IR peephole optimization pass that runs after lowering and before C codegen.
/// Performs store-load forwarding, copy fusion, and dead code elimination.
/// </summary>
public static class PeepholeOptimizer
{
    public static void Optimize(IrModule module)
    {
        foreach (var fn in module.Functions)
            OptimizeFunction(fn);
    }

    private static void OptimizeFunction(IrFunction fn)
    {
        var substitutions = new Dictionary<Value, Value>();
        var dead = new HashSet<Instruction>();

        // Phase 1: Store-Load Forwarding (per block)
        foreach (var block in fn.BasicBlocks)
            StoreLoadForwarding(block, substitutions, dead);

        // Phase 2: Copy Fusion (per block, needs function-wide use counts)
        var useCounts = BuildUseCounts(fn, substitutions, dead);
        foreach (var block in fn.BasicBlocks)
            CopyFusion(block, substitutions, dead, useCounts);

        // Phase 3: Dead Code Elimination (function-wide)
        DeadCodeElimination(fn, substitutions, dead);

        // Phase 4: Rebuild blocks with substitutions applied, dead instructions removed
        Rebuild(fn, substitutions, dead);
    }

    private static Value Resolve(Dictionary<Value, Value> subs, Value v)
    {
        while (subs.TryGetValue(v, out var replacement))
            v = replacement;
        return v;
    }

    // ── Phase 1 ──────────────────────────────────────────────────────────

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
                    var ptr = Resolve(substitutions, sp.Pointer);
                    var val = Resolve(substitutions, sp.Value);
                    // Conservative: any store might alias other tracked pointers
                    // (e.g., storing to a GEP of an alloca invalidates the alloca's entry).
                    // Clear all, then record this store.
                    pointerStore.Clear();
                    pointerStore[ptr] = val;
                    break;
                }

                case LoadInstruction load:
                {
                    var ptr = Resolve(substitutions, load.Pointer);
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

    // ── Phase 2: Copy Fusion ─────────────────────────────────────────────

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
                foreach (var op in GetOperands(inst))
                {
                    var resolved = Resolve(substitutions, op);
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

            // Pattern 1: Load + StorePointer → Copy
            if (producer is LoadInstruction load && consumer is StorePointerInstruction store)
            {
                var resolvedStoreVal = Resolve(substitutions, store.Value);
                if (resolvedStoreVal == load.Result)
                {
                    useCounts.TryGetValue(load.Result, out int uses);
                    if (uses == 1)
                    {
                        var srcPtr = Resolve(substitutions, load.Pointer);
                        var dstPtr = Resolve(substitutions, store.Pointer);
                        var valueType = load.Result.IrType ?? TypeLayoutService.IrI32;
                        var copy = new CopyInstruction(load.Span, srcPtr, dstPtr, valueType);
                        instructions[i] = copy;
                        dead.Add(consumer);
                        continue;
                    }
                }
            }

            // Pattern 2: GEP + Load → CopyFromOffset
            if (producer is GetElementPtrInstruction gep1 && consumer is LoadInstruction load2)
            {
                var resolvedLoadPtr = Resolve(substitutions, load2.Pointer);
                if (resolvedLoadPtr == gep1.Result)
                {
                    useCounts.TryGetValue(gep1.Result, out int uses);
                    if (uses == 1)
                    {
                        var basePtr = Resolve(substitutions, gep1.BasePointer);
                        var offset = Resolve(substitutions, gep1.ByteOffset);
                        var copyFrom = new CopyFromOffsetInstruction(gep1.Span, basePtr, offset, load2.Result);
                        instructions[i] = copyFrom;
                        dead.Add(consumer);
                        continue;
                    }
                }
            }

            // Pattern 3: GEP + StorePointer → CopyToOffset
            if (producer is GetElementPtrInstruction gep2 && consumer is StorePointerInstruction store2)
            {
                var resolvedStorePtr = Resolve(substitutions, store2.Pointer);
                if (resolvedStorePtr == gep2.Result)
                {
                    useCounts.TryGetValue(gep2.Result, out int uses);
                    if (uses == 1)
                    {
                        var basePtr = Resolve(substitutions, gep2.BasePointer);
                        var offset = Resolve(substitutions, gep2.ByteOffset);
                        var val = Resolve(substitutions, store2.Value);
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

    // ── Phase 3 ──────────────────────────────────────────────────────────

    private static void DeadCodeElimination(
        IrFunction fn,
        Dictionary<Value, Value> substitutions,
        HashSet<Instruction> dead)
    {
        // Build use counts (function-wide)
        bool changed = true;
        while (changed)
        {
            changed = false;
            var useCounts = new Dictionary<Value, int>();

            // Count uses across all blocks
            foreach (var block in fn.BasicBlocks)
            {
                foreach (var inst in block.Instructions)
                {
                    if (dead.Contains(inst)) continue;
                    foreach (var op in GetOperands(inst))
                    {
                        var resolved = Resolve(substitutions, op);
                        useCounts.TryGetValue(resolved, out int count);
                        useCounts[resolved] = count + 1;
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

                    var result = GetResult(inst);
                    if (result == null) continue;

                    var resolvedResult = Resolve(substitutions, result);
                    useCounts.TryGetValue(resolvedResult, out int uses);
                    if (uses == 0)
                    {
                        dead.Add(inst);
                        changed = true;
                    }
                }
            }
        }
    }

    private static bool IsSideEffectFree(Instruction inst) => inst is
        AllocaInstruction or LoadInstruction or CastInstruction or
        BinaryInstruction or UnaryInstruction or GetElementPtrInstruction or
        AddressOfInstruction or CopyFromOffsetInstruction;

    // ── Phase 4 ──────────────────────────────────────────────────────────

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
                newInstructions.Add(RewriteOperands(inst, substitutions));
            }
            block.Instructions.Clear();
            block.Instructions.AddRange(newInstructions);
        }
    }

    private static Instruction RewriteOperands(Instruction inst, Dictionary<Value, Value> subs)
    {
        // Only rewrite if at least one operand actually changes
        bool anyChanged = false;
        foreach (var op in GetOperands(inst))
        {
            if (subs.ContainsKey(op)) { anyChanged = true; break; }
        }
        if (!anyChanged) return inst;

        Value R(Value v) => Resolve(subs, v);
        IReadOnlyList<Value> RList(IReadOnlyList<Value> vs)
        {
            var list = new List<Value>(vs.Count);
            foreach (var v in vs)
                list.Add(R(v));
            return list;
        }

        switch (inst)
        {
            case BinaryInstruction b:
                return new BinaryInstruction(b.Span, b.Operation, R(b.Left), R(b.Right), b.Result);

            case UnaryInstruction u:
                return new UnaryInstruction(u.Span, u.Operation, R(u.Operand), u.Result);

            case CallInstruction c:
            {
                var newCall = new CallInstruction(c.Span, c.FunctionName, RList(c.Arguments), c.Result)
                {
                    CalleeIrParamTypes = c.CalleeIrParamTypes,
                    IsForeignCall = c.IsForeignCall,
                    IsIndirectCall = c.IsIndirectCall
                };
                return newCall;
            }

            case IndirectCallInstruction ic:
                return new IndirectCallInstruction(ic.Span, R(ic.FunctionPointer), RList(ic.Arguments), ic.Result);

            case LoadInstruction l:
                return new LoadInstruction(l.Span, R(l.Pointer), l.Result);

            case StoreInstruction s:
                return new StoreInstruction(s.Span, s.VariableName, R(s.Value), s.Result);

            case StorePointerInstruction sp:
                return new StorePointerInstruction(sp.Span, R(sp.Pointer), R(sp.Value));

            case AllocaInstruction a:
                return a; // no operands to rewrite

            case GetElementPtrInstruction g:
                return new GetElementPtrInstruction(g.Span, R(g.BasePointer), R(g.ByteOffset), g.Result);

            case CastInstruction ca:
                return new CastInstruction(ca.Span, R(ca.Source), ca.Result);

            case AddressOfInstruction ao:
                return ao; // operand is a string name, not a Value

            case ReturnInstruction r:
                return new ReturnInstruction(r.Span, R(r.Value));

            case JumpInstruction j:
                return j; // no Value operands

            case BranchInstruction br:
                return new BranchInstruction(br.Span, R(br.Condition), br.TrueBlock, br.FalseBlock);

            case CopyInstruction cp:
                return new CopyInstruction(cp.Span, R(cp.SrcPtr), R(cp.DstPtr), cp.ValueType);

            case CopyFromOffsetInstruction cfo:
                return new CopyFromOffsetInstruction(cfo.Span, R(cfo.SrcPtr), R(cfo.ByteOffset), cfo.Result);

            case CopyToOffsetInstruction cto:
                return new CopyToOffsetInstruction(cto.Span, R(cto.Val), R(cto.DstPtr), R(cto.ByteOffset), cto.ValueType);

            default:
                return inst;
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    private static Value? GetResult(Instruction inst) => inst switch
    {
        BinaryInstruction b => b.Result,
        UnaryInstruction u => u.Result,
        CallInstruction c => c.Result,
        IndirectCallInstruction ic => ic.Result,
        LoadInstruction l => l.Result,
        StoreInstruction s => s.Result,
        AllocaInstruction a => a.Result,
        GetElementPtrInstruction g => g.Result,
        CastInstruction ca => ca.Result,
        AddressOfInstruction ao => ao.Result,
        CopyFromOffsetInstruction cfo => cfo.Result,
        _ => null
    };

    private static IEnumerable<Value> GetOperands(Instruction inst)
    {
        switch (inst)
        {
            case BinaryInstruction b:
                yield return b.Left;
                yield return b.Right;
                break;
            case UnaryInstruction u:
                yield return u.Operand;
                break;
            case CallInstruction c:
                foreach (var a in c.Arguments) yield return a;
                break;
            case IndirectCallInstruction ic:
                yield return ic.FunctionPointer;
                foreach (var a in ic.Arguments) yield return a;
                break;
            case LoadInstruction l:
                yield return l.Pointer;
                break;
            case StoreInstruction s:
                yield return s.Value;
                break;
            case StorePointerInstruction sp:
                yield return sp.Pointer;
                yield return sp.Value;
                break;
            case GetElementPtrInstruction g:
                yield return g.BasePointer;
                yield return g.ByteOffset;
                break;
            case CastInstruction ca:
                yield return ca.Source;
                break;
            case ReturnInstruction r:
                yield return r.Value;
                break;
            case BranchInstruction br:
                yield return br.Condition;
                break;
            case CopyInstruction cp:
                yield return cp.SrcPtr;
                yield return cp.DstPtr;
                break;
            case CopyFromOffsetInstruction cfo:
                yield return cfo.SrcPtr;
                yield return cfo.ByteOffset;
                break;
            case CopyToOffsetInstruction cto:
                yield return cto.Val;
                yield return cto.DstPtr;
                yield return cto.ByteOffset;
                break;
            // AllocaInstruction, AddressOfInstruction, JumpInstruction: no Value operands
        }
    }
}
