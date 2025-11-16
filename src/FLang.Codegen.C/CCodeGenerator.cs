using System.Text;
using FLang.Core;
using FLang.IR;
using FLang.IR.Instructions;

namespace FLang.Codegen.C;

/// <summary>
/// Clean C code generator that maps FIR directly to C code.
/// Based on the philosophy: simple 1-to-1 translation with explicit type information.
/// </summary>
public class CCodeGenerator
{
    private readonly StringBuilder _output = new();
    private readonly HashSet<string> _emittedStructs = new();
    private readonly Dictionary<string, string> _stringLiterals = new();

    public static string Generate(Function function)
    {
        var generator = new CCodeGenerator();
        return generator.GenerateFunction(function);
    }

    private string GenerateFunction(Function function)
    {
        // Skip foreign function declarations - they come from headers
        if (function.IsForeign)
            return string.Empty;

        // Phase 1: Analyze and collect dependencies
        AnalyzeFunction(function);

        // Phase 2: Emit headers and type definitions
        EmitHeaders();
        EmitTypeDefinitions(function);
        EmitStringLiterals();

        // Phase 3: Emit function definition
        EmitFunctionDefinition(function);

        return _output.ToString();
    }

    #region Phase 1: Analysis

    private void AnalyzeFunction(Function function)
    {
        // Collect all struct types used
        CollectStructType(function.ReturnType);
        foreach (var param in function.Parameters)
            CollectStructType(param.Type);

        // Scan all instructions for struct types and string literals
        foreach (var block in function.BasicBlocks)
        {
            foreach (var instruction in block.Instructions)
            {
                AnalyzeInstruction(instruction);
            }
        }
    }

    private void AnalyzeInstruction(Instruction instruction)
    {
        switch (instruction)
        {
            case AllocaInstruction alloca:
                CollectStructType(alloca.AllocatedType);
                break;

            case StoreInstruction store:
                CollectStringLiteralFromValue(store.Value);
                CollectStructType(store.Value.Type);
                break;

            case CallInstruction call:
                foreach (var arg in call.Arguments)
                {
                    CollectStringLiteralFromValue(arg);
                    CollectStructType(arg.Type);
                }
                CollectStructType(call.Result.Type);
                break;

            case CastInstruction cast:
                CollectStringLiteralFromValue(cast.Source);
                CollectStructType(cast.Source.Type);
                CollectStructType(cast.TargetType);
                break;

            case ReturnInstruction ret:
                CollectStringLiteralFromValue(ret.Value);
                break;

            case LoadInstruction load:
                CollectStructType(load.Result.Type);
                break;

            case StorePointerInstruction storePtr:
                CollectStringLiteralFromValue(storePtr.Value);
                CollectStructType(storePtr.Value.Type);
                break;

            case BinaryInstruction binary:
                CollectStringLiteralFromValue(binary.Left);
                CollectStringLiteralFromValue(binary.Right);
                CollectStructType(binary.Result.Type);
                break;

            case GetElementPtrInstruction gep:
                CollectStringLiteralFromValue(gep.BasePointer);
                CollectStringLiteralFromValue(gep.ByteOffset);
                CollectStructType(gep.Result.Type);
                break;

            case AddressOfInstruction addressOf:
                CollectStructType(addressOf.Result.Type);
                break;
        }
    }

    private void CollectStructType(FType? type)
    {
        if (type == null) return;

        switch (type)
        {
            case StructType st:
                if (!_emittedStructs.Contains(GetStructCName(st)))
                {
                    _emittedStructs.Add(GetStructCName(st));
                    // Recursively collect nested struct fields
                    foreach (var (_, fieldType) in st.Fields)
                        CollectStructType(fieldType);
                }
                break;

            case ReferenceType rt:
                CollectStructType(rt.InnerType);
                break;

            case ArrayType at:
                CollectStructType(at.ElementType);
                // Arrays become slices - need String struct for u8 arrays
                if (at.ElementType.Equals(TypeRegistry.U8))
                    _emittedStructs.Add("FLangString");
                break;

            case SliceType slt:
                CollectStructType(slt.ElementType);
                // Slices need struct definition
                if (slt.ElementType.Equals(TypeRegistry.U8))
                    _emittedStructs.Add("FLangString");
                break;
        }
    }

    private void CollectStringLiteralFromValue(Value? value)
    {
        if (value is StringConstantValue strConst && !_stringLiterals.ContainsKey(strConst.Name))
        {
            _stringLiterals[strConst.Name] = strConst.StringValue;
            CollectStructType(strConst.Type);
        }
    }

    #endregion

    #region Phase 2: Emit Headers and Declarations

    private void EmitHeaders()
    {
        _output.AppendLine("#include <stdint.h>");
        _output.AppendLine("#include <stdio.h>");
        _output.AppendLine("#include <string.h>");
        _output.AppendLine();
    }

    private void EmitTypeDefinitions(Function function)
    {
        // Always emit FLangString if needed for u8 slices/arrays
        if (_emittedStructs.Contains("FLangString"))
        {
            _output.AppendLine("struct String {");
            _output.AppendLine("    uint8_t* ptr;");
            _output.AppendLine("    uintptr_t len;");
            _output.AppendLine("};");
            _output.AppendLine();
        }

        // Collect all slice element types that need struct definitions
        var sliceElementTypes = new HashSet<FType>();
        CollectSliceElementTypes(function, sliceElementTypes);

        // Emit slice type definitions
        foreach (var elemType in sliceElementTypes)
        {
            if (elemType.Equals(TypeRegistry.U8)) continue; // String struct handles u8

            var elemCType = TypeToCType(elemType);
            var structName = $"Slice_{elemCType.Replace("*", "Ptr").Replace(" ", "_")}";

            _output.AppendLine($"struct {structName} {{");
            _output.AppendLine($"    {elemCType}* ptr;");
            _output.AppendLine("    uintptr_t len;");
            _output.AppendLine("};");
            _output.AppendLine();
        }

        // Emit other struct definitions in dependency order
        // For now, emit in the order collected (could topologically sort if needed)
        foreach (var structName in _emittedStructs)
        {
            if (structName == "FLangString") continue; // Already emitted

            // Find the struct type to emit its definition
            var structType = FindStructType(function, structName);
            if (structType != null)
                EmitStructDefinition(structType);
        }
    }

    private void CollectSliceElementTypes(Function function, HashSet<FType> sliceElementTypes)
    {
        // Check return type
        if (function.ReturnType is ArrayType rat)
            sliceElementTypes.Add(rat.ElementType);
        else if (function.ReturnType is SliceType rslt)
            sliceElementTypes.Add(rslt.ElementType);

        // Check parameters
        foreach (var param in function.Parameters)
        {
            if (param.Type is ArrayType pat)
                sliceElementTypes.Add(pat.ElementType);
            else if (param.Type is SliceType pslt)
                sliceElementTypes.Add(pslt.ElementType);
        }

        // Scan instructions
        foreach (var block in function.BasicBlocks)
        {
            foreach (var instruction in block.Instructions)
            {
                if (instruction is AllocaInstruction alloca)
                {
                    if (alloca.AllocatedType is ArrayType aat)
                        sliceElementTypes.Add(aat.ElementType);
                    else if (alloca.AllocatedType is SliceType aslt)
                        sliceElementTypes.Add(aslt.ElementType);
                }

                if (instruction is StoreInstruction store && store.Value.Type != null)
                {
                    if (store.Value.Type is ArrayType sat)
                        sliceElementTypes.Add(sat.ElementType);
                    else if (store.Value.Type is SliceType sslt)
                        sliceElementTypes.Add(sslt.ElementType);
                    else if (store.Value.Type is ReferenceType { InnerType: ArrayType iaat })
                        sliceElementTypes.Add(iaat.ElementType);
                    else if (store.Value.Type is ReferenceType { InnerType: SliceType iaslt })
                        sliceElementTypes.Add(iaslt.ElementType);
                }
            }
        }
    }

    private StructType? FindStructType(Function function, string cName)
    {
        // Search function signature and instructions for struct type matching cName
        if (function.ReturnType is StructType rst && GetStructCName(rst) == cName)
            return rst;

        foreach (var param in function.Parameters)
            if (param.Type is StructType pst && GetStructCName(pst) == cName)
                return pst;

        foreach (var block in function.BasicBlocks)
        {
            foreach (var instruction in block.Instructions)
            {
                var foundType = FindStructTypeInInstruction(instruction, cName);
                if (foundType != null) return foundType;
            }
        }

        return null;
    }

    private StructType? FindStructTypeInInstruction(Instruction instruction, string cName)
    {
        switch (instruction)
        {
            case AllocaInstruction alloca:
                if (alloca.AllocatedType is StructType st && GetStructCName(st) == cName)
                    return st;
                break;

            case StoreInstruction store:
                if (store.Value.Type is StructType st2 && GetStructCName(st2) == cName)
                    return st2;
                break;

            case CastInstruction cast:
                if (cast.TargetType is StructType st3 && GetStructCName(st3) == cName)
                    return st3;
                if (cast.Source.Type is StructType st4 && GetStructCName(st4) == cName)
                    return st4;
                break;
        }

        return null;
    }

    private void EmitStructDefinition(StructType structType)
    {
        var cName = GetStructCName(structType);
        _output.AppendLine($"struct {cName} {{");

        foreach (var (fieldName, fieldType) in structType.Fields)
        {
            var fieldCType = TypeToCType(fieldType);
            _output.AppendLine($"    {fieldCType} {fieldName};");
        }

        _output.AppendLine("};");
        _output.AppendLine();
    }

    private void EmitStringLiterals()
    {
        foreach (var (name, value) in _stringLiterals)
        {
            // Emit string data and String struct
            // Example:
            // static const uint8_t str_0_data[] = "hello";
            // static const struct String str_0 = { (uint8_t*)str_0_data, 5 };
            var escaped = EscapeStringForC(value);
            _output.AppendLine($"static const uint8_t {name}_data[] = \"{escaped}\";");
            _output.AppendLine($"static const struct String {name} = {{ (uint8_t*){name}_data, {value.Length} }};");
        }

        if (_stringLiterals.Count > 0)
            _output.AppendLine();
    }

    #endregion

    #region Phase 3: Emit Function Definition

    private void EmitFunctionDefinition(Function function)
    {
        // Determine function name (mangled unless main or foreign)
        var functionName = function.Name == "main"
            ? "main"
            : NameMangler.GenericFunction(function.Name, function.Parameters.Select(p => p.Type).ToList());

        // Build parameter list
        var paramList = function.Parameters.Count == 0
            ? "void"
            : string.Join(", ", function.Parameters.Select(p => $"{TypeToCType(p.Type)} {p.Name}"));

        // Emit function signature
        var returnType = TypeToCType(function.ReturnType);
        _output.AppendLine($"{returnType} {functionName}({paramList}) {{");

        // Emit basic blocks
        for (int i = 0; i < function.BasicBlocks.Count; i++)
        {
            var block = function.BasicBlocks[i];

            // Emit label (except for first block which is the function entry)
            if (i > 0)
                _output.AppendLine($"{block.Label}:");

            // Emit instructions
            foreach (var instruction in block.Instructions)
                EmitInstruction(instruction);
        }

        _output.AppendLine("}");
    }

    private void EmitInstruction(Instruction instruction)
    {
        switch (instruction)
        {
            case AllocaInstruction alloca:
                EmitAlloca(alloca);
                break;

            case StoreInstruction store:
                EmitStore(store);
                break;

            case StorePointerInstruction storePtr:
                EmitStorePointer(storePtr);
                break;

            case LoadInstruction load:
                EmitLoad(load);
                break;

            case AddressOfInstruction addressOf:
                EmitAddressOf(addressOf);
                break;

            case GetElementPtrInstruction gep:
                EmitGetElementPtr(gep);
                break;

            case BinaryInstruction binary:
                EmitBinary(binary);
                break;

            case CastInstruction cast:
                EmitCast(cast);
                break;

            case CallInstruction call:
                EmitCall(call);
                break;

            case ReturnInstruction ret:
                EmitReturn(ret);
                break;

            case BranchInstruction branch:
                EmitBranch(branch);
                break;

            case JumpInstruction jump:
                EmitJump(jump);
                break;

            default:
                _output.AppendLine($"    // TODO: {instruction.GetType().Name}");
                break;
        }
    }

    private void EmitAlloca(AllocaInstruction alloca)
    {
        // alloca creates a stack variable and returns its address
        // Example: %ptr = alloca i32 -> int tmp; int* ptr = &tmp;

        var allocType = TypeToCType(alloca.AllocatedType);
        var tempVarName = $"{alloca.Result.Name}_val";

        if (alloca.AllocatedType is ArrayType arrayType)
        {
            // Arrays: allocate the data array directly
            // Example: %arr = alloca [3 x i32] -> int arr_val[3]; int* arr = arr_val;
            var elemType = TypeToCType(arrayType.ElementType);
            _output.AppendLine($"    {elemType} {tempVarName}[{arrayType.Length}];");
            _output.AppendLine($"    {elemType}* {alloca.Result.Name} = {tempVarName};");
        }
        else
        {
            // Scalars and structs
            _output.AppendLine($"    {allocType} {tempVarName};");
            _output.AppendLine($"    {allocType}* {alloca.Result.Name} = &{tempVarName};");
        }
    }

    private void EmitStore(StoreInstruction store)
    {
        // store is SSA assignment: %result = value
        var resultType = TypeToCType(store.Result.Type ?? TypeRegistry.I32);
        var valueExpr = ValueToString(store.Value);

        // Handle special case: storing pointer-to-array as struct
        if (store.Value.Type is ReferenceType { InnerType: ArrayType arrayType })
        {
            // Convert array pointer to slice struct
            var elemCType = TypeToCType(arrayType.ElementType);
            var structType = arrayType.ElementType.Equals(TypeRegistry.U8)
                ? "struct String"
                : $"struct Slice_{elemCType.Replace("*", "Ptr").Replace(" ", "_")}";

            _output.AppendLine($"    {structType} {store.Result.Name};");
            _output.AppendLine($"    {store.Result.Name}.ptr = {valueExpr};");
            _output.AppendLine($"    {store.Result.Name}.len = {arrayType.Length};");
            return;
        }

        // Handle storing dereferenced struct/slice pointers
        if (store.Value.Type is ReferenceType { InnerType: StructType or SliceType })
        {
            var innerType = TypeToCType(((ReferenceType)store.Value.Type).InnerType);
            _output.AppendLine($"    {innerType} {store.Result.Name} = *{valueExpr};");
            return;
        }

        // Normal scalar assignment
        _output.AppendLine($"    {resultType} {store.Result.Name} = {valueExpr};");
    }

    private void EmitStorePointer(StorePointerInstruction storePtr)
    {
        // *ptr = value
        var ptrExpr = ValueToString(storePtr.Pointer);
        var valueExpr = ValueToString(storePtr.Value);

        // Special case: struct memcpy if both are struct pointers
        if (storePtr.Pointer.Type is ReferenceType { InnerType: StructType dstStruct } &&
            storePtr.Value.Type is ReferenceType { InnerType: StructType srcStruct } &&
            dstStruct.Equals(srcStruct))
        {
            var structCType = TypeToCType(dstStruct);
            _output.AppendLine($"    memcpy({ptrExpr}, {valueExpr}, sizeof({structCType}));");
        }
        else
        {
            _output.AppendLine($"    *{ptrExpr} = {valueExpr};");
        }
    }

    private void EmitLoad(LoadInstruction load)
    {
        // %result = load %ptr -> type result = *ptr;
        var resultType = TypeToCType(load.Result.Type ?? TypeRegistry.I32);
        var ptrExpr = ValueToString(load.Pointer);
        _output.AppendLine($"    {resultType} {load.Result.Name} = *{ptrExpr};");
    }

    private void EmitAddressOf(AddressOfInstruction addressOf)
    {
        // %result = addr_of var -> type* result = &var;
        var resultType = TypeToCType(addressOf.Result.Type ?? new ReferenceType(TypeRegistry.I32));
        _output.AppendLine($"    {resultType} {addressOf.Result.Name} = &{addressOf.VariableName};");
    }

    private void EmitGetElementPtr(GetElementPtrInstruction gep)
    {
        // %result = getelementptr %base, offset
        // -> type* result = (type*)((char*)base + offset);

        var resultType = TypeToCType(gep.Result.Type ?? new ReferenceType(TypeRegistry.I32));
        var baseExpr = ValueToString(gep.BasePointer);
        var offsetExpr = ValueToString(gep.ByteOffset);

        // If base is not already a pointer, take its address
        if (gep.BasePointer.Type is not ReferenceType)
            baseExpr = $"&{baseExpr}";

        _output.AppendLine($"    {resultType} {gep.Result.Name} = ({resultType})((char*){baseExpr} + {offsetExpr});");
    }

    private void EmitBinary(BinaryInstruction binary)
    {
        var opSymbol = binary.Operation switch
        {
            BinaryOp.Add => "+",
            BinaryOp.Subtract => "-",
            BinaryOp.Multiply => "*",
            BinaryOp.Divide => "/",
            BinaryOp.Modulo => "%",
            BinaryOp.Equal => "==",
            BinaryOp.NotEqual => "!=",
            BinaryOp.LessThan => "<",
            BinaryOp.GreaterThan => ">",
            BinaryOp.LessThanOrEqual => "<=",
            BinaryOp.GreaterThanOrEqual => ">=",
            _ => throw new Exception($"Unknown binary operation: {binary.Operation}")
        };

        var resultType = TypeToCType(binary.Result.Type ?? TypeRegistry.I32);
        var left = ValueToString(binary.Left);
        var right = ValueToString(binary.Right);

        _output.AppendLine($"    {resultType} {binary.Result.Name} = {left} {opSymbol} {right};");
    }

    private void EmitCast(CastInstruction cast)
    {
        var targetType = TypeToCType(cast.TargetType ?? TypeRegistry.I32);
        var sourceExpr = ValueToString(cast.Source);

        // Check if this is a struct-to-struct reinterpretation cast
        if (cast.Source.Type is StructType && cast.TargetType is StructType)
        {
            // Use pointer reinterpretation: *(TargetType*)&source
            _output.AppendLine($"    {targetType} {cast.Result.Name} = *({targetType}*)&{sourceExpr};");
        }
        else
        {
            // Regular C cast
            _output.AppendLine($"    {targetType} {cast.Result.Name} = ({targetType}){sourceExpr};");
        }
    }

    private void EmitCall(CallInstruction call)
    {
        // Determine callee name (mangled unless foreign/intrinsic)
        var calleeName = call.IsForeignCall
            ? call.FunctionName
            : NameMangler.GenericFunction(call.FunctionName,
                call.CalleeParamTypes?.ToList() ?? call.Arguments.Select(a => a.Type ?? TypeRegistry.I32).ToList());

        var args = string.Join(", ", call.Arguments.Select(ValueToString));
        var resultType = TypeToCType(call.Result.Type ?? TypeRegistry.I32);

        _output.AppendLine($"    {resultType} {call.Result.Name} = {calleeName}({args});");
    }

    private void EmitReturn(ReturnInstruction ret)
    {
        var valueExpr = ValueToString(ret.Value);
        _output.AppendLine($"    return {valueExpr};");
    }

    private void EmitBranch(BranchInstruction branch)
    {
        var condition = ValueToString(branch.Condition);
        _output.AppendLine($"    if ({condition}) goto {branch.TrueBlock.Label};");
        _output.AppendLine($"    goto {branch.FalseBlock.Label};");
    }

    private void EmitJump(JumpInstruction jump)
    {
        _output.AppendLine($"    goto {jump.TargetBlock.Label};");
    }

    #endregion

    #region Helper Methods

    private string ValueToString(Value value)
    {
        return value switch
        {
            ConstantValue constant => constant.IntValue.ToString(),

            StringConstantValue strConst when strConst.Type is ReferenceType => $"&{strConst.Name}",
            StringConstantValue strConst => strConst.Name,

            LocalValue local => local.Name,

            _ => throw new Exception($"Unknown value type: {value.GetType().Name}")
        };
    }

    private string TypeToCType(FType type)
    {
        return type switch
        {
            PrimitiveType { Name: "i8" } => "int8_t",
            PrimitiveType { Name: "i16" } => "int16_t",
            PrimitiveType { Name: "i32" } => "int32_t",
            PrimitiveType { Name: "i64" } => "int64_t",
            PrimitiveType { Name: "isize" } => "intptr_t",
            PrimitiveType { Name: "u8" } => "uint8_t",
            PrimitiveType { Name: "u16" } => "uint16_t",
            PrimitiveType { Name: "u32" } => "uint32_t",
            PrimitiveType { Name: "u64" } => "uint64_t",
            PrimitiveType { Name: "usize" } => "uintptr_t",
            PrimitiveType { Name: "bool" } => "int",
            PrimitiveType { Name: "void" } => "void",

            ReferenceType rt => $"{TypeToCType(rt.InnerType)}*",

            StructType st => $"struct {GetStructCName(st)}",

            ArrayType at when at.ElementType.Equals(TypeRegistry.U8) => "struct String",
            ArrayType at => $"struct Slice_{TypeToCType(at.ElementType).Replace("*", "Ptr").Replace(" ", "_")}",

            SliceType st when st.ElementType.Equals(TypeRegistry.U8) => "struct String",
            SliceType st => $"struct Slice_{TypeToCType(st.ElementType).Replace("*", "Ptr").Replace(" ", "_")}",

            _ => "int" // Fallback
        };
    }

    private string GetStructCName(StructType structType)
    {
        // Handle builtin String type
        if (structType.StructName == "String")
            return "String";

        // For generic structs, mangle type parameters into name
        if (structType.TypeParameters.Count > 0)
        {
            var typeParams = string.Join("_", structType.TypeParameters.Select(p =>
                p.Replace("*", "Ptr").Replace(" ", "_").Replace("[", "").Replace("]", "")));
            return $"{structType.StructName}_{typeParams}";
        }

        return structType.StructName;
    }

    private string EscapeStringForC(string value)
    {
        var builder = new StringBuilder();
        foreach (var ch in value)
        {
            switch (ch)
            {
                case '\n': builder.Append("\\n"); break;
                case '\t': builder.Append("\\t"); break;
                case '\r': builder.Append("\\r"); break;
                case '\\': builder.Append("\\\\"); break;
                case '"': builder.Append("\\\""); break;
                case '\0': builder.Append("\\0"); break;
                default: builder.Append(ch); break;
            }
        }
        return builder.ToString();
    }

    #endregion
}
