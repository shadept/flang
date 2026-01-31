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
    private readonly Dictionary<string, StructType> _structDefinitions = [];
    private readonly Dictionary<string, EnumType> _enumDefinitions = [];
    private readonly HashSet<string> _emittedGlobals = [];
    private readonly Dictionary<string, string> _parameterRemap = [];
    private readonly HashSet<string> _foreignFunctionsWithWrappers = [];
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
                CollectGlobalValueTypes(global);
            }
        }
    }

    /// <summary>
    /// Recursively collect struct types from a global value and its initializer.
    /// </summary>
    private void CollectGlobalValueTypes(GlobalValue global)
    {
        CollectStructType(global.Type);
        switch (global.Initializer)
        {
            case StructConstantValue structConst:
                CollectStructType(structConst.Type);
                foreach (var kvp in structConst.FieldValues)
                {
                    if (kvp.Value is GlobalValue gv)
                        CollectGlobalValueTypes(gv);
                    else if (kvp.Value is StructConstantValue nested)
                        CollectStructConstantTypes(nested);
                }
                break;
            case ArrayConstantValue arrayConst when arrayConst.Type is ArrayType arrType:
                CollectStructType(arrType.ElementType);
                break;
        }
    }

    private void CollectStructConstantTypes(StructConstantValue scv)
    {
        CollectStructType(scv.Type);
        foreach (var kvp in scv.FieldValues)
        {
            if (kvp.Value is GlobalValue gv)
                CollectGlobalValueTypes(gv);
            else if (kvp.Value is StructConstantValue nested)
                CollectStructConstantTypes(nested);
        }
    }

    private void EmitProgram(IReadOnlyList<Function> functions)
    {
        EmitHeaders();
        EmitStructDefinitions();
        EmitEnumDefinitions();
        EmitForeignPrototypes(functions);
        EmitFunctionPrototypes(functions);
        EmitGlobals(functions);
        EmitForeignWrappers(functions);

        foreach (var function in functions)
        {
            if (function.IsForeign) continue;
            _parameterRemap.Clear();
            EmitFunctionDefinition(function);
            _output.AppendLine();
        }
    }

    private void EmitStructDefinitions()
    {
        // Topologically sort structs by their dependencies
        // A struct depends on another if it contains a field of that struct type (not pointer/reference)
        var structs = _structDefinitions.Values
            // TODO remove String restriction and use String from corelib
            .Where(s => !TypeRegistry.IsString(s) && !TypeRegistry.IsType(s) && !TypeRegistry.IsTypeInfo(s) && !TypeRegistry.IsFieldInfo(s))
            .ToList();

        var sorted = TopologicalSortStructs(structs);

        foreach (var structType in sorted)
        {
            EmitStructDefinition(structType);
        }
    }

    private static List<StructType> TopologicalSortStructs(List<StructType> structs)
    {
        // Build dependency graph - struct A depends on B if A has a field of type B (by value, not pointer)
        var structsByName = structs.ToDictionary(GetStructCName, s => s);
        var dependencies = new Dictionary<string, HashSet<string>>();

        foreach (var s in structs)
        {
            var name = GetStructCName(s);
            dependencies[name] = new HashSet<string>();

            foreach (var (_, fieldType) in s.Fields)
            {
                // Only by-value struct fields create dependencies
                // Pointers/references don't need the full definition, just forward declaration
                if (fieldType is StructType fieldStruct && !TypeRegistry.IsString(fieldStruct) && !TypeRegistry.IsType(fieldStruct) && !TypeRegistry.IsTypeInfo(fieldStruct) && !TypeRegistry.IsFieldInfo(fieldStruct))
                {
                    var depName = GetStructCName(fieldStruct);
                    if (structsByName.ContainsKey(depName))
                        dependencies[name].Add(depName);
                }
            }
        }

        // Kahn's algorithm for topological sort
        // inDegree[X] = number of dependencies X has (must be emitted before X)
        var result = new List<StructType>();
        var inDegree = structs.ToDictionary(GetStructCName, s => dependencies[GetStructCName(s)].Count);

        var queue = new Queue<string>(inDegree.Where(kv => kv.Value == 0).Select(kv => kv.Key).OrderBy(x => x));

        while (queue.Count > 0)
        {
            var name = queue.Dequeue();
            result.Add(structsByName[name]);

            // Find all structs that depend on this one and reduce their in-degree
            foreach (var (otherName, deps) in dependencies)
            {
                if (deps.Contains(name))
                {
                    inDegree[otherName]--;
                    if (inDegree[otherName] == 0)
                        queue.Enqueue(otherName);
                }
            }
        }

        // If we couldn't emit all structs, there's a cycle - fall back to alphabetical
        if (result.Count < structs.Count)
        {
            var emitted = new HashSet<string>(result.Select(GetStructCName));
            foreach (var s in structs.OrderBy(GetStructCName))
            {
                if (!emitted.Contains(GetStructCName(s)))
                    result.Add(s);
            }
        }

        return result;
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
                var (VariantName, PayloadType) = enumType.Variants[i];
                if (PayloadType != null)
                {
                    var payloadCType = TypeToCType(PayloadType);
                    _output.AppendLine($"        {payloadCType} variant_{i};  // {VariantName}");
                }
            }
            _output.AppendLine("    } payload;");
        }

        _output.AppendLine("};");
        _output.AppendLine();
    }

    // C stdlib functions already declared in headers - don't emit prototypes
    private static readonly HashSet<string> _cStdlibFunctions =
    [
        "malloc", "free", "realloc", "calloc",
        "memcpy", "memset", "memmove", "memcmp",
        "printf", "fprintf", "sprintf", "snprintf",
        "abort", "exit"
    ];

    /// <summary>
    /// C functions whose arguments expect char*/const char* rather than uint8_t*.
    /// Used to emit casts and avoid -Wpointer-sign errors on clang/gcc.
    /// </summary>
    private static readonly HashSet<string> _charPtrFunctions =
    [
        "printf", "fprintf", "sprintf", "snprintf",
        "puts", "fputs", "strcmp", "strncmp", "strlen",
        "strcpy", "strncpy", "strcat", "strncat"
    ];

    private void EmitForeignPrototypes(IEnumerable<Function> functions)
    {
        var emitted = new HashSet<string>();
        foreach (var function in functions)
        {
            if (!function.IsForeign) continue;
            if (function.Name == "__flang_unimplemented") continue;
            var name = GetFunctionCName(function);

            // Skip C stdlib functions - they're already declared in headers
            if (_cStdlibFunctions.Contains(name)) continue;
            if (!emitted.Add(name)) continue;

            // For foreign functions, map optional references to raw C pointers
            var returnType = ForeignTypeToCType(function.ReturnType);
            var paramList = BuildForeignParameterList(function);
            _output.AppendLine($"extern {returnType} {name}({paramList});");
        }

        if (emitted.Count > 0)
            _output.AppendLine();
    }

    private void EmitForeignWrappers(IEnumerable<Function> functions)
    {
        foreach (var function in functions)
        {
            if (!function.IsForeign) continue;
            if (function.Name == "__flang_unimplemented") continue;

            // Check if wrapper is needed (has optional reference params or return)
            bool needsWrapper = NeedsForeignWrapper(function);
            if (!needsWrapper) continue;

            // Track this function so EmitCall uses the wrapper instead of raw C call
            _foreignFunctionsWithWrappers.Add(function.Name);
            EmitForeignWrapper(function);
        }
    }

    private static bool NeedsForeignWrapper(Function function)
    {
        // Wrapper needed if return type or any param is Option<&T>
        if (IsOptionalReference(function.ReturnType)) return true;
        return function.Parameters.Any(p => IsOptionalReference(p.Type));
    }

    private static bool IsOptionalReference(TypeBase type)
    {
        if (type is StructType st && TypeRegistry.IsOption(st) && st.TypeArguments.Count > 0)
        {
            return st.TypeArguments[0] is ReferenceType;
        }
        return false;
    }

    private void EmitForeignWrapper(Function function)
    {
        var wrapperName = NameMangler.GenericFunction(function.Name, [.. function.Parameters.Select(p => p.Type)]);
        var rawName = function.Name;

        // Build wrapper signature with FLang types (Option structs)
        var returnType = TypeToCType(function.ReturnType);
        var paramList = BuildParameterList(function);

        _output.AppendLine($"{returnType} {wrapperName}({paramList}) {{");

        // Build call to raw C function, converting Option params to raw pointers
        var callArgs = new List<string>();
        foreach (var param in function.Parameters)
        {
            var paramName = EscapeCIdentifier(param.Name);
            if (IsOptionalReference(param.Type))
            {
                // Extract .value from Option struct (the raw pointer)
                // For optional params, pass NULL if has_value is false
                callArgs.Add($"({paramName}->has_value ? {paramName}->value : (void*)0)");
            }
            else if (param.Type is StructType)
            {
                // Struct params are passed by pointer, dereference for C call if needed
                callArgs.Add($"*{paramName}");
            }
            else
            {
                callArgs.Add(paramName);
            }
        }
        var argsStr = string.Join(", ", callArgs);

        if (IsOptionalReference(function.ReturnType))
        {
            // Call returns raw pointer, wrap in Option
            var optionType = (StructType)function.ReturnType;
            var innerType = optionType.TypeArguments[0];
            var innerCType = TypeToCType(innerType);

            _output.AppendLine($"    {innerCType} __raw_result = {rawName}({argsStr});");
            _output.AppendLine($"    {returnType} __result;");  // TODO TypeToCType
            _output.AppendLine($"    if (__raw_result == (void*)0) {{");
            _output.AppendLine($"        __result.has_value = 0;");
            _output.AppendLine($"    }} else {{");
            _output.AppendLine($"        __result.has_value = 1;");
            _output.AppendLine($"        __result.value = __raw_result;");
            _output.AppendLine($"    }}");
            _output.AppendLine($"    return __result;");
        }
        else if (function.ReturnType.Equals(TypeRegistry.Void))
        {
            _output.AppendLine($"    {rawName}({argsStr});");
        }
        else
        {
            _output.AppendLine($"    return {rawName}({argsStr});");
        }

        _output.AppendLine($"}}");
        _output.AppendLine();
    }

    /// <summary>
    /// Convert FLang type to C type for foreign function signatures.
    /// Optional references become raw C pointers.
    /// </summary>
    private string ForeignTypeToCType(TypeBase type)
    {
        // Option<&T> -> T* (nullable pointer)
        if (type is StructType st && TypeRegistry.IsOption(st) && st.TypeArguments.Count > 0)
        {
            var inner = st.TypeArguments[0];
            if (inner is ReferenceType rt)
            {
                return $"{TypeToCType(rt.InnerType)}*";
            }
        }
        return TypeToCType(type);
    }

    /// <summary>
    /// Build parameter list for foreign function prototypes.
    /// Optional references become raw C pointers.
    /// </summary>
    private string BuildForeignParameterList(Function function)
    {
        if (function.Parameters.Count == 0) return "void";

        return string.Join(", ", function.Parameters.Select(p =>
        {
            var paramType = ForeignTypeToCType(p.Type);
            // Don't add extra * for structs in foreign functions - they use C calling convention
            return $"{paramType} {EscapeCIdentifier(p.Name)}";
        }));
    }

    private void EmitFunctionPrototypes(IEnumerable<Function> functions)
    {
        foreach (var function in functions)
        {
            if (function.IsForeign) continue;
            _currentFunction = function;  // Track for error messages
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

        // Handle general struct constants (e.g., vtables with function pointers)
        if (global.Initializer is StructConstantValue generalStructConst &&
            generalStructConst.Type is StructType generalSt)
        {
            // Recursively emit any globals referenced by this struct's fields
            EmitDependentGlobals(generalStructConst);
            var structTypeName = TypeToCType(generalSt);
            var initStr = EmitStructConstantInline(generalStructConst);
            _output.AppendLine($"static const {structTypeName} {global.Name} = {initStr};");
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

    /// <summary>
    /// Recursively emit any GlobalValue fields referenced by a struct constant,
    /// ensuring they are declared before the struct that references them.
    /// </summary>
    private void EmitDependentGlobals(StructConstantValue scv)
    {
        foreach (var kvp in scv.FieldValues)
        {
            if (kvp.Value is GlobalValue gv)
            {
                // Recursively emit the referenced global first
                EmitGlobal(gv);
            }
            else if (kvp.Value is StructConstantValue nested)
            {
                EmitDependentGlobals(nested);
            }
        }
    }

    private string EmitStructConstantInline(StructConstantValue scv)
    {
        var fields = scv.FieldValues.Select(kvp =>
        {
            var value = kvp.Value switch
            {
                ConstantValue cv => cv.IntValue.ToString(),
                FunctionReferenceValue funcRef => GetMangledFunctionName(funcRef),
                // Handle inline ArrayConstantValue with string representation (e.g., type names in RTTI)
                ArrayConstantValue arrayConst when arrayConst.StringRepresentation != null
                    => $"(const uint8_t*)\"{EscapeStringForC(arrayConst.StringRepresentation)}\"",
                GlobalValue gv when gv.Initializer is ArrayConstantValue arrayConst && arrayConst.StringRepresentation != null
                    => $"(const uint8_t*)\"{EscapeStringForC(arrayConst.StringRepresentation)}\"",
                GlobalValue gv => FormatGlobalReference(gv, kvp.Value.Type),
                StructConstantValue nested => EmitStructConstantInline(nested),
                _ => throw new InvalidOperationException($"Unsupported field value type: {kvp.Value}")
            };
            return $".{kvp.Key} = {value}";
        });
        return $"{{ {string.Join(", ", fields)} }}";
    }

    /// <summary>
    /// Format a GlobalValue reference for use in a constant initializer.
    /// GlobalValues are pointers to their data, so in C we need &amp;name.
    /// If the target type differs from the natural pointer type, emit a cast.
    /// </summary>
    private string FormatGlobalReference(GlobalValue gv, TypeBase? targetType)
    {
        // For array globals, the C declaration is `T name[N]`, so the name itself
        // decays to a pointer to the first element — no & needed.
        // Using & would give a pointer-to-array type mismatch.
        var expr = gv.Initializer is ArrayConstantValue ? gv.Name : $"&{gv.Name}";

        // Globals are emitted as `static const`, so &name yields a const pointer.
        // Cast to the target pointer type to strip const and handle type mismatches
        // (e.g., (uint8_t*)&__global_inner_state, (AllocatorVTable*)&vtable).
        // Skip for array references — array name already decays to the correct pointer.
        if (targetType is ReferenceType rt && rt.InnerType is not ArrayType)
        {
            var castType = TypeToCType(targetType);
            return $"({castType}){expr}";
        }

        return expr;
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
            CollectGlobalValueTypes(global);
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

            case UnaryInstruction unary:
                CollectStructType(unary.Result.Type);
                break;

            case GetElementPtrInstruction gep:
                CollectStructType(gep.Result.Type);
                break;

            case AddressOfInstruction addressOf:
                CollectStructType(addressOf.Result.Type);
                break;
        }
    }

    private void CollectStructType(TypeBase? type)
    {
        if (type == null) return;

        switch (type)
        {
            case StructType st when TypeRegistry.IsString(st):
                // String struct is emitted in headers, don't collect
                return;

            case StructType st when TypeRegistry.IsType(st):
                // Type struct is emitted in headers (as TypeInfo), don't collect
                return;

            case StructType st when TypeRegistry.IsTypeInfo(st):
                // TypeInfo struct is emitted in headers, don't collect
                return;

            case StructType st when TypeRegistry.IsFieldInfo(st):
                // FieldInfo struct is emitted in headers, don't collect
                return;

            case StructType st when TypeRegistry.IsSlice(st):
                {
                    // Collect slice as a regular struct
                    var cName = GetStructCName(st);
                    if (!_structDefinitions.ContainsKey(cName))
                    {
                        _structDefinitions[cName] = st;
                        // Also collect the element type
                        if (st.TypeArguments.Count > 0)
                            CollectStructType(st.TypeArguments[0]);
                    }
                    break;
                }

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
                // Arrays may be coerced to slices, so collect a Slice struct for the element type
                var sliceType = TypeRegistry.MakeSlice(at.ElementType);
                CollectStructType(sliceType);
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
        _output.AppendLine("struct TypeInfo;");
        _output.AppendLine("struct FieldInfo {");
        _output.AppendLine("    struct String name;");
        _output.AppendLine("    uintptr_t offset;");
        _output.AppendLine("    const struct TypeInfo* type;");
        _output.AppendLine("};");
        _output.AppendLine();
        _output.AppendLine("struct TypeInfo {");
        _output.AppendLine("    struct String name;");
        _output.AppendLine("    uint8_t size;");
        _output.AppendLine("    uint8_t align;");
        _output.AppendLine("    struct { const struct FieldInfo* ptr; uintptr_t len; } fields;");
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

        // C requires structs to have at least one member
        // Add a dummy field for empty structs (like unit type / empty tuple)
        if (structType.Fields.Count == 0)
        {
            _output.AppendLine("    uint8_t __dummy;");
        }
        else
        {
            foreach (var (fieldName, fieldType) in structType.Fields)
            {
                // Function pointer fields need special declaration syntax
                if (fieldType is FunctionType ft)
                {
                    var declaration = FunctionTypeToDeclaration(ft, fieldName);
                    _output.AppendLine($"    {declaration};");
                }
                else
                {
                    var fieldCType = TypeToCType(fieldType);
                    _output.AppendLine($"    {fieldCType} {fieldName};");
                }
            }
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
                var escapedName = EscapeCIdentifier(param.Name);
                var copyName = $"{escapedName}_copy";
                _output.AppendLine($"    {structType} {copyName} = *{escapedName};");
                // Track that uses of param should be remapped to param_copy
                _parameterRemap[param.Name] = copyName;
            }
        }

        // Emit basic blocks
        for (int i = 0; i < function.BasicBlocks.Count; i++)
        {
            var block = function.BasicBlocks[i];

            // Emit label (except for first block which is the function entry)
            // Follow with a null statement so a declaration can appear next (C11 compliance)
            if (i > 0)
                _output.AppendLine($"{block.Label}: ;");

            // Emit instructions
            foreach (var instruction in block.Instructions)
                EmitInstruction(instruction);

            // C requires a statement after a label - add empty statement if block has no instructions
            // or if the last block is just a label (like if_merge at end of void function)
            if (i > 0 && block.Instructions.Count == 0)
                _output.AppendLine("    ;");
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

            case UnaryInstruction unary:
                EmitUnary(unary);
                break;

            case CastInstruction cast:
                EmitCast(cast);
                break;

            case CallInstruction call:
                EmitCall(call);
                break;

            case IndirectCallInstruction indirectCall:
                EmitIndirectCall(indirectCall);
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
        else if (alloca.AllocatedType is FunctionType ft)
        {
            // Function pointers: special declaration syntax
            // Example: %fptr = alloca fn(i32) i32 -> int32_t (*fptr_val)(int32_t); int32_t (**fptr)(int32_t) = &fptr_val;
            var declaration = FunctionTypeToDeclaration(ft, tempVarName);
            _output.AppendLine($"    {declaration};");
            var ptrDecl = FunctionTypeToDeclaration(ft, $"*{resultName}");
            _output.AppendLine($"    {ptrDecl} = &{tempVarName};");
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
        var resultName = SanitizeCIdentifier(load.Result.Name);
        var ptrExpr = ValueToString(load.Pointer);

        // Function pointers need special declaration syntax
        if (load.Result.Type is FunctionType ft)
        {
            var declaration = FunctionTypeToDeclaration(ft, resultName);
            _output.AppendLine($"    {declaration} = *{ptrExpr};");
        }
        else
        {
            var resultType = TypeToCType(load.Result.Type ?? TypeRegistry.I32);
            _output.AppendLine($"    {resultType} {resultName} = *{ptrExpr};");
        }
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

        var resultName = SanitizeCIdentifier(gep.Result.Name);
        var baseExpr = ValueToString(gep.BasePointer);
        var offsetExpr = ValueToString(gep.ByteOffset);

        // If base is not already a pointer, take its address
        if (gep.BasePointer.Type is not ReferenceType)
            baseExpr = $"&{baseExpr}";

        // Pointer-to-function-pointer needs special C declaration syntax
        if (gep.Result.Type is ReferenceType { InnerType: FunctionType ft })
        {
            var declaration = FunctionPointerTypeToDeclaration(ft, resultName);
            var castType = FunctionPointerTypeToCast(ft);
            _output.AppendLine($"    {declaration} = ({castType})((uint8_t*){baseExpr} + {offsetExpr});");
        }
        else
        {
            var resultType = TypeToCType(gep.Result.Type ?? new ReferenceType(TypeRegistry.I32));
            _output.AppendLine($"    {resultType} {resultName} = ({resultType})((uint8_t*){baseExpr} + {offsetExpr});");
        }
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

    private void EmitUnary(UnaryInstruction unary)
    {
        var opSymbol = unary.Operation switch
        {
            UnaryOp.Negate => "-",
            UnaryOp.Not => "!",
            _ => throw new Exception($"Unknown unary operation: {unary.Operation}")
        };

        var resultType = TypeToCType(unary.Result.Type ?? TypeRegistry.I32);
        var resultName = SanitizeCIdentifier(unary.Result.Name);
        var operand = ValueToString(unary.Operand);

        _output.AppendLine($"    {resultType} {resultName} = {opSymbol}{operand};");
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
            // Cast to element pointer type to strip const from static const array globals.
            var elemCType = TypeToCType(arrayType!.ElementType);
            _output.AppendLine($"    {cTargetType} {resultName} = {{ .ptr = ({elemCType}*){ptrExpr}, .len = {arrayType.Length} }};");
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
    private static bool IsArrayToPointerCast(TypeBase? sourceType, TypeBase targetType)
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
        // Determine callee name
        // For foreign calls with wrappers (optional ref params/return), use the mangled wrapper name
        // For other foreign calls without wrappers, use raw name (direct C FFI)
        // For non-foreign calls, always mangle
        var paramTypes = call.CalleeParamTypes?.ToList() ?? [.. call.Arguments.Select(a => a.Type ?? TypeRegistry.I32)];
        var calleeName = call.IsForeignCall && !_foreignFunctionsWithWrappers.Contains(call.FunctionName)
            ? call.FunctionName
            : NameMangler.GenericFunction(call.FunctionName, paramTypes);

        // Build argument list - take address of struct values since params are pointers
        var castUint8PtrToCharPtr = call.IsForeignCall && _charPtrFunctions.Contains(call.FunctionName);
        var args = string.Join(", ", call.Arguments.Select(arg =>
        {
            var argStr = ValueToString(arg);
            // If argument is a struct value (not a pointer), take its address
            // GlobalValue with StructConstantValue already returns &LC0, so check for that
            if (arg.Type is StructType && !argStr.StartsWith('&'))
                return $"&{argStr}";
            // Cast uint8_t* to const char* for C functions expecting char* (e.g. printf)
            if (castUint8PtrToCharPtr && arg.Type is ReferenceType rt && rt.InnerType.Equals(TypeRegistry.U8))
                return $"(const char*){argStr}";
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

    private void EmitIndirectCall(IndirectCallInstruction call)
    {
        // Get the function pointer value
        var funcPtrExpr = ValueToString(call.FunctionPointer);

        // Build argument list - take address of struct values since params are pointers
        var args = string.Join(", ", call.Arguments.Select(arg =>
        {
            var argStr = ValueToString(arg);
            // If argument is a struct value (not a pointer), take its address
            if (arg.Type is StructType && !argStr.StartsWith('&'))
                return $"&{argStr}";
            return argStr;
        }));

        // Check if function returns void - if so, don't capture result
        if (call.Result.Type != null && call.Result.Type.Equals(TypeRegistry.Void))
        {
            _output.AppendLine($"    {funcPtrExpr}({args});");
        }
        else
        {
            var resultType = TypeToCType(call.Result.Type ?? TypeRegistry.I32);
            var resultName = SanitizeCIdentifier(call.Result.Name);
            _output.AppendLine($"    {resultType} {resultName} = {funcPtrExpr}({args});");
        }
    }

    private void EmitReturn(ReturnInstruction ret)
    {
        // For void functions, emit simple return; without value
        if (_currentFunction?.ReturnType == TypeRegistry.Void ||
            _currentFunction?.ReturnType?.Name == "void")
        {
            _output.AppendLine("    return;");
            return;
        }

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

    private static string GetFunctionCName(Function function)
    {
        // Foreign functions use their exact name - no mangling (direct C FFI)
        if (function.IsForeign)
            return function.Name;

        // main is special - no mangling
        if (function.Name == "main")
            return "main";

        // All other FLang functions are mangled to support overloading
        return NameMangler.GenericFunction(function.Name, [.. function.Parameters.Select(p => p.Type)]);
    }

    private string BuildParameterList(Function function)
    {
        if (function.Parameters.Count == 0) return "void";

        return string.Join(", ", function.Parameters.Select(p =>
        {
            // Function types need special handling - variable name goes inside the declaration
            if (p.Type is FunctionType ft)
            {
                return FunctionTypeToDeclaration(ft, EscapeCIdentifier(p.Name));
            }

            var paramType = TypeToCType(p.Type);
            if (p.Type is StructType)
                paramType = "const " + paramType + "*";
            return $"{paramType} {EscapeCIdentifier(p.Name)}";
        }));
    }

    private string ValueToString(Value value)
    {
        return value switch
        {
            ConstantValue constant => constant.IntValue.ToString(),

            // Handle GlobalValue
            // If it's a struct constant (like String literal), take its address
            // since GlobalValue type is &T (pointer) but C emits it as T (struct).
            // Cast to non-const pointer since globals are emitted as static const.
            GlobalValue global when global.Initializer is StructConstantValue scv
                => $"({TypeToCType(scv.Type!)}*)&{SanitizeCIdentifier(global.Name)}",

            GlobalValue global => SanitizeCIdentifier(global.Name),

            // Handle FunctionReferenceValue - just emit the mangled function name
            // C will implicitly convert a function name to a function pointer
            FunctionReferenceValue funcRef => GetMangledFunctionName(funcRef),

            // Handle LocalValue - check if it's a remapped parameter
            LocalValue local => _parameterRemap.TryGetValue(local.Name, out var remapped)
                ? remapped
                : SanitizeCIdentifier(local.Name),

            _ => throw new Exception($"Unknown value type: {value.GetType().Name}")
        };
    }

    private static string GetMangledFunctionName(FunctionReferenceValue funcRef)
    {
        // Get the function type to determine parameter types for mangling
        if (funcRef.Type is FunctionType ft)
        {
            return NameMangler.GenericFunction(funcRef.FunctionName, ft.ParameterTypes);
        }
        return SanitizeCIdentifier(funcRef.FunctionName);
    }

    /// <summary>
    /// Sanitize an identifier name to be a valid C identifier.
    /// Replaces dots and other invalid characters with underscores,
    /// and escapes C reserved keywords.
    /// </summary>
    private static string SanitizeCIdentifier(string name)
    {
        var sanitized = name.Replace('.', '_');
        return EscapeCIdentifier(sanitized);
    }

    private string TypeToCType(TypeBase type)
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

            // Function types: C function pointer syntax
            // fn(i32, i32) i32 -> int32_t (*)(int32_t, int32_t)
            FunctionType ft => FunctionTypeToCType(ft),

            // Arrays are not converted to struct types - they remain as C arrays
            // Array syntax must be handled specially at declaration sites (see alloca handling)
            ArrayType => throw new InvalidOperationException("Array types must be handled specially at declaration sites"),

            GenericParameterType gp => throw new InvalidOperationException($"Generic parameter type '{gp.ParamName}' escaped to codegen (from function '{_currentFunction?.Name ?? "unknown"}')"),
            _ => throw new InvalidOperationException($"Cannot convert type '{prunedType}' (type: {prunedType.GetType().Name}, original: '{type}', original type: {type.GetType().Name}) to C type in function '{_currentFunction?.Name ?? "unknown"}'. This indicates an unhandled type in the C code generator.")
        };
    }

    /// <summary>
    /// Builds the C parameter type list and return type for a FunctionType.
    /// Struct parameters become const pointers per our C calling convention.
    /// </summary>
    private (string ReturnType, string ParamTypes) BuildFunctionTypeParts(FunctionType ft)
    {
        var returnType = TypeToCType(ft.ReturnType);
        var paramTypes = ft.ParameterTypes.Count == 0
            ? "void"
            : string.Join(", ", ft.ParameterTypes.Select(p =>
            {
                var pType = TypeToCType(p);
                if (p is StructType) pType = "const " + pType + "*";
                return pType;
            }));
        return (returnType, paramTypes);
    }

    /// <summary> fn(i32, i32) i32 -> int32_t (*)(int32_t, int32_t) </summary>
    private string FunctionTypeToCType(FunctionType ft)
    {
        var (ret, parms) = BuildFunctionTypeParts(ft);
        return $"{ret} (*)({parms})";
    }

    /// <summary> fn(i32, i32) i32 with name "f" -> int32_t (*f)(int32_t, int32_t) </summary>
    private string FunctionTypeToDeclaration(FunctionType ft, string varName)
    {
        var (ret, parms) = BuildFunctionTypeParts(ft);
        return $"{ret} (*{varName})({parms})";
    }

    /// <summary> &amp;fn(i32, i32) i32 with name "f" -> int32_t (**f)(int32_t, int32_t) </summary>
    private string FunctionPointerTypeToDeclaration(FunctionType ft, string varName)
    {
        var (ret, parms) = BuildFunctionTypeParts(ft);
        return $"{ret} (**{varName})({parms})";
    }

    /// <summary> &amp;fn(i32, i32) i32 -> int32_t (**)(int32_t, int32_t) </summary>
    private string FunctionPointerTypeToCast(FunctionType ft)
    {
        var (ret, parms) = BuildFunctionTypeParts(ft);
        return $"{ret} (**)({parms})";
    }

    private static bool HasSliceLayout(StructType structType)
    {
        if (TypeRegistry.IsString(structType))
            return true;
        if (TypeRegistry.IsSlice(structType) && structType.GetFieldType("ptr") != null && structType.GetFieldType("len") != null)
            return true;
        return false;
    }

    private static bool TryGetArrayType(TypeBase? type, out ArrayType? arrayType)
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

    private static string GetStructCName(StructType structType)
    {
        // Handle builtin String type
        if (TypeRegistry.IsString(structType))
            return "String";

        // Handle builtin Type(T) - all instantiations use the same C struct
        if (TypeRegistry.IsType(structType))
            return "TypeInfo";

        // Handle builtin TypeInfo struct
        if (TypeRegistry.IsTypeInfo(structType))
            return "TypeInfo";

        // Handle builtin FieldInfo struct
        if (TypeRegistry.IsFieldInfo(structType))
            return "FieldInfo";

        // Handle anonymous structs (tuples) - generate name from field types
        if (string.IsNullOrEmpty(structType.StructName))
        {
            var fieldTypes = string.Join("_", structType.Fields.Select(f =>
                SanitizeTypeForCName(f.Type)));
            return $"__anon_{fieldTypes}";
        }

        // For generic structs, mangle type arguments into name
        if (structType.TypeArguments.Count > 0)
        {
            var typeArgs = string.Join("_", structType.TypeArguments.Select(SanitizeTypeForCName));
            return $"{structType.StructName.Replace('.', '_')}_{typeArgs}";
        }

        return structType.StructName.Replace('.', '_');
    }

    /// <summary>
    /// Converts a type to a safe C identifier string for use in mangled names.
    /// Uses the type structure directly rather than string manipulation on Type.Name.
    /// </summary>
    private static string SanitizeTypeForCName(TypeBase type)
    {
        return type switch
        {
            PrimitiveType pt => pt.Name,
            ReferenceType rt => $"ref_{SanitizeTypeForCName(rt.InnerType)}",
            StructType st when TypeRegistry.IsSlice(st) && st.TypeArguments.Count > 0 =>
                $"slice_{SanitizeTypeForCName(st.TypeArguments[0])}",
            StructType st when TypeRegistry.IsOption(st) && st.TypeArguments.Count > 0 =>
                $"opt_{SanitizeTypeForCName(st.TypeArguments[0])}",
            StructType st => st.StructName.Replace('.', '_'),
            ArrayType at => $"arr{at.Length}_{SanitizeTypeForCName(at.ElementType)}",
            EnumType et => et.Name.Replace('.', '_'),
            FunctionType ft => $"fn_{string.Join("_", ft.ParameterTypes.Select(SanitizeTypeForCName))}_ret_{SanitizeTypeForCName(ft.ReturnType)}",
            _ => type.Name.Replace(".", "_").Replace(" ", "_")
        };
    }

    private static string GetEnumCName(EnumType enumType)
    {
        // For generic enums, mangle type arguments into name
        if (enumType.TypeArguments.Count > 0)
        {
            var typeArgs = string.Join("_", enumType.TypeArguments.Select(SanitizeTypeForCName));
            return $"{enumType.Name.Replace('.', '_')}_{typeArgs}";
        }

        return enumType.Name.Replace('.', '_');
    }

    private static string EscapeStringForC(string value)
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

    // C reserved keywords that must be escaped when used as identifiers
    private static readonly HashSet<string> CReservedKeywords =
    [
        "auto", "break", "case", "char", "const", "continue", "default", "do",
        "double", "else", "enum", "extern", "float", "for", "goto", "if",
        "inline", "int", "long", "register", "restrict", "return", "short",
        "signed", "sizeof", "static", "struct", "switch", "typedef", "union",
        "unsigned", "void", "volatile", "while", "_Alignas", "_Alignof",
        "_Atomic", "_Bool", "_Complex", "_Generic", "_Imaginary", "_Noreturn",
        "_Static_assert", "_Thread_local"
    ];

    /// <summary>
    /// Escapes a FLang identifier if it conflicts with a C reserved keyword.
    /// </summary>
    private static string EscapeCIdentifier(string name)
    {
        return CReservedKeywords.Contains(name) ? $"{name}_" : name;
    }

    #endregion
}
