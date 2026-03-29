using FLang.IR.Instructions;

namespace FLang.IR;

public class BasicBlock
{
    public string Label { get; }
    public List<Instruction> Instructions { get; } = [];

    // CFG edges — populated by terminator emit methods
    public List<BasicBlock> Successors { get; } = [];
    public List<BasicBlock> Predecessors { get; } = [];

    // Null for blocks created without a context (legacy / test use)
    internal BlockBuildContext? Ctx { get; }

    /// <summary>Legacy constructor (no context). Used by tests and before per-function context exists.</summary>
    public BasicBlock(string label)
    {
        Label = label;
    }

    internal BasicBlock(string label, BlockBuildContext ctx)
    {
        Label = label;
        Ctx = ctx;
    }

    // =========================================================================
    // Block creation (delegates to shared context)
    // =========================================================================

    public BasicBlock CreateBlock(string label) => Ctx!.CreateBlock(label);

    // =========================================================================
    // Terminator test
    // =========================================================================

    public bool IsTerminated => Instructions.Count > 0
        && Instructions[^1] is ReturnInstruction or JumpInstruction or BranchInstruction;

    // =========================================================================
    // Low-level emit methods
    // =========================================================================

    public LocalValue EmitAlloca(IrType type, bool isArrayStorage = false)
    {
        var result = Ctx!.FreshLocal("alloca", new IrPointer(type));
        Instructions.Add(new AllocaInstruction(Ctx.Span, type.Size, result) { IsArrayStorage = isArrayStorage });
        return result;
    }

    public void EmitStorePtr(Value dest, Value val)
        => Instructions.Add(new StorePointerInstruction(Ctx!.Span, dest, val));

    public LocalValue EmitLoad(Value ptr, IrType resultType)
    {
        var result = Ctx!.FreshLocal("load", resultType);
        Instructions.Add(new LoadInstruction(Ctx.Span, ptr, result));
        return result;
    }

    public LocalValue EmitCast(Value source, IrType targetType)
    {
        var result = Ctx!.FreshLocal("cast", targetType);
        Instructions.Add(new CastInstruction(Ctx.Span, source, result));
        return result;
    }

    public LocalValue EmitGEP(Value basePtr, int byteOffset, IrType resultType)
    {
        var result = Ctx!.FreshLocal("gep", new IrPointer(resultType));
        Instructions.Add(new GetElementPtrInstruction(Ctx.Span, basePtr, byteOffset, result));
        return result;
    }

    public LocalValue EmitGEP(Value basePtr, Value byteOffset, IrType resultType)
    {
        var result = Ctx!.FreshLocal("gep", new IrPointer(resultType));
        Instructions.Add(new GetElementPtrInstruction(Ctx.Span, basePtr, byteOffset, result));
        return result;
    }

    public LocalValue EmitAddressOf(string variableName, IrType pointeeType)
    {
        var result = Ctx!.FreshLocal("addr", new IrPointer(pointeeType));
        Instructions.Add(new AddressOfInstruction(Ctx.Span, variableName, result));
        return result;
    }

    public LocalValue EmitBinary(BinaryOp op, Value left, Value right, IrType resultType)
    {
        var result = Ctx!.FreshLocal("bin", resultType);
        Instructions.Add(new BinaryInstruction(Ctx.Span, op, left, right, result));
        return result;
    }

    public LocalValue EmitUnary(UnaryOp op, Value operand, IrType resultType)
    {
        var result = Ctx!.FreshLocal("unary", resultType);
        Instructions.Add(new UnaryInstruction(Ctx.Span, op, operand, result));
        return result;
    }

    public LocalValue EmitCopyFromOffset(Value basePtr, Value byteOffset, IrType resultType)
    {
        var result = Ctx!.FreshLocal("fld", resultType);
        Instructions.Add(new CopyFromOffsetInstruction(Ctx.Span, basePtr, byteOffset, result));
        return result;
    }

    public void EmitCopyToOffset(Value dstPtr, Value byteOffset, Value val, IrType valueType)
        => Instructions.Add(new CopyToOffsetInstruction(Ctx!.Span, val, dstPtr, byteOffset, valueType));

    // =========================================================================
    // Terminator emit methods (record CFG edges)
    // =========================================================================

    public void EmitJump(BasicBlock target)
    {
        Instructions.Add(new JumpInstruction(Ctx!.Span, target));
        AddEdge(this, target);
    }

    public void EmitBranch(Value cond, BasicBlock trueBlock, BasicBlock falseBlock)
    {
        Instructions.Add(new BranchInstruction(Ctx!.Span, cond, trueBlock, falseBlock));
        AddEdge(this, trueBlock);
        AddEdge(this, falseBlock);
    }

    public void EmitReturn(Value val)
        => Instructions.Add(new ReturnInstruction(Ctx!.Span, val));

    /// <summary>
    /// Emit a jump only if this block has no terminator yet.
    /// Used for implicit fall-through (e.g., loop back-edges).
    /// </summary>
    public void EmitJumpIfNotTerminated(BasicBlock target)
    {
        if (!IsTerminated)
            EmitJump(target);
    }

    // =========================================================================
    // ABI-aware call emit methods
    // =========================================================================

    /// <summary>
    /// Emit a complete FLang function call with ABI transformations:
    /// large value args are materialized as pointers, and a hidden return slot
    /// is inserted for large return types.
    /// Pass isForeign=true to skip ABI transformation (C calling convention).
    /// </summary>
    public LocalValue EmitCall(string fnName, List<Value> args, IrType retType,
                               List<IrType>? calleeParamTypes, bool isForeign = false,
                               bool isIndirect = false)
    {
        bool skipAbi = isForeign || isIndirect;

        if (!skipAbi)
            MaterializeArgs(args, calleeParamTypes);

        if (!skipAbi && TypeLayoutService.IsLargeValue(retType))
        {
            var retSlot = EmitAlloca(retType);
            args.Insert(0, retSlot);

            var voidResult = Ctx!.FreshLocal("call", TypeLayoutService.IrVoidPrim);
            var inst = new CallInstruction(Ctx.Span, fnName, args, voidResult);
            if (calleeParamTypes is { Count: > 0 })
                inst.CalleeIrParamTypes = calleeParamTypes;
            Instructions.Add(inst);

            return EmitLoad(retSlot, retType);
        }

        var result = Ctx!.FreshLocal("call", retType);
        var call = new CallInstruction(Ctx.Span, fnName, args, result);
        call.IsForeignCall = isForeign;
        call.IsIndirectCall = isIndirect;
        if (calleeParamTypes is { Count: > 0 })
            call.CalleeIrParamTypes = calleeParamTypes;
        Instructions.Add(call);
        return result;
    }

    /// <summary>
    /// Emit an indirect call through a function pointer with ABI transformations.
    /// </summary>
    public LocalValue EmitIndirectCall(Value fnPtr, List<Value> args, IrType retType)
    {
        MaterializeArgsByType(args);

        if (TypeLayoutService.IsLargeValue(retType))
        {
            var retSlot = EmitAlloca(retType);
            args.Insert(0, retSlot);

            var voidResult = Ctx!.FreshLocal("call", TypeLayoutService.IrVoidPrim);
            Instructions.Add(new IndirectCallInstruction(Ctx.Span, fnPtr, args, voidResult));

            return EmitLoad(retSlot, retType);
        }

        var result = Ctx!.FreshLocal("call", retType);
        Instructions.Add(new IndirectCallInstruction(Ctx.Span, fnPtr, args, result));
        return result;
    }

    /// <summary>
    /// Emit a function return respecting the return-slot convention.
    /// If the function uses a return slot, stores val to __ret and returns void.
    /// </summary>
    public void EmitFunctionReturn(Value val, IrFunction fn, Value? retSlotLocal)
    {
        if (fn.UsesReturnSlot && retSlotLocal != null)
        {
            EmitStorePtr(retSlotLocal, val);
            EmitReturn(Ctx!.FreshLocal("void", TypeLayoutService.IrVoidPrim));
        }
        else
        {
            EmitReturn(val);
        }
    }

    // =========================================================================
    // Callee-side ABI setup (static factory)
    // =========================================================================

    /// <summary>
    /// Apply FLang ABI to a function's parameter list: mark large params IsByRef,
    /// insert __ret pointer param for large return types.
    /// Returns the transformed param list, locals map, and ABI flags.
    /// </summary>
    public static CalleeAbiResult SetupCalleeAbi(
        IReadOnlyList<(string Name, IrType Type)> declaredParams,
        IrType returnType,
        bool isEntryPoint)
    {
        var irParams = new List<IrParam>();
        var byRefNames = new HashSet<string>();
        var locals = new Dictionary<string, Value>();

        foreach (var (name, paramType) in declaredParams)
        {
            var irParam = new IrParam(name, paramType);
            if (TypeLayoutService.IsLargeValue(paramType))
            {
                irParam = irParam with { IsByRef = true };
                locals[name] = new LocalValue(name, new IrPointer(paramType));
                byRefNames.Add(name);
            }
            else
            {
                locals[name] = new LocalValue(name, paramType);
            }
            irParams.Add(irParam);
        }

        bool usesReturnSlot = false;
        if (TypeLayoutService.IsLargeValue(returnType) && !isEntryPoint)
        {
            usesReturnSlot = true;
            var retPtrType = new IrPointer(returnType);
            irParams.Insert(0, new IrParam("__ret", retPtrType));
            locals["__ret"] = new LocalValue("__ret", retPtrType);
        }

        return new CalleeAbiResult
        {
            Params = irParams,
            UsesReturnSlot = usesReturnSlot,
            Locals = locals,
            ByRefParams = byRefNames,
        };
    }

    // =========================================================================
    // Private ABI helpers
    // =========================================================================

    /// <summary>
    /// Materialize large-value args using callee param types.
    /// Used for direct calls where callee types are known.
    /// </summary>
    private void MaterializeArgs(List<Value> args, IReadOnlyList<IrType>? calleeParamTypes)
    {
        if (calleeParamTypes == null) return;
        for (int i = 0; i < args.Count && i < calleeParamTypes.Count; i++)
        {
            if (TypeLayoutService.IsLargeValue(calleeParamTypes[i]) && args[i].IrType is not IrPointer)
            {
                var argType = args[i].IrType ?? calleeParamTypes[i];
                var temp = EmitAlloca(argType);
                EmitStorePtr(temp, args[i]);
                args[i] = temp;
            }
        }
    }

    /// <summary>
    /// Materialize large-value args using each arg's own type.
    /// Used for indirect calls where callee param types are not available.
    /// </summary>
    private void MaterializeArgsByType(List<Value> args)
    {
        for (int i = 0; i < args.Count; i++)
        {
            if (TypeLayoutService.IsLargeValue(args[i].IrType) && args[i].IrType is not IrPointer)
            {
                var argType = args[i].IrType ?? TypeLayoutService.IrVoidPrim;
                var temp = EmitAlloca(argType);
                EmitStorePtr(temp, args[i]);
                args[i] = temp;
            }
        }
    }

    // =========================================================================
    // CFG edge helper
    // =========================================================================

    private static void AddEdge(BasicBlock from, BasicBlock to)
    {
        from.Successors.Add(to);
        to.Predecessors.Add(from);
    }
}

/// <summary>Result of callee-side ABI setup.</summary>
public sealed class CalleeAbiResult
{
    public IReadOnlyList<IrParam> Params { get; init; } = [];
    public bool UsesReturnSlot { get; init; }
    public IReadOnlyDictionary<string, Value> Locals { get; init; } = null!;
    public IReadOnlySet<string> ByRefParams { get; init; } = null!;
}
