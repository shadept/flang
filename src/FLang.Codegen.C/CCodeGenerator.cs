using System.Text;
using FLang.Core;
using FLang.IR;
using FLang.IR.Instructions;

namespace FLang.Codegen.C;

public class CCodeGenerator
{
    private readonly HashSet<string> _declaredVars = new();
    private readonly HashSet<string> _pointerVars = new(); // Track which variables are pointers
    private readonly Dictionary<string, string> _varTypes = new(); // Track C type per local variable
    private readonly Dictionary<string, string> _stringLiterals = new(); // Track string literals (name -> value)
    private readonly HashSet<StructType> _usedStructs = new(); // Track structs used in this function

    public static string Generate(Function function)
    {
        var generator = new CCodeGenerator();
        return generator.GenerateFunction(function);
    }

    private string GenerateFunction(Function function)
    {
        // First pass: collect all struct types and string literals used in this function
        CollectUsedStructs(function);
        CollectStringLiterals(function);

        var builder = new StringBuilder();
        builder.AppendLine("#include <stdio.h>");
        builder.AppendLine("#include <stdint.h>");
        builder.AppendLine();

        // Ensure String struct definition is available when u8[] is used (mapped to struct String)
        bool needsStringStruct = function.ReturnType is SliceType sret && sret.ElementType.Equals(TypeRegistry.U8) ||
                                 function.Parameters.Any(p => p.Type is SliceType st && st.ElementType.Equals(TypeRegistry.U8));
        // Also if a String struct is otherwise used, its definition will be emitted below via _usedStructs.
        if (needsStringStruct && !_usedStructs.Any(st => st.StructName == "String"))
        {
            builder.AppendLine("struct String {");
            builder.AppendLine("    unsigned char* ptr;");
            builder.AppendLine("    uintptr_t len;");
            builder.AppendLine("};");
            builder.AppendLine();
        }

        // Generate struct definitions
        foreach (var structType in _usedStructs)
        {
            GenerateStructDefinition(structType, builder);
            builder.AppendLine();
        }


        // Generate string literal declarations
        foreach (var (name, value) in _stringLiterals) GenerateStringLiteral(name, value, builder);

        if (_stringLiterals.Count > 0) builder.AppendLine();

        // Generate parameter list
        var paramList = string.Join(", ", function.Parameters.Select(p => $"{TypeRegistry.ToCType(p.Type)} {p.Name}"));
        if (function.Parameters.Count == 0) paramList = "void"; // C convention for no parameters

        // Foreign functions are declared as extern
        if (function.IsForeign)
        {
            builder.AppendLine($"extern {TypeRegistry.ToCType(function.ReturnType)} {function.Name}({paramList});");
            builder.AppendLine();
            return builder.ToString();
        }

        // Add parameters to declared vars so they don't get redeclared
        // Also track which parameters are pointers
        foreach (var param in function.Parameters)
        {
            _declaredVars.Add(param.Name);
            var ctype = TypeRegistry.ToCType(param.Type);
            _varTypes[param.Name] = ctype;
            if (param.Type is ReferenceType) _pointerVars.Add(param.Name);
        }

        builder.AppendLine($"{TypeRegistry.ToCType(function.ReturnType)} {function.Name}({paramList}) {{");

        // Generate each basic block
        for (var i = 0; i < function.BasicBlocks.Count; i++)
        {
            var block = function.BasicBlocks[i];

            // Emit label for this block (except first block)
            if (i > 0) builder.AppendLine($"{block.Label}:");

            // Emit instructions
            foreach (var instruction in block.Instructions) GenerateInstruction(instruction, builder);
        }

        builder.AppendLine("}");

        return builder.ToString();
    }

    private void GenerateInstruction(Instruction instruction, StringBuilder builder)
    {
        switch (instruction)
        {
            case StoreInstruction store:
                // Determine if the value is a pointer from its FLang type
                var valType = store.Value.Type;
                var isPointer = valType is ReferenceType || (store.Value is LocalValue local && _pointerVars.Contains(local.Name));

                if (!_declaredVars.Contains(store.VariableName))
                {
                    // Prefer declared C type from the value's FLang type
                    string typeStr;
                    if (valType != null)
                    {
                        typeStr = TypeRegistry.ToCType(valType);
                        if (valType is ReferenceType) _pointerVars.Add(store.VariableName);
                    }
                    else if (store.Value is LocalValue v && _varTypes.TryGetValue(v.Name, out var vt))
                    {
                        typeStr = vt;
                        if (vt.Contains("*")) _pointerVars.Add(store.VariableName);
                    }
                    else
                    {
                        typeStr = isPointer ? "int*" : "int";
                        if (isPointer) _pointerVars.Add(store.VariableName);
                    }

                    builder.Append($"    {typeStr} {store.VariableName}");
                    _declaredVars.Add(store.VariableName);
                    _varTypes[store.VariableName] = typeStr;
                }
                else
                {
                    builder.Append($"    {store.VariableName}");
                }

                builder.AppendLine($" = {EmitValue(store.Value)};");
                break;

            case BinaryInstruction binary:
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

                if (binary.Result != null && !_declaredVars.Contains(binary.Result.Name))
                {
                    var rt = (binary.Result.Type != null) ? TypeRegistry.ToCType(binary.Result.Type) : "int";
                    builder.AppendLine(
                        $"    {rt} {binary.Result.Name} = {EmitValue(binary.Left)} {opSymbol} {EmitValue(binary.Right)};");
                    _declaredVars.Add(binary.Result.Name);
                    _varTypes[binary.Result.Name] = rt;
                }

                break;

            case BranchInstruction branch:
                builder.AppendLine($"    if ({EmitValue(branch.Condition)}) goto {branch.TrueBlock.Label};");
                builder.AppendLine($"    goto {branch.FalseBlock.Label};");
                break;

            case JumpInstruction jump:
                builder.AppendLine($"    goto {jump.TargetBlock.Label};");
                break;

            case ReturnInstruction returnInst:
                builder.AppendLine($"    return {EmitValue(returnInst.Value)};");
                break;

            case CallInstruction call:
                var argsStr = string.Join(", ", call.Arguments.Select(EmitValue));
                if (call.Result != null && !_declaredVars.Contains(call.Result.Name))
                {
                    var retType = (call.Result.Type != null) ? TypeRegistry.ToCType(call.Result.Type) : "int";
                    builder.AppendLine($"    {retType} {call.Result.Name} = {call.FunctionName}({argsStr});");
                    _declaredVars.Add(call.Result.Name);
                    _varTypes[call.Result.Name] = retType;
                    if (call.Result.Type is ReferenceType) _pointerVars.Add(call.Result.Name);
                }
                else if (call.Result != null)
                {
                    builder.AppendLine($"    {call.Result.Name} = {call.FunctionName}({argsStr});");
                }
                else
                {
                    builder.AppendLine($"    {call.FunctionName}({argsStr});");
                }

                break;

            case AddressOfInstruction addressOf:
                if (addressOf.Result != null && !_declaredVars.Contains(addressOf.Result.Name))
                {
                    var at = (addressOf.Result.Type != null) ? TypeRegistry.ToCType(addressOf.Result.Type) : "int*";
                    builder.AppendLine($"    {at} {addressOf.Result.Name} = &{addressOf.VariableName};");
                    _declaredVars.Add(addressOf.Result.Name);
                    _pointerVars.Add(addressOf.Result.Name); // Mark as pointer
                    _varTypes[addressOf.Result.Name] = at;
                }

                break;

            case LoadInstruction load:
                if (load.Result != null && !_declaredVars.Contains(load.Result.Name))
                {
                    var lt = (load.Result.Type != null) ? TypeRegistry.ToCType(load.Result.Type) : "int";
                    builder.AppendLine($"    {lt} {load.Result.Name} = *{EmitValue(load.Pointer)};");
                    _declaredVars.Add(load.Result.Name);
                    _varTypes[load.Result.Name] = lt;
                }

                break;

            case StorePointerInstruction storePtr:
                builder.AppendLine($"    *{EmitValue(storePtr.Pointer)} = {EmitValue(storePtr.Value)};");
                break;

            case CastInstruction cast:
                if (cast.Result != null && !_declaredVars.Contains(cast.Result.Name))
                {
                    var dst = cast.Result.Type != null ? TypeRegistry.ToCType(cast.Result.Type) : "int";
                    builder.AppendLine($"    {dst} {cast.Result.Name} = ({dst}){EmitValue(cast.Source)};");
                    _declaredVars.Add(cast.Result.Name);
                    _varTypes[cast.Result.Name] = dst;
                    if (cast.Result.Type is ReferenceType) _pointerVars.Add(cast.Result.Name);
                }
                else if (cast.Result != null)
                {
                    var dst = cast.Result.Type != null ? TypeRegistry.ToCType(cast.Result.Type) : "int";
                    builder.AppendLine($"    {cast.Result.Name} = ({dst}){EmitValue(cast.Source)};");
                }
                break;

            case AllocaInstruction alloca:
                if (alloca.Result != null && !_declaredVars.Contains(alloca.Result.Name))
                {
                    // Allocate space on stack - Result is a pointer to the allocated space
                    var tempVarName = $"{alloca.Result.Name}_val";

                    // Special handling for arrays: C syntax requires [N] after variable name
                    if (alloca.AllocatedType is ArrayType arrayType)
                    {
                        var elementType = TypeRegistry.ToCType(arrayType.ElementType);
                        var length = arrayType.Length;

                        // Declare array: int array_val[3];
                        builder.AppendLine($"    {elementType} {tempVarName}[{length}];");
                        // Pointer to array: int (*array_ptr)[3] = &array_val;
                        builder.AppendLine($"    {elementType} (*{alloca.Result.Name})[{length}] = &{tempVarName};");
                        _varTypes[alloca.Result.Name] = $"{elementType} (*)[{length}]"; // not exact, but tracks 'pointer'
                    }
                    else
                    {
                        var allocType = TypeRegistry.ToCType(alloca.AllocatedType);
                        builder.AppendLine($"    {allocType} {tempVarName};");
                        builder.AppendLine($"    {allocType}* {alloca.Result.Name} = &{tempVarName};");
                        _varTypes[alloca.Result.Name] = $"{allocType}*";
                    }

                    _declaredVars.Add(tempVarName);
                    _declaredVars.Add(alloca.Result.Name);
                    _pointerVars.Add(alloca.Result.Name);
                }

                break;

            case GetElementPtrInstruction gep:
                if (gep.Result != null && !_declaredVars.Contains(gep.Result.Name))
                {
                    // Cast to char* for pointer arithmetic, then calculate offset
                    var rt = (gep.Result.Type != null) ? TypeRegistry.ToCType(gep.Result.Type) : "int*";
                    var baseExpr = EnsurePointerExpression(gep.BasePointer);

                    builder.AppendLine(
                        $"    {rt} {gep.Result.Name} = ({rt})((char*){baseExpr} + {EmitValue(gep.ByteOffset)});");
                    _declaredVars.Add(gep.Result.Name);
                    _pointerVars.Add(gep.Result.Name);
                    _varTypes[gep.Result.Name] = rt;
                }

                break;

        }
    }

    private string EmitValue(Value value)
    {
        switch (value)
        {
            case ConstantValue constant:
                return constant.IntValue.ToString();
            case StringConstantValue stringConst:
                // If the expected type is a reference, return &name, otherwise name
                if (stringConst.Type is ReferenceType)
                    return $"&{stringConst.Name}";
                return stringConst.Name;
            case LocalValue local:
                return local.Name;
            default:
                throw new Exception($"Unknown value type: {value.GetType().Name}");
        }
    }

    private string EnsurePointerExpression(Value baseValue)
    {
        if (baseValue.Type is ReferenceType)
            return EmitValue(baseValue);

        if (baseValue is LocalValue local)
        {
            if (_varTypes.TryGetValue(local.Name, out var cType) && (cType.Contains("*") || cType.Contains("(*)")))
                return local.Name;

            return $"&{local.Name}";
        }

        if (baseValue is StringConstantValue stringConst)
            return $"&{stringConst.Name}";

        return EmitValue(baseValue);
    }

    private void CollectStringLiteral(Value? value)
    {
        if (value is not StringConstantValue strConst)
            return;

        _stringLiterals[strConst.Name] = strConst.StringValue;
        if (strConst.Type is StructType st)
        {
            _usedStructs.Add(st);
            CollectNestedStructs(st);
        }
    }

    private void CollectUsedStructs(Function function)

    {
        // Include structs from parameters and return types
        foreach (var p in function.Parameters)
            if (p.Type is StructType st)
            {
                _usedStructs.Add(st);
                CollectNestedStructs(st);
            }
        if (function.ReturnType is StructType rst)
        {
            _usedStructs.Add(rst);
            CollectNestedStructs(rst);
        }

        // Scan instructions for stack allocations of structs
        foreach (var block in function.BasicBlocks)
        foreach (var instruction in block.Instructions)
            if (instruction is AllocaInstruction alloca)
                if (alloca.AllocatedType is StructType structType)
                {
                    _usedStructs.Add(structType);
                    // Also collect nested struct types
                    CollectNestedStructs(structType);
                }
    }

    private void CollectNestedStructs(StructType structType)
    {
        foreach (var (_, fieldType) in structType.Fields)
            if (fieldType is StructType nestedStruct && !_usedStructs.Contains(nestedStruct))
            {
                _usedStructs.Add(nestedStruct);
                CollectNestedStructs(nestedStruct);
            }
    }

    private void GenerateStructDefinition(StructType structType, StringBuilder builder)
    {
        builder.AppendLine($"struct {structType.StructName} {{");

        foreach (var (fieldName, fieldType) in structType.Fields)
        {
            var cType = TypeRegistry.ToCType(fieldType);
            builder.AppendLine($"    {cType} {fieldName};");
        }

        builder.AppendLine("};");
    }

    private void CollectStringLiterals(Function function)
    {
        foreach (var block in function.BasicBlocks)
        foreach (var instruction in block.Instructions)
            CollectStringLiteralsFromInstruction(instruction);
    }

    private void CollectStringLiteralsFromInstruction(Instruction instruction)
    {
        switch (instruction)
        {
            case StoreInstruction store:
                CollectStringLiteral(store.Value);
                break;
            case BinaryInstruction binary:
                CollectStringLiteral(binary.Left);
                CollectStringLiteral(binary.Right);
                break;
            case ReturnInstruction ret:
                CollectStringLiteral(ret.Value);
                break;
            case CallInstruction call:
                foreach (var arg in call.Arguments)
                    CollectStringLiteral(arg);
                break;
            case BranchInstruction branch:
                CollectStringLiteral(branch.Condition);
                break;
            case LoadInstruction load:
                CollectStringLiteral(load.Pointer);
                break;
            case StorePointerInstruction storePtr:
                CollectStringLiteral(storePtr.Pointer);
                CollectStringLiteral(storePtr.Value);
                break;
            case CastInstruction cast:
                CollectStringLiteral(cast.Source);
                break;
            case GetElementPtrInstruction gep:
                CollectStringLiteral(gep.BasePointer);
                CollectStringLiteral(gep.ByteOffset);
                break;
        }
    }


    private void GenerateStringLiteral(string name, string value, StringBuilder builder)
    {
        // Generate a null-terminated string literal as a struct String
        // String is defined as: struct String { unsigned char* ptr; uintptr_t len; }

        // Escape special characters for C string literal
        var escapedValue = EscapeStringForC(value);

        // Generate the raw string data with null terminator
        builder.AppendLine($"static const unsigned char {name}_data[] = \"{escapedValue}\";");

        // Generate the String struct instance with ptr and len
        // Length does NOT include the null terminator (as per spec)
        builder.AppendLine($"static const struct String {name} = {{ (unsigned char*){name}_data, {value.Length} }};");
    }

    private string EscapeStringForC(string value)
    {
        var builder = new StringBuilder();
        foreach (var ch in value)
            switch (ch)
            {
                case '\n':
                    builder.Append("\\n");
                    break;
                case '\t':
                    builder.Append("\\t");
                    break;
                case '\r':
                    builder.Append("\\r");
                    break;
                case '\\':
                    builder.Append("\\\\");
                    break;
                case '"':
                    builder.Append("\\\"");
                    break;
                case '\0':
                    builder.Append("\\0");
                    break;
                default:
                    builder.Append(ch);
                    break;
            }

        return builder.ToString();
    }
}