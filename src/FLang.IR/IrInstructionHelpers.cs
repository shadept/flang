using FLang.IR.Instructions;

namespace FLang.IR;

/// <summary>
/// Shared utilities used by optimization passes and the inliner:
/// value resolution through a substitution map, operand/result extraction,
/// and operand rewriting. These live outside any single pass because
/// the inliner and every optimization pass need them.
/// </summary>
public static class IrInstructionHelpers
{
    /// <summary>
    /// Walks a substitution map to its fixed point. Used when a prior pass
    /// has forwarded a load result to the stored value, etc.
    /// </summary>
    public static Value Resolve(Dictionary<Value, Value> subs, Value v)
    {
        while (subs.TryGetValue(v, out var replacement))
            v = replacement;
        return v;
    }

    /// <summary>
    /// Yields the <see cref="Value"/> operands an instruction reads. Instructions
    /// that reference their inputs by string name (<see cref="AllocaInstruction"/>,
    /// <see cref="AddressOfInstruction"/>, <see cref="JumpInstruction"/>) yield
    /// nothing here — callers handle those cases explicitly.
    /// </summary>
    public static IEnumerable<Value> GetOperands(Instruction inst)
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
        }
    }

    /// <summary>
    /// The SSA value an instruction defines, or null for pure-side-effect
    /// instructions (stores, copies, jumps, returns, etc.).
    /// </summary>
    public static Value? GetResult(Instruction inst) => inst switch
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

    /// <summary>
    /// Returns a new instruction with its <see cref="Value"/> operands rewritten
    /// through <paramref name="subs"/>. If no operand actually changes, the
    /// original instruction is returned unchanged to avoid needless allocation.
    /// Used by <see cref="IrOptimizer"/> during the final rebuild.
    /// </summary>
    public static Instruction RewriteOperands(Instruction inst, Dictionary<Value, Value> subs)
    {
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
                return new CallInstruction(c.Span, c.FunctionName, RList(c.Arguments), c.Result)
                {
                    CalleeIrParamTypes = c.CalleeIrParamTypes,
                    CalleeIrReturnType = c.CalleeIrReturnType,
                    CalleeSemanticKey = c.CalleeSemanticKey,
                    IsForeignCall = c.IsForeignCall,
                    IsIndirectCall = c.IsIndirectCall
                };

            case IndirectCallInstruction ic:
                return new IndirectCallInstruction(ic.Span, R(ic.FunctionPointer), RList(ic.Arguments), ic.Result);

            case LoadInstruction l:
                return new LoadInstruction(l.Span, R(l.Pointer), l.Result);

            case StoreInstruction s:
                return new StoreInstruction(s.Span, s.VariableName, R(s.Value), s.Result);

            case StorePointerInstruction sp:
                return new StorePointerInstruction(sp.Span, R(sp.Pointer), R(sp.Value));

            case AllocaInstruction a:
                return a;

            case GetElementPtrInstruction g:
                return new GetElementPtrInstruction(g.Span, R(g.BasePointer), R(g.ByteOffset), g.Result);

            case CastInstruction ca:
                return new CastInstruction(ca.Span, R(ca.Source), ca.Result);

            case AddressOfInstruction ao:
                return ao;

            case ReturnInstruction r:
                return new ReturnInstruction(r.Span, R(r.Value));

            case JumpInstruction j:
                return j;

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
}
