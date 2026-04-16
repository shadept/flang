using FLang.IR.Instructions;

namespace FLang.IR;

/// <summary>
/// Removes StorePointer/Copy/CopyToOffset instructions that write to allocas
/// whose contents are never read and whose address never escapes. These are
/// otherwise kept alive by their "side effect" status even though no observer
/// ever witnesses the written value.
///
/// Algorithm:
///  1. Collect all allocas (keyed by name — see identity note below).
///  2. Build a derivation map: local-pointer name -> root alloca name.
///     GEPs and casts propagate derivation; fixed-point internal to step 2
///     until stable (this is a small, cheap traversal; not the kind of
///     cascade we want the driver loop to handle).
///  3. Walk every instruction. Any use of a derived pointer outside the
///     destination slot of a pure store marks that alloca as live. This
///     covers: loads, reads via Copy/CopyFromOffset src, pointer stored as
///     a value (escape), call arguments, returns, branches, and AddressOf
///     by matching variable name.
///  4. For each alloca not marked live, mark all writes targeting any
///     pointer derived from it as dead. A subsequent <see cref="DeadCodeElimination"/>
///     sweep then removes orphaned GEPs, loads, and the alloca itself.
///
/// Identity note: local <see cref="Value"/> instances are NOT reliably
/// reference-equal across the IR. An <see cref="AllocaInstruction"/>'s
/// Result can be a different LocalValue instance from the SrcPtr/DstPtr
/// that later read or write through it — they share only a Name. Therefore
/// everything here is keyed by name, not by reference.
/// </summary>
public static class DeadStoreElimination
{
    public static bool Run(
        IrFunction fn,
        Dictionary<Value, Value> substitutions,
        HashSet<Instruction> dead)
    {
        int deadBefore = dead.Count;

        static string? LocalKey(Value v) => v is LocalValue ? v.Name : null;

        // Step 1: collect allocas by name
        var allocaNames = new HashSet<string>();
        foreach (var block in fn.BasicBlocks)
        {
            foreach (var inst in block.Instructions)
            {
                if (dead.Contains(inst)) continue;
                if (inst is AllocaInstruction a && a.Result.Name is string n)
                    allocaNames.Add(n);
            }
        }
        if (allocaNames.Count == 0) return false;

        // Step 2: derivation map — local name -> root alloca name.
        var derivedFrom = new Dictionary<string, string>();
        foreach (var n in allocaNames) derivedFrom[n] = n;

        string? RootOf(Value v)
        {
            var r = IrInstructionHelpers.Resolve(substitutions, v);
            var key = LocalKey(r);
            if (key != null && derivedFrom.TryGetValue(key, out var root))
                return root;
            return null;
        }

        bool grew = true;
        while (grew)
        {
            grew = false;
            foreach (var block in fn.BasicBlocks)
            {
                foreach (var inst in block.Instructions)
                {
                    if (dead.Contains(inst)) continue;
                    if (inst is GetElementPtrInstruction gep)
                    {
                        var root = RootOf(gep.BasePointer);
                        var key = LocalKey(gep.Result);
                        if (root != null && key != null && !derivedFrom.ContainsKey(key))
                        {
                            derivedFrom[key] = root;
                            grew = true;
                        }
                    }
                    else if (inst is CastInstruction cast)
                    {
                        var root = RootOf(cast.Source);
                        var key = LocalKey(cast.Result);
                        if (root != null && key != null && !derivedFrom.ContainsKey(key))
                        {
                            derivedFrom[key] = root;
                            grew = true;
                        }
                    }
                }
            }
        }

        // Step 3: compute live set of alloca names — any alloca whose derived
        // pointer is used anywhere other than as the destination of a pure
        // store/copy, or whose name is taken via AddressOf.
        var live = new HashSet<string>();

        void MarkLive(Value v)
        {
            var root = RootOf(v);
            if (root != null) live.Add(root);
        }

        foreach (var block in fn.BasicBlocks)
        {
            foreach (var inst in block.Instructions)
            {
                if (dead.Contains(inst)) continue;

                switch (inst)
                {
                    case AllocaInstruction:
                        break; // defining instruction — not a use

                    case AddressOfInstruction ao:
                        if (allocaNames.Contains(ao.VariableName))
                            live.Add(ao.VariableName);
                        break;

                    case LoadInstruction load:
                        MarkLive(load.Pointer);
                        break;

                    case StorePointerInstruction sp:
                        // Destination pointer does NOT make the alloca live — it's a pure store.
                        // Value side DOES — storing the address of the alloca elsewhere is escape.
                        MarkLive(sp.Value);
                        break;

                    case CopyInstruction cp:
                        // SrcPtr reads — live. DstPtr is pure store — not live by itself.
                        MarkLive(cp.SrcPtr);
                        break;

                    case CopyFromOffsetInstruction cfo:
                        MarkLive(cfo.SrcPtr);
                        MarkLive(cfo.ByteOffset);
                        break;

                    case CopyToOffsetInstruction cto:
                        // Val side: storing the alloca's address elsewhere is escape.
                        MarkLive(cto.Val);
                        MarkLive(cto.ByteOffset);
                        break;

                    case GetElementPtrInstruction gep:
                        // Base handled by derivation map; the GEP itself isn't a "use"
                        // of its base in the sense that matters — it just derives a new
                        // pointer. The derived pointer's uses downstream decide.
                        MarkLive(gep.ByteOffset);
                        break;

                    case CastInstruction:
                        // Cast source derivation is tracked above. Cast itself doesn't
                        // force liveness — the downstream use of the cast result does.
                        break;

                    case CallInstruction call:
                        foreach (var arg in call.Arguments) MarkLive(arg);
                        break;

                    case IndirectCallInstruction icall:
                        MarkLive(icall.FunctionPointer);
                        foreach (var arg in icall.Arguments) MarkLive(arg);
                        break;

                    case ReturnInstruction ret:
                        MarkLive(ret.Value);
                        break;

                    case BinaryInstruction bin:
                        MarkLive(bin.Left);
                        MarkLive(bin.Right);
                        break;

                    case UnaryInstruction un:
                        MarkLive(un.Operand);
                        break;

                    case BranchInstruction br:
                        MarkLive(br.Condition);
                        break;

                    case StoreInstruction s:
                        // StoreInstruction writes to a named local; its Value might be a
                        // derived pointer being squirreled away — treat as escape.
                        MarkLive(s.Value);
                        break;
                }
            }
        }

        // Step 4: kill writes to dead allocas
        foreach (var block in fn.BasicBlocks)
        {
            foreach (var inst in block.Instructions)
            {
                if (dead.Contains(inst)) continue;

                string? dstRoot = inst switch
                {
                    StorePointerInstruction sp => RootOf(sp.Pointer),
                    CopyInstruction cp => RootOf(cp.DstPtr),
                    CopyToOffsetInstruction cto => RootOf(cto.DstPtr),
                    _ => null
                };

                if (dstRoot != null && !live.Contains(dstRoot))
                    dead.Add(inst);
            }
        }

        return dead.Count != deadBefore;
    }
}
