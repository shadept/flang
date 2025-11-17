using System.Text;
using FLang.Core;
using FLang.IR.Instructions;

namespace FLang.IR;

/// <summary>
/// Prints FIR (FLang Intermediate Representation) in a readable format similar to LLVM IR.
/// </summary>
public static class FirPrinter
{
    public static string Print(Function function)
    {
        var builder = new StringBuilder();

        // Emit globals first
        foreach (var global in function.Globals)
        {
            builder.AppendLine(PrintGlobal(global));
        }

        if (function.Globals.Count > 0)
            builder.AppendLine();

        // Function signature with type
        var paramTypes = string.Join(", ", function.Parameters.Select(p => TypeToString(p.Type)));
        builder.AppendLine($"define {TypeToString(function.ReturnType)} @{function.Name}({paramTypes}) {{");

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

    private static string PrintGlobal(GlobalValue global)
    {
        var initType = TypeToString(global.Initializer.Type);

        if (global.Initializer is ArrayConstantValue arrayConst &&
            arrayConst.StringRepresentation != null)
        {
            return $"@{global.Name} = global {initType} \"{arrayConst.StringRepresentation}\"";
        }

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
            CastInstruction cast => PrintCast(cast),
            CallInstruction call => PrintCall(call),
            ReturnInstruction ret => PrintReturn(ret),
            BranchInstruction branch => PrintBranch(branch),
            JumpInstruction jump => PrintJump(jump),
            _ => $"; <unknown instruction: {instruction.GetType().Name}>"
        };
    }

    private static string PrintAlloca(AllocaInstruction alloca)
    {
        // %result = alloca <type>, align <alignment>
        var typeStr = TypeToString(alloca.AllocatedType);
        return $"{PrintTypedValue(alloca.Result)} = alloca {typeStr} ; {alloca.SizeInBytes} bytes";
    }

    private static string PrintStore(StoreInstruction store)
    {
        // %result = store <value>
        // This is FLang's SSA assignment, not LLVM's store
        return $"{PrintTypedValue(store.Result)} = {PrintTypedValue(store.Value)}";
    }

    private static string PrintStorePointer(StorePointerInstruction storePtr)
    {
        // store <value> to <ptr>
        return $"store {PrintTypedValue(storePtr.Value)}, ptr {PrintValue(storePtr.Pointer)}";
    }

    private static string PrintLoad(LoadInstruction load)
    {
        // %result = load <type>, ptr %ptr
        return
            $"{PrintTypedValue(load.Result)} = load {TypeToString(load.Result.Type)}, ptr {PrintValue(load.Pointer)}";
    }

    private static string PrintAddressOf(AddressOfInstruction addressOf)
    {
        // %result = getelementptr inbounds %var (taking address)
        return $"{PrintTypedValue(addressOf.Result)} = addressof {addressOf.VariableName}";
    }

    private static string PrintGetElementPtr(GetElementPtrInstruction gep)
    {
        // %result = getelementptr <base>, <offset>
        var baseStr = PrintTypedValue(gep.BasePointer);
        var offsetStr = PrintTypedValue(gep.ByteOffset);
        return $"{PrintTypedValue(gep.Result)} = getelementptr {baseStr}, {offsetStr}";
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
            _ => "?"
        };

        return $"{PrintTypedValue(binary.Result)} = {opStr} {PrintTypedValue(binary.Left)}, {PrintValue(binary.Right)}";
    }

    private static string PrintCast(CastInstruction cast)
    {
        // %result = <cast_op> <src_type> %src to <dst_type>
        var srcType = TypeToString(cast.Source.Type);
        var dstType = TypeToString(cast.TargetType);

        // Determine cast operation type
        string castOp = "bitcast"; // Default
        if (srcType != dstType)
        {
            // Could be trunc, zext, sext, etc. - for now use generic
            castOp = IsPrimitiveInt(cast.Source.Type) && IsPrimitiveInt(cast.TargetType)
                ? "cast"
                : "bitcast";
        }

        return $"{PrintTypedValue(cast.Result)} = {castOp} {PrintTypedValue(cast.Source)} to {dstType}";
    }

    private static string PrintCall(CallInstruction call)
    {
        // %result = call <ret_type> @func(<args>)
        var argsStr = string.Join(", ", call.Arguments.Select(PrintTypedValue));
        var retType = TypeToString(call.Result.Type);
        return $"{PrintTypedValue(call.Result)} = call {retType} @{call.FunctionName}({argsStr})";
    }

    private static string PrintReturn(ReturnInstruction ret)
    {
        // ret <type> <value>
        return $"ret {PrintTypedValue(ret.Value)}";
    }

    private static string PrintBranch(BranchInstruction branch)
    {
        // br i1 <cond>, label %true_block, label %false_block
        return
            $"br i1 {PrintValue(branch.Condition)}, label %{branch.TrueBlock.Label}, label %{branch.FalseBlock.Label}";
    }

    private static string PrintJump(JumpInstruction jump)
    {
        // br label %target
        return $"br label %{jump.TargetBlock.Label}";
    }

    /// <summary>
    /// Print a value with its type (LLVM style: "i32 42" or "ptr %x")
    /// </summary>
    private static string PrintTypedValue(Value? value)
    {
        if (value == null)
            return "void";

        var typeStr = value.Type != null ? TypeToString(value.Type) : "<MISSING_TYPE>";
        var valueStr = PrintValue(value);

        return $"{typeStr} {valueStr}";
    }

    /// <summary>
    /// Print just the value part (no type)
    /// </summary>
    private static string PrintValue(Value? value)
    {
        if (value == null)
            return "null";

        return value switch
        {
            GlobalValue global => $"@{global.Name}",
            ConstantValue constant => constant.IntValue.ToString(),
            LocalValue local => $"%{local.Name}",
            _ => $"%{value.Name}"
        };
    }

    /// <summary>
    /// Convert FType to string representation (LLVM-like)
    /// </summary>
    private static string TypeToString(FType? type)
    {
        if (type == null)
            return "void";

        return type switch
        {
            PrimitiveType { Name: "i8" } => "i8",
            PrimitiveType { Name: "i16" } => "i16",
            PrimitiveType { Name: "i32" } => "i32",
            PrimitiveType { Name: "i64" } => "i64",
            PrimitiveType { Name: "isize" } => "i64",
            PrimitiveType { Name: "u8" } => "u8",
            PrimitiveType { Name: "u16" } => "u16",
            PrimitiveType { Name: "u32" } => "u32",
            PrimitiveType { Name: "u64" } => "u64",
            PrimitiveType { Name: "usize" } => "u64",
            PrimitiveType { Name: "bool" } => "i1",
            PrimitiveType { Name: "void" } => "void",
            ReferenceType rt => $"ptr.{TypeToString(rt.InnerType).Replace("%", "").Replace(" ", "_")}",
            StructType st => $"%struct.{st.StructName}",
            ArrayType at => $"[{at.Length} x {TypeToString(at.ElementType).Replace("%", "").Replace(" ", "_")}]",
            SliceType st => $"%slice.{TypeToString(st.ElementType).Replace("%", "").Replace(" ", "_")}",
            _ => type.Name
        };
    }

    /// <summary>
    /// Check if a type is a primitive integer
    /// </summary>
    private static bool IsPrimitiveInt(FType? type)
    {
        return type is PrimitiveType pt && (pt.Name.StartsWith('i') || pt.Name.StartsWith('u'));
    }
}
