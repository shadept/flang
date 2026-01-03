using System.Text;
using System.Linq;
using FLang.Core;
using FType = FLang.Core.TypeBase;
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
    private readonly Dictionary<string, StructType> _structDefinitions = [];
    private readonly Dictionary<string, EnumType> _enumDefinitions = [];
    private readonly HashSet<FType> _sliceElementTypes = [];
    private readonly HashSet<string> _emittedGlobals = [];
    private readonly Dictionary<string, string> _parameterRemap = [];
    private Function? _currentFunction;
    private bool _headersEmitted;

    public static string GenerateProgram(IEnumerable<Function> functions)
    {
        var generator = new CCodeGenerator();
        var functionList = functions.ToList();
        generator.AnalyzeFunctions(functionList);
        generator.EmitProgram(functionList);
        return generator._output.ToString();
    }

    private void AnalyzeFunctions(IEnumerable<Function> functions)
    {
        foreach (var function in functions)
        {
            AnalyzeFunction(function);

            foreach (var global in function.Globals)
            {
                CollectStructType(global.Type);
                switch (global.Initializer)
                {
                    case StructConstantValue structConst:
                        CollectStructType(structConst.Type);
                        break;
                    case ArrayConstantValue arrayConst when arrayConst.Type is ArrayType arrType:
                        CollectStructType(arrType.ElementType);
                        break;
                }
            }
        }
    }

    private void EmitProgram(IReadOnlyList<Function> functions)
    {
        EmitHeaders();
        EmitSliceStructs();
        EmitStructDefinitions();
        EmitEnumDefinitions();
        EmitForeignPrototypes(functions);
        EmitFunctionPrototypes(functions);
        EmitGlobals(functions);

        foreach (var function in functions)
        {
            if (function.IsForeign) continue;
            _parameterRemap.Clear();
            EmitFunctionDefinition(function);
            _output.AppendLine();
        }
    }

    private void EmitSliceStructs()
    {
        foreach (var elemType in _sliceElementTypes)
        {
            // Create the Slice<T> StructType to get the correct C name
            var sliceType = TypeRegistry.MakeSlice(elemType);
            var structName = GetStructCName(sliceType);

            // Skip if this is String (which is manually defined in headers)
            if (structName == "String") continue;

            var elemCType = TypeToCType(elemType);
            _output.AppendLine($"struct {structName} {{");
            _output.AppendLine($"    {elemCType}* ptr;");
            _output.AppendLine("    uintptr_t len;");
            _output.AppendLine("};");
            _output.AppendLine();
        }
    }

    private void EmitStructDefinitions()
    {
        foreach (var structType in _structDefinitions.OrderBy(kvp => kvp.Key).Select(kvp => kvp.Value))
        {
            if (TypeRegistry.IsString(structType)) continue;
            if (TypeRegistry.IsType(structType)) continue;
            EmitStructDefinition(structType);
        }
    }

    private void EmitEnumDefinitions()
    {
        foreach (var enumType in _enumDefinitions.OrderBy(kvp => kvp.Key).Select(kvp => kvp.Value))
        {
            EmitEnumDefinition(enumType);
        }
    }

    private void EmitEnumDefinition(EnumType enumType)
    {
        var cName = GetEnumCName(enumType);
        
        _output.AppendLine($"// Enum: {enumType.Name}");
        _output.AppendLine($"struct {cName} {{");
        _output.AppendLine("    int32_t tag;");
        
        // Emit union for payloads
        if (enumType.Variants.Any(v => v.PayloadType != null))
        {
            _output.AppendLine("    union {");
            for (int i = 0; i < enumType.Variants.Count; i++)
            {
                var variant = enumType.Variants[i];
                if (variant.PayloadType != null)
                {
                    var payloadCType = TypeToCType(variant.PayloadType);
                    _output.AppendLine($"        {payloadCType} variant_{i};  // {variant.VariantName}");
                }
            }
            _output.AppendLine("    } payload;");
        }
        
        _output.AppendLine("};");
        _output.AppendLine();
    }

    private void EmitForeignPrototypes(IEnumerable<Function> functions)
    {
        var emitted = new HashSet<string>();
        foreach (var function in functions)
        {
            if (!function.IsForeign) continue;
            if (function.Name == "__flang_unimplemented") continue;
            var name = GetFunctionCName(function);
            if (!emitted.Add(name)) continue;
            var paramList = BuildParameterList(function);
            _output.AppendLine($"extern {TypeToCType(function.ReturnType)} {name}({paramList});");
        }

        if (emitted.Count > 0)
            _output.AppendLine();
    }

    private void EmitFunctionPrototypes(IEnumerable<Function> functions)
    {
        foreach (var function in functions)
        {
            if (function.IsForeign) continue;
            var name = GetFunctionCName(function);
            var paramList = BuildParameterList(function);
            _output.AppendLine($"{TypeToCType(function.ReturnType)} {name}({paramList});");
        }

        if (functions.Any(f => !f.IsForeign))
            _output.AppendLine();
    }

    private void EmitGlobals(IEnumerable<Function> functions)
    {
        foreach (var function in functions)
            foreach (var global in function.Globals)
                EmitGlobal(global);

        if (_emittedGlobals.Count > 0)
            _output.AppendLine();
    }

    private void EmitGlobal(GlobalValue global)
    {
        if (!_emittedGlobals.Add(global.Name))
            return;

        if (global.Initializer is StructConstantValue structConst &&
            structConst.Type is StructType st && TypeRegistry.IsString(st))
        {
            var ptrField = structConst.FieldValues["ptr"];
            var lenField = structConst.FieldValues["len"];
            if (ptrField is ArrayConstantValue arrayConst && arrayConst.StringRepresentation != null)
            {
                var escaped = EscapeStringForC(arrayConst.StringRepresentation);
                var length = ((ConstantValue)lenField).IntValue;
                _output.AppendLine($"static const struct String {global.Name} = {{ .ptr = (uint8_t*)\"{escaped}\", .len = {length} }};");
            }
            return;
        }

        if (global.Initializer is ArrayConstantValue arrayConst2 && arrayConst2.StringRepresentation != null)
        {
            var escaped = EscapeStringForC(arrayConst2.StringRepresentation);
            _output.AppendLine($"const uint8_t* {global.Name} = (const uint8_t*)\"{escaped}\";");
            return;
        }

        if (global.Initializer is ArrayConstantValue arrayConst3 &&
            arrayConst3.Elements != null && arrayConst3.Type is ArrayType arrType)
        {
            var elemType = TypeToCType(arrType.ElementType);

            // Handle array of structs (like the type table)
            if (arrType.ElementType is StructType)
            {
                var elements = string.Join(",\n    ", arrayConst3.Elements.Select(e =>
                {
                    if (e is StructConstantValue scv)
                    {
                        // Emit struct initializer
                        var fields = scv.FieldValues.Select(kvp =>
                        {
                            var value = kvp.Value switch
                            {
                                ConstantValue cv => cv.IntValue.ToString(),
                                GlobalValue gv => $"&{gv.Name}",
                                StructConstantValue nested => EmitStructConstantInline(nested),
                                _ => throw new InvalidOperationException($"Unsupported field value type: {kvp.Value}")
                            };
                            return $".{kvp.Key} = {value}";
                        });
                        return $"{{ {string.Join(", ", fields)} }}";
                    }
                    throw new InvalidOperationException($"Expected StructConstantValue in struct array: {e}");
                }));
                _output.AppendLine($"static const {elemType} {global.Name}[{arrType.Length}] = {{");
                _output.AppendLine($"    {elements}");
                _output.AppendLine("};");
                return;
            }

            // Handle array of primitives
            var primitiveElements = string.Join(", ", arrayConst3.Elements.Select(e =>
            {
                if (e is ConstantValue cv) return cv.IntValue.ToString();
                throw new InvalidOperationException($"Non-constant value in array literal: {e}");
            }));
            _output.AppendLine($"static const {elemType} {global.Name}[{arrType.Length}] = {{{primitiveElements}}};");
        }
    }

    private string EmitStructConstantInline(StructConstantValue scv)
    {
        var fields = scv.FieldValues.Select(kvp =>
        {
            var value = kvp.Value switch
            {
                ConstantValue cv => cv.IntValue.ToString(),
                GlobalValue gv when gv.Initializer is ArrayConstantValue arrayConst && arrayConst.StringRepresentation != null
                    => $"(const uint8_t*)\"{EscapeStringForC(arrayConst.StringRepresentation)}\"",
                GlobalValue gv => gv.Name,
                StructConstantValue nested => EmitStructConstantInline(nested),
                _ => throw new InvalidOperationException($"Unsupported field value type: {kvp.Value}")
            };
            return $".{kvp.Key} = {value}";
        });
        return $"{{ {string.Join(", ", fields)} }}";
    }

    #region Phase 1: Analysis

    private void AnalyzeFunction(Function function)
    {
        // Collect all struct types used
        CollectStructType(function.ReturnType);
        foreach (var param in function.Parameters)
            CollectStructType(param.Type);

        // Collect struct types from globals (e.g., String literals)
        foreach (var global in function.Globals)
        {
            CollectStructType(global.Type);
            // Also collect from the initializer if it's a struct constant
            if (global.Initializer is StructConstantValue structConst)
                CollectStructType(structConst.Type);
        }

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
                CollectStructType(store.Value.Type);
                break;

            case CallInstruction call:
                foreach (var arg in call.Arguments)
                {
                    CollectStructType(arg.Type);
                }
                CollectStructType(call.Result.Type);
                break;

            case CastInstruction cast:
                CollectStructType(cast.Source.Type);
                CollectStructType(cast.TargetType);
                break;

            case ReturnInstruction ret:
                // No collection needed
                break;

            case LoadInstruction load:
                CollectStructType(load.Result.Type);
                break;

            case StorePointerInstruction storePtr:
                CollectStructType(storePtr.Value.Type);
                break;

            case BinaryInstruction binary:
                CollectStructType(binary.Result.Type);
                break;

            case GetElementPtrInstruction gep:
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
            case StructType st when TypeRegistry.IsString(st):
                // String struct is emitted in headers, don't collect
                return;

            case StructType st when TypeRegistry.IsType(st):
                // Type struct is emitted in headers, don't collect
                return;

            case StructType st when TypeRegistry.IsSlice(st):
                if (st.TypeArguments.Count > 0)
                {
                    _sliceElementTypes.Add(st.TypeArguments[0]);
                    CollectStructType(st.TypeArguments[0]);
                }
                break;

            case EnumType et:
                {
                    var cName = GetEnumCName(et);
                    if (!_enumDefinitions.ContainsKey(cName))
                    {
                        _enumDefinitions[cName] = et;
                        foreach (var (_, payloadType) in et.Variants)
                        {
                            if (payloadType != null)
                                CollectStructType(payloadType);
                        }
                    }
                    break;
                }

            case StructType st:
                {
                    var cName = GetStructCName(st);
                    if (!_structDefinitions.ContainsKey(cName))
                    {
                        _structDefinitions[cName] = st;
                        foreach (var (_, fieldType) in st.Fields)
                            CollectStructType(fieldType);
                    }
                    break;
                }

            case ReferenceType rt:
                CollectStructType(rt.InnerType);
                break;

            case ArrayType at:
                _sliceElementTypes.Add(at.ElementType);
                CollectStructType(at.ElementType);
                break;
        }
    }

    #endregion

    #region Phase 2: Emit Headers and Declarations

    private void EmitHeaders()
    {
        if (_headersEmitted) return;
        _headersEmitted = true;

        _output.AppendLine("#include <stdint.h>");
        _output.AppendLine("#include <stdio.h>");
        _output.AppendLine("#include <string.h>");
        _output.AppendLine("#include <stdlib.h>");
        _output.AppendLine();
        _output.AppendLine("struct String {");
        _output.AppendLine("    const uint8_t* ptr;");
        _output.AppendLine("    uintptr_t len;");
        _output.AppendLine("};");
        _output.AppendLine();
        _output.AppendLine("// Runtime type information");
        _output.AppendLine("struct Type {");
        _output.AppendLine("    struct String name;");
        _output.AppendLine("    uint8_t size;");
        _output.AppendLine("    uint8_t align;");
        _output.AppendLine("};");
        _output.AppendLine();
        _output.AppendLine("static void __flang_unimplemented(void) {");
        _output.AppendLine("    fprintf(stderr, \"flang: unimplemented feature invoked\\n\");");
        _output.AppendLine("    abort();");
        _output.AppendLine("}");
        _output.AppendLine();
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


    #endregion

    #region Phase 3: Emit Function Definition

    private void EmitFunctionDefinition(Function function)
    {
        _currentFunction = function;
        var functionName = GetFunctionCName(function);
        var paramList = BuildParameterList(function);
        var returnType = TypeToCType(function.ReturnType);
        _output.AppendLine($"{returnType} {functionName}({paramList}) {{");

        // Emit defensive copies for by-value struct parameters
        foreach (var param in function.Parameters)
        {
            // If param is a struct (not a reference), create defensive copy
            if (param.Type is StructType st)
            {
                var structType = TypeToCType(st);
                var copyName = $"{param.Name}_copy";
                _output.AppendLine($"    {structType} {copyName} = *{param.Name};");
                // Track that uses of param should be remapped to param_copy
                _parameterRemap[param.Name] = copyName;
            }
        }

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

        var resultName = SanitizeCIdentifier(alloca.Result.Name);
        var tempVarName = $"{resultName}_val";

        if (alloca.AllocatedType is ArrayType arrayType)
        {
            // Arrays: allocate the data array directly
            // Example: %arr = alloca [3 x i32] -> int arr_val[3]; int* arr = arr_val;
            var elemType = TypeToCType(arrayType.ElementType);
            _output.AppendLine($"    {elemType} {tempVarName}[{arrayType.Length}];");
            _output.AppendLine($"    {elemType}* {resultName} = {tempVarName};");
        }
        else
        {
            // Scalars and structs
            var allocType = TypeToCType(alloca.AllocatedType);
            _output.AppendLine($"    {allocType} {tempVarName};");
            _output.AppendLine($"    {allocType}* {resultName} = &{tempVarName};");
        }
    }

    private void EmitStore(StoreInstruction store)
    {
        // store is SSA assignment: %result = value
        var resultName = SanitizeCIdentifier(store.Result.Name);
        var valueExpr = ValueToString(store.Value);

        // Handle storing dereferenced struct/slice pointers
        if (store.Value.Type is ReferenceType { InnerType: StructType })
        {
            var innerType = TypeToCType(((ReferenceType)store.Value.Type).InnerType);
            _output.AppendLine($"    {innerType} {resultName} = *{valueExpr};");
            return;
        }

        // Arrays should not appear here - they should be handled via alloca + memcpy
        // If we see an array type, it's a codegen error
        if (store.Result.Type is ArrayType)
        {
            throw new InvalidOperationException(
                $"Cannot emit store for array type {store.Result.Type.Name}. " +
                "Arrays should be allocated via alloca and copied via memcpy.");
        }

        var resultType = TypeToCType(store.Result.Type ?? TypeRegistry.I32);

        // Normal scalar assignment
        _output.AppendLine($"    {resultType} {resultName} = {valueExpr};");
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
        var resultName = SanitizeCIdentifier(load.Result.Name);
        var ptrExpr = ValueToString(load.Pointer);
        _output.AppendLine($"    {resultType} {resultName} = *{ptrExpr};");
    }

    private void EmitAddressOf(AddressOfInstruction addressOf)
    {
        // %result = addr_of var -> type* result = &var;
        var resultType = TypeToCType(addressOf.Result.Type ?? new ReferenceType(TypeRegistry.I32));
        var resultName = SanitizeCIdentifier(addressOf.Result.Name);
        _output.AppendLine($"    {resultType} {resultName} = &{addressOf.VariableName};");
    }

    private void EmitGetElementPtr(GetElementPtrInstruction gep)
    {
        // %result = getelementptr %base, offset
        // -> type* result = (type*)((uint8_t*)base + offset);

        var resultType = TypeToCType(gep.Result.Type ?? new ReferenceType(TypeRegistry.I32));
        var resultName = SanitizeCIdentifier(gep.Result.Name);
        var baseExpr = ValueToString(gep.BasePointer);
        var offsetExpr = ValueToString(gep.ByteOffset);

        // If base is not already a pointer, take its address
        if (gep.BasePointer.Type is not ReferenceType)
            baseExpr = $"&{baseExpr}";

        _output.AppendLine($"    {resultType} {resultName} = ({resultType})((uint8_t*){baseExpr} + {offsetExpr});");
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
        var resultName = SanitizeCIdentifier(binary.Result.Name);
        var left = ValueToString(binary.Left);
        var right = ValueToString(binary.Right);

        _output.AppendLine($"    {resultType} {resultName} = {left} {opSymbol} {right};");
    }

    private void EmitCast(CastInstruction cast)
    {
        var sourceType = cast.Source.Type;
        var targetType = cast.TargetType ?? TypeRegistry.I32;
        var cTargetType = TypeToCType(targetType);
        var resultName = SanitizeCIdentifier(cast.Result.Name);
        var sourceExpr = ValueToString(cast.Source);

        // Detect array-to-pointer decay: [T; N] -> &T or &[T; N] -> &T
        if (IsArrayToPointerCast(sourceType, targetType))
        {
            // Array pointer decays naturally in C - just a simple cast
            _output.AppendLine($"    {cTargetType} {resultName} = ({cTargetType}){sourceExpr};");
        }
        else if (targetType is StructType targetStruct && HasSliceLayout(targetStruct) && TryGetArrayType(sourceType, out var arrayType))
        {
            var ptrExpr = sourceType is ReferenceType ? sourceExpr : $"&{sourceExpr}";
            _output.AppendLine($"    {cTargetType} {resultName} = {{ .ptr = {ptrExpr}, .len = {arrayType!.Length} }};");
        }
        // Check if this is a struct-to-struct reinterpretation cast
        else if (targetType is StructType)
        {
            // Reinterpret cast: *(TargetType*)source_ptr
            // If source is a value, we need &source; if it's already a pointer, use it directly
            var sourcePtr = sourceType is ReferenceType
                ? sourceExpr  // Already a pointer
                : $"&{sourceExpr}";  // Take address of value

            _output.AppendLine($"    {cTargetType} {resultName} = *({cTargetType}*){sourcePtr};");
        }
        else
        {
            // Regular C cast (numeric conversions, pointer casts, etc.)
            _output.AppendLine($"    {cTargetType} {resultName} = ({cTargetType}){sourceExpr};");
        }
    }

    /// <summary>
    /// Detects if this is an array-to-pointer decay cast.
    /// Handles both [T; N] -> &T and &[T; N] -> &T cases.
    /// </summary>
    private static bool IsArrayToPointerCast(FType? sourceType, FType targetType)
    {
        if (sourceType == null) return false;

        // Case 1: [T; N] -> &T (array value to pointer)
        if (sourceType is ArrayType && targetType is ReferenceType)
            return true;

        // Case 2: &[T; N] -> &T (pointer to array to pointer to element)
        if (sourceType is ReferenceType { InnerType: ArrayType } && targetType is ReferenceType)
            return true;

        return false;
    }

    private void EmitCall(CallInstruction call)
    {
        // Determine callee name (mangled unless foreign/intrinsic)
        var calleeName = call.IsForeignCall
            ? call.FunctionName
            : NameMangler.GenericFunction(call.FunctionName,
                call.CalleeParamTypes?.ToList() ?? call.Arguments.Select(a => a.Type ?? TypeRegistry.I32).ToList());

        // Build argument list - take address of struct values since params are pointers
        var args = string.Join(", ", call.Arguments.Select(arg =>
        {
            var argStr = ValueToString(arg);
            // If argument is a struct value (not a pointer), take its address
            // GlobalValue with StructConstantValue already returns &LC0, so check for that
            if (arg.Type is StructType && !argStr.StartsWith("&"))
                return $"&{argStr}";
            return argStr;
        }));

        // Check if function returns void - if so, don't capture result
        if (call.Result.Type != null && call.Result.Type.Equals(TypeRegistry.Void))
        {
            _output.AppendLine($"    {calleeName}({args});");
        }
        else
        {
            var resultType = TypeToCType(call.Result.Type ?? TypeRegistry.I32);
            var resultName = SanitizeCIdentifier(call.Result.Name);
            _output.AppendLine($"    {resultType} {resultName} = {calleeName}({args});");
        }
    }

    private void EmitReturn(ReturnInstruction ret)
    {
        var valueExpr = ValueToString(ret.Value);

        // If returning a struct by value, but the IR value is a pointer, dereference it
        if (ret.Value.Type is ReferenceType { InnerType: StructType } &&
            _currentFunction?.ReturnType is StructType)
        {
            valueExpr = $"*{valueExpr}";
        }

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

    private string GetSliceStructName(FType elementType)
    {
        return $"Slice_{TypeToCType(elementType).Replace("*", "Ptr").Replace(" ", "_")}";
    }

    private string GetFunctionCName(Function function)
    {
        return function.Name == "main"
            ? "main"
            : NameMangler.GenericFunction(function.Name, function.Parameters.Select(p => p.Type).ToList());
    }

    private string BuildParameterList(Function function)
    {
        if (function.Parameters.Count == 0) return "void";

        return string.Join(", ", function.Parameters.Select(p =>
        {
            var paramType = TypeToCType(p.Type);
            if (p.Type is StructType)
                paramType += "*";
            return $"{paramType} {p.Name}";
        }));
    }

    private string ValueToString(Value value)
    {
        return value switch
        {
            ConstantValue constant => constant.IntValue.ToString(),

            // Handle GlobalValue
            // If it's a struct constant (like String literal), take its address
            // since GlobalValue type is &T (pointer) but C emits it as T (struct)
            GlobalValue global when global.Initializer is StructConstantValue => $"&{SanitizeCIdentifier(global.Name)}",

            GlobalValue global => SanitizeCIdentifier(global.Name),

            // Handle LocalValue - check if it's a remapped parameter
            LocalValue local => _parameterRemap.TryGetValue(local.Name, out var remapped)
                ? remapped
                : SanitizeCIdentifier(local.Name),

            _ => throw new Exception($"Unknown value type: {value.GetType().Name}")
        };
    }

    /// <summary>
    /// Sanitize an identifier name to be a valid C identifier.
    /// Replaces dots and other invalid characters with underscores.
    /// </summary>
    private static string SanitizeCIdentifier(string name)
    {
        return name.Replace('.', '_');
    }

    private string TypeToCType(FType type)
    {
        // Prune TypeVars to get the actual concrete type
        var prunedType = type.Prune();

        return prunedType switch
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

            EnumType et => $"struct {GetEnumCName(et)}",

            // Arrays are not converted to struct types - they remain as C arrays
            // Array syntax must be handled specially at declaration sites (see alloca handling)
            ArrayType => throw new InvalidOperationException("Array types must be handled specially at declaration sites"),

            _ => throw new InvalidOperationException($"Cannot convert type '{prunedType}' (original: '{type}') to C type. This indicates an unhandled type in the C code generator.")
        };
    }

    private static bool HasSliceLayout(StructType structType)
    {
        if (TypeRegistry.IsString(structType))
            return true;
        if (TypeRegistry.IsSlice(structType) && structType.GetFieldType("ptr") != null && structType.GetFieldType("len") != null)
            return true;
        return false;
    }

    private static bool TryGetArrayType(FType? type, out ArrayType? arrayType)
    {
        switch (type)
        {
            case ArrayType at:
                arrayType = at;
                return true;
            case ReferenceType { InnerType: ArrayType inner }:
                arrayType = inner;
                return true;
            default:
                arrayType = null;
                return false;
        }
    }

    private string GetStructCName(StructType structType)
    {
        // Handle builtin String type
        if (TypeRegistry.IsString(structType))
            return "String";

        // Handle builtin Type(T) - all instantiations use the same C struct
        if (TypeRegistry.IsType(structType))
            return "Type";

        // For generic structs, mangle type arguments into name
        if (structType.TypeArguments.Count > 0)
        {
            var typeArgs = string.Join("_", structType.TypeArguments.Select(t =>
                t.Name.Replace("*", "Ptr").Replace(" ", "_").Replace("[", "").Replace("]", "").Replace("<", "_").Replace(">", "_").Replace(".", "_")));
            return $"{structType.StructName.Replace('.', '_')}_{typeArgs}";
        }

        return structType.StructName.Replace('.', '_');
    }

    private string GetEnumCName(EnumType enumType)
    {
        // For generic enums, mangle type arguments into name
        if (enumType.TypeArguments.Count > 0)
        {
            var typeArgs = string.Join("_", enumType.TypeArguments.Select(t =>
                t.Name.Replace("*", "Ptr").Replace(" ", "_").Replace("[", "").Replace("]", "").Replace("<", "_").Replace(">", "_").Replace(".", "_")));
            return $"{enumType.Name.Replace('.', '_')}_{typeArgs}";
        }

        return enumType.Name.Replace('.', '_');
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
