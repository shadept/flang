using System.Text;
using FLang.IR.Instructions;

namespace FLang.IR;

/// <summary>
/// Prints FIR (FLang Intermediate Representation) in a readable format similar to LLVM IR.
/// </summary>
public static class FirPrinter
{
    public static string Print(IrFunction function)
    {
        var builder = new StringBuilder();

        var paramStr = string.Join(", ", function.Params.Select(p => $"{TypeToString(p.Type)} %{p.Name}"));
        builder.AppendLine($"define {TypeToString(function.ReturnType)} @{function.Name}({paramStr}) {{");

        foreach (var block in function.BasicBlocks)
        {
            builder.AppendLine($"{block.Label}:");
            foreach (var instruction in block.Instructions)
            {
                builder.Append("  ");
                builder.AppendLine(PrintInstruction(instruction));
            }
        }

        builder.AppendLine("}");
        return builder.ToString();
    }

    public static string PrintModule(IrModule module)
    {
        var builder = new StringBuilder();

        foreach (var global in module.GlobalValues)
            builder.AppendLine(PrintGlobal(global));

        if (module.GlobalValues.Count > 0)
            builder.AppendLine();

        foreach (var func in module.Functions)
            builder.Append(Print(func));

        return builder.ToString();
    }

    private static string PrintGlobal(GlobalValue global)
    {
        var initType = TypeToString(global.Initializer.IrType);

        if (global.Initializer is ArrayConstantValue { StringRepresentation: { } str })
            return $"@{global.Name} = global {initType} \"{str}\"";

        return $"@{global.Name} = global {initType} <data>";
    }

    private static string PrintInstruction(Instruction instruction)
    {
        return instruction switch
        {
            AllocaInstruction alloca => PrintAlloca(alloca),
            StoreInstruction store => PrintStore(store),
            StorePointerInstruction storePtr => PrintStorePointer(storePtr),
            LoadInstruction load => PrintLoad(load),
            AddressOfInstruction addressOf => PrintAddressOf(addressOf),
            GetElementPtrInstruction gep => PrintGetElementPtr(gep),
            BinaryInstruction binary => PrintBinary(binary),
            UnaryInstruction unary => PrintUnary(unary),
            CastInstruction cast => PrintCast(cast),
            CallInstruction call => PrintCall(call),
            IndirectCallInstruction icall => PrintIndirectCall(icall),
            ReturnInstruction ret => PrintReturn(ret),
            BranchInstruction branch => PrintBranch(branch),
            JumpInstruction jump => PrintJump(jump),
            _ => $"; <unknown instruction: {instruction.GetType().Name}>"
        };
    }

    private static string PrintAlloca(AllocaInstruction alloca)
    {
        var typeStr = TypeToString(alloca.Result.IrType is IrPointer p ? p.Pointee : alloca.Result.IrType);
        return $"{PrintTypedValue(alloca.Result)} = alloca {typeStr} ; {alloca.SizeInBytes} bytes";
    }

    private static string PrintStore(StoreInstruction store)
    {
        return $"{PrintTypedValue(store.Result)} = {PrintTypedValue(store.Value)}";
    }

    private static string PrintStorePointer(StorePointerInstruction storePtr)
    {
        return $"store {PrintTypedValue(storePtr.Value)}, ptr {PrintValue(storePtr.Pointer)}";
    }

    private static string PrintLoad(LoadInstruction load)
    {
        var loadType = TypeToString(load.Result.IrType);
        return $"{PrintTypedValue(load.Result)} = load {loadType}, ptr {PrintValue(load.Pointer)}";
    }

    private static string PrintAddressOf(AddressOfInstruction addressOf)
    {
        return $"{PrintTypedValue(addressOf.Result)} = addressof {addressOf.VariableName}";
    }

    private static string PrintGetElementPtr(GetElementPtrInstruction gep)
    {
        return $"{PrintTypedValue(gep.Result)} = getelementptr {PrintTypedValue(gep.BasePointer)}, {PrintTypedValue(gep.ByteOffset)}";
    }

    private static string PrintBinary(BinaryInstruction binary)
    {
        var opStr = binary.Operation switch
        {
            BinaryOp.Add => "add",
            BinaryOp.Subtract => "sub",
            BinaryOp.Multiply => "mul",
            BinaryOp.Divide => "sdiv",
            BinaryOp.Modulo => "srem",
            BinaryOp.Equal => "icmp eq",
            BinaryOp.NotEqual => "icmp ne",
            BinaryOp.LessThan => "icmp slt",
            BinaryOp.GreaterThan => "icmp sgt",
            BinaryOp.LessThanOrEqual => "icmp sle",
            BinaryOp.GreaterThanOrEqual => "icmp sge",
            BinaryOp.BitwiseAnd => "and",
            BinaryOp.BitwiseOr => "or",
            BinaryOp.BitwiseXor => "xor",
            _ => "?"
        };

        return $"{PrintTypedValue(binary.Result)} = {opStr} {PrintTypedValue(binary.Left)}, {PrintValue(binary.Right)}";
    }

    private static string PrintUnary(UnaryInstruction unary)
    {
        var opStr = unary.Operation switch
        {
            UnaryOp.Negate => "neg",
            UnaryOp.Not => "not",
            _ => "?"
        };

        return $"{PrintTypedValue(unary.Result)} = {opStr} {PrintTypedValue(unary.Operand)}";
    }

    private static string PrintCast(CastInstruction cast)
    {
        var srcType = TypeToString(cast.Source.IrType);
        var dstType = TypeToString(cast.Result.IrType);

        string castOp = IsPrimitiveInt(cast.Source.IrType) && IsPrimitiveInt(cast.Result.IrType)
            ? "cast"
            : "bitcast";

        return $"{PrintTypedValue(cast.Result)} = {castOp} {PrintTypedValue(cast.Source)} to {dstType}";
    }

    private static string PrintCall(CallInstruction call)
    {
        var argsStr = string.Join(", ", call.Arguments.Select(PrintTypedValue));
        var retType = TypeToString(call.Result.IrType);
        return $"{PrintTypedValue(call.Result)} = call {retType} @{call.FunctionName}({argsStr})";
    }

    private static string PrintIndirectCall(IndirectCallInstruction call)
    {
        var argsStr = string.Join(", ", call.Arguments.Select(PrintTypedValue));
        var retType = TypeToString(call.Result.IrType);
        return $"{PrintTypedValue(call.Result)} = call {retType} {PrintValue(call.FunctionPointer)}({argsStr})";
    }

    private static string PrintReturn(ReturnInstruction ret)
    {
        return $"ret {PrintTypedValue(ret.Value)}";
    }

    private static string PrintBranch(BranchInstruction branch)
    {
        return $"br i1 {PrintValue(branch.Condition)}, label %{branch.TrueBlock.Label}, label %{branch.FalseBlock.Label}";
    }

    private static string PrintJump(JumpInstruction jump)
    {
        return $"br label %{jump.TargetBlock.Label}";
    }

    private static string PrintTypedValue(Value? value)
    {
        if (value == null)
            return "void";

        var typeStr = TypeToString(value.IrType);
        var valueStr = PrintValue(value);
        return $"{typeStr} {valueStr}";
    }

    private static string PrintValue(Value? value)
    {
        if (value == null)
            return "null";

        return value switch
        {
            GlobalValue global => $"@{global.Name}",
            ConstantValue constant => constant.IntValue.ToString(),
            StringTableValue stv => $"@string_table[{stv.Index}]",
            FunctionReferenceValue fv => $"@{fv.FunctionName}",
            LocalValue local => $"%{local.Name}",
            _ => $"%{value.Name}"
        };
    }

    private static string TypeToString(IrType? type)
    {
        if (type == null)
            return "void";

        return type switch
        {
            IrPrimitive { Name: "bool" } => "i1",
            IrPrimitive { Name: "isize" } => "i64",
            IrPrimitive { Name: "usize" } => "u64",
            IrPrimitive p => p.Name,
            IrPointer { Pointee: var inner, IsNullable: true } => $"ptr.{TypeToString(inner).Replace("%", "").Replace(" ", "_")}?",
            IrPointer { Pointee: var inner } => $"ptr.{TypeToString(inner).Replace("%", "").Replace(" ", "_")}",
            IrArray { Element: var elem, Length: var len } => $"[{len ?? 0} x {TypeToString(elem)}]",
            IrStruct s => $"%struct.{s.Name}",
            IrEnum e => $"%enum.{e.Name}",
            IrFunctionPtr fp => $"fn({string.Join(", ", fp.Params.Select(TypeToString))}) -> {TypeToString(fp.Return)}",
            _ => type.ToString()
        };
    }

    private static bool IsPrimitiveInt(IrType? type)
    {
        return type is IrPrimitive p && (p.Name.StartsWith('i') || p.Name.StartsWith('u'));
    }
}
