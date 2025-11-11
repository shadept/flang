using System.Collections.Generic;
using System.Linq;
using System.Text;
using FLang.Core;
using FLang.IR;
using FLang.IR.Instructions;

namespace FLang.Codegen.C;

public class CCodeGenerator
{
    private readonly HashSet<string> _declaredVars = new();
    private readonly HashSet<string> _pointerVars = new(); // Track which variables are pointers
    private readonly HashSet<StructType> _usedStructs = new(); // Track structs used in this function

    public static string Generate(Function function)
    {
        var generator = new CCodeGenerator();
        return generator.GenerateFunction(function);
    }

    private string GenerateFunction(Function function)
    {
        // First pass: collect all struct types used in this function
        CollectUsedStructs(function);

        var builder = new StringBuilder();
        builder.AppendLine("#include <stdio.h>");
        builder.AppendLine("#include <stdint.h>");
        builder.AppendLine();

        // Generate struct definitions
        foreach (var structType in _usedStructs)
        {
            GenerateStructDefinition(structType, builder);
            builder.AppendLine();
        }

        // Generate parameter list
        var paramList = string.Join(", ", function.Parameters.Select(p => $"{p.Type} {p.Name}"));
        if (function.Parameters.Count == 0)
        {
            paramList = "void"; // C convention for no parameters
        }

        // Foreign functions are declared as extern
        if (function.IsForeign)
        {
            builder.AppendLine($"extern int {function.Name}({paramList});");
            builder.AppendLine();
            return builder.ToString();
        }

        // Add parameters to declared vars so they don't get redeclared
        // Also track which parameters are pointers
        foreach (var param in function.Parameters)
        {
            _declaredVars.Add(param.Name);
            if (param.Type.Contains("*"))
            {
                _pointerVars.Add(param.Name);
            }
        }

        builder.AppendLine($"int {function.Name}({paramList}) {{");

        // Generate each basic block
        for (int i = 0; i < function.BasicBlocks.Count; i++)
        {
            var block = function.BasicBlocks[i];

            // Emit label for this block (except first block)
            if (i > 0)
            {
                builder.AppendLine($"{block.Label}:");
            }

            // Emit instructions
            foreach (var instruction in block.Instructions)
            {
                GenerateInstruction(instruction, builder);
            }
        }

        builder.AppendLine("}");

        return builder.ToString();
    }

    private void GenerateInstruction(Instruction instruction, StringBuilder builder)
    {
        switch (instruction)
        {
            case StoreInstruction store:
                // Check if the value being stored is a pointer
                bool isPointer = store.Value is LocalValue local && _pointerVars.Contains(local.Name);

                if (!_declaredVars.Contains(store.VariableName))
                {
                    var typeStr = isPointer ? "int*" : "int";
                    builder.Append($"    {typeStr} {store.VariableName}");
                    _declaredVars.Add(store.VariableName);
                    if (isPointer)
                    {
                        _pointerVars.Add(store.VariableName);
                    }
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
                    _ => throw new System.Exception($"Unknown binary operation: {binary.Operation}")
                };

                if (binary.Result != null && !_declaredVars.Contains(binary.Result.Name))
                {
                    builder.AppendLine($"    int {binary.Result.Name} = {EmitValue(binary.Left)} {opSymbol} {EmitValue(binary.Right)};");
                    _declaredVars.Add(binary.Result.Name);
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
                    builder.AppendLine($"    int {call.Result.Name} = {call.FunctionName}({argsStr});");
                    _declaredVars.Add(call.Result.Name);
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
                    builder.AppendLine($"    int* {addressOf.Result.Name} = &{addressOf.VariableName};");
                    _declaredVars.Add(addressOf.Result.Name);
                    _pointerVars.Add(addressOf.Result.Name); // Mark as pointer
                }
                break;

            case LoadInstruction load:
                if (load.Result != null && !_declaredVars.Contains(load.Result.Name))
                {
                    builder.AppendLine($"    int {load.Result.Name} = *{EmitValue(load.Pointer)};");
                    _declaredVars.Add(load.Result.Name);
                }
                break;

            case StorePointerInstruction storePtr:
                builder.AppendLine($"    *{EmitValue(storePtr.Pointer)} = {EmitValue(storePtr.Value)};");
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
                    }
                    else
                    {
                        var allocType = TypeRegistry.ToCType(alloca.AllocatedType);
                        builder.AppendLine($"    {allocType} {tempVarName};");
                        builder.AppendLine($"    {allocType}* {alloca.Result.Name} = &{tempVarName};");
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
                    builder.AppendLine($"    int* {gep.Result.Name} = (int*)((char*){EmitValue(gep.BasePointer)} + {EmitValue(gep.ByteOffset)});");
                    _declaredVars.Add(gep.Result.Name);
                    _pointerVars.Add(gep.Result.Name);
                }
                break;
        }
    }

    private string EmitValue(Value value)
    {
        return value switch
        {
            ConstantValue constant => constant.IntValue.ToString(),
            LocalValue local => local.Name,
            _ => throw new System.Exception($"Unknown value type: {value.GetType().Name}")
        };
    }

    private void CollectUsedStructs(Function function)
    {
        foreach (var block in function.BasicBlocks)
        {
            foreach (var instruction in block.Instructions)
            {
                if (instruction is AllocaInstruction alloca)
                {
                    if (alloca.AllocatedType is StructType structType)
                    {
                        _usedStructs.Add(structType);
                        // Also collect nested struct types
                        CollectNestedStructs(structType);
                    }
                }
            }
        }
    }

    private void CollectNestedStructs(StructType structType)
    {
        foreach (var (_, fieldType) in structType.Fields)
        {
            if (fieldType is StructType nestedStruct && !_usedStructs.Contains(nestedStruct))
            {
                _usedStructs.Add(nestedStruct);
                CollectNestedStructs(nestedStruct);
            }
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
}
