using System.Linq;
using System.Text;
using FLang.IR.Instructions;

namespace FLang.IR;

public static class FirPrinter
{
    public static string Print(Function function)
    {
        var builder = new StringBuilder();
        builder.AppendLine($"function {function.Name}:");

        foreach (var block in function.BasicBlocks)
        {
            builder.AppendLine($"  {block.Label}:");
            foreach (var instruction in block.Instructions)
            {
                builder.Append("    ");
                builder.AppendLine(PrintInstruction(instruction));
            }
        }

        return builder.ToString();
    }

    private static string PrintInstruction(Instruction instruction)
    {
        return instruction switch
        {
            BinaryInstruction binary => PrintBinary(binary),
            StoreInstruction store => $"store {store.VariableName} = {PrintValue(store.Value)}",
            ReturnInstruction ret => $"return {PrintValue(ret.Value)}",
            BranchInstruction branch => $"branch {PrintValue(branch.Condition)} ? {branch.TrueBlock.Label} : {branch.FalseBlock.Label}",
            JumpInstruction jump => $"jump {jump.TargetBlock.Label}",
            CallInstruction call => PrintCall(call),
            AddressOfInstruction addressOf => PrintAddressOf(addressOf),
            LoadInstruction load => PrintLoad(load),
            StorePointerInstruction storePtr => $"store_ptr {PrintValue(storePtr.Pointer)} = {PrintValue(storePtr.Value)}",
            AllocaInstruction alloca => PrintAlloca(alloca),
            GetElementPtrInstruction gep => PrintGetElementPtr(gep),
            _ => instruction.GetType().Name
        };
    }

    private static string PrintAddressOf(AddressOfInstruction addressOf)
    {
        var result = addressOf.Result != null ? $"{addressOf.Result.Name} = " : "";
        return $"{result}addr_of {addressOf.VariableName}";
    }

    private static string PrintLoad(LoadInstruction load)
    {
        var result = load.Result != null ? $"{load.Result.Name} = " : "";
        return $"{result}load {PrintValue(load.Pointer)}";
    }

    private static string PrintBinary(BinaryInstruction binary)
    {
        var opStr = binary.Operation switch
        {
            BinaryOp.Add => "add",
            BinaryOp.Subtract => "sub",
            BinaryOp.Multiply => "mul",
            BinaryOp.Divide => "div",
            BinaryOp.Modulo => "mod",
            BinaryOp.Equal => "eq",
            BinaryOp.NotEqual => "ne",
            BinaryOp.LessThan => "lt",
            BinaryOp.GreaterThan => "gt",
            BinaryOp.LessThanOrEqual => "le",
            BinaryOp.GreaterThanOrEqual => "ge",
            _ => "?"
        };

        var result = binary.Result != null ? $"{binary.Result.Name} = " : "";
        return $"{result}{opStr} {PrintValue(binary.Left)}, {PrintValue(binary.Right)}";
    }

    private static string PrintCall(CallInstruction call)
    {
        var argsStr = string.Join(", ", call.Arguments.Select(PrintValue));
        var result = call.Result != null ? $"{call.Result.Name} = " : "";
        return $"{result}call {call.FunctionName}({argsStr})";
    }

    private static string PrintAlloca(AllocaInstruction alloca)
    {
        var result = alloca.Result != null ? $"{alloca.Result.Name} = " : "";
        return $"{result}alloca {alloca.SizeInBytes} bytes";
    }

    private static string PrintGetElementPtr(GetElementPtrInstruction gep)
    {
        var result = gep.Result != null ? $"{gep.Result.Name} = " : "";
        return $"{result}getelementptr {PrintValue(gep.BasePointer)}, {gep.ByteOffset}";
    }

    private static string PrintValue(Value value)
    {
        return value switch
        {
            ConstantValue constant => constant.IntValue.ToString(),
            LocalValue local => $"%{local.Name}",
            _ => value.Name
        };
    }
}
