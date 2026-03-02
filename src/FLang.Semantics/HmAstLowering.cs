using System.Text;
using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;
using FLang.IR;
using FLang.IR.Instructions;
using FunctionType = FLang.Core.Types.FunctionType;
using Type = FLang.Core.Types.Type;

namespace FLang.Semantics;

/// <summary>
/// Lowers type-checked AST (via HmTypeChecker) to IrModule.
/// Uses IrType exclusively — no TypeBase.
/// </summary>
public class HmAstLowering
{
    private readonly HmTypeChecker _checker;
    private readonly TypeLayoutService _layout;
    private readonly InferenceEngine _engine;
    private readonly IrModule _module = new();
    private readonly List<Diagnostic> _diagnostics = [];

    // Per-function state
    private readonly Dictionary<string, Value> _locals = [];
    private readonly HashSet<string> _parameters = [];
    private readonly HashSet<string> _byRefParams = [];
    private readonly Dictionary<string, int> _shadowCounter = [];
    private BasicBlock _currentBlock = null!;
    private IrFunction _currentFunction = null!;
    private SourceSpan _currentSpan;
    private int _tempCounter;
    private int _blockCounter;
    private readonly Dictionary<string, int> _stringTableIndices = [];

    // Loop control flow
    private readonly Stack<(BasicBlock BodyBlock, BasicBlock ExitBlock)> _loopStack = new();

    // Defer stack — per-function, stores deferred expressions in LIFO order
    private readonly Stack<ExpressionNode> _deferStack = new();

    // Global constants — name -> lowered Value
    private readonly Dictionary<string, Value> _globalConstants = [];

    // Type table — maps type cache key -> GlobalValue for Type(T) RTTI
    private Dictionary<string, GlobalValue>? _typeTableGlobals;

    public IReadOnlyList<Diagnostic> Diagnostics => _diagnostics;

    public HmAstLowering(HmTypeChecker checker, TypeLayoutService layout, InferenceEngine engine)
    {
        _checker = checker;
        _layout = layout;
        _engine = engine;
    }

    // =========================================================================
    // Niche optimization helpers: Option[&T] -> nullable pointer
    // =========================================================================

    /// <summary>
    /// Returns true when the IrType is a niche-optimized Option[&T] (nullable pointer).
    /// </summary>
    private static bool IsNicheOption(IrType? t) => t is IrPointer { IsNullable: true };

    /// <summary>
    /// Strip the nullable flag from a nullable pointer to get the non-nullable equivalent.
    /// </summary>
    private static IrPointer StripNullable(IrPointer p) => new(p.Pointee, false);

    /// <summary>
    /// Returns true when the type is a large value type (struct or enum > 8 bytes)
    /// that should be passed by implicit reference at the ABI level.
    /// </summary>
    private static bool IsLargeValue(IrType type) => TypeLayoutService.IsLargeValue(type);

    // =========================================================================
    // Fused offset helpers — emit CopyFromOffset / CopyToOffset directly
    // =========================================================================

    /// <summary>
    /// Load a field from basePtr + constant byte offset (replaces GEP+Load).
    /// </summary>
    private LocalValue EmitLoadFromOffset(Value basePtr, int byteOffset, IrType fieldType, string nameHint)
    {
        var result = new LocalValue($"{nameHint}_{_tempCounter++}", fieldType);
        var offset = new IntConstantValue(byteOffset, TypeLayoutService.IrUSize);
        _currentBlock.Instructions.Add(new CopyFromOffsetInstruction(_currentSpan, basePtr, offset, result));
        return result;
    }

    /// <summary>
    /// Load a field from basePtr + dynamic byte offset (replaces GEP+Load).
    /// </summary>
    private LocalValue EmitLoadFromOffset(Value basePtr, Value byteOffset, IrType fieldType, string nameHint)
    {
        var result = new LocalValue($"{nameHint}_{_tempCounter++}", fieldType);
        _currentBlock.Instructions.Add(new CopyFromOffsetInstruction(_currentSpan, basePtr, byteOffset, result));
        return result;
    }

    /// <summary>
    /// Store a value to basePtr + constant byte offset (replaces GEP+StorePointer).
    /// </summary>
    private void EmitStoreToOffset(Value basePtr, int byteOffset, Value val, IrType valueType)
    {
        var offset = new IntConstantValue(byteOffset, TypeLayoutService.IrUSize);
        _currentBlock.Instructions.Add(new CopyToOffsetInstruction(_currentSpan, val, basePtr, offset, valueType));
    }

    /// <summary>
    /// Store a value to basePtr + dynamic byte offset (replaces GEP+StorePointer).
    /// </summary>
    private void EmitStoreToOffset(Value basePtr, Value byteOffset, Value val, IrType valueType)
    {
        _currentBlock.Instructions.Add(new CopyToOffsetInstruction(_currentSpan, val, basePtr, byteOffset, valueType));
    }

    /// <summary>
    /// Emit a non-foreign call instruction with implicit by-ref transformations:
    /// - Large value args are materialized as pointers
    /// - Large return types use a hidden return slot
    /// </summary>
    private LocalValue EmitFLangCall(string fnName, List<Value> args, IrType retIrType, List<IrType>? calleeIrParamTypes)
    {
        // Materialize large value args as pointers
        if (calleeIrParamTypes != null)
        {
            for (int i = 0; i < args.Count && i < calleeIrParamTypes.Count; i++)
            {
                if (IsLargeValue(calleeIrParamTypes[i]) && args[i].IrType is not IrPointer)
                {
                    var argIrType = args[i].IrType ?? calleeIrParamTypes[i];
                    var temp = new LocalValue($"byref_arg_{_tempCounter++}", new IrPointer(argIrType));
                    _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, argIrType.Size, temp));
                    _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, temp, args[i]));
                    args[i] = temp;
                }
            }
        }

        // Return slot for large return types
        if (IsLargeValue(retIrType))
        {
            var retSlot = new LocalValue($"retslot_{_tempCounter++}", new IrPointer(retIrType));
            _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, retIrType.Size, retSlot));
            args.Insert(0, retSlot);

            var voidResult = new LocalValue($"call_{_tempCounter++}", TypeLayoutService.IrVoidPrim);
            var callInst = new CallInstruction(_currentSpan, fnName, args, voidResult);
            if (calleeIrParamTypes != null && calleeIrParamTypes.Count > 0)
                callInst.CalleeIrParamTypes = calleeIrParamTypes;
            _currentBlock.Instructions.Add(callInst);

            var loaded = new LocalValue($"retload_{_tempCounter++}", retIrType);
            _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, retSlot, loaded));
            return loaded;
        }

        var result = new LocalValue($"call_{_tempCounter++}", retIrType);
        var normalCall = new CallInstruction(_currentSpan, fnName, args, result);
        if (calleeIrParamTypes != null && calleeIrParamTypes.Count > 0)
            normalCall.CalleeIrParamTypes = calleeIrParamTypes;
        _currentBlock.Instructions.Add(normalCall);
        return result;
    }

    // =========================================================================
    // Module lowering
    // =========================================================================

    public IrModule LowerModule(IEnumerable<(string ModulePath, ModuleNode Module)> modules, bool runTests = false)
    {
        // Materialize so we can iterate multiple times
        var moduleList = modules.ToList();

        // Lower global constants first (before functions that reference them)
        foreach (var (modulePath, module) in moduleList)
            LowerModuleGlobals(module);

        // Collect foreign declarations (also collects types from signatures)
        foreach (var (modulePath, module) in moduleList)
        {
            foreach (var fn in module.Functions)
            {
                if ((fn.Modifiers & FunctionModifiers.Foreign) == 0) continue;
                var foreignDecl = LowerForeignDecl(fn);
                if (foreignDecl != null)
                    _module.ForeignDecls.Add(foreignDecl);
            }
        }

        // Track emitted function mangled names to deduplicate across modules
        var emittedFunctions = new HashSet<string>();

        // Lower non-generic, non-foreign functions
        foreach (var (modulePath, module) in moduleList)
        {
            foreach (var fn in module.Functions)
            {
                if ((fn.Modifiers & FunctionModifiers.Foreign) != 0) continue;
                if (fn.IsGeneric) continue;
                var irFn = LowerFunction(fn);
                var mangledName = irFn.IsEntryPoint ? "main"
                    : IrNameMangling.MangleFunctionName(irFn.Name,
                        [.. irFn.Params.Select(p => p.Type)]);
                if (emittedFunctions.Add(mangledName))
                    _module.Functions.Add(irFn);
            }
        }

        // Lower specialized/synthesized functions (lambdas, monomorphized generics)
        foreach (var fn in _checker.GetSpecializedFunctions())
        {
            var irFn = LowerFunction(fn);
            var mangledName = irFn.IsEntryPoint ? "main"
                : IrNameMangling.MangleFunctionName(irFn.Name,
                    [.. irFn.Params.Select(p => p.Type)]);
            if (emittedFunctions.Add(mangledName))
                _module.Functions.Add(irFn);
        }

        // When running tests: lower test blocks and generate synthetic main
        if (runTests)
        {
            var testFunctions = new List<(string Name, IrFunction Function)>();
            int testIndex = 0;
            foreach (var (modulePath, module) in moduleList)
            {
                foreach (var test in module.Tests)
                {
                    var irFn = LowerTestBlock(test, testIndex++);
                    _module.Functions.Add(irFn);
                    testFunctions.Add((test.Name, irFn));
                }
            }

            if (testFunctions.Count > 0)
            {
                var mainFn = GenerateTestMain(testFunctions);
                // Remove any existing entry point (test files shouldn't have main)
                foreach (var fn in _module.Functions)
                    fn.IsEntryPoint = false;
                _module.Functions.Add(mainFn);
            }
        }

        // Collect struct/enum types referenced in function signatures
        CollectReferencedTypes();

        // Post-lowering validation: mark functions that call unlowered targets
        ValidateCallTargets();

        return _module;
    }

    // =========================================================================
    // Test block lowering
    // =========================================================================

    private IrFunction LowerTestBlock(TestDeclarationNode test, int index)
    {
        // Reset per-function state
        _locals.Clear();
        _parameters.Clear();
        _byRefParams.Clear();
        _shadowCounter.Clear();
        _loopStack.Clear();
        _deferStack.Clear();
        _tempCounter = 0;
        _blockCounter = 0;

        var fnName = $"__test_{index}__";
        var irFn = new IrFunction(fnName, TypeLayoutService.IrVoidPrim);
        _currentFunction = irFn;

        _currentBlock = CreateBlock("entry");
        irFn.BasicBlocks.Add(_currentBlock);

        foreach (var stmt in test.Body)
            LowerStatement(stmt);

        // Emit deferred expressions
        if (_currentBlock.Instructions.Count == 0 ||
            _currentBlock.Instructions[^1] is not (ReturnInstruction or JumpInstruction or BranchInstruction))
        {
            EmitDeferredExpressions();
        }

        // Add implicit void return to unterminated blocks
        foreach (var block in irFn.BasicBlocks)
        {
            if (block.Instructions.Count == 0 ||
                block.Instructions[^1] is not (ReturnInstruction or JumpInstruction or BranchInstruction))
            {
                var retVal = new IntConstantValue(0, TypeLayoutService.IrVoidPrim);
                block.Instructions.Add(new ReturnInstruction(_currentSpan, retVal));
            }
        }

        return irFn;
    }

    private IrFunction GenerateTestMain(List<(string Name, IrFunction Function)> testFunctions)
    {
        _locals.Clear();
        _parameters.Clear();
        _byRefParams.Clear();
        _shadowCounter.Clear();
        _loopStack.Clear();
        _deferStack.Clear();
        _tempCounter = 0;
        _blockCounter = 0;

        var irFn = new IrFunction("main", TypeLayoutService.IrI32);
        irFn.IsEntryPoint = true;
        _currentFunction = irFn;

        _currentBlock = CreateBlock("entry");
        irFn.BasicBlocks.Add(_currentBlock);

        // Print header
        AddStringPrintf($"Running {testFunctions.Count} test(s)...\\n");

        for (int i = 0; i < testFunctions.Count; i++)
        {
            var (name, testFn) = testFunctions[i];

            // Print: "test N/total: name... "
            AddStringPrintf($"test {i + 1}/{testFunctions.Count}: {EscapeCString(name)}... ");

            // Call the test function
            var callResult = new LocalValue($"call_{_tempCounter++}", TypeLayoutService.IrVoidPrim);
            var callInst = new CallInstruction(SourceSpan.None, testFn.Name, [], callResult);
            _currentBlock.Instructions.Add(callInst);

            // Print "ok\n"
            AddStringPrintf("ok\\n");
        }

        // Print summary
        AddStringPrintf($"\\nAll {testFunctions.Count} test(s) passed.\\n");

        // return 0
        _currentBlock.Instructions.Add(new ReturnInstruction(SourceSpan.None,
            new IntConstantValue(0, TypeLayoutService.IrI32)));

        return irFn;
    }

    private void AddStringPrintf(string text)
    {
        var fmtResult = new LocalValue($"call_{_tempCounter++}", TypeLayoutService.IrI32);
        var fmtStr = new RawCStringValue(text);
        var printfCall = new CallInstruction(SourceSpan.None, "printf", [fmtStr], fmtResult)
        {
            IsForeignCall = true
        };
        _currentBlock.Instructions.Add(printfCall);
    }

    private static string EscapeCString(string s)
    {
        return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n");
    }

    // =========================================================================
    // Global constant lowering
    // =========================================================================

    private void LowerModuleGlobals(ModuleNode module)
    {
        foreach (var globalConst in module.GlobalConstants)
        {
            if (globalConst.Initializer == null) continue;
            var hmType = _checker.Engine.Resolve(_checker.GetInferredType(globalConst));
            var irType = _layout.Lower(hmType);
            var value = LowerGlobalInitializer(globalConst.Initializer, irType, globalConst.Name,
                isTopLevel: true);
            if (value != null)
            {
                _globalConstants[globalConst.Name] = value;
                if (value is GlobalValue gv)
                    _module.GlobalValues.Add(gv);
            }
        }
    }

    private Value? LowerGlobalInitializer(ExpressionNode expr, IrType targetType, string name,
        bool isTopLevel = false)
    {
        // Unwrap implicit coercions
        if (expr is ImplicitCoercionNode coercion)
            return LowerGlobalInitializer(coercion.Inner, targetType, name, isTopLevel);

        // Integer literal
        if (expr is IntegerLiteralNode intLit)
            return new IntConstantValue(intLit.Value, targetType);

        // Floating-point literal
        if (expr is FloatingPointLiteralNode floatLit)
            return new FloatConstantValue(floatLit.Value, targetType);

        // Boolean literal
        if (expr is BooleanLiteralNode boolLit)
            return new IntConstantValue(boolLit.Value ? 1 : 0, targetType);

        // String literal — add to string table and return inline struct value
        if (expr is StringLiteralNode strLit && targetType is IrStruct strStruct)
        {
            // Reuse LowerStringLiteral to add to string table, but we need the
            // raw bytes for the inline C initializer
            var bytes = System.Text.Encoding.UTF8.GetBytes(strLit.Value);
            var nullTerminated = new byte[bytes.Length + 1];
            Array.Copy(bytes, nullTerminated, bytes.Length);

            // Add to string table for the data
            if (!_stringTableIndices.TryGetValue(strLit.Value, out var strIndex))
            {
                strIndex = _module.StringTable.Count;
                _module.StringTable.Add(new StringTableEntry(strLit.Value, nullTerminated));
                _stringTableIndices[strLit.Value] = strIndex;
            }

            return new StringTableValue(strIndex, targetType);
        }

        // Enum variant access (e.g., FileMode.Read) — lower to tag constant
        if (expr is MemberAccessExpressionNode memberAccess && targetType is IrEnum irEnum)
        {
            foreach (var variant in irEnum.Variants)
            {
                if (variant.Name == memberAccess.FieldName)
                {
                    // Naked enum: return a StructConstantValue with just the tag field
                    var fieldValues = new Dictionary<string, Value>
                    {
                        ["tag"] = new IntConstantValue(variant.TagValue, TypeLayoutService.IrI32)
                    };
                    var result = new StructConstantValue(irEnum, fieldValues);
                    if (isTopLevel)
                    {
                        var global = new GlobalValue($"__global_{name}", result, irEnum);
                        return global;
                    }
                    return result;
                }
            }
        }

        // Struct construction
        if (expr is StructConstructionExpressionNode sc && targetType is IrStruct irStruct)
        {
            var fieldValues = new Dictionary<string, Value>();
            foreach (var field in sc.Fields)
            {
                var fieldDef = irStruct.Fields.FirstOrDefault(f => f.Name == field.FieldName);
                if (fieldDef == null) continue;
                var fieldVal = LowerGlobalInitializer(field.Value, fieldDef.Type, $"{name}.{field.FieldName}");
                if (fieldVal != null)
                    fieldValues[field.FieldName] = fieldVal;
            }
            var structConst = new StructConstantValue(irStruct, fieldValues);
            if (isTopLevel)
            {
                var global = new GlobalValue($"__global_{name}", structConst, irStruct);
                return global;
            }
            return structConst;
        }

        // Anonymous struct construction
        if (expr is AnonymousStructExpressionNode anon && targetType is IrStruct anonStruct)
        {
            var fieldValues = new Dictionary<string, Value>();
            foreach (var field in anon.Fields)
            {
                var fieldDef = anonStruct.Fields.FirstOrDefault(f => f.Name == field.FieldName);
                if (fieldDef == null) continue;
                var fieldVal = LowerGlobalInitializer(field.Value, fieldDef.Type, $"{name}.{field.FieldName}");
                if (fieldVal != null)
                    fieldValues[field.FieldName] = fieldVal;
            }
            var structConst = new StructConstantValue(anonStruct, fieldValues);
            if (isTopLevel)
            {
                var global = new GlobalValue($"__global_{name}", structConst, anonStruct);
                return global;
            }
            return structConst;
        }

        // Identifier — reference to another global constant or function
        if (expr is IdentifierExpressionNode id)
        {
            // Check for function reference
            var idType = _checker.Engine.Resolve(_checker.GetInferredType(id));
            if (idType is FunctionType)
                return new FunctionReferenceValue(id.Name, _layout.Lower(idType));

            // Check for another global constant
            if (_globalConstants.TryGetValue(id.Name, out var existing))
                return existing;

            return null;
        }

        // Address-of
        if (expr is AddressOfExpressionNode addrOf)
        {
            var innerType = _checker.Engine.Resolve(_checker.GetInferredType(addrOf.Target));
            var innerIrType = _layout.Lower(innerType);
            var innerVal = LowerGlobalInitializer(addrOf.Target, innerIrType, name);
            if (innerVal is GlobalValue)
                return innerVal; // GlobalValue is already a pointer
            return innerVal;
        }

        // Cast — unwrap and use target type
        if (expr is CastExpressionNode cast)
        {
            var castTargetType = _checker.Engine.Resolve(_checker.GetInferredType(cast));
            var castIrType = _layout.Lower(castTargetType);
            return LowerGlobalInitializer(cast.Expression, castIrType, name);
        }

        return null;
    }

    // =========================================================================
    // Type table (RTTI) — builds GlobalValue entries for each Type(T)
    // =========================================================================

    private void EnsureTypeTableExists()
    {
        if (_typeTableGlobals != null) return;
        _typeTableGlobals = new Dictionary<string, GlobalValue>();

        // Get the IrStruct for TypeInfo
        var typeInfoNominal = _checker.LookupNominalType("core.rtti.TypeInfo");
        if (typeInfoNominal == null) return;
        var typeInfoIr = _layout.Lower(typeInfoNominal) as IrStruct;
        if (typeInfoIr == null) return;

        // Get the IrStruct for FieldInfo
        var fieldInfoNominal = _checker.LookupNominalType("core.rtti.FieldInfo");
        var fieldInfoIr = fieldInfoNominal != null ? _layout.Lower(fieldInfoNominal) as IrStruct : null;

        // Get the IrStruct for ParamInfo
        var paramInfoNominal = _checker.LookupNominalType("core.rtti.ParamInfo");
        var paramInfoIr = paramInfoNominal != null ? _layout.Lower(paramInfoNominal) as IrStruct : null;

        // Get the IrStruct for String
        var stringNominal = _checker.LookupNominalType(WellKnown.String);
        var stringIr = stringNominal != null ? _layout.Lower(stringNominal) as IrStruct : null;

        // Get slice IrStructs by looking at TypeInfo field types
        IrStruct? fieldsSliceIr = null;
        IrStruct? typeParamsSliceIr = null;
        IrStruct? typeArgsSliceIr = null;
        IrStruct? paramsSliceIr = null;
        foreach (var field in typeInfoIr.Fields)
        {
            if (field.Name == "fields" && field.Type is IrStruct fs) fieldsSliceIr = fs;
            else if (field.Name == "type_params" && field.Type is IrStruct tps) typeParamsSliceIr = tps;
            else if (field.Name == "type_args" && field.Type is IrPointer { Pointee: IrStruct tas }) typeArgsSliceIr = tas;
            else if (field.Name == "params" && field.Type is IrStruct ps) paramsSliceIr = ps;
        }

        // Expand InstantiatedTypes to include field types of struct types
        var allTypes = new HashSet<Type>(_checker.InstantiatedTypes.Select(t => _engine.Resolve(t)));
        bool changed = true;
        while (changed)
        {
            changed = false;
            foreach (var type in allTypes.ToList())
            {
                if (type is NominalType { Kind: NominalKind.Struct or NominalKind.Tuple } nt
                    && !nt.Name.StartsWith(WellKnown.RttiPrefix) && nt.Name != WellKnown.String)
                {
                    foreach (var (_, ft) in nt.FieldsOrVariants)
                    {
                        var fieldType = _engine.Resolve(ft);
                        if (fieldType is Core.Types.ReferenceType refT) fieldType = _engine.Resolve(refT.InnerType);
                        if (fieldType is Core.Types.TypeVar) continue;
                        if (allTypes.Add(fieldType)) changed = true;
                    }
                }
                // Expand function types: include parameter types and return type
                else if (type is FunctionType fnType)
                {
                    foreach (var pt in fnType.ParameterTypes)
                    {
                        var paramType = _engine.Resolve(pt);
                        if (paramType is Core.Types.ReferenceType refT) paramType = _engine.Resolve(refT.InnerType);
                        if (paramType is Core.Types.TypeVar) continue;
                        if (allTypes.Add(paramType)) changed = true;
                    }
                    var retType = _engine.Resolve(fnType.ReturnType);
                    if (retType is Core.Types.ReferenceType retRef) retType = _engine.Resolve(retRef.InnerType);
                    if (retType is not Core.Types.TypeVar && allTypes.Add(retType)) changed = true;
                }
            }
        }

        // First pass: create all globals (so we can reference them for field type pointers)
        var typeKeys = new Dictionary<string, Type>();
        foreach (var innerType in allTypes)
        {
            var key = BuildTypeKey(innerType);
            if (!typeKeys.ContainsKey(key))
                typeKeys[key] = innerType;
        }

        // Helper: build a String constant value
        StructConstantValue MakeStringConstant(string text)
        {
            var bytes = System.Text.Encoding.UTF8.GetBytes(text + "\0");
            var arr = new ArrayConstantValue(bytes, TypeLayoutService.IrU8)
            {
                StringRepresentation = text
            };
            return new StructConstantValue(stringIr!, new Dictionary<string, Value>
            {
                ["ptr"] = arr,
                ["len"] = new IntConstantValue(text.Length, TypeLayoutService.IrUSize),
            });
        }

        // Helper: get TypeKind integer
        int GetTypeKind(Type t) => t switch
        {
            Core.Types.PrimitiveType => 0,
            Core.Types.ArrayType => 1,
            NominalType { Kind: NominalKind.Struct or NominalKind.Tuple } => 2,
            NominalType { Kind: NominalKind.Enum } => 3,
            Core.Types.FunctionType => 4,
            _ => 0
        };

        // Helper: make empty slice constant
        StructConstantValue MakeEmptySlice(IrStruct sliceIr)
        {
            return new StructConstantValue(sliceIr, new Dictionary<string, Value>
            {
                ["ptr"] = new IntConstantValue(0, TypeLayoutService.IrUSize),
                ["len"] = new IntConstantValue(0, TypeLayoutService.IrUSize),
            });
        }

        // Create static empty type_args slice global (type_args is &Slice, so we need a global to point to)
        GlobalValue? emptyTypeArgsGlobal = null;
        if (typeArgsSliceIr != null)
        {
            var emptySlice = MakeEmptySlice(typeArgsSliceIr);
            emptyTypeArgsGlobal = new GlobalValue("__flang__empty_type_args", emptySlice, typeArgsSliceIr);
            _module.GlobalValues.Add(emptyTypeArgsGlobal);
        }

        // Deferred patches: after all globals are created, wire up type_info pointers
        var patches = new List<(Dictionary<string, Value> Dict, string Field, Type TargetType)>();

        // Build type table entries
        int typeIndex = 0;
        foreach (var (key, innerType) in typeKeys.OrderBy(kv => kv.Key))
        {
            if (_typeTableGlobals.ContainsKey(key)) continue;

            var innerIr = _layout.Lower(innerType);
            var typeName = innerType switch
            {
                NominalType nt2 => nt2.Name,
                FunctionType ft2 =>
                    $"fn({string.Join(", ", ft2.ParameterTypes.Select(p => _engine.Resolve(p).ToString()))}) {_engine.Resolve(ft2.ReturnType)}",
                _ => innerType.ToString() ?? "unknown"
            };
            var globalName = $"__flang__typeinfo_{key}";

            // Build field values
            var fieldValues = new Dictionary<string, Value>
            {
                ["size"] = new IntConstantValue(innerIr.Size, TypeLayoutService.IrU8),
                ["align"] = new IntConstantValue(innerIr.Alignment, TypeLayoutService.IrU8),
                ["kind"] = new IntConstantValue(GetTypeKind(innerType), TypeLayoutService.IrI32),
            };

            // Name field
            if (stringIr != null)
                fieldValues["name"] = MakeStringConstant(typeName);

            // Empty slices for type_params, type_args
            if (typeParamsSliceIr != null)
                fieldValues["type_params"] = MakeEmptySlice(typeParamsSliceIr);
            if (emptyTypeArgsGlobal != null)
                fieldValues["type_args"] = emptyTypeArgsGlobal;

            // Fields slice
            if (fieldsSliceIr != null && fieldInfoIr != null && stringIr != null
                && innerType is NominalType { Kind: NominalKind.Struct or NominalKind.Tuple } structType
                && structType.FieldsOrVariants.Count > 0
                && !structType.Name.StartsWith(WellKnown.RttiPrefix))
            {
                // Build FieldInfo array for this struct's fields
                var fieldElements = new List<Value>();
                var structIr = innerIr as IrStruct;

                foreach (var (fieldName, fieldType) in structType.FieldsOrVariants)
                {
                    // Find field offset from IR
                    int offset = 0;
                    if (structIr != null)
                    {
                        var irField = structIr.Fields.FirstOrDefault(f => f.Name == fieldName);
                        if (irField.Type != null) offset = irField.ByteOffset;
                    }

                    var fieldInfoValues = new Dictionary<string, Value>
                    {
                        ["name"] = MakeStringConstant(fieldName),
                        ["offset"] = new IntConstantValue(offset, TypeLayoutService.IrUSize),
                        ["type_info"] = new IntConstantValue(0, TypeLayoutService.IrUSize), // patched below
                    };

                    // Resolve the field type for deferred patching
                    var resolvedFieldType = _engine.Resolve(fieldType);
                    if (resolvedFieldType is Core.Types.ReferenceType refFT)
                        resolvedFieldType = _engine.Resolve(refFT.InnerType);
                    if (resolvedFieldType is not Core.Types.TypeVar)
                        patches.Add((fieldInfoValues, "type_info", resolvedFieldType));

                    fieldElements.Add(new StructConstantValue(fieldInfoIr, fieldInfoValues));
                }

                // Create global array for fields
                var fieldArrayGlobal = new GlobalValue(
                    $"__flang__typeinfo_{key}_fields",
                    new ArrayConstantValue(
                        new IrArray(fieldInfoIr, fieldElements.Count),
                        fieldElements.ToArray()),
                    new IrArray(fieldInfoIr, fieldElements.Count));
                _module.GlobalValues.Add(fieldArrayGlobal);

                fieldValues["fields"] = new StructConstantValue(fieldsSliceIr, new Dictionary<string, Value>
                {
                    ["ptr"] = fieldArrayGlobal,
                    ["len"] = new IntConstantValue(fieldElements.Count, TypeLayoutService.IrUSize),
                });
            }
            else if (fieldsSliceIr != null)
            {
                fieldValues["fields"] = MakeEmptySlice(fieldsSliceIr);
            }

            // Params slice (for function types)
            if (paramsSliceIr != null && paramInfoIr != null && stringIr != null
                && innerType is FunctionType fnType2)
            {
                var paramElements = new List<Value>();
                for (int i = 0; i < fnType2.ParameterTypes.Count; i++)
                {
                    var paramInfoValues = new Dictionary<string, Value>
                    {
                        ["name"] = MakeStringConstant($"_{i}"),
                        ["type_info"] = new IntConstantValue(0, TypeLayoutService.IrUSize), // patched below
                    };

                    // Resolve the param type for deferred patching
                    var resolvedParamType = _engine.Resolve(fnType2.ParameterTypes[i]);
                    if (resolvedParamType is Core.Types.ReferenceType refPT)
                        resolvedParamType = _engine.Resolve(refPT.InnerType);
                    if (resolvedParamType is not Core.Types.TypeVar)
                        patches.Add((paramInfoValues, "type_info", resolvedParamType));

                    paramElements.Add(new StructConstantValue(paramInfoIr, paramInfoValues));
                }

                if (paramElements.Count > 0)
                {
                    var paramArrayGlobal = new GlobalValue(
                        $"__flang__typeinfo_{key}_params",
                        new ArrayConstantValue(
                            new IrArray(paramInfoIr, paramElements.Count),
                            paramElements.ToArray()),
                        new IrArray(paramInfoIr, paramElements.Count));
                    _module.GlobalValues.Add(paramArrayGlobal);

                    fieldValues["params"] = new StructConstantValue(paramsSliceIr, new Dictionary<string, Value>
                    {
                        ["ptr"] = paramArrayGlobal,
                        ["len"] = new IntConstantValue(paramElements.Count, TypeLayoutService.IrUSize),
                    });
                }
                else
                {
                    fieldValues["params"] = MakeEmptySlice(paramsSliceIr);
                }

                // return_type pointer — patched below
                fieldValues["return_type"] = new IntConstantValue(0, TypeLayoutService.IrUSize);
                var resolvedRetType = _engine.Resolve(fnType2.ReturnType);
                if (resolvedRetType is Core.Types.ReferenceType refRT)
                    resolvedRetType = _engine.Resolve(refRT.InnerType);
                if (resolvedRetType is not Core.Types.TypeVar)
                    patches.Add((fieldValues, "return_type", resolvedRetType));
            }
            else
            {
                if (paramsSliceIr != null)
                    fieldValues["params"] = MakeEmptySlice(paramsSliceIr);
                fieldValues["return_type"] = new IntConstantValue(0, TypeLayoutService.IrUSize); // NULL
            }

            var structConst = new StructConstantValue(typeInfoIr, fieldValues);
            var global = new GlobalValue(globalName, structConst, typeInfoIr);

            _typeTableGlobals[key] = global;
            _module.GlobalValues.Add(global);
            typeIndex++;
        }

        // Second pass: apply deferred patches to wire up type_info and return_type pointers
        foreach (var (dict, field, targetType) in patches)
        {
            var targetKey = BuildTypeKey(targetType);
            if (_typeTableGlobals.TryGetValue(targetKey, out var targetGlobal))
                dict[field] = targetGlobal;
        }
    }

    private string BuildTypeKey(Type type)
    {
        var resolved = _engine.Resolve(type);
        return resolved switch
        {
            Core.Types.PrimitiveType pt => pt.Name,
            NominalType nt => nt.TypeArguments.Count > 0
                ? $"{nt.Name}|{string.Join("|", nt.TypeArguments.Select(a => BuildTypeKey(a)))}"
                : nt.Name,
            Core.Types.ReferenceType rt => $"&{BuildTypeKey(rt.InnerType)}",
            Core.Types.ArrayType at => $"[{BuildTypeKey(at.ElementType)};{at.Length}]",
            FunctionType ft =>
                $"fn({string.Join(",", ft.ParameterTypes.Select(BuildTypeKey))}){BuildTypeKey(ft.ReturnType)}",
            _ => resolved.ToString() ?? "unknown"
        };
    }

    // =========================================================================
    // Post-lowering validation
    // =========================================================================

    /// <summary>
    /// Mark functions as unsupported if they call targets that don't exist in the module.
    /// This catches calls to generic functions that weren't specialized/lowered.
    /// </summary>
    private void ValidateCallTargets()
    {
        var knownFunctions = new HashSet<string>();
        foreach (var fn in _module.Functions)
        {
            var paramList = fn.UsesReturnSlot ? fn.Params.Skip(1) : fn.Params;
            knownFunctions.Add(MangleFunctionName(fn.Name, paramList.Select(p => p.Type).ToArray()));
        }
        foreach (var decl in _module.ForeignDecls)
            knownFunctions.Add(decl.CName);
        // C stdlib functions are always available
        knownFunctions.UnionWith([
            "printf", "fprintf", "sprintf", "snprintf", "puts", "putchar",
            "malloc", "calloc", "realloc", "free",
            "memcpy", "memset", "memmove", "memcmp",
            "strlen", "strcmp", "strncmp", "strcpy", "strncpy",
            "abort", "exit", "atexit"
        ]);

        foreach (var fn in _module.Functions)
        {
            foreach (var block in fn.BasicBlocks)
            {
                foreach (var inst in block.Instructions)
                {
                    if (inst is CallInstruction call && !call.IsForeignCall && !call.IsIndirectCall)
                    {
                        var irParamTypes = call.CalleeIrParamTypes
                            ?? call.Arguments.Select(a => a.IrType ?? TypeLayoutService.IrI32).ToArray();
                        var calleeName = MangleFunctionName(call.FunctionName, (IReadOnlyList<IrType>)irParamTypes);
                        if (!knownFunctions.Contains(calleeName))
                        {
                            _diagnostics.Add(Diagnostic.Error(
                                $"Unknown call target `{calleeName}` in function `{fn.Name}`",
                                default, null, "E3002"));
                        }
                    }
                }
            }
        }
    }

    // =========================================================================
    // Type collection — gather struct/enum types from function signatures
    // =========================================================================

    private void CollectReferencedTypes()
    {
        var collected = new HashSet<string>();

        foreach (var fn in _module.Functions)
        {
            CollectIrType(fn.ReturnType, collected);
            foreach (var p in fn.Params)
                CollectIrType(p.Type, collected);

            // Walk function body to collect types used in local values
            foreach (var bb in fn.BasicBlocks)
                foreach (var inst in bb.Instructions)
                {
                    Value? result = inst switch
                    {
                        AllocaInstruction a => a.Result,
                        CallInstruction c => c.Result,
                        CastInstruction c => c.Result,
                        BinaryInstruction b => b.Result,
                        UnaryInstruction u => u.Result,
                        LoadInstruction l => l.Result,
                        GetElementPtrInstruction g => g.Result,
                        AddressOfInstruction a => a.Result,
                        _ => null
                    };
                    if (result?.IrType != null)
                        CollectIrType(result.IrType, collected);
                }
        }

        foreach (var decl in _module.ForeignDecls)
        {
            CollectIrType(decl.ReturnType, collected);
            foreach (var pt in decl.ParamTypes)
                CollectIrType(pt, collected);
        }

        // Walk global values to collect their struct types
        foreach (var gv in _module.GlobalValues)
        {
            if (gv.IrType != null)
                CollectIrType(gv.IrType, collected);
        }
    }

    private void CollectIrType(IrType type, HashSet<string> collected)
    {
        switch (type)
        {
            case IrStruct s:
                // Resolve through the layout cache to get the canonical struct.
                // During recursive lowering, pointer pointees may hold stale stubs
                // with empty fields — the cache always has the final version.
                var resolved = _layout.ResolveStruct(s);
                if (collected.Add(resolved.CName))
                {
                    // Collect field types first (dependencies)
                    foreach (var f in resolved.Fields)
                        CollectIrType(f.Type, collected);
                    _module.TypeDefs.Add(resolved);
                }
                break;
            case IrEnum e:
                if (collected.Add(e.CName))
                {
                    foreach (var v in e.Variants)
                        if (v.PayloadType != null)
                            CollectIrType(v.PayloadType, collected);
                    _module.TypeDefs.Add(e);
                }
                break;
            case IrPointer p:
                CollectIrType(p.Pointee, collected);
                break;
            case IrArray a:
                CollectIrType(a.Element, collected);
                break;
            case IrFunctionPtr fp:
                CollectIrType(fp.Return, collected);
                foreach (var pt in fp.Params)
                    CollectIrType(pt, collected);
                break;
        }
    }

    // =========================================================================
    // Foreign declaration lowering
    // =========================================================================

    private IrForeignDecl LowerForeignDecl(FunctionDeclarationNode fn)
    {
        var fnType = GetFunctionHmType(fn);
        var retIr = _layout.Lower(fnType.ReturnType);
        var paramIrs = new IrType[fnType.ParameterTypes.Count];
        for (int i = 0; i < fnType.ParameterTypes.Count; i++)
            paramIrs[i] = _layout.Lower(fnType.ParameterTypes[i]);

        return new IrForeignDecl(fn.Name, fn.Name, retIr, paramIrs);
    }

    // =========================================================================
    // Function lowering
    // =========================================================================

    private IrFunction LowerFunction(FunctionDeclarationNode fn)
    {
        // Reset per-function state
        _locals.Clear();
        _parameters.Clear();
        _byRefParams.Clear();
        _shadowCounter.Clear();
        _loopStack.Clear();
        _deferStack.Clear();
        _tempCounter = 0;
        _blockCounter = 0;

        var fnType = GetFunctionHmType(fn);
        var retIrType = _layout.Lower(fnType.ReturnType);

        var irFn = new IrFunction(fn.Name, retIrType);
        _currentFunction = irFn;

        if (fn.Name == "main")
            irFn.IsEntryPoint = true;

        // Create entry block
        _currentBlock = CreateBlock("entry");
        irFn.BasicBlocks.Add(_currentBlock);

        // Lower parameters
        if (fnType != null)
        {
            for (int i = 0; i < fn.Parameters.Count; i++)
            {
                var param = fn.Parameters[i];
                var paramIrType = _layout.Lower(fnType.ParameterTypes[i]);
                var irParam = new IrParam(param.Name, paramIrType);

                if (IsLargeValue(paramIrType))
                {
                    irParam = irParam with { IsByRef = true };
                    var paramVal = new LocalValue(param.Name, new IrPointer(paramIrType));
                    _locals[param.Name] = paramVal;
                    _parameters.Add(param.Name);
                    _byRefParams.Add(param.Name);
                }
                else
                {
                    var paramVal = new LocalValue(param.Name, paramIrType);
                    _locals[param.Name] = paramVal;
                    _parameters.Add(param.Name);
                }

                irFn.Params.Add(irParam);
            }
        }

        // Large struct return: use hidden __ret pointer parameter
        if (IsLargeValue(retIrType) && fn.Name != "main")
        {
            irFn.UsesReturnSlot = true;
            var retPtrType = new IrPointer(retIrType);
            irFn.Params.Insert(0, new IrParam("__ret", retPtrType));
            var retLocal = new LocalValue("__ret", retPtrType);
            _locals["__ret"] = retLocal;
            _parameters.Add("__ret");
        }

        // Pre-create allocas for parameters that are assigned to in the body.
        // This ensures ALL reads (including those textually before the assignment,
        // e.g. in a loop condition) go through the alloca, not the original param.
        PromoteMutatedParameters(fn.Body);

        // Lower body statements — the last expression-statement in a non-void
        // function is an implicit return value.
        var isNonVoid = retIrType != TypeLayoutService.IrVoidPrim
                     && retIrType != TypeLayoutService.IrNeverPrim;
        for (int si = 0; si < fn.Body.Count; si++)
        {
            var stmt = fn.Body[si];
            if (si == fn.Body.Count - 1 && isNonVoid && stmt is ExpressionStatementNode lastExpr)
            {
                var val = LowerExpression(lastExpr.Expression, retIrType);
                if (irFn.UsesReturnSlot)
                {
                    _currentBlock.Instructions.Add(new StorePointerInstruction(stmt.Span, _locals["__ret"], val));
                    _currentBlock.Instructions.Add(new ReturnInstruction(stmt.Span, new IntConstantValue(0, TypeLayoutService.IrVoidPrim)));
                }
                else
                {
                    _currentBlock.Instructions.Add(new ReturnInstruction(stmt.Span, val));
                }
                continue;
            }
            LowerStatement(stmt);
        }

        // Emit deferred expressions at function epilogue (before implicit return),
        // but only if the current block isn't already terminated by a return/jump.
        if (_currentBlock.Instructions.Count == 0 ||
            _currentBlock.Instructions[^1] is not (ReturnInstruction or JumpInstruction or BranchInstruction))
        {
            EmitDeferredExpressions();
        }

        // Add implicit return to any unterminated block
        foreach (var block in irFn.BasicBlocks)
        {
            if (block.Instructions.Count == 0 ||
                block.Instructions[^1] is not (ReturnInstruction or JumpInstruction or BranchInstruction))
            {
                var retType = irFn.UsesReturnSlot ? TypeLayoutService.IrVoidPrim
                    : (isNonVoid ? retIrType : TypeLayoutService.IrVoidPrim);
                var retVal = new IntConstantValue(0, retType);
                block.Instructions.Add(new ReturnInstruction(_currentSpan, retVal));
            }
        }

        return irFn;
    }

    // =========================================================================
    // Statement lowering
    // =========================================================================

    private void LowerStatement(StatementNode stmt)
    {
        _currentSpan = stmt.Span;
        switch (stmt)
        {
            case ReturnStatementNode ret:
                LowerReturn(ret);
                break;
            case ExpressionStatementNode exprStmt:
                LowerExpression(exprStmt.Expression);
                break;
            case VariableDeclarationNode varDecl:
                LowerVariableDeclaration(varDecl);
                break;
            case LoopNode loop:
                LowerLoop(loop);
                break;
            case BreakStatementNode brk:
                LowerBreak(brk);
                break;
            case ContinueStatementNode cont:
                LowerContinue(cont);
                break;
            case ForLoopNode forLoop:
                LowerForLoop(forLoop);
                break;
            case DeferStatementNode defer:
                LowerDefer(defer);
                break;
        }
    }

    private void LowerReturn(ReturnStatementNode ret)
    {
        // Emit deferred expressions before returning
        EmitDeferredExpressions();

        if (ret.Expression != null)
        {
            var fnRetType = _currentFunction.ReturnType;
            var val = LowerExpression(ret.Expression, fnRetType);
            if (_currentFunction.UsesReturnSlot)
            {
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, _locals["__ret"], val));
                _currentBlock.Instructions.Add(new ReturnInstruction(_currentSpan, new IntConstantValue(0, TypeLayoutService.IrVoidPrim)));
            }
            else
            {
                _currentBlock.Instructions.Add(new ReturnInstruction(_currentSpan, val));
            }
        }
        else
        {
            var voidVal = new IntConstantValue(0, TypeLayoutService.IrVoidPrim);
            _currentBlock.Instructions.Add(new ReturnInstruction(_currentSpan, voidVal));
        }
    }

    /// <summary>
    /// If the target type is an Option-like struct (has_value + value fields) and the
    /// source value's type matches the value field, wrap it in Some(val).
    /// </summary>
    /// <summary>
    /// Apply implicit coercions when the lowered value doesn't match the expected type.
    /// Mirrors the coercion rules in the type checker (CoercionRules.cs).
    /// </summary>
    private Value ApplyCoercions(Value val, IrType expectedType)
    {
        var actualType = val.IrType;
        if (actualType == null || actualType == expectedType) return val;
        // Same C name means same concrete type
        if (actualType is IrStruct aS && expectedType is IrStruct eS && aS.CName == eS.CName) return val;

        // 1. Array -> Slice: [T; N] -> Slice[T] (also handles pointer-to-array from LowerArrayLiteral)
        IrArray? coerceArrType = actualType as IrArray;
        if (coerceArrType == null && actualType is IrPointer { Pointee: IrArray innerArr })
            coerceArrType = innerArr;
        if (coerceArrType != null && expectedType is IrStruct sliceStruct)
        {
            var ptrField = sliceStruct.Fields.FirstOrDefault(f => f.Name == "ptr");
            var lenField = sliceStruct.Fields.FirstOrDefault(f => f.Name == "len");
            if (ptrField.Type != null && lenField.Type != null)
                return CoerceArrayToSlice(val, coerceArrType, sliceStruct, ptrField, lenField);
        }

        // 2. Slice[T] -> &T: extract .ptr field
        if (actualType is IrStruct sliceSrc && expectedType is IrPointer ptrTarget)
        {
            var ptrField = sliceSrc.Fields.FirstOrDefault(f => f.Name == "ptr");
            if (ptrField.Type != null)
                return CoerceSliceToPointer(val, sliceSrc, ptrField);
        }

        // 3. String -> Slice[u8]: binary compatible, reinterpret cast
        if (actualType is IrStruct strSrc && expectedType is IrStruct sliceDst
            && strSrc.Name == WellKnown.String && sliceDst.Name == WellKnown.Slice
            && strSrc.Size == sliceDst.Size)
        {
            return ReinterpretCast(val, strSrc, sliceDst);
        }

        // 4. Anonymous struct -> named struct: reinterpret cast (same layout)
        if (actualType is IrStruct anonSrc && expectedType is IrStruct namedDst
            && anonSrc.CName != namedDst.CName && anonSrc.Size == namedDst.Size)
        {
            return ReinterpretCast(val, anonSrc, namedDst);
        }

        // 5a. Niche Option: non-nullable pointer -> nullable pointer (same bits, retype)
        if (expectedType is IrPointer { IsNullable: true } expectedNullable
            && actualType is IrPointer { IsNullable: false })
        {
            val.IrType = expectedNullable;
            return val;
        }

        // 5. T -> Option[T]: wrap in Some
        //    Handles: same-size value, integer widening, pointer->Option[pointer]
        if (expectedType is IrStruct optStruct)
        {
            var hvField = optStruct.Fields.FirstOrDefault(f => f.Name == "has_value");
            var valField = optStruct.Fields.FirstOrDefault(f => f.Name == "value");
            if (hvField.Type != null && valField.Type != null
                && hvField.Type == TypeLayoutService.IrBool)
            {
                // Exact size match — wrap directly
                if (actualType.Size == valField.Type.Size)
                    return CoerceToOption(val, optStruct, hvField, valField);

                // Integer widening then wrap: e.g. i32 -> usize -> Option[usize]
                if (actualType is IrPrimitive && valField.Type is IrPrimitive)
                {
                    var widened = new LocalValue($"widen_{_tempCounter++}", valField.Type);
                    _currentBlock.Instructions.Add(new CastInstruction(_currentSpan, val, widened));
                    return CoerceToOption(widened, optStruct, hvField, valField);
                }

                // Pointer -> Option[pointer]: e.g. &Allocator -> Option[&Allocator]
                if (actualType is IrPointer && valField.Type is IrPointer)
                    return CoerceToOption(val, optStruct, hvField, valField);
            }
        }

        // 6. Primitive widening: e.g. i32 -> usize
        if (actualType is IrPrimitive && expectedType is IrPrimitive && actualType.Size < expectedType.Size)
        {
            var widened = new LocalValue($"widen_{_tempCounter++}", expectedType);
            _currentBlock.Instructions.Add(new CastInstruction(_currentSpan, val, widened));
            return widened;
        }

        return val;
    }

    private Value CoerceArrayToSlice(Value val, IrArray arrType, IrStruct sliceStruct,
        IrField ptrField, IrField lenField)
    {
        var tmpPtr = new LocalValue($"slice_{_tempCounter++}", new IrPointer(sliceStruct));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, sliceStruct.Size, tmpPtr));

        // ptr = (element_type*)array
        var elemPtrType = new IrPointer(arrType.Element);
        var castResult = new LocalValue($"slice_ptr_{_tempCounter++}", elemPtrType);
        _currentBlock.Instructions.Add(new CastInstruction(_currentSpan, val, castResult));

        EmitStoreToOffset(tmpPtr, ptrField.ByteOffset, castResult, ptrField.Type);

        // len = array_length
        EmitStoreToOffset(tmpPtr, lenField.ByteOffset,
            new IntConstantValue(arrType.Length ?? 0, TypeLayoutService.IrUSize), lenField.Type);

        var loaded = new LocalValue($"slice_val_{_tempCounter++}", sliceStruct);
        _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, tmpPtr, loaded));
        return loaded;
    }

    private Value CoerceSliceToPointer(Value val, IrStruct sliceStruct, IrField ptrField)
    {
        // Spill to alloca, GEP to ptr field, load
        var tmpPtr = new LocalValue($"slice_tmp_{_tempCounter++}", new IrPointer(sliceStruct));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, sliceStruct.Size, tmpPtr));
        _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, tmpPtr, val));

        var loaded = EmitLoadFromOffset(tmpPtr, ptrField.ByteOffset, ptrField.Type, "slice_ptr_val");
        return loaded;
    }

    private Value ReinterpretCast(Value val, IrStruct srcType, IrStruct dstType)
    {
        var tmpPtr = new LocalValue($"cast_tmp_{_tempCounter++}", new IrPointer(srcType));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, srcType.Size, tmpPtr));
        _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, tmpPtr, val));
        var casted = new LocalValue($"cast_val_{_tempCounter++}", dstType);
        _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, tmpPtr, casted));
        return casted;
    }

    private Value CoerceToOption(Value val, IrStruct optStruct, IrField hvField, IrField valField)
    {
        var tmpPtr = new LocalValue($"some_{_tempCounter++}", new IrPointer(optStruct));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, optStruct.Size, tmpPtr));

        // has_value = true
        EmitStoreToOffset(tmpPtr, hvField.ByteOffset, new IntConstantValue(1, TypeLayoutService.IrBool), TypeLayoutService.IrBool);

        // value = val
        EmitStoreToOffset(tmpPtr, valField.ByteOffset, val, valField.Type);

        var loaded = new LocalValue($"some_val_{_tempCounter++}", optStruct);
        _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, tmpPtr, loaded));
        return loaded;
    }

    /// <summary>
    /// Wrap a raw pointer from a foreign call into Option[&T].
    /// has_value = (ptr != NULL), value = ptr.
    /// </summary>
    private Value WrapPointerInOption(Value rawPtr, IrStruct optStruct, IrField hvField, IrField valField)
    {
        // has_value = (rawPtr != 0)
        var nullVal = new IntConstantValue(0, rawPtr.IrType!);
        var hvResult = new LocalValue($"ffi_nonnull_{_tempCounter++}", TypeLayoutService.IrBool);
        _currentBlock.Instructions.Add(new BinaryInstruction(_currentSpan, BinaryOp.NotEqual, rawPtr, nullVal, hvResult));

        var tmpPtr = new LocalValue($"ffi_opt_{_tempCounter++}", new IrPointer(optStruct));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, optStruct.Size, tmpPtr));

        // has_value field
        EmitStoreToOffset(tmpPtr, hvField.ByteOffset, hvResult, TypeLayoutService.IrBool);

        // value field = raw pointer
        EmitStoreToOffset(tmpPtr, valField.ByteOffset, rawPtr, valField.Type);

        var loaded = new LocalValue($"ffi_opt_val_{_tempCounter++}", optStruct);
        _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, tmpPtr, loaded));
        return loaded;
    }

    private void LowerVariableDeclaration(VariableDeclarationNode varDecl)
    {
        // Discard pattern: `let _ = expr` — evaluate for side effects, don't store
        if (varDecl.Name == "_")
        {
            if (varDecl.Initializer != null)
                LowerExpression(varDecl.Initializer);
            return;
        }

        var irType = GetIrType(varDecl);
        var uniqueName = GetUniqueVariableName(varDecl.Name);

        // Array variables with initializers: reuse the literal's alloca directly.
        // LowerArrayLiteral already creates storage and stores elements — creating a
        // second alloca and trying to "store" the array pointer into it is wrong.
        var isArray = irType is IrArray;
        if (isArray && varDecl.Initializer != null)
        {
            var initVal = LowerExpression(varDecl.Initializer, irType);
            _locals[varDecl.Name] = new LocalValue(initVal.Name, new IrPointer(irType));
            return;
        }

        // Allocate stack space
        var allocaResult = new LocalValue(uniqueName, new IrPointer(irType));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, irType.Size, allocaResult)
        {
            IsArrayStorage = isArray
        });

        // Store initializer if present, otherwise zero-initialize
        if (varDecl.Initializer != null)
        {
            var initVal = LowerExpression(varDecl.Initializer, irType);
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, allocaResult, initVal));
        }
        else
        {
            // Zero-initialize variables declared without an initializer (e.g. `let sb: StringBuilder`)
            var memsetResult = new LocalValue($"memset_{_tempCounter++}", TypeLayoutService.IrVoidPrim);
            _currentBlock.Instructions.Add(new CallInstruction(_currentSpan, "memset",
                [allocaResult, new IntConstantValue(0, TypeLayoutService.IrI32), new IntConstantValue(irType.Size, TypeLayoutService.IrUSize)],
                memsetResult)
            { IsForeignCall = true });
        }

        _locals[varDecl.Name] = allocaResult;
    }

    private void LowerLoop(LoopNode loop)
    {
        var bodyBlock = CreateBlock("loop_body");
        var exitBlock = CreateBlock("loop_exit");

        // Jump from current block into the loop body
        _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, bodyBlock));
        _currentFunction.BasicBlocks.Add(bodyBlock);
        _currentBlock = bodyBlock;

        // Push loop context for break/continue
        _loopStack.Push((bodyBlock, exitBlock));

        // Lower loop body — the body is an ExpressionNode (typically a BlockExpression)
        LowerExpression(loop.Body);

        // Pop loop context
        _loopStack.Pop();

        // Back-edge: jump back to loop body (if not already terminated)
        if (_currentBlock.Instructions.Count == 0 ||
            _currentBlock.Instructions[^1] is not (ReturnInstruction or JumpInstruction or BranchInstruction))
        {
            _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, bodyBlock));
        }

        // Continue after the loop
        _currentFunction.BasicBlocks.Add(exitBlock);
        _currentBlock = exitBlock;
    }

    private void LowerBreak(BreakStatementNode _)
    {
        if (_loopStack.Count == 0)
        {
            _diagnostics.Add(Diagnostic.Error("break outside of loop", _.Span, "break can only be used inside for/while loops", "E3006"));
            return;
        }

        var (_, exitBlock) = _loopStack.Peek();
        _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, exitBlock));

        // Start a dead block — subsequent code is unreachable but we need a valid block
        var deadBlock = CreateBlock("dead");
        _currentFunction.BasicBlocks.Add(deadBlock);
        _currentBlock = deadBlock;
    }

    private void LowerContinue(ContinueStatementNode _)
    {
        if (_loopStack.Count == 0)
        {
            _diagnostics.Add(Diagnostic.Error("continue outside of loop", _.Span, "continue can only be used inside for/while loops", "E3007"));
            return;
        }

        var (bodyBlock, _2) = _loopStack.Peek();
        _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, bodyBlock));

        // Start a dead block
        var deadBlock = CreateBlock("dead");
        _currentFunction.BasicBlocks.Add(deadBlock);
        _currentBlock = deadBlock;
    }

    private void LowerForLoop(ForLoopNode forLoop)
    {
        // If iter/next functions are not resolved, fall back to direct array iteration
        if (forLoop.ResolvedIterFunction == null || forLoop.ResolvedNextFunction == null)
        {
            LowerForLoopDirect(forLoop);
            return;
        }

        // Get element type (recorded by type checker)
        var elementIrType = GetIrType(forLoop);

        // Get iterator type from iter function return type
        var iterFnType = GetFunctionHmType(forLoop.ResolvedIterFunction);
        var iteratorIrType = _layout.Lower(iterFnType.ReturnType);

        // Get Option type from next function return type
        var nextFnType = GetFunctionHmType(forLoop.ResolvedNextFunction);
        var optionIrType = _layout.Lower(nextFnType.ReturnType);

        // Create loop blocks
        var condBlock = CreateBlock("for_cond");
        var bodyBlock = CreateBlock("for_body");
        var exitBlock = CreateBlock("for_exit");

        // 1. Lower iterable expression
        var iterableVal = LowerExpression(forLoop.IterableExpression);

        // Materialize iterable to alloca if not already a pointer (iter takes &T)
        if (iterableVal.IrType is not IrPointer)
        {
            var iterableIrType = iterableVal.IrType ?? TypeLayoutService.IrVoidPrim;
            var temp = new LocalValue($"iterable_tmp_{_tempCounter++}", new IrPointer(iterableIrType));
            _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, iterableIrType.Size, temp));
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, temp, iterableVal));
            iterableVal = temp;
        }

        // 2. Call iter(&iterable) -> IteratorStruct
        var iterCalleeParamTypes = new List<IrType>();
        foreach (var p in forLoop.ResolvedIterFunction.Parameters)
            iterCalleeParamTypes.Add(GetIrType(p));
        var iterResult = EmitFLangCall("iter", [iterableVal], iteratorIrType, iterCalleeParamTypes);

        // 3. Allocate iterator state on stack
        var iteratorPtr = new LocalValue($"iter_ptr_{_tempCounter++}", new IrPointer(iteratorIrType));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, iteratorIrType.Size, iteratorPtr));
        _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, iteratorPtr, iterResult));

        // 4. Allocate loop variable on stack
        var loopVarName = GetUniqueVariableName(forLoop.IteratorVariable);
        var loopVarPtr = new LocalValue(loopVarName, new IrPointer(elementIrType));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, elementIrType.Size, loopVarPtr));
        _locals[forLoop.IteratorVariable] = loopVarPtr;

        // Jump to condition block
        _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, condBlock));

        // 5. Condition block: call next(&iterator), check has_value
        _currentFunction.BasicBlocks.Add(condBlock);
        _currentBlock = condBlock;

        var nextCalleeParamTypes = new List<IrType>();
        foreach (var p in forLoop.ResolvedNextFunction.Parameters)
            nextCalleeParamTypes.Add(GetIrType(p));
        var nextResult = EmitFLangCall("next", [iteratorPtr], optionIrType, nextCalleeParamTypes);

        if (IsNicheOption(optionIrType))
        {
            // Niche-optimized: nextResult is a nullable pointer; NULL = None
            var nichePtr = (IrPointer)optionIrType;
            var nullVal = new IntConstantValue(0, nichePtr);
            var isNonNull = new LocalValue($"for_niche_{_tempCounter++}", TypeLayoutService.IrBool);
            _currentBlock.Instructions.Add(new BinaryInstruction(_currentSpan, BinaryOp.NotEqual, nextResult, nullVal, isNonNull));
            _currentBlock.Instructions.Add(new BranchInstruction(_currentSpan, isNonNull, bodyBlock, exitBlock));

            // Body: cast to non-nullable, store to loop var
            _currentFunction.BasicBlocks.Add(bodyBlock);
            _currentBlock = bodyBlock;
            _loopStack.Push((condBlock, exitBlock));

            var stripped = StripNullable(nichePtr);
            var castVal = new LocalValue($"for_strip_{_tempCounter++}", stripped);
            _currentBlock.Instructions.Add(new CastInstruction(_currentSpan, nextResult, castVal));
            // If element type differs from stripped pointer (e.g. loop var is the inner pointee), load
            if (elementIrType is IrPointer)
            {
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, loopVarPtr, castVal));
            }
            else
            {
                var loaded = new LocalValue($"for_deref_{_tempCounter++}", elementIrType);
                _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, castVal, loaded));
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, loopVarPtr, loaded));
            }
        }
        else
        {
            // Materialize next result to alloca so we can GEP into it
            var nextPtr = new LocalValue($"next_ptr_{_tempCounter++}", new IrPointer(optionIrType));
            _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, optionIrType.Size, nextPtr));
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, nextPtr, nextResult));

            // Load has_value field
            var optionStruct = (IrStruct)optionIrType;
            var hvField = FindField(optionStruct, "has_value");

            var hvVal = EmitLoadFromOffset(nextPtr, hvField.ByteOffset, TypeLayoutService.IrBool, "for_hv");

            // Branch: has_value -> body, else -> exit
            _currentBlock.Instructions.Add(new BranchInstruction(_currentSpan, hvVal, bodyBlock, exitBlock));

            // 6. Body block: extract value, store to loop var, lower body, jump back to cond
            _currentFunction.BasicBlocks.Add(bodyBlock);
            _currentBlock = bodyBlock;
            _loopStack.Push((condBlock, exitBlock));

            // Extract value field from Option
            var valField = FindField(optionStruct, "value");
            var valLoaded = EmitLoadFromOffset(nextPtr, valField.ByteOffset, elementIrType, "for_val");
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, loopVarPtr, valLoaded));
        }

        // Lower loop body
        LowerExpression(forLoop.Body);

        _loopStack.Pop();

        // Back-edge to condition
        if (_currentBlock.Instructions.Count == 0 ||
            _currentBlock.Instructions[^1] is not (ReturnInstruction or JumpInstruction or BranchInstruction))
        {
            _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, condBlock));
        }

        // 7. Exit block
        _currentFunction.BasicBlocks.Add(exitBlock);
        _currentBlock = exitBlock;
    }

    /// <summary>
    /// Direct index-based iteration for arrays/slices when no iter/next functions are resolved.
    /// Pattern: index = 0; while (index < length) { elem = arr[index]; body; index++; }
    /// </summary>
    private void LowerForLoopDirect(ForLoopNode forLoop)
    {
        var elementIrType = GetIrType(forLoop);

        // Lower iterable
        var iterableVal = LowerExpression(forLoop.IterableExpression);

        // Determine array length and get a pointer to the array data
        var usizeType = TypeLayoutService.IrUSize;
        Value arrayPtr;
        Value lengthVal;

        var baseIrType = iterableVal.IrType;
        // If it's a pointer to an array, load through it
        if (baseIrType is IrPointer ptrType && ptrType.Pointee is IrArray)
            baseIrType = ptrType.Pointee;

        if (baseIrType is IrArray irArray && irArray.Length.HasValue)
        {
            // Fixed-size array — length is compile-time known
            lengthVal = new IntConstantValue(irArray.Length.Value, usizeType);

            // Get pointer to array start
            if (iterableVal.IrType is IrPointer)
                arrayPtr = iterableVal; // already a pointer
            else
            {
                // Materialize to stack
                var temp = new LocalValue($"arr_tmp_{_tempCounter++}", new IrPointer(baseIrType));
                _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, baseIrType.Size, temp));
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, temp, iterableVal));
                arrayPtr = temp;
            }
        }
        else
        {
            throw new InternalCompilerError(
                $"Unsupported direct iteration over {baseIrType}", forLoop.Span);
        }

        // Allocate index counter (usize, init to 0)
        var indexPtr = new LocalValue($"for_idx_{_tempCounter++}", new IrPointer(usizeType));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, usizeType.Size, indexPtr));
        _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, indexPtr,
            new IntConstantValue(0, usizeType)));

        // Allocate loop variable
        var loopVarName = GetUniqueVariableName(forLoop.IteratorVariable);
        var loopVarPtr = new LocalValue(loopVarName, new IrPointer(elementIrType));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, elementIrType.Size, loopVarPtr));
        _locals[forLoop.IteratorVariable] = loopVarPtr;

        // Create blocks
        var condBlock = CreateBlock("for_cond");
        var bodyBlock = CreateBlock("for_body");
        var exitBlock = CreateBlock("for_exit");

        _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, condBlock));

        // Condition block: load index, compare < length
        _currentFunction.BasicBlocks.Add(condBlock);
        _currentBlock = condBlock;

        var indexVal = new LocalValue($"for_i_{_tempCounter++}", usizeType);
        _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, indexPtr, indexVal));

        var cmpResult = new LocalValue($"for_cmp_{_tempCounter++}", TypeLayoutService.IrBool);
        _currentBlock.Instructions.Add(
            new BinaryInstruction(_currentSpan, BinaryOp.LessThan, indexVal, lengthVal, cmpResult));

        _currentBlock.Instructions.Add(new BranchInstruction(_currentSpan, cmpResult, bodyBlock, exitBlock));

        // Body block: GEP to array[index], load element, store to loop var
        _currentFunction.BasicBlocks.Add(bodyBlock);
        _currentBlock = bodyBlock;

        _loopStack.Push((condBlock, exitBlock));

        // Compute byte offset: index * element_size
        var elemSize = new IntConstantValue(elementIrType.Size, usizeType);
        var byteOffset = new LocalValue($"for_off_{_tempCounter++}", usizeType);
        _currentBlock.Instructions.Add(
            new BinaryInstruction(_currentSpan, BinaryOp.Multiply, indexVal, elemSize, byteOffset));

        // Load element at dynamic offset
        var elemVal = EmitLoadFromOffset(arrayPtr, byteOffset, elementIrType, "for_elem");
        _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, loopVarPtr, elemVal));

        // Lower loop body
        LowerExpression(forLoop.Body);

        _loopStack.Pop();

        // Increment index: index = index + 1
        var one = new IntConstantValue(1, usizeType);
        var indexVal2 = new LocalValue($"for_i2_{_tempCounter++}", usizeType);
        _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, indexPtr, indexVal2));
        var nextIndex = new LocalValue($"for_inc_{_tempCounter++}", usizeType);
        _currentBlock.Instructions.Add(
            new BinaryInstruction(_currentSpan, BinaryOp.Add, indexVal2, one, nextIndex));
        _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, indexPtr, nextIndex));

        // Back-edge to condition
        if (_currentBlock.Instructions.Count == 0 ||
            _currentBlock.Instructions[^1] is not (ReturnInstruction or JumpInstruction or BranchInstruction))
        {
            _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, condBlock));
        }

        // Exit block
        _currentFunction.BasicBlocks.Add(exitBlock);
        _currentBlock = exitBlock;
    }

    private void LowerDefer(DeferStatementNode defer)
    {
        // Push the expression onto the defer stack; it will be emitted before returns
        _deferStack.Push(defer.Expression);
    }

    /// <summary>
    /// Emit all deferred expressions in LIFO order. Does not clear the stack
    /// (so multiple returns each emit all defers).
    /// </summary>
    private void EmitDeferredExpressions()
    {
        if (_deferStack.Count == 0) return;
        // Emit in LIFO order (stack iteration is LIFO)
        foreach (var expr in _deferStack)
        {
            LowerExpression(expr);
        }
    }

    // =========================================================================
    // Expression lowering
    // =========================================================================

    private Value LowerExpression(ExpressionNode expr, IrType? expectedType = null)
    {
        _currentSpan = expr.Span;
        var result = expr switch
        {
            IntegerLiteralNode intLit => LowerIntegerLiteral(intLit),
            FloatingPointLiteralNode floatLit => LowerFloatingPointLiteral(floatLit),
            BooleanLiteralNode boolLit => LowerBooleanLiteral(boolLit),
            StringLiteralNode strLit => LowerStringLiteral(strLit),
            NullLiteralNode nullLit => LowerNullLiteral(nullLit),
            IdentifierExpressionNode id => LowerIdentifier(id),
            CallExpressionNode call when call.IsTypeInstantiation => LowerTypeInstantiation(call),
            CallExpressionNode call when IsVariantConstruction(call) => LowerEnumConstruction(call),
            CallExpressionNode call => LowerCall(call),
            BinaryExpressionNode binary when binary.Operator is BinaryOperatorKind.And or BinaryOperatorKind.Or
                => LowerShortCircuitLogical(binary),
            BinaryExpressionNode binary => LowerBinary(binary),
            UnaryExpressionNode unary => LowerUnary(unary),
            MemberAccessExpressionNode member => LowerMemberAccess(member),
            CastExpressionNode cast => LowerCast(cast),
            BlockExpressionNode block => LowerBlock(block),
            IfExpressionNode ifExpr => LowerIf(ifExpr),
            MatchExpressionNode match => LowerMatch(match),
            AddressOfExpressionNode addrOf => LowerAddressOf(addrOf),
            DereferenceExpressionNode deref => LowerDereference(deref),
            AssignmentExpressionNode assign => LowerAssignment(assign),
            StructConstructionExpressionNode structCtor => LowerStructConstruction(structCtor),
            AnonymousStructExpressionNode anonStruct => LowerAnonymousStruct(anonStruct, expectedType),
            ArrayLiteralExpressionNode arrLit => LowerArrayLiteral(arrLit),
            IndexExpressionNode index => LowerIndex(index),
            RangeExpressionNode range => LowerRange(range),
            ImplicitCoercionNode coercion => LowerImplicitCoercion(coercion),
            CoalesceExpressionNode coalesce => LowerCoalesce(coalesce),
            NullPropagationExpressionNode nullProp => LowerNullPropagation(nullProp),
            LambdaExpressionNode lambda => LowerLambda(lambda),
            NamedArgumentExpressionNode na => LowerExpression(na.Value, expectedType),
            _ => throw new InternalCompilerError($"Lowering of expression type {expr.GetType()} is not implemented.", expr.Span)
        };

        if (expectedType != null)
            result = ApplyCoercions(result, expectedType);

        return result;
    }

    private Value LowerIntegerLiteral(IntegerLiteralNode intLit)
    {
        var irType = GetIrType(intLit);
        // The HM type checker may unify the literal with a non-primitive type
        // (e.g., Option[usize] for `return 0` in a usize? function).
        // Always produce a primitive-typed constant; ApplyCoercions handles wrapping.
        if (irType is not IrPrimitive)
            irType = TypeLayoutService.IrI32;

        // Integer literal unified with a float type (e.g., 1 assigned to f32 field)
        if (irType is IrPrimitive { Name: "f32" or "f64" })
            return new FloatConstantValue((double)intLit.Value, irType);

        return new IntConstantValue(intLit.Value, irType);
    }

    private Value LowerFloatingPointLiteral(FloatingPointLiteralNode floatLit)
    {
        var irType = GetIrType(floatLit);
        if (irType is not IrPrimitive)
            irType = TypeLayoutService.IrF64;
        return new FloatConstantValue(floatLit.Value, irType);
    }

    private Value LowerBooleanLiteral(BooleanLiteralNode boolLit)
    {
        return new IntConstantValue(boolLit.Value ? 1 : 0, TypeLayoutService.IrBool);
    }

    private Value LowerStringLiteral(StringLiteralNode strLit)
    {
        var stringNominal = _checker.LookupNominalType(WellKnown.String)
            ?? throw new InternalCompilerError($"Well-known type `{WellKnown.String}` not registered", strLit.Span);
        var stringIrType = _layout.Lower(stringNominal);

        // Deduplicate: reuse existing entry for the same string value
        if (_stringTableIndices.TryGetValue(strLit.Value, out var existingIndex))
            return new StringTableValue(existingIndex, stringIrType);

        // Encode string to UTF-8 with null terminator
        var bytes = Encoding.UTF8.GetBytes(strLit.Value);
        var nullTerminated = new byte[bytes.Length + 1];
        Array.Copy(bytes, nullTerminated, bytes.Length);

        var index = _module.StringTable.Count;
        _module.StringTable.Add(new StringTableEntry(strLit.Value, nullTerminated));
        _stringTableIndices[strLit.Value] = index;

        return new StringTableValue(index, stringIrType);
    }

    private Value LowerNullLiteral(NullLiteralNode nullLit)
    {
        // Null is an Option with has_value = false
        var irType = GetIrType(nullLit);

        // Niche-optimized Option[&T]: null = 0 (NULL pointer)
        if (IsNicheOption(irType))
            return new IntConstantValue(0, irType);

        if (irType is IrStruct optionStruct && optionStruct.Fields.Length > 0)
        {
            // Alloca the option struct, store has_value = false (0)
            var allocaResult = new LocalValue($"null_{_tempCounter++}", new IrPointer(irType));
            _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, irType.Size, allocaResult));

            // Find has_value field and store 0
            foreach (var f in optionStruct.Fields)
            {
                if (f.Name == "has_value")
                {
                    EmitStoreToOffset(allocaResult, f.ByteOffset,
                        new IntConstantValue(0, TypeLayoutService.IrBool), TypeLayoutService.IrBool);
                    break;
                }
            }

            // Load and return the struct
            var loaded = new LocalValue($"null_val_{_tempCounter++}", irType);
            _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, allocaResult, loaded));
            return loaded;
        }

        return new IntConstantValue(0, irType);
    }

    /// <summary>
    /// Lower a generic type instantiation in expression context (e.g., Foo(i32) used as type-as-value).
    /// Emits a reference to the RTTI type info global, same as bare type identifiers like i32 or Point.
    /// </summary>
    private Value LowerTypeInstantiation(CallExpressionNode call)
    {
        var resolvedType = _engine.Resolve(_checker.GetInferredType(call));
        if (resolvedType is NominalType { Name: "core.rtti.Type" } typeNom
            && typeNom.TypeArguments.Count > 0)
        {
            EnsureTypeTableExists();
            var key = BuildTypeKey(typeNom.TypeArguments[0]);
            if (_typeTableGlobals != null && _typeTableGlobals.TryGetValue(key, out var typeInfoGlobal))
            {
                var typeIrType = _layout.Lower(resolvedType);
                var loaded = new LocalValue($"type_load_{_tempCounter++}", typeIrType);
                _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, typeInfoGlobal, loaded));
                return loaded;
            }
        }
        // Fallback: should not happen for correctly typed code
        return new IntConstantValue(0, _layout.Lower(resolvedType));
    }

    private Value LowerIdentifier(IdentifierExpressionNode id)
    {
        if (_locals.TryGetValue(id.Name, out var localVal))
        {
            if (_parameters.Contains(id.Name))
            {
                if (_byRefParams.Contains(id.Name))
                {
                    // By-ref param: load the value through the pointer
                    var innerType = ((IrPointer)localVal.IrType).Pointee;
                    var byRefLoaded = new LocalValue($"t{_tempCounter++}", innerType);
                    _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, localVal, byRefLoaded));
                    return byRefLoaded;
                }
                // Parameters are used directly
                return localVal;
            }

            // Local variables are stored via alloca — need to load
            var irType = GetIrType(id);

            // Array locals use IsArrayStorage — the alloca pointer IS the array base,
            // no load needed (same pattern as LowerArrayLiteral).
            if (irType is IrArray)
                return new LocalValue(localVal.Name, irType);

            var loaded = new LocalValue($"t{_tempCounter++}", irType);
            _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, localVal, loaded));
            return loaded;
        }

        var inferredType = _checker.GetInferredType(id);

        // Check for function reference
        if (inferredType is FunctionType)
            return new FunctionReferenceValue(id.Name, GetIrType(id));

        // Check for global constant
        if (_globalConstants.TryGetValue(id.Name, out var globalVal))
            return globalVal;

        // Check for type-as-value (e.g., u8 in size_of(u8)) — Type(T) with RTTI
        var resolvedType = _engine.Resolve(inferredType);
        if (resolvedType is NominalType { Name: "core.rtti.Type" } typeNom
            && typeNom.TypeArguments.Count > 0)
        {
            EnsureTypeTableExists();
            var key = BuildTypeKey(typeNom.TypeArguments[0]);
            if (_typeTableGlobals != null && _typeTableGlobals.TryGetValue(key, out var typeInfoGlobal))
            {
                var typeIrType = GetIrType(id);
                var loaded = new LocalValue($"type_load_{_tempCounter++}", typeIrType);
                _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, typeInfoGlobal, loaded));
                return loaded;
            }
        }

        // Check for bare enum variant (payload-less variant constructor used as identifier)
        var idIrType = _layout.Lower(inferredType);
        if (idIrType is IrEnum irEnum)
        {
            return LowerBareVariant(id.Name, irEnum);
        }

        _diagnostics.Add(Diagnostic.Error(
            $"Unresolved identifier `{id.Name}`", id.Span, null, "E3002"));
        return new IntConstantValue(0, TypeLayoutService.IrVoidPrim);
    }

    /// <summary>
    /// Lower a bare (payload-less) enum variant name to an enum value.
    /// </summary>
    private Value LowerBareVariant(string variantName, IrEnum irEnum)
    {
        IrVariant? foundVariant = null;
        foreach (var v in irEnum.Variants)
        {
            if (v.Name == variantName)
            {
                foundVariant = v;
                break;
            }
        }

        if (foundVariant == null)
        {
            var suggestion = StringDistance.FindClosestMatch(variantName, irEnum.Variants.Select(v => v.Name));
            var hint = suggestion != null ? $"did you mean `{suggestion}`?" : null;
            _diagnostics.Add(Diagnostic.Error(
                $"Variant `{variantName}` not found in enum `{irEnum.Name}`",
                default, hint, "E3037"));
            return new IntConstantValue(0, irEnum);
        }

        var variant = foundVariant.Value;

        // Alloca + store tag + load
        var enumPtr = new LocalValue($"enum_{_tempCounter++}", new IrPointer(irEnum));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, irEnum.Size, enumPtr));

        EmitStoreToOffset(enumPtr, 0, new IntConstantValue(variant.TagValue, TypeLayoutService.IrI32), TypeLayoutService.IrI32);

        var enumResult = new LocalValue($"enum_val_{_tempCounter++}", irEnum);
        _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, enumPtr, enumResult));
        return enumResult;
    }

    private Value LowerCall(CallExpressionNode call)
    {
        var retIrType = GetIrType(call);

        // Handle field-access-then-call (vtable pattern): obj.field(args)
        // where field is a function pointer within a struct
        if (call.IsIndirectCall && call.UfcsReceiver != null && call.MethodName != null)
        {
            return LowerIndirectFieldCall(call, retIrType);
        }

        // Handle indirect call through a local variable holding a function pointer
        if (call.IsIndirectCall && call.UfcsReceiver == null)
        {
            return LowerIndirectVarCall(call, retIrType);
        }

        // Use ResolvedArguments (from named/default/variadic resolution) when available
        var callArguments = call.ResolvedArguments ?? call.Arguments;

        // Lower arguments
        var args = new List<Value>();

        // UFCS: prepend receiver as first arg
        if (call.UfcsReceiver != null)
        {
            // Check if callee's first param expects a pointer (i.e. &self)
            // or if it's a non-foreign function with a large value param (implicit by-ref)
            var firstParamWantsPtr = false;
            IrType? firstParamIrType = null;
            if (call.ResolvedTarget != null && call.ResolvedTarget.Parameters.Count > 0)
            {
                firstParamIrType = GetIrType(call.ResolvedTarget.Parameters[0]);
                firstParamWantsPtr = firstParamIrType is IrPointer;
            }
            var isForeignCheck = call.ResolvedTarget != null &&
                                 (call.ResolvedTarget.Modifiers & FunctionModifiers.Foreign) != 0;
            var needsByRef = firstParamWantsPtr ||
                             (!isForeignCheck && firstParamIrType != null && IsLargeValue(firstParamIrType));

            // When callee expects &self (or implicit by-ref) and receiver is a local variable
            // whose alloca type matches the expected param type, pass the alloca pointer directly
            // so the function can mutate the original variable (not a copy).
            // Only applies to non-pointer value types — if the variable already stores a
            // pointer (e.g. `let w: &Writer`), loading is needed to avoid double-indirection.
            // By-ref params are already pointers, so they also qualify for direct passing.
            if (needsByRef && call.UfcsReceiver is IdentifierExpressionNode receiverId
                && _locals.TryGetValue(receiverId.Name, out var localAlloca)
                && (!_parameters.Contains(receiverId.Name) || _byRefParams.Contains(receiverId.Name))
                && localAlloca.IrType is IrPointer ptrType
                && ptrType.Pointee is not IrPointer) // value type, not already a pointer
            {
                args.Add(localAlloca);
            }
            else if (needsByRef && call.UfcsReceiver is MemberAccessExpressionNode memberReceiver)
            {
                // UFCS on a field: self.field.method() where method wants &self.
                // Compute a pointer to the field in-place (avoid copying the field value,
                // which would lose mutation semantics for iterators, etc.).
                var targetVal = LowerExpression(memberReceiver.Target);
                var baseVal = targetVal;
                var baseIrType = targetVal.IrType;

                // Auto-deref all but the last pointer layer (keep the struct pointer)
                for (int i = 0; i < memberReceiver.AutoDerefCount - 1; i++)
                {
                    if (baseIrType is IrPointer derefPtrType)
                    {
                        var derefResult = new LocalValue($"autoderef_{_tempCounter++}", derefPtrType.Pointee);
                        _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, baseVal, derefResult));
                        baseVal = derefResult;
                        baseIrType = derefPtrType.Pointee;
                    }
                }

                if (baseIrType is IrPointer { Pointee: IrStruct baseStruct })
                {
                    var field = FindField(baseStruct, memberReceiver.FieldName);

                    if (field.Type is IrPointer)
                    {
                        // Field is itself a pointer (e.g. sb: &StringBuilder) — load the
                        // pointer value so we pass &StringBuilder, not &&StringBuilder.
                        var loadedPtr = EmitLoadFromOffset(baseVal, field.ByteOffset, field.Type, "ufcs_field_load");
                        args.Add(loadedPtr);
                    }
                    else
                    {
                        // Field is a value type — pass the GEP pointer so callee can
                        // mutate the field in-place (e.g. iterator state).
                        var fieldPtr = new LocalValue($"ufcs_field_ptr_{_tempCounter++}", new IrPointer(field.Type));
                        _currentBlock.Instructions.Add(
                            new GetElementPtrInstruction(_currentSpan, baseVal, field.ByteOffset, fieldPtr));
                        args.Add(fieldPtr);
                    }
                }
                else
                {
                    // Fallback: base is a value, copy + materialize pointer
                    var receiverVal = LowerExpression(call.UfcsReceiver);
                    var receiverIrType = receiverVal.IrType ?? TypeLayoutService.IrVoidPrim;
                    var temp = new LocalValue($"ufcs_tmp_{_tempCounter++}", new IrPointer(receiverIrType));
                    _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, receiverIrType.Size, temp));
                    _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, temp, receiverVal));
                    args.Add(temp);
                }
            }
            else
            {
                var receiverVal = LowerExpression(call.UfcsReceiver);

                if (needsByRef && receiverVal.IrType is not IrPointer)
                {
                    // Callee expects &self or implicit by-ref — materialize a pointer
                    var receiverIrType = receiverVal.IrType ?? TypeLayoutService.IrVoidPrim;
                    var temp = new LocalValue($"ufcs_tmp_{_tempCounter++}", new IrPointer(receiverIrType));
                    _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, receiverIrType.Size, temp));
                    _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, temp, receiverVal));
                    args.Add(temp);
                }
                else if (!needsByRef && receiverVal.IrType is IrPointer recvPtr)
                {
                    // Callee expects value but receiver is a pointer (e.g. self: &List(T)
                    // calling as_slice(self: List(T))) — deref the pointer
                    var loaded = new LocalValue($"ufcs_deref_{_tempCounter++}", recvPtr.Pointee);
                    _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, receiverVal, loaded));
                    args.Add(loaded);
                }
                else
                {
                    args.Add(receiverVal);
                }
            }
        }

        // Resolve target function name
        var targetName = call.ResolvedTarget?.Name ?? call.FunctionName;
        var isForeign = call.ResolvedTarget != null &&
                        (call.ResolvedTarget.Modifiers & FunctionModifiers.Foreign) != 0;

        // Generic functions must be monomorphized before lowering
        if (call.ResolvedTarget != null && !isForeign && call.ResolvedTarget.IsGeneric)
            throw new InternalCompilerError(
                $"Call to unspecialized generic function `{targetName}`", call.Span);

        // Build callee param IrTypes for name mangling (non-foreign only)
        var calleeIrParamTypes = new List<IrType>();
        if (call.ResolvedTarget != null && !isForeign)
        {
            foreach (var param in call.ResolvedTarget.Parameters)
                calleeIrParamTypes.Add(GetIrType(param));
        }

        // For foreign functions, resolve param types from the function's HM type signature
        // (foreign params don't have inferred types recorded on their AST nodes)
        List<IrType>? foreignParamTypes = null;
        if (isForeign && call.ResolvedTarget != null)
        {
            var fnHmType = GetFunctionHmType(call.ResolvedTarget);
            foreignParamTypes = new List<IrType>();
            foreach (var pt in fnHmType.ParameterTypes)
                foreignParamTypes.Add(_layout.Lower(pt));
        }

        // Lower arguments with expected types from callee params (triggers coercions)
        // Offset by ufcs arg count since receiver was already added
        var ufcsOffset = call.UfcsReceiver != null ? 1 : 0;
        for (int i = 0; i < callArguments.Count; i++)
        {
            var paramIdx = i + ufcsOffset;
            IrType? expectedParamType = null;
            if (paramIdx < calleeIrParamTypes.Count)
                expectedParamType = calleeIrParamTypes[paramIdx];
            else if (foreignParamTypes != null && paramIdx < foreignParamTypes.Count)
                expectedParamType = foreignParamTypes[paramIdx];

            // Special case: empty array literal for variadic → construct empty slice directly
            if (callArguments[i] is ArrayLiteralExpressionNode { Elements.Count: 0 } emptyArr
                && expectedParamType is IrStruct sliceStruct)
            {
                var ptrField = sliceStruct.Fields.FirstOrDefault(f => f.Name == "ptr");
                var lenField = sliceStruct.Fields.FirstOrDefault(f => f.Name == "len");
                if (ptrField.Type != null && lenField.Type != null)
                {
                    var tmpPtr = new LocalValue($"empty_slice_{_tempCounter++}", new IrPointer(sliceStruct));
                    _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, sliceStruct.Size, tmpPtr));
                    // ptr = NULL (0 cast to pointer)
                    EmitStoreToOffset(tmpPtr, ptrField.ByteOffset,
                        new IntConstantValue(0, ptrField.Type), ptrField.Type);
                    // len = 0
                    EmitStoreToOffset(tmpPtr, lenField.ByteOffset,
                        new IntConstantValue(0, TypeLayoutService.IrUSize), lenField.Type);
                    var loaded = new LocalValue($"empty_slice_val_{_tempCounter++}", sliceStruct);
                    _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, tmpPtr, loaded));

                    if (!isForeign && IsLargeValue(expectedParamType))
                    {
                        var temp = new LocalValue($"byref_arg_{_tempCounter++}", new IrPointer(sliceStruct));
                        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, sliceStruct.Size, temp));
                        _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, temp, loaded));
                        args.Add(temp);
                    }
                    else
                    {
                        args.Add(loaded);
                    }
                    continue;
                }
            }

            var argVal = LowerExpression(callArguments[i], expectedParamType);

            // Implicit by-ref: large value args to non-foreign functions need pointer materialization
            if (!isForeign && expectedParamType != null && IsLargeValue(expectedParamType) && argVal.IrType is not IrPointer)
            {
                var argIrType = argVal.IrType ?? expectedParamType;
                var temp = new LocalValue($"byref_arg_{_tempCounter++}", new IrPointer(argIrType));
                _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, argIrType.Size, temp));
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, temp, argVal));
                args.Add(temp);
            }
            else
            {
                args.Add(argVal);
            }
        }

        // For foreign calls returning Option[&T], the C function returns a raw pointer.
        // Emit the call with pointer return type, then wrap in Option.
        var actualRetType = retIrType;
        IrStruct? foreignOptionRet = null;
        IrField foreignValField = default;
        if (isForeign && retIrType is IrStruct optRet)
        {
            var hvF = optRet.Fields.FirstOrDefault(f => f.Name == "has_value");
            var vF = optRet.Fields.FirstOrDefault(f => f.Name == "value");
            if (hvF.Type == TypeLayoutService.IrBool && vF.Type is IrPointer)
            {
                actualRetType = vF.Type; // raw pointer
                foreignOptionRet = optRet;
                foreignValField = vF;
            }
        }

        // Return slot: non-foreign, non-indirect call returning large value
        if (!isForeign && !call.IsIndirectCall && IsLargeValue(retIrType) && foreignOptionRet == null)
        {
            var retSlot = new LocalValue($"retslot_{_tempCounter++}", new IrPointer(retIrType));
            _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, retIrType.Size, retSlot));
            args.Insert(0, retSlot);

            var voidResult = new LocalValue($"call_{_tempCounter++}", TypeLayoutService.IrVoidPrim);
            var callInst = new CallInstruction(_currentSpan, targetName, args, voidResult);
            callInst.IsForeignCall = false;
            callInst.IsIndirectCall = false;
            if (calleeIrParamTypes.Count > 0)
                callInst.CalleeIrParamTypes = calleeIrParamTypes;
            _currentBlock.Instructions.Add(callInst);

            var loaded = new LocalValue($"retload_{_tempCounter++}", retIrType);
            _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, retSlot, loaded));
            return loaded;
        }

        var result = new LocalValue($"call_{_tempCounter++}", actualRetType);
        var callInstNorm = new CallInstruction(_currentSpan, targetName, args, result);
        callInstNorm.IsForeignCall = isForeign;
        callInstNorm.IsIndirectCall = call.IsIndirectCall;
        if (calleeIrParamTypes.Count > 0)
            callInstNorm.CalleeIrParamTypes = calleeIrParamTypes;

        _currentBlock.Instructions.Add(callInstNorm);

        // Wrap foreign raw-pointer return in Option[&T]
        if (foreignOptionRet != null)
        {
            var hvField = foreignOptionRet.Fields.First(f => f.Name == "has_value");
            return WrapPointerInOption(result, foreignOptionRet, hvField, foreignValField);
        }

        return result;
    }

    /// <summary>
    /// Lower a field-call: receiver.field(args) where field is a function pointer.
    /// Extracts the function pointer from the struct and emits an IndirectCallInstruction.
    /// </summary>
    private Value LowerIndirectFieldCall(CallExpressionNode call, IrType retIrType)
    {
        var receiverVal = LowerExpression(call.UfcsReceiver!);
        var baseVal = receiverVal;
        var baseIrType = receiverVal.IrType;

        // Auto-deref pointer layers, but stop early if pointee is a struct/enum
        // (GEP needs a pointer base, so keep the last pointer level)
        while (baseIrType is IrPointer ptrType)
        {
            if (ptrType.Pointee is IrStruct or IrEnum)
            {
                baseIrType = ptrType.Pointee;
                break;
            }
            var derefResult = new LocalValue($"autoderef_{_tempCounter++}", ptrType.Pointee);
            _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, baseVal, derefResult));
            baseVal = derefResult;
            baseIrType = ptrType.Pointee;
        }

        // GEP requires a pointer base. Try to use original pointer to avoid load-then-spill.
        if (baseIrType is IrStruct or IrEnum && baseVal.IrType is not IrPointer)
        {
            Value? directPtr = null;
            if (call.UfcsReceiver is IdentifierExpressionNode targetId
                && _locals.TryGetValue(targetId.Name, out var localPtr)
                && localPtr.IrType is IrPointer
                && (!_parameters.Contains(targetId.Name) || _byRefParams.Contains(targetId.Name)))
            {
                directPtr = localPtr;
            }

            if (directPtr != null)
            {
                baseVal = directPtr;
            }
            else
            {
                var tmpPtr = new LocalValue($"field_tmp_{_tempCounter++}", new IrPointer(baseIrType));
                _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, baseIrType.Size, tmpPtr));
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, tmpPtr, baseVal));
                baseVal = tmpPtr;
            }
        }

        // Find the function pointer field
        var structType = baseIrType switch
        {
            IrStruct s => s,
            IrPointer { Pointee: IrStruct s } => s,
            _ => throw new InternalCompilerError(
                $"Indirect field call receiver is not a struct: {baseIrType}", call.Span)
        };

        var field = FindField(structType, call.MethodName!);

        // Load function pointer from field
        var funcPtrVal = EmitLoadFromOffset(baseVal, field.ByteOffset, field.Type, "fptr_load");

        // Lower arguments — apply implicit by-ref for large values
        var args = new List<Value>();
        IrFunctionPtr? fpType = funcPtrVal.IrType as IrFunctionPtr;
        foreach (var arg in call.Arguments)
        {
            var argVal = LowerExpression(arg);
            // Materialize large value args as pointers to match the transformed function pointer type
            if (IsLargeValue(argVal.IrType) && argVal.IrType is not IrPointer)
            {
                var argIrType = argVal.IrType ?? TypeLayoutService.IrVoidPrim;
                var temp = new LocalValue($"ifc_tmp_{_tempCounter++}", new IrPointer(argIrType));
                _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, argIrType.Size, temp));
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, temp, argVal));
                args.Add(temp);
            }
            else
            {
                args.Add(argVal);
            }
        }

        // Return slot for large return types
        if (IsLargeValue(retIrType))
        {
            var retSlot = new LocalValue($"retslot_{_tempCounter++}", new IrPointer(retIrType));
            _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, retIrType.Size, retSlot));
            args.Insert(0, retSlot);

            var voidResult = new LocalValue($"call_{_tempCounter++}", TypeLayoutService.IrVoidPrim);
            _currentBlock.Instructions.Add(new IndirectCallInstruction(_currentSpan, funcPtrVal, args, voidResult));

            var loaded = new LocalValue($"retload_{_tempCounter++}", retIrType);
            _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, retSlot, loaded));
            return loaded;
        }

        var result = new LocalValue($"call_{_tempCounter++}", retIrType);
        _currentBlock.Instructions.Add(new IndirectCallInstruction(_currentSpan, funcPtrVal, args, result));
        return result;
    }

    /// <summary>
    /// Lower an indirect call through a variable holding a function pointer.
    /// </summary>
    private Value LowerIndirectVarCall(CallExpressionNode call, IrType retIrType)
    {
        // Look up the local that holds the function pointer
        Value funcPtrVal;
        if (_locals.TryGetValue(call.FunctionName, out var localPtr))
        {
            // Load from local pointer if it's stored as a pointer
            if (localPtr.IrType is IrPointer { Pointee: IrFunctionPtr } ptrToFn)
            {
                var loadResult = new LocalValue($"fptr_load_{_tempCounter++}", ptrToFn.Pointee);
                _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, localPtr, loadResult));
                funcPtrVal = loadResult;
            }
            else
            {
                funcPtrVal = localPtr;
            }
        }
        else
        {
            // Fall back to a named reference (e.g. global function pointer)
            funcPtrVal = new LocalValue(call.FunctionName, retIrType);
        }

        // Lower arguments — apply implicit by-ref for large values
        var args = new List<Value>();
        foreach (var arg in call.Arguments)
        {
            var argVal = LowerExpression(arg);
            if (IsLargeValue(argVal.IrType) && argVal.IrType is not IrPointer)
            {
                var argIrType = argVal.IrType ?? TypeLayoutService.IrVoidPrim;
                var temp = new LocalValue($"ivc_tmp_{_tempCounter++}", new IrPointer(argIrType));
                _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, argIrType.Size, temp));
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, temp, argVal));
                args.Add(temp);
            }
            else
            {
                args.Add(argVal);
            }
        }

        // Return slot for large return types
        if (IsLargeValue(retIrType))
        {
            var retSlot = new LocalValue($"retslot_{_tempCounter++}", new IrPointer(retIrType));
            _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, retIrType.Size, retSlot));
            args.Insert(0, retSlot);

            var voidResult = new LocalValue($"call_{_tempCounter++}", TypeLayoutService.IrVoidPrim);
            _currentBlock.Instructions.Add(new IndirectCallInstruction(_currentSpan, funcPtrVal, args, voidResult));

            var loaded = new LocalValue($"retload_{_tempCounter++}", retIrType);
            _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, retSlot, loaded));
            return loaded;
        }

        var result = new LocalValue($"call_{_tempCounter++}", retIrType);
        _currentBlock.Instructions.Add(new IndirectCallInstruction(_currentSpan, funcPtrVal, args, result));
        return result;
    }

    private Value LowerShortCircuitLogical(BinaryExpressionNode binary)
    {
        var isAnd = binary.Operator == BinaryOperatorKind.And;
        var left = LowerExpression(binary.Left);

        // Allocate result on stack
        var resultPtr = new LocalValue($"logic_result_{_tempCounter++}", new IrPointer(TypeLayoutService.IrBool));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, TypeLayoutService.IrBool.Size, resultPtr));

        // Store short-circuit default: false for 'and', true for 'or'
        var defaultVal = new IntConstantValue(isAnd ? 0 : 1, TypeLayoutService.IrBool);
        _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, resultPtr, defaultVal));

        var rhsBlock = CreateBlock(isAnd ? "and_rhs" : "or_rhs");
        var mergeBlock = CreateBlock(isAnd ? "and_merge" : "or_merge");

        // For 'and': if LHS is true, evaluate RHS; else skip (result stays false)
        // For 'or':  if LHS is false, evaluate RHS; else skip (result stays true)
        if (isAnd)
            _currentBlock.Instructions.Add(new BranchInstruction(_currentSpan, left, rhsBlock, mergeBlock));
        else
            _currentBlock.Instructions.Add(new BranchInstruction(_currentSpan, left, mergeBlock, rhsBlock));

        // RHS block: evaluate right side and store
        _currentFunction.BasicBlocks.Add(rhsBlock);
        _currentBlock = rhsBlock;
        var right = LowerExpression(binary.Right);
        _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, resultPtr, right));
        _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, mergeBlock));

        // Merge block: load and return result
        _currentFunction.BasicBlocks.Add(mergeBlock);
        _currentBlock = mergeBlock;
        var result = new LocalValue($"logic_val_{_tempCounter++}", TypeLayoutService.IrBool);
        _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, resultPtr, result));
        return result;
    }

    private Value LowerBinary(BinaryExpressionNode binary)
    {
        var resolved = _checker.GetResolvedOperator(binary);
        if (resolved != null)
            return LowerOperatorFunctionCall(binary, resolved);

        var left = LowerExpression(binary.Left);
        var right = LowerExpression(binary.Right);

        var irType = GetIrType(binary);

        var op = MapBinaryOp(binary.Operator);
        var result = new LocalValue($"t{_tempCounter++}", irType);
        _currentBlock.Instructions.Add(new BinaryInstruction(_currentSpan, op, left, right, result));
        return result;
    }

    /// <summary>
    /// Emit a CallInstruction for a resolved operator function (binary or unary).
    /// Handles NegateResult (derived != from ==) and CmpDerivedOperator (derived comparison from op_cmp).
    /// </summary>
    private Value LowerOperatorFunctionCall(ExpressionNode expr, ResolvedOperator resolved)
    {
        // Collect operands
        var args = new List<Value>();
        if (expr is BinaryExpressionNode bin)
        {
            args.Add(LowerExpression(bin.Left));
            args.Add(LowerExpression(bin.Right));
        }
        else if (expr is UnaryExpressionNode un)
        {
            args.Add(LowerExpression(un.Operand));
        }

        var fn = resolved.Function;

        // Build callee param IrTypes for name mangling
        var calleeIrParamTypes = new List<IrType>();
        foreach (var param in fn.Parameters)
            calleeIrParamTypes.Add(GetIrType(param));

        // Auto-materialize: if param expects pointer but arg is a value, alloca+store
        for (int i = 0; i < args.Count && i < calleeIrParamTypes.Count; i++)
        {
            if (calleeIrParamTypes[i] is IrPointer && args[i].IrType is not IrPointer)
            {
                var argIrType = args[i].IrType ?? TypeLayoutService.IrVoidPrim;
                var temp = new LocalValue($"op_tmp_{_tempCounter++}", new IrPointer(argIrType));
                _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, argIrType.Size, temp));
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, temp, args[i]));
                args[i] = temp;
            }
        }

        // Determine return type: for CmpDerived, the call returns the function's return type (Ord/i32)
        var fnHmType = GetFunctionHmType(fn);
        var callRetIrType = _layout.Lower(fnHmType.ReturnType);

        var isForeignOp = (fn.Modifiers & FunctionModifiers.Foreign) != 0;
        Value callResult;
        if (!isForeignOp)
        {
            callResult = EmitFLangCall(fn.Name, args, callRetIrType, calleeIrParamTypes);
        }
        else
        {
            var opResult = new LocalValue($"op_{_tempCounter++}", callRetIrType);
            var callInst = new CallInstruction(_currentSpan, fn.Name, args, opResult);
            callInst.IsForeignCall = true;
            if (calleeIrParamTypes.Count > 0)
                callInst.CalleeIrParamTypes = calleeIrParamTypes;
            _currentBlock.Instructions.Add(callInst);
            callResult = opResult;
        }

        // Auto-derived op_eq/op_ne: negate the complement's result
        if (resolved.NegateResult)
        {
            var negResult = new LocalValue($"not_{_tempCounter++}", callRetIrType);
            _currentBlock.Instructions.Add(new UnaryInstruction(_currentSpan, UnaryOp.Not, callResult, negResult));
            return negResult;
        }

        // Auto-derived from op_cmp: extract tag from Ord enum, compare against 0
        if (resolved.CmpDerivedOperator is { } cmpOp)
        {
            var ordPtr = new LocalValue($"ord_ptr_{_tempCounter++}", new IrPointer(callRetIrType));
            _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, callRetIrType.Size, ordPtr));
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, ordPtr, callResult));

            var tagValue = EmitLoadFromOffset(ordPtr, 0, TypeLayoutService.IrI32, "ord_tag");

            var irOp = cmpOp switch
            {
                BinaryOperatorKind.LessThan => BinaryOp.LessThan,
                BinaryOperatorKind.GreaterThan => BinaryOp.GreaterThan,
                BinaryOperatorKind.LessThanOrEqual => BinaryOp.LessThanOrEqual,
                BinaryOperatorKind.GreaterThanOrEqual => BinaryOp.GreaterThanOrEqual,
                BinaryOperatorKind.Equal => BinaryOp.Equal,
                BinaryOperatorKind.NotEqual => BinaryOp.NotEqual,
                _ => throw new InternalCompilerError($"Unexpected CmpDerivedOperator: {cmpOp}", expr.Span)
            };

            var zero = new IntConstantValue(0, TypeLayoutService.IrI32);
            var cmpResult = new LocalValue($"cmp_{_tempCounter++}", TypeLayoutService.IrBool);
            _currentBlock.Instructions.Add(new BinaryInstruction(_currentSpan, irOp, tagValue, zero, cmpResult));
            return cmpResult;
        }

        return callResult;
    }

    private Value LowerUnary(UnaryExpressionNode unary)
    {
        // Check table for resolved operator function
        var resolved = _checker.GetResolvedOperator(unary);
        if (resolved != null)
            return LowerOperatorFunctionCall(unary, resolved);

        var operand = LowerExpression(unary.Operand);
        var irType = GetIrType(unary);

        var op = unary.Operator switch
        {
            UnaryOperatorKind.Negate => UnaryOp.Negate,
            UnaryOperatorKind.Not => UnaryOp.Not,
            _ => UnaryOp.Negate
        };

        var unaryResult = new LocalValue($"t{_tempCounter++}", irType);
        _currentBlock.Instructions.Add(new UnaryInstruction(_currentSpan, op, operand, unaryResult));
        return unaryResult;
    }

    private Value LowerMemberAccess(MemberAccessExpressionNode member)
    {
        var fieldName = member.FieldName;

        // Check if this is an enum variant access (e.g., FileMode.Read)
        // The target's inferred type is the enum type, and the member is a variant name.
        var targetInferredType = _checker.GetInferredType(member.Target);
        var resolvedTarget = _checker.Engine.Resolve(targetInferredType);
        if (resolvedTarget is NominalType { Kind: NominalKind.Enum })
        {
            var irType = GetIrType(member);
            if (irType is IrEnum irEnum)
                return LowerBareVariant(fieldName, irEnum);
        }

        var targetVal = LowerExpression(member.Target);

        // Handle array .len and .ptr (arrays act as having these virtual fields)
        var targetIrType = targetVal.IrType;
        var arrayIr = targetIrType as IrArray ?? (targetIrType as IrPointer)?.Pointee as IrArray;
        if (arrayIr != null)
        {
            if (fieldName == "len")
                return new IntConstantValue(arrayIr.Length ?? 0, TypeLayoutService.IrUSize);
            if (fieldName == "ptr")
            {
                var elemPtrType = new IrPointer(arrayIr.Element);
                var castResult = new LocalValue($"array_ptr_{_tempCounter++}", elemPtrType);
                _currentBlock.Instructions.Add(new CastInstruction(_currentSpan, targetVal, castResult));
                return castResult;
            }
        }

        // Get the result type from the type checker
        var fieldIrType = GetIrType(member);

        // Auto-dereference: peel off pointer layers as needed, but stop early
        // if pointee is a struct/enum (GEP needs a pointer base)
        var baseVal = targetVal;
        var baseIrType = targetIrType;
        for (int i = 0; i < member.AutoDerefCount; i++)
        {
            if (baseIrType is IrPointer ptrType)
            {
                if (ptrType.Pointee is IrStruct or IrEnum)
                {
                    baseIrType = ptrType.Pointee;
                    break;
                }
                var derefResult = new LocalValue($"autoderef_{_tempCounter++}", ptrType.Pointee);
                _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, baseVal, derefResult));
                baseVal = derefResult;
                baseIrType = ptrType.Pointee;
            }
        }

        // Niche-optimized Option[&T]: .has_value -> ptr != NULL, .value -> cast to non-nullable
        if (IsNicheOption(baseIrType))
        {
            var nichePtr = (IrPointer)baseIrType;
            if (fieldName == "has_value")
            {
                var nullVal = new IntConstantValue(0, nichePtr);
                var cmpResult = new LocalValue($"niche_hv_{_tempCounter++}", TypeLayoutService.IrBool);
                _currentBlock.Instructions.Add(new BinaryInstruction(_currentSpan, BinaryOp.NotEqual, baseVal, nullVal, cmpResult));
                return cmpResult;
            }
            if (fieldName == "value")
            {
                var stripped = StripNullable(nichePtr);
                var castResult = new LocalValue($"niche_val_{_tempCounter++}", stripped);
                _currentBlock.Instructions.Add(new CastInstruction(_currentSpan, baseVal, castResult));
                return castResult;
            }
        }

        // Find the IrStruct to get field offset
        IrStruct? structType = baseIrType switch
        {
            IrStruct s => s,
            IrPointer { Pointee: IrStruct s } => s,
            _ => null
        };

        // Type(T) is a phantom alias for TypeInfo — redirect field access to TypeInfo's layout
        if (structType != null && structType.Fields.Length == 0)
        {
            var targetHmType = _checker.Engine.Resolve(_checker.GetInferredType(member.Target));
            if (targetHmType is NominalType { Name: "core.rtti.Type" })
            {
                var typeInfo = _checker.LookupNominalType("core.rtti.TypeInfo");
                if (typeInfo != null)
                    structType = _layout.Lower(typeInfo) as IrStruct;
            }
        }

        if (structType == null)
            throw new InternalCompilerError(
                $"Member access on non-struct type `{baseIrType}`", member.Span);

        // GEP requires a pointer base. If the base is a struct VALUE (not a pointer),
        // try to use the original pointer (by-ref param or alloca local) to avoid load-then-spill.
        if (baseIrType is IrStruct or IrEnum && baseVal.IrType is not IrPointer)
        {
            Value? directPtr = null;
            if (member.Target is IdentifierExpressionNode targetId
                && _locals.TryGetValue(targetId.Name, out var localPtr)
                && localPtr.IrType is IrPointer
                && (!_parameters.Contains(targetId.Name) || _byRefParams.Contains(targetId.Name))
                && member.AutoDerefCount == 0)
            {
                directPtr = localPtr;
            }

            if (directPtr != null)
            {
                baseVal = directPtr;
            }
            else
            {
                var tmpPtr = new LocalValue($"field_tmp_{_tempCounter++}", new IrPointer(baseIrType));
                _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, baseIrType.Size, tmpPtr));
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, tmpPtr, baseVal));
                baseVal = tmpPtr;
            }
        }

        var field = FindField(structType, fieldName);

        // Load the field value
        var loadResult = EmitLoadFromOffset(baseVal, field.ByteOffset, fieldIrType, "field");
        return loadResult;
    }

    private Value LowerCast(CastExpressionNode cast)
    {
        var srcVal = LowerExpression(cast.Expression);

        var targetIrType = GetIrType(cast);

        // No-op if types match
        if (srcVal.IrType != null && srcVal.IrType == targetIrType)
            return srcVal;

        // Try systematic coercions first (handles array->slice, pointer->Option, etc.)
        var coerced = ApplyCoercions(srcVal, targetIrType);
        if (coerced != srcVal)
            return coerced;

        // Pointer -> Slice: e.g. `buf as u8[]` where buf is [u8; N]
        // The source is a pointer (arrays decay to pointers), target is a Slice struct.
        if (srcVal.IrType is IrPointer && targetIrType is IrStruct sliceTarget)
        {
            var ptrField = sliceTarget.Fields.FirstOrDefault(f => f.Name == "ptr");
            var lenField = sliceTarget.Fields.FirstOrDefault(f => f.Name == "len");
            if (ptrField.Type != null && lenField.Type != null)
            {
                // Get the array length from the HM type (the IrType lost length info)
                var hmSrcType = _engine.Resolve(_checker.GetInferredType(cast.Expression));
                int length = 0;
                if (hmSrcType is Core.Types.ArrayType arrHm)
                    length = arrHm.Length;

                var tmpPtr = new LocalValue($"slice_{_tempCounter++}", new IrPointer(sliceTarget));
                _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, sliceTarget.Size, tmpPtr));

                EmitStoreToOffset(tmpPtr, ptrField.ByteOffset, srcVal, ptrField.Type);
                EmitStoreToOffset(tmpPtr, lenField.ByteOffset,
                    new IntConstantValue(length, TypeLayoutService.IrUSize), lenField.Type);

                var loaded = new LocalValue($"slice_val_{_tempCounter++}", sliceTarget);
                _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, tmpPtr, loaded));
                return loaded;
            }
        }

        // Constant folding for primitive casts
        if (srcVal is IntConstantValue constSrc && targetIrType is IrPrimitive)
            return new IntConstantValue(constSrc.IntValue, targetIrType);

        // Emit cast instruction — pass null! for TypeBase, codegen uses IrType
        var result = new LocalValue($"cast_{_tempCounter++}", targetIrType);
        _currentBlock.Instructions.Add(new CastInstruction(_currentSpan, srcVal, result));
        return result;
    }

    private Value LowerBlock(BlockExpressionNode block)
    {
        foreach (var stmt in block.Statements)
            LowerStatement(stmt);

        if (block.TrailingExpression != null)
            return LowerExpression(block.TrailingExpression);

        return new IntConstantValue(0, TypeLayoutService.IrVoidPrim);
    }

    private Value LowerIf(IfExpressionNode ifExpr)
    {
        var condVal = LowerExpression(ifExpr.Condition);

        var resultIrType = GetIrType(ifExpr);
        var isVoid = resultIrType == TypeLayoutService.IrVoidPrim;

        var thenBlock = CreateBlock("if_then");
        var elseBlock = CreateBlock("if_else");
        var mergeBlock = CreateBlock("if_merge");

        // Phi-via-alloca: allocate result slot if non-void
        Value? resultPtr = null;
        if (!isVoid)
        {
            resultPtr = new LocalValue($"if_result_{_tempCounter++}", new IrPointer(resultIrType));
            _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, resultIrType.Size, resultPtr));
        }

        _currentBlock.Instructions.Add(new BranchInstruction(_currentSpan, condVal, thenBlock, elseBlock));

        // Then branch
        _currentFunction.BasicBlocks.Add(thenBlock);
        _currentBlock = thenBlock;
        var thenVal = LowerExpression(ifExpr.ThenBranch, isVoid ? null : resultIrType);
        if (!isVoid && resultPtr != null)
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, resultPtr, thenVal));
        if (_currentBlock.Instructions.Count == 0 ||
            _currentBlock.Instructions[^1] is not (ReturnInstruction or JumpInstruction or BranchInstruction))
        {
            _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, mergeBlock));
        }

        // Else branch
        _currentFunction.BasicBlocks.Add(elseBlock);
        _currentBlock = elseBlock;
        if (ifExpr.ElseBranch != null)
        {
            var elseVal = LowerExpression(ifExpr.ElseBranch, isVoid ? null : resultIrType);
            if (!isVoid && resultPtr != null)
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, resultPtr, elseVal));
        }
        if (_currentBlock.Instructions.Count == 0 ||
            _currentBlock.Instructions[^1] is not (ReturnInstruction or JumpInstruction or BranchInstruction))
        {
            _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, mergeBlock));
        }

        // Merge
        _currentFunction.BasicBlocks.Add(mergeBlock);
        _currentBlock = mergeBlock;

        if (!isVoid && resultPtr != null)
        {
            var loaded = new LocalValue($"if_val_{_tempCounter++}", resultIrType);
            _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, resultPtr, loaded));
            return loaded;
        }

        return new IntConstantValue(0, TypeLayoutService.IrVoidPrim);
    }

    private Value LowerAddressOf(AddressOfExpressionNode addrOf)
    {
        // If target is an identifier that maps to an alloca, return the alloca pointer directly
        if (addrOf.Target is IdentifierExpressionNode id && _locals.TryGetValue(id.Name, out var localVal))
        {
            // localVal is already a pointer (alloca result) for locals
            if (!_parameters.Contains(id.Name))
                return localVal;

            // For parameters that are already pointer types (e.g., sink: &Sink),
            // &sink returns the pointer value directly — no double-indirection.
            if (localVal.IrType is IrPointer)
                return localVal;
        }

        // If target is a global constant, the GlobalValue is already a pointer
        if (addrOf.Target is IdentifierExpressionNode gid
            && _globalConstants.TryGetValue(gid.Name, out var gv)
            && gv is GlobalValue)
        {
            return gv;
        }

        // Temporary promotion: if target is a call result, materialize on the stack
        // so we can take its address (same pattern as UFCS temp materialization).
        if (addrOf.Target is CallExpressionNode)
        {
            var targetVal = LowerExpression(addrOf.Target);
            var valType = targetVal.IrType ?? TypeLayoutService.IrVoidPrim;
            var temp = new LocalValue($"addrof_tmp_{_tempCounter++}", new IrPointer(valType));
            _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, valType.Size, temp));
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, temp, targetVal));
            return temp;
        }

        // General case: emit AddressOfInstruction
        var targetVal2 = LowerExpression(addrOf.Target);
        var irType = GetIrType(addrOf);

        var result = new LocalValue($"addr_{_tempCounter++}", irType);
        _currentBlock.Instructions.Add(new AddressOfInstruction(_currentSpan, targetVal2.Name, result));
        return result;
    }

    private LocalValue LowerDereference(DereferenceExpressionNode deref)
    {
        var targetVal = LowerExpression(deref.Target);

        var irType = GetIrType(deref);

        var result = new LocalValue($"deref_{_tempCounter++}", irType);
        _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, targetVal, result));
        return result;
    }

    private IntConstantValue LowerAssignment(AssignmentExpressionNode assign)
    {
        // Indexed assignment with op_set_index
        if (assign.Target is IndexExpressionNode idx)
        {
            var resolved = _checker.GetResolvedOperator(assign);
            if (resolved != null)
                return LowerSetIndexCall(idx, assign.Value, resolved);
        }

        var ptr = LowerLValue(assign.Target);
        // Determine expected type from LValue's pointee type
        IrType? expectedType = ptr?.IrType is IrPointer ptrType ? ptrType.Pointee : null;
        var val = LowerExpression(assign.Value, expectedType);

        if (ptr != null)
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, ptr, val));

        return new IntConstantValue(0, TypeLayoutService.IrVoidPrim);
    }

    private IntConstantValue LowerSetIndexCall(IndexExpressionNode idx, ExpressionNode valueExpr, ResolvedOperator resolved)
    {
        var indexVal = LowerExpression(idx.Index);
        var val = LowerExpression(valueExpr);

        // For op_set_index(&base, ...), pass the address of the original variable
        // so mutations are visible to the caller. Use LowerLValue if the first
        // param expects a reference, otherwise fall back to LowerExpression + materialize.
        var calleeIrParamTypes0 = GetIrType(resolved.Function.Parameters[0]);
        Value baseVal;
        if (calleeIrParamTypes0 is IrPointer)
        {
            baseVal = LowerLValue(idx.Base) ?? LowerExpression(idx.Base);
            if (baseVal.IrType is not IrPointer)
            {
                var baseIrType = baseVal.IrType ?? TypeLayoutService.IrVoidPrim;
                var temp = new LocalValue($"setidx_tmp_{_tempCounter++}", new IrPointer(baseIrType));
                _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, baseIrType.Size, temp));
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, temp, baseVal));
                baseVal = temp;
            }
        }
        else
        {
            baseVal = LowerExpression(idx.Base);
        }

        var calleeIrParamTypes = new List<IrType>();
        foreach (var param in resolved.Function.Parameters)
            calleeIrParamTypes.Add(GetIrType(param));

        EmitFLangCall(resolved.Function.Name, [baseVal, indexVal, val], TypeLayoutService.IrVoidPrim, calleeIrParamTypes);
        return new IntConstantValue(0, TypeLayoutService.IrVoidPrim);
    }

    private LocalValue LowerStructConstruction(StructConstructionExpressionNode structCtor)
    {
        var irType = GetIrType(structCtor);

        if (irType is not IrStruct structIrType)
            throw new InternalCompilerError($"Struct construction target is not a struct type: `{irType}`", structCtor.Span);

        return EmitStructConstruction(structIrType, structCtor.Fields, structCtor.Span);
    }

    private LocalValue LowerAnonymousStruct(AnonymousStructExpressionNode anonStruct, IrType? expectedType = null)
    {
        // Prefer the expected type (e.g. function return type) over the inferred anonymous type.
        // This handles cases like `return .{ current = ..., end = ... }` in a function returning
        // RangeIterator(T), where the anonymous struct's inferred fields may have unresolved TypeVars.
        var irType = expectedType is IrStruct expectedStruct
                     && HasMatchingFields(expectedStruct, anonStruct)
            ? expectedType
            : GetIrType(anonStruct);

        if (irType is not IrStruct structIrType)
            throw new InternalCompilerError($"Anonymous struct target is not a struct type: `{irType}`", anonStruct.Span);

        return EmitStructConstruction(structIrType, anonStruct.Fields, anonStruct.Span);
    }

    private static bool HasMatchingFields(IrStruct expected, AnonymousStructExpressionNode anon)
    {
        if (anon.Fields.Count > expected.Fields.Length) return false;
        foreach (var (fieldName, _) in anon.Fields)
        {
            if (!expected.Fields.Any(f => f.Name == fieldName))
                return false;
        }
        return true;
    }

    /// <summary>
    /// Shared helper for struct construction: alloca + GEP/store per field + load result.
    /// </summary>
    private LocalValue EmitStructConstruction(IrStruct structIrType,
        IReadOnlyList<(string FieldName, ExpressionNode Value)> fields, SourceSpan span)
    {
        var resultPtr = new LocalValue($"struct_{_tempCounter++}", new IrPointer(structIrType));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, structIrType.Size, resultPtr));

        // Zero-initialize the struct so unspecified fields get default values
        var memsetResult = new LocalValue($"memset_{_tempCounter++}", TypeLayoutService.IrVoidPrim);
        _currentBlock.Instructions.Add(new CallInstruction(_currentSpan, "memset",
            [resultPtr, new IntConstantValue(0, TypeLayoutService.IrI32), new IntConstantValue(structIrType.Size, TypeLayoutService.IrUSize)],
            memsetResult)
        { IsForeignCall = true });

        foreach (var (fieldName, fieldExpr) in fields)
        {
            var irField = FindField(structIrType, fieldName);
            var fieldVal = LowerExpression(fieldExpr, irField.Type);

            EmitStoreToOffset(resultPtr, irField.ByteOffset, fieldVal, irField.Type);
        }

        // Load the complete struct value
        var loaded = new LocalValue($"struct_val_{_tempCounter++}", structIrType);
        _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, resultPtr, loaded));
        return loaded;
    }

    /// <summary>
    /// Construct a struct value from pre-lowered field values (alloca + GEP/store per field + load).
    /// </summary>
    private LocalValue BuildStruct(IrStruct structType, Dictionary<string, Value> fieldValues)
    {
        var resultPtr = new LocalValue($"struct_{_tempCounter++}", new IrPointer(structType));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, structType.Size, resultPtr));

        // Zero-initialize the struct so unspecified fields get default values
        var memsetResult = new LocalValue($"memset_{_tempCounter++}", TypeLayoutService.IrVoidPrim);
        _currentBlock.Instructions.Add(new CallInstruction(_currentSpan, "memset",
            [resultPtr, new IntConstantValue(0, TypeLayoutService.IrI32), new IntConstantValue(structType.Size, TypeLayoutService.IrUSize)],
            memsetResult)
        { IsForeignCall = true });

        foreach (var field in structType.Fields)
        {
            if (!fieldValues.TryGetValue(field.Name, out var val)) continue;
            EmitStoreToOffset(resultPtr, field.ByteOffset, val, field.Type);
        }

        var loaded = new LocalValue($"struct_val_{_tempCounter++}", structType);
        _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, resultPtr, loaded));
        return loaded;
    }

    private LocalValue LowerArrayLiteral(ArrayLiteralExpressionNode arrLit)
    {
        var irType = GetIrType(arrLit);

        if (irType is not IrArray arrayIrType)
            throw new InternalCompilerError(
                $"Array literal target is not an array type: `{irType}`", arrLit.Span);

        var elementIrType = arrayIrType.Element;
        var allocaResult = new LocalValue($"arr_{_tempCounter++}", new IrPointer(irType));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, irType.Size, allocaResult)
        { IsArrayStorage = true });

        if (arrLit.IsRepeatSyntax && arrLit.RepeatValue != null && arrLit.RepeatCountExpression != null)
        {
            var repeatVal = LowerExpression(arrLit.RepeatValue);
            var count = arrayIrType.Length ?? throw new InternalCompilerError(
                "Array repeat count must be compile-time evaluable", arrLit.Span);
            var elemSize = elementIrType.Size;
            var totalSize = elemSize * count;

            // Fast path: memset for single-byte elements or zero-valued constants
            bool useMemset = false;
            int memsetByte = 0;
            if (repeatVal is IntConstantValue cv)
            {
                if (cv.IntValue == 0)
                {
                    // Zero works for any type via memset
                    useMemset = true;
                    memsetByte = 0;
                }
                else if (elemSize == 1 && cv.IntValue >= 0 && cv.IntValue <= 255)
                {
                    // Single-byte element (u8, i8, bool) with value that fits in a byte
                    useMemset = true;
                    memsetByte = (int)cv.IntValue;
                }
            }

            if (useMemset)
            {
                var voidResult = new LocalValue($"memset_{_tempCounter++}", TypeLayoutService.IrVoidPrim);
                _currentBlock.Instructions.Add(new CallInstruction(_currentSpan, "memset",
                    [allocaResult, new IntConstantValue(memsetByte, TypeLayoutService.IrI32),
                     new IntConstantValue(totalSize, TypeLayoutService.IrUSize)],
                    voidResult)
                { IsForeignCall = true });
            }
            else
            {
                // General path: store element 0, then doubling memcpy to fill the rest
                EmitStoreToOffset(allocaResult, 0, repeatVal, elementIrType);

                if (count > 1)
                {
                    int filled = 1;
                    while (filled < count)
                    {
                        var chunk = Math.Min(filled, count - filled);
                        var destPtr = new LocalValue($"arr_fill_ptr_{_tempCounter++}", new IrPointer(elementIrType));
                        _currentBlock.Instructions.Add(
                            new GetElementPtrInstruction(_currentSpan, allocaResult, filled * elemSize, destPtr));
                        var voidResult = new LocalValue($"memcpy_{_tempCounter++}", TypeLayoutService.IrVoidPrim);
                        _currentBlock.Instructions.Add(new CallInstruction(_currentSpan, "memcpy",
                            [destPtr, allocaResult, new IntConstantValue(chunk * elemSize, TypeLayoutService.IrUSize)],
                            voidResult)
                        { IsForeignCall = true });
                        filled += chunk;
                    }
                }
            }
        }
        else if (arrLit.Elements != null)
        {
            // [a, b, c] — store each element
            for (int i = 0; i < arrLit.Elements.Count; i++)
            {
                var elemVal = LowerExpression(arrLit.Elements[i]);
                var elemOffset = elementIrType.Size * i;
                EmitStoreToOffset(allocaResult, elemOffset, elemVal, elementIrType);
            }
        }

        // Array values in C are just pointers — return the alloca pointer directly
        // (no Load needed; the alloca result name in C is already a pointer to the array data)
        return new LocalValue(allocaResult.Name, irType);
    }

    private Value LowerIndex(IndexExpressionNode index)
    {
        // If resolved to an op_index function, emit as call
        var resolved = _checker.GetResolvedOperator(index);
        if (resolved != null)
        {
            var baseVal = LowerExpression(index.Base);
            var indexVal = LowerExpression(index.Index);

            var retIrType = GetIrType(index);

            var calleeIrParamTypes = new List<IrType>();
            foreach (var param in resolved.Function.Parameters)
                calleeIrParamTypes.Add(GetIrType(param));

            // Materialize base to a temp pointer if the callee expects a pointer
            // or if it's a large value type (implicit by-ref)
            var firstParamIsPtr = calleeIrParamTypes.Count > 0 && calleeIrParamTypes[0] is IrPointer;
            var firstParamNeedsByRef = firstParamIsPtr ||
                (calleeIrParamTypes.Count > 0 && IsLargeValue(calleeIrParamTypes[0]));
            if (firstParamNeedsByRef && baseVal.IrType is not IrPointer)
            {
                var baseIrType = baseVal.IrType ?? TypeLayoutService.IrVoidPrim;
                var temp = new LocalValue($"idx_tmp_{_tempCounter++}", new IrPointer(baseIrType));
                _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, baseIrType.Size, temp));
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, temp, baseVal));
                baseVal = temp;
            }

            return EmitFLangCall(resolved.Function.Name, [baseVal, indexVal], retIrType, calleeIrParamTypes);
        }

        // Built-in array/slice indexing
        var arrVal = LowerExpression(index.Base);
        var resultIrType = GetIrType(index);

        // Range indexing with literal range expression: handle partial ranges (pos.., ..end, ..)
        if (index.Index is RangeExpressionNode rangeExpr)
        {
            // Start: use 0 if not specified
            Value startVal = rangeExpr.Start != null
                ? LowerExpression(rangeExpr.Start)
                : new IntConstantValue(0, TypeLayoutService.IrUSize);

            // End: use base length if not specified
            Value endVal;
            if (rangeExpr.End != null)
            {
                endVal = LowerExpression(rangeExpr.End);
            }
            else
            {
                // Get length from base: fixed array has compile-time length, slice has .len field
                var baseSemanticType = _checker.Engine.Resolve(_checker.GetInferredType(index.Base));
                if (baseSemanticType is Core.Types.ArrayType arrType)
                    endVal = new IntConstantValue(arrType.Length, TypeLayoutService.IrUSize);
                else
                    endVal = ExtractSliceLen(arrVal);
            }

            return LowerRangeSlicingWithBounds(arrVal, startVal, endVal, resultIrType);
        }

        var idxVal = LowerExpression(index.Index);

        // Range indexing with a Range value (not literal): both bounds already set
        if (idxVal.IrType is IrStruct rangeStruct && rangeStruct.Name == WellKnown.Range)
        {
            return LowerRangeSlicing(arrVal, idxVal, rangeStruct, resultIrType);
        }

        // If base is a Slice struct, extract .ptr field for pointer arithmetic
        var basePtr = arrVal;
        if (arrVal.IrType is IrStruct sliceBase)
        {
            var ptrField = sliceBase.Fields.FirstOrDefault(f => f.Name == "ptr");
            if (ptrField.Type != null)
            {
                basePtr = CoerceSliceToPointer(arrVal, sliceBase, ptrField);
            }
        }

        // Scalar indexing: compute element pointer via GEP
        var elementSize = new IntConstantValue(resultIrType.Size, TypeLayoutService.IrUSize);
        var byteOffset = new LocalValue($"idx_offset_{_tempCounter++}", TypeLayoutService.IrUSize);
        _currentBlock.Instructions.Add(new BinaryInstruction(_currentSpan, BinaryOp.Multiply, idxVal, elementSize, byteOffset));

        var loaded = EmitLoadFromOffset(basePtr, byteOffset, resultIrType, "elem");
        return loaded;
    }

    /// <summary>
    /// Lower range slicing: base[range] -> Slice { ptr: base.ptr + start, len: end - start }
    /// </summary>
    private Value LowerRangeSlicing(Value baseVal, Value rangeVal, IrStruct rangeStruct, IrType resultIrType)
    {
        // Extract start and end from range struct
        var startField = FindField(rangeStruct, "start");
        var endField = FindField(rangeStruct, "end");

        // Spill range to alloca for field access
        var rangePtr = new LocalValue($"rng_ptr_{_tempCounter++}", new IrPointer(rangeStruct));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, rangeStruct.Size, rangePtr));
        _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, rangePtr, rangeVal));

        var startVal = EmitLoadFromOffset(rangePtr, startField.ByteOffset, startField.Type, "rng_start");
        var endVal = EmitLoadFromOffset(rangePtr, endField.ByteOffset, endField.Type, "rng_end");

        // Get base pointer: for Slice, extract .ptr; for array, use array pointer directly
        Value basePtrVal;
        if (baseVal.IrType is IrStruct baseStruct && baseStruct.Name == WellKnown.Slice)
        {
            // Slice: extract .ptr field
            var ptrField = FindField(baseStruct, "ptr");
            var baseSpill = new LocalValue($"base_ptr_{_tempCounter++}", new IrPointer(baseStruct));
            _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, baseStruct.Size, baseSpill));
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, baseSpill, baseVal));
            basePtrVal = EmitLoadFromOffset(baseSpill, ptrField.ByteOffset, ptrField.Type, "base_raw_ptr");
        }
        else
        {
            basePtrVal = baseVal;
        }

        // Compute new_ptr = base_ptr + start (byte offset, element is u8-sized for slices)
        var newPtr = new LocalValue($"slice_ptr_{_tempCounter++}", basePtrVal.IrType!);
        _currentBlock.Instructions.Add(new BinaryInstruction(_currentSpan, BinaryOp.Add,
            basePtrVal, startVal, newPtr));

        // Compute new_len = end - start
        var newLen = new LocalValue($"slice_len_{_tempCounter++}", TypeLayoutService.IrUSize);
        _currentBlock.Instructions.Add(new BinaryInstruction(_currentSpan, BinaryOp.Subtract,
            endVal, startVal, newLen));

        // Construct slice struct: { ptr, len }
        if (resultIrType is IrStruct sliceStruct)
        {
            return BuildStruct(sliceStruct, new Dictionary<string, Value>
            {
                ["ptr"] = newPtr,
                ["len"] = newLen
            });
        }

        // Fallback — shouldn't happen
        return rangeVal;
    }

    /// <summary>
    /// Extract the 'len' field from a Slice struct value.
    /// </summary>
    private Value ExtractSliceLen(Value sliceVal)
    {
        if (sliceVal.IrType is IrStruct sliceStruct)
        {
            var lenField = sliceStruct.Fields.FirstOrDefault(f => f.Name == "len");
            if (lenField.Type != null)
            {
                var tmpPtr = new LocalValue($"slen_tmp_{_tempCounter++}", new IrPointer(sliceStruct));
                _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, sliceStruct.Size, tmpPtr));
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, tmpPtr, sliceVal));
                var lenVal = EmitLoadFromOffset(tmpPtr, lenField.ByteOffset, lenField.Type, "slen_val");
                return lenVal;
            }
        }
        // Fallback: 0 (shouldn't happen for valid slice types)
        return new IntConstantValue(0, TypeLayoutService.IrUSize);
    }

    /// <summary>
    /// Lower range slicing with pre-resolved start/end values (handles partial ranges).
    /// </summary>
    private LocalValue LowerRangeSlicingWithBounds(Value baseVal, Value startVal, Value endVal, IrType resultIrType)
    {
        // Get base pointer: for Slice, extract .ptr; for array, use array pointer directly
        Value basePtrVal;
        if (baseVal.IrType is IrStruct baseStruct && baseStruct.Name == WellKnown.Slice)
        {
            var ptrField = FindField(baseStruct, "ptr");
            var baseSpill = new LocalValue($"base_ptr_{_tempCounter++}", new IrPointer(baseStruct));
            _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, baseStruct.Size, baseSpill));
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, baseSpill, baseVal));
            basePtrVal = EmitLoadFromOffset(baseSpill, ptrField.ByteOffset, ptrField.Type, "base_raw_ptr");
        }
        else
        {
            basePtrVal = baseVal;
        }

        // Compute new_ptr = base_ptr + start
        var newPtr = new LocalValue($"slice_ptr_{_tempCounter++}", basePtrVal.IrType!);
        _currentBlock.Instructions.Add(new BinaryInstruction(_currentSpan, BinaryOp.Add,
            basePtrVal, startVal, newPtr));

        // Compute new_len = end - start
        var newLen = new LocalValue($"slice_len_{_tempCounter++}", TypeLayoutService.IrUSize);
        _currentBlock.Instructions.Add(new BinaryInstruction(_currentSpan, BinaryOp.Subtract,
            endVal, startVal, newLen));

        // Construct slice struct: { ptr, len }
        if (resultIrType is IrStruct sliceStruct)
        {
            return BuildStruct(sliceStruct, new Dictionary<string, Value>
            {
                ["ptr"] = newPtr,
                ["len"] = newLen
            });
        }

        // Fallback
        return newPtr;
    }

    private LocalValue LowerRange(RangeExpressionNode range)
    {
        // Use the inferred concrete type (e.g. Range[usize]), not the generic template
        var rangeIrType = GetIrType(range);
        if (rangeIrType is not IrStruct rangeStruct)
            throw new InternalCompilerError(
                $"Range type is not a struct: `{rangeIrType}`", range.Span);

        var resultPtr = new LocalValue($"range_{_tempCounter++}", new IrPointer(rangeStruct));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, rangeStruct.Size, resultPtr));

        // Store start
        if (range.Start != null)
        {
            var startVal = LowerExpression(range.Start);
            var startField = FindField(rangeStruct, "start");
            EmitStoreToOffset(resultPtr, startField.ByteOffset, startVal, startField.Type);
        }

        // Store end
        if (range.End != null)
        {
            var endVal = LowerExpression(range.End);
            var endField = FindField(rangeStruct, "end");
            EmitStoreToOffset(resultPtr, endField.ByteOffset, endVal, endField.Type);
        }

        var loaded = new LocalValue($"range_val_{_tempCounter++}", rangeStruct);
        _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, resultPtr, loaded));
        return loaded;
    }

    private Value LowerImplicitCoercion(ImplicitCoercionNode coercion)
    {
        var innerVal = LowerExpression(coercion.Inner);

        var targetIrType = GetIrType(coercion);

        switch (coercion.Kind)
        {
            case CoercionKind.IntegerWidening:
                {
                    // Emit a cast instruction for widening
                    var result = new LocalValue($"widen_{_tempCounter++}", targetIrType);
                    _currentBlock.Instructions.Add(new CastInstruction(_currentSpan, innerVal, result));
                    return result;
                }

            case CoercionKind.ReinterpretCast:
                {
                    // No-op: same binary representation, just change the IrType
                    innerVal.IrType = targetIrType;
                    return innerVal;
                }

            case CoercionKind.Wrap:
                {
                    // Niche-optimized Option[&T]: retype inner pointer as nullable
                    if (IsNicheOption(targetIrType))
                    {
                        innerVal.IrType = targetIrType;
                        return innerVal;
                    }

                    // Wrap T -> Option(T): construct Option struct with has_value=true, value=inner
                    if (targetIrType is IrStruct optionStruct && optionStruct.Fields.Length >= 2)
                    {
                        var resultPtr = new LocalValue($"wrap_{_tempCounter++}", new IrPointer(optionStruct));
                        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, optionStruct.Size, resultPtr));

                        // Store has_value = true
                        var hvField = FindField(optionStruct, "has_value");
                        EmitStoreToOffset(resultPtr, hvField.ByteOffset,
                            new IntConstantValue(1, TypeLayoutService.IrBool), TypeLayoutService.IrBool);

                        // Store value = inner
                        var valField = FindField(optionStruct, "value");
                        EmitStoreToOffset(resultPtr, valField.ByteOffset, innerVal, valField.Type);

                        var loaded = new LocalValue($"wrap_val_{_tempCounter++}", optionStruct);
                        _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, resultPtr, loaded));
                        return loaded;
                    }

                    // Fallback: just return inner with target type
                    innerVal.IrType = targetIrType;
                    return innerVal;
                }

            default:
                return innerVal;
        }
    }

    private LocalValue LowerCoalesce(CoalesceExpressionNode coalesce)
    {
        // Lower as call to op_coalesce if resolved
        var resolved = _checker.GetResolvedOperator(coalesce);
        if (resolved != null)
        {
            var leftVal = LowerExpression(coalesce.Left);
            var rightVal = LowerExpression(coalesce.Right);

            var retIrType = GetIrType(coalesce);

            var calleeIrParamTypes = new List<IrType>();
            foreach (var param in resolved.Function.Parameters)
                calleeIrParamTypes.Add(GetIrType(param));

            return EmitFLangCall(resolved.Function.Name, [leftVal, rightVal], retIrType, calleeIrParamTypes);
        }

        // Inline Option[T] ?? T: if left.has_value then left.value else right
        var leftOption = LowerExpression(coalesce.Left);
        var resultIrType = GetIrType(coalesce);

        // Niche-optimized Option[&T]: ptr != NULL ? ptr : right
        if (IsNicheOption(leftOption.IrType))
            return LowerCoalesceNiche(coalesce, leftOption, resultIrType);

        IrStruct? optionStruct = leftOption.IrType as IrStruct;
        if (optionStruct == null && leftOption.IrType is IrPointer { Pointee: IrStruct s })
            optionStruct = s;

        if (optionStruct == null)
            throw new InternalCompilerError(
                $"Coalesce left operand is not an Option struct: `{leftOption.IrType}`", coalesce.Span);

        // Materialize left to alloca
        Value leftPtr;
        if (leftOption.IrType is IrPointer)
        {
            leftPtr = leftOption;
        }
        else
        {
            leftPtr = new LocalValue($"coal_tmp_{_tempCounter++}", new IrPointer(optionStruct));
            _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, optionStruct.Size, leftPtr));
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, leftPtr, leftOption));
        }

        // Load has_value
        var hvField = FindField(optionStruct, "has_value");
        var hvVal = EmitLoadFromOffset(leftPtr, hvField.ByteOffset, TypeLayoutService.IrBool, "coal_hv");

        // Alloca for result
        var resultPtr = new LocalValue($"coal_result_{_tempCounter++}", new IrPointer(resultIrType));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, resultIrType.Size, resultPtr));

        var thenBlock = CreateBlock("coal_then");
        var elseBlock = CreateBlock("coal_else");
        var mergeBlock = CreateBlock("coal_merge");

        _currentBlock.Instructions.Add(new BranchInstruction(_currentSpan, hvVal, thenBlock, elseBlock));

        // Then: left has value
        _currentFunction.BasicBlocks.Add(thenBlock);
        _currentBlock = thenBlock;

        // Check if result is also Option (Option[T] ?? Option[T] -> Option[T])
        // In that case, store the whole left Option, don't unwrap
        bool resultIsOption = resultIrType is IrStruct resultStruct
            && resultStruct.Name == WellKnown.Option;

        if (resultIsOption)
        {
            // Store entire left Option into result
            var leftLoaded = new LocalValue($"coal_left_{_tempCounter++}", optionStruct);
            _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, leftPtr, leftLoaded));
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, resultPtr, leftLoaded));
        }
        else
        {
            // Unwrap: store left.value into result
            var valField = FindField(optionStruct, "value");
            var valLoaded = EmitLoadFromOffset(leftPtr, valField.ByteOffset, valField.Type, "coal_val");
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, resultPtr, valLoaded));
        }
        _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, mergeBlock));

        // Else: right
        _currentFunction.BasicBlocks.Add(elseBlock);
        _currentBlock = elseBlock;
        var rightVal2 = LowerExpression(coalesce.Right);
        _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, resultPtr, rightVal2));
        _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, mergeBlock));

        // Merge
        _currentFunction.BasicBlocks.Add(mergeBlock);
        _currentBlock = mergeBlock;
        var finalResult = new LocalValue($"coal_final_{_tempCounter++}", resultIrType);
        _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, resultPtr, finalResult));
        return finalResult;
    }

    private LocalValue LowerCoalesceNiche(CoalesceExpressionNode coalesce, Value leftOption, IrType resultIrType)
    {
        var nichePtr = (IrPointer)leftOption.IrType!;
        var nullVal = new IntConstantValue(0, nichePtr);
        var isNonNull = new LocalValue($"coal_niche_{_tempCounter++}", TypeLayoutService.IrBool);
        _currentBlock.Instructions.Add(new BinaryInstruction(_currentSpan, BinaryOp.NotEqual, leftOption, nullVal, isNonNull));

        var resultPtr = new LocalValue($"coal_result_{_tempCounter++}", new IrPointer(resultIrType));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, resultIrType.Size, resultPtr));

        var thenBlock = CreateBlock("coal_niche_then");
        var elseBlock = CreateBlock("coal_niche_else");
        var mergeBlock = CreateBlock("coal_niche_merge");
        _currentBlock.Instructions.Add(new BranchInstruction(_currentSpan, isNonNull, thenBlock, elseBlock));

        // Then: use the pointer (strip nullable if result is non-option)
        _currentFunction.BasicBlocks.Add(thenBlock);
        _currentBlock = thenBlock;
        if (IsNicheOption(resultIrType))
        {
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, resultPtr, leftOption));
        }
        else
        {
            var stripped = StripNullable(nichePtr);
            var castResult = new LocalValue($"coal_strip_{_tempCounter++}", stripped);
            _currentBlock.Instructions.Add(new CastInstruction(_currentSpan, leftOption, castResult));
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, resultPtr, castResult));
        }
        _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, mergeBlock));

        // Else: evaluate right
        _currentFunction.BasicBlocks.Add(elseBlock);
        _currentBlock = elseBlock;
        var rightVal = LowerExpression(coalesce.Right);
        _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, resultPtr, rightVal));
        _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, mergeBlock));

        // Merge
        _currentFunction.BasicBlocks.Add(mergeBlock);
        _currentBlock = mergeBlock;
        var finalResult = new LocalValue($"coal_niche_final_{_tempCounter++}", resultIrType);
        _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, resultPtr, finalResult));
        return finalResult;
    }

    private LocalValue LowerNullPropagation(NullPropagationExpressionNode nullProp)
    {
        // target?.field
        // if target.has_value: Some(target.value.field) else: null
        var targetVal = LowerExpression(nullProp.Target);

        var resultIrType = GetIrType(nullProp);

        // Niche-optimized Option[&T]: ptr != NULL ? ptr.field : null
        if (IsNicheOption(targetVal.IrType))
            return LowerNullPropagationNiche(nullProp, targetVal, resultIrType);

        // Get the target's Option type
        var targetIrType = targetVal.IrType;
        IrStruct? optionStruct = targetIrType as IrStruct;
        if (optionStruct == null && targetIrType is IrPointer { Pointee: IrStruct s })
            optionStruct = s;

        if (optionStruct == null)
            throw new InternalCompilerError(
                $"Null propagation target is not an Option type: `{targetIrType}`", nullProp.Span);

        // Materialize target to alloca if not already a pointer
        Value targetPtr;
        if (targetIrType is IrPointer)
        {
            targetPtr = targetVal;
        }
        else
        {
            targetPtr = new LocalValue($"np_tmp_{_tempCounter++}", new IrPointer(optionStruct));
            _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, optionStruct.Size, targetPtr));
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, targetPtr, targetVal));
        }

        // Load has_value field
        var hvField = FindField(optionStruct, "has_value");
        var hvVal = EmitLoadFromOffset(targetPtr, hvField.ByteOffset, TypeLayoutService.IrBool, "np_hv");

        // Branch on has_value
        var thenBlock = CreateBlock("np_then");
        var elseBlock = CreateBlock("np_else");
        var mergeBlock = CreateBlock("np_merge");

        // Alloca for result
        var resultPtr = new LocalValue($"np_result_{_tempCounter++}", new IrPointer(resultIrType));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, resultIrType.Size, resultPtr));
        _currentBlock.Instructions.Add(new BranchInstruction(_currentSpan, hvVal, thenBlock, elseBlock));

        // Then: access target.value.field, wrap in new Option
        _currentFunction.BasicBlocks.Add(thenBlock);
        _currentBlock = thenBlock;

        // GEP to value field
        var valField = FindField(optionStruct, "value");
        var valPtr = new LocalValue($"np_val_ptr_{_tempCounter++}", new IrPointer(valField.Type));
        _currentBlock.Instructions.Add(new GetElementPtrInstruction(_currentSpan, targetPtr, valField.ByteOffset, valPtr));

        // Access the member on value
        var innerStruct = (IrStruct)valField.Type;
        var memberField = FindField(innerStruct, nullProp.MemberName);
        var memberVal = EmitLoadFromOffset(valPtr, memberField.ByteOffset, memberField.Type, "np_member");

        // Wrap in Option if result is Option type
        if (resultIrType is IrStruct resultOptionStruct && resultOptionStruct.Fields.Length >= 2)
        {
            var somePtr = new LocalValue($"np_some_{_tempCounter++}", new IrPointer(resultOptionStruct));
            _currentBlock.Instructions.Add(
                new AllocaInstruction(_currentSpan, resultOptionStruct.Size, somePtr));

            var someHvField = FindField(resultOptionStruct, "has_value");
            EmitStoreToOffset(somePtr, someHvField.ByteOffset,
                new IntConstantValue(1, TypeLayoutService.IrBool), TypeLayoutService.IrBool);

            var someValField = FindField(resultOptionStruct, "value");
            EmitStoreToOffset(somePtr, someValField.ByteOffset, memberVal, someValField.Type);

            var someLoaded = new LocalValue($"np_some_val_{_tempCounter++}", resultOptionStruct);
            _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, somePtr, someLoaded));
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, resultPtr, someLoaded));
        }
        else
        {
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, resultPtr, memberVal));
        }
        _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, mergeBlock));

        // Else: return null Option
        _currentFunction.BasicBlocks.Add(elseBlock);
        _currentBlock = elseBlock;
        if (resultIrType is IrStruct nullOptionStruct)
        {
            var nullPtr = new LocalValue($"np_null_{_tempCounter++}", new IrPointer(nullOptionStruct));
            _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, nullOptionStruct.Size, nullPtr));

            var nullHvField = FindField(nullOptionStruct, "has_value");
            EmitStoreToOffset(nullPtr, nullHvField.ByteOffset,
                new IntConstantValue(0, TypeLayoutService.IrBool), TypeLayoutService.IrBool);

            var nullLoaded = new LocalValue($"np_null_val_{_tempCounter++}", nullOptionStruct);
            _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, nullPtr, nullLoaded));
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, resultPtr, nullLoaded));
        }
        _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, mergeBlock));

        // Merge
        _currentFunction.BasicBlocks.Add(mergeBlock);
        _currentBlock = mergeBlock;

        var finalResult = new LocalValue($"np_final_{_tempCounter++}", resultIrType);
        _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, resultPtr, finalResult));
        return finalResult;
    }

    private LocalValue LowerNullPropagationNiche(NullPropagationExpressionNode nullProp, Value targetVal, IrType resultIrType)
    {
        var nichePtr = (IrPointer)targetVal.IrType!;
        var nullVal = new IntConstantValue(0, nichePtr);
        var isNonNull = new LocalValue($"np_niche_{_tempCounter++}", TypeLayoutService.IrBool);
        _currentBlock.Instructions.Add(new BinaryInstruction(_currentSpan, BinaryOp.NotEqual, targetVal, nullVal, isNonNull));

        var resultPtr = new LocalValue($"np_result_{_tempCounter++}", new IrPointer(resultIrType));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, resultIrType.Size, resultPtr));

        var thenBlock = CreateBlock("np_niche_then");
        var elseBlock = CreateBlock("np_niche_else");
        var mergeBlock = CreateBlock("np_niche_merge");
        _currentBlock.Instructions.Add(new BranchInstruction(_currentSpan, isNonNull, thenBlock, elseBlock));

        // Then: dereference the pointer, access field, wrap result
        _currentFunction.BasicBlocks.Add(thenBlock);
        _currentBlock = thenBlock;
        var strippedPtr = StripNullable(nichePtr);
        var castVal = new LocalValue($"np_strip_{_tempCounter++}", strippedPtr);
        _currentBlock.Instructions.Add(new CastInstruction(_currentSpan, targetVal, castVal));

        var innerType = strippedPtr.Pointee;
        if (innerType is IrStruct innerStruct)
        {
            var memberField = FindField(innerStruct, nullProp.MemberName);
            var memberVal = EmitLoadFromOffset(castVal, memberField.ByteOffset, memberField.Type, "np_member");

            if (IsNicheOption(resultIrType))
            {
                memberVal.IrType = resultIrType;
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, resultPtr, memberVal));
            }
            else if (resultIrType is IrStruct resultOptionStruct && resultOptionStruct.Fields.Length >= 2)
            {
                var somePtr = new LocalValue($"np_some_{_tempCounter++}", new IrPointer(resultOptionStruct));
                _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, resultOptionStruct.Size, somePtr));

                var someHvField = FindField(resultOptionStruct, "has_value");
                EmitStoreToOffset(somePtr, someHvField.ByteOffset,
                    new IntConstantValue(1, TypeLayoutService.IrBool), TypeLayoutService.IrBool);

                var someValField = FindField(resultOptionStruct, "value");
                EmitStoreToOffset(somePtr, someValField.ByteOffset, memberVal, someValField.Type);

                var someLoaded = new LocalValue($"np_some_val_{_tempCounter++}", resultOptionStruct);
                _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, somePtr, someLoaded));
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, resultPtr, someLoaded));
            }
            else
            {
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, resultPtr, memberVal));
            }
        }
        _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, mergeBlock));

        // Else: return null
        _currentFunction.BasicBlocks.Add(elseBlock);
        _currentBlock = elseBlock;
        if (IsNicheOption(resultIrType))
        {
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, resultPtr,
                new IntConstantValue(0, resultIrType)));
        }
        else if (resultIrType is IrStruct nullOptionStruct)
        {
            var nullPtr2 = new LocalValue($"np_null_{_tempCounter++}", new IrPointer(nullOptionStruct));
            _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, nullOptionStruct.Size, nullPtr2));

            var nullHvField = FindField(nullOptionStruct, "has_value");
            EmitStoreToOffset(nullPtr2, nullHvField.ByteOffset,
                new IntConstantValue(0, TypeLayoutService.IrBool), TypeLayoutService.IrBool);

            var nullLoaded = new LocalValue($"np_null_val_{_tempCounter++}", nullOptionStruct);
            _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, nullPtr2, nullLoaded));
            _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, resultPtr, nullLoaded));
        }
        _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, mergeBlock));

        // Merge
        _currentFunction.BasicBlocks.Add(mergeBlock);
        _currentBlock = mergeBlock;
        var finalResult = new LocalValue($"np_niche_final_{_tempCounter++}", resultIrType);
        _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, resultPtr, finalResult));
        return finalResult;
    }

    // =========================================================================
    // Enum variant construction
    // =========================================================================

    /// <summary>
    /// Detect whether a CallExpressionNode is an enum variant construction.
    /// Variant constructors have no ResolvedTarget (they're scope-bound types,
    /// not function declarations) and their inferred type resolves to an IrEnum.
    /// </summary>
    private bool IsVariantConstruction(CallExpressionNode call)
    {
        if (call.ResolvedTarget != null || call.IsIndirectCall) return false;
        var hmType = _checker.GetInferredType(call);
        var irType = _layout.Lower(hmType);
        return irType is IrEnum;
    }

    private Value LowerEnumConstruction(CallExpressionNode call)
    {
        var irEnum = (IrEnum)GetIrType(call);

        // Parse variant name: may be "EnumName.VariantName" or just "VariantName"
        var lookupName = call.MethodName ?? call.FunctionName;
        string variantName;
        if (lookupName.Contains('.'))
        {
            var parts = lookupName.Split('.');
            variantName = parts[1];
        }
        else
        {
            variantName = lookupName;
        }

        // Find the IrVariant
        IrVariant? foundVariant = null;
        foreach (var v in irEnum.Variants)
        {
            if (v.Name == variantName)
            {
                foundVariant = v;
                break;
            }
        }

        if (foundVariant == null)
        {
            var suggestion = StringDistance.FindClosestMatch(variantName, irEnum.Variants.Select(v => v.Name));
            var hint = suggestion != null ? $"did you mean `{suggestion}`?" : null;
            _diagnostics.Add(Diagnostic.Error(
                $"Variant `{variantName}` not found in enum `{irEnum.Name}`",
                call.Span, hint, "E3037"));
            return new IntConstantValue(0, irEnum);
        }

        var variant = foundVariant.Value;

        // 1. Alloca enum-sized storage
        var enumPtr = new LocalValue($"enum_{_tempCounter++}", new IrPointer(irEnum));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, irEnum.Size, enumPtr));

        // 2. Store tag value (offset 0) as i32
        EmitStoreToOffset(enumPtr, 0, new IntConstantValue(variant.TagValue, TypeLayoutService.IrI32), TypeLayoutService.IrI32);

        // 3. If variant has payload, store payload data
        if (variant.PayloadType != null)
        {
            if (variant.PayloadType is IrStruct payloadStruct
                && payloadStruct.Name.StartsWith("__tuple_")
                && call.Arguments.Count > 1)
            {
                // Multi-payload (synthetic tuple): each arg maps to a field in the payload struct
                for (int i = 0; i < call.Arguments.Count && i < payloadStruct.Fields.Length; i++)
                {
                    var argVal = LowerExpression(call.Arguments[i]);
                    var fieldOffset = variant.PayloadOffset + payloadStruct.Fields[i].ByteOffset;
                    EmitStoreToOffset(enumPtr, fieldOffset, argVal, payloadStruct.Fields[i].Type);
                }
            }
            else
            {
                // Single payload
                var argVal = LowerExpression(call.Arguments[0]);
                EmitStoreToOffset(enumPtr, variant.PayloadOffset, argVal, variant.PayloadType);
            }
        }

        // 4. Load the complete enum value
        var enumResult = new LocalValue($"enum_val_{_tempCounter++}", irEnum);
        _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, enumPtr, enumResult));
        return enumResult;
    }

    // =========================================================================
    // Match expression lowering
    // =========================================================================

    private Value LowerMatch(MatchExpressionNode match)
    {
        // 1. Lower scrutinee and resolve to enum type
        var scrutineeValue = LowerExpression(match.Scrutinee);
        var scrutineeHmType = _checker.GetInferredType(match.Scrutinee);
        var scrutineeIrType = _layout.Lower(scrutineeHmType);

        // Dereference if scrutinee is a pointer/reference to get the enum value
        if (scrutineeIrType is IrPointer ptrType && ptrType.Pointee is IrEnum)
        {
            var derefVal = new LocalValue($"match_deref_{_tempCounter++}", ptrType.Pointee);
            _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, scrutineeValue, derefVal));
            scrutineeValue = derefVal;
            scrutineeIrType = ptrType.Pointee;
        }

        var irEnum = scrutineeIrType as IrEnum;
        if (irEnum == null)
        {
            _diagnostics.Add(Diagnostic.Error(
                "Match scrutinee is not an enum type", match.Span, null, "E3038"));
            return new IntConstantValue(0, TypeLayoutService.IrVoidPrim);
        }

        var resultIrType = GetIrType(match);
        var isVoid = resultIrType == TypeLayoutService.IrVoidPrim;

        // 2. Store scrutinee to alloca (need addressable for GEP)
        var scrutineePtr = new LocalValue($"match_scrutinee_ptr_{_tempCounter++}", new IrPointer(irEnum));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, irEnum.Size, scrutineePtr));
        _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, scrutineePtr, scrutineeValue));

        // 3. Extract tag: load i32 at offset 0
        var tagValue = EmitLoadFromOffset(scrutineePtr, 0, TypeLayoutService.IrI32, "match_tag");

        // 4. Alloca result (phi-via-alloca pattern)
        Value? resultPtr = null;
        if (!isVoid)
        {
            resultPtr = new LocalValue($"match_result_ptr_{_tempCounter++}", new IrPointer(resultIrType));
            _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, resultIrType.Size, resultPtr));
        }

        // 5. Create basic blocks
        var armBlocks = new List<BasicBlock>();
        for (int i = 0; i < match.Arms.Count; i++)
            armBlocks.Add(CreateBlock($"match_arm_{i}"));

        var checkBlocks = new List<BasicBlock>();
        for (int i = 0; i < match.Arms.Count - 1; i++)
            checkBlocks.Add(CreateBlock($"match_check_{i}"));

        var mergeBlock = CreateBlock("match_merge");

        // 6. For each arm: emit check + arm body
        for (int armIndex = 0; armIndex < match.Arms.Count; armIndex++)
        {
            var arm = match.Arms[armIndex];
            var armBlock = armBlocks[armIndex];

            // First arm uses current block for check, others use their check block
            var checkBlock = armIndex == 0 ? _currentBlock : checkBlocks[armIndex - 1];
            _currentBlock = checkBlock;

            // Emit condition check
            if (arm.Pattern is ElsePatternNode or WildcardPatternNode)
            {
                // Unconditional match
                _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, armBlock));
            }
            else if (arm.Pattern is VariablePatternNode)
            {
                // Variable pattern: matches everything (binds whole scrutinee)
                _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, armBlock));
            }
            else if (arm.Pattern is EnumVariantPatternNode evpCheck)
            {
                // Find variant and compare tag
                IrVariant? checkVariant = null;
                foreach (var v in irEnum.Variants)
                {
                    if (v.Name == evpCheck.VariantName)
                    {
                        checkVariant = v;
                        break;
                    }
                }

                if (checkVariant != null)
                {
                    var expectedTag = new IntConstantValue(checkVariant.Value.TagValue, TypeLayoutService.IrI32);
                    var cmpResult = new LocalValue($"match_cmp_{_tempCounter++}", TypeLayoutService.IrBool);
                    _currentBlock.Instructions.Add(
                        new BinaryInstruction(_currentSpan, BinaryOp.Equal, tagValue, expectedTag, cmpResult));

                    var elseTarget = armIndex < match.Arms.Count - 1
                        ? checkBlocks[armIndex]
                        : mergeBlock;
                    _currentBlock.Instructions.Add(new BranchInstruction(_currentSpan, cmpResult, armBlock, elseTarget));
                }
                else
                {
                    // Unknown variant — unconditional jump (error already caught in TC)
                    _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, armBlock));
                }
            }

            // Add check block to function (skip first arm, it reuses current block)
            if (armIndex > 0)
                _currentFunction.BasicBlocks.Add(checkBlock);

            // Fill in arm block
            _currentFunction.BasicBlocks.Add(armBlock);
            _currentBlock = armBlock;

            // Bind pattern variables
            if (arm.Pattern is EnumVariantPatternNode evp)
            {
                IrVariant? armVariant = null;
                foreach (var v in irEnum.Variants)
                {
                    if (v.Name == evp.VariantName)
                    {
                        armVariant = v;
                        break;
                    }
                }

                if (armVariant != null && armVariant.Value.PayloadType != null)
                {
                    if (armVariant.Value.PayloadType is IrStruct payloadStruct
                        && payloadStruct.Name.StartsWith("__tuple_")
                        && payloadStruct.Fields.Length > 1)
                    {
                        // Multi-payload (synthetic tuple): bind each sub-pattern to its payload field
                        for (int i = 0; i < evp.SubPatterns.Count && i < payloadStruct.Fields.Length; i++)
                        {
                            if (evp.SubPatterns[i] is VariablePatternNode vp)
                            {
                                var fieldOffset = armVariant.Value.PayloadOffset
                                                  + payloadStruct.Fields[i].ByteOffset;
                                var fieldPtr = new LocalValue(
                                    $"payload_field_{_tempCounter++}",
                                    new IrPointer(payloadStruct.Fields[i].Type));
                                _currentBlock.Instructions.Add(
                                    new GetElementPtrInstruction(_currentSpan, scrutineePtr, fieldOffset, fieldPtr));
                                _locals[vp.Name] = fieldPtr;
                            }
                        }
                    }
                    else if (evp.SubPatterns.Count > 0 && evp.SubPatterns[0] is VariablePatternNode vp)
                    {
                        // Single payload
                        var payloadPtr = new LocalValue(
                            $"payload_{_tempCounter++}",
                            new IrPointer(armVariant.Value.PayloadType));
                        _currentBlock.Instructions.Add(
                            new GetElementPtrInstruction(_currentSpan,
                                scrutineePtr, armVariant.Value.PayloadOffset, payloadPtr));
                        _locals[vp.Name] = payloadPtr;
                    }
                }
            }
            else if (arm.Pattern is VariablePatternNode varPat)
            {
                // Bind entire scrutinee to variable
                _locals[varPat.Name] = scrutineePtr;
            }

            // Lower arm result expression
            var armResultVal = LowerExpression(arm.ResultExpr, isVoid ? null : resultIrType);
            if (!isVoid && resultPtr != null)
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, resultPtr, armResultVal));

            // Jump to merge
            if (_currentBlock.Instructions.Count == 0 ||
                _currentBlock.Instructions[^1] is not (ReturnInstruction or JumpInstruction or BranchInstruction))
            {
                _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, mergeBlock));
            }
        }

        // 7. Merge block
        _currentFunction.BasicBlocks.Add(mergeBlock);
        _currentBlock = mergeBlock;

        if (!isVoid && resultPtr != null)
        {
            var finalResult = new LocalValue($"match_result_{_tempCounter++}", resultIrType);
            _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, resultPtr, finalResult));
            return finalResult;
        }

        return new IntConstantValue(0, TypeLayoutService.IrVoidPrim);
    }

    // =========================================================================
    // Lambda lowering
    // =========================================================================

    private FunctionReferenceValue LowerLambda(LambdaExpressionNode lambda)
    {
        if (lambda.SynthesizedFunction == null)
            throw new InternalCompilerError(
                "Lambda has no synthesized function", lambda.Span);

        var irType = GetIrType(lambda);
        return new FunctionReferenceValue(lambda.SynthesizedFunction.Name, irType);
    }

    // =========================================================================
    // Parameter mutation pre-scan
    // =========================================================================

    /// <summary>
    /// Scans the function body for assignments to parameters and eagerly creates
    /// allocas for them. This ensures all reads (including those in loop conditions
    /// textually before the assignment) go through the alloca, not the original param.
    /// </summary>
    private void PromoteMutatedParameters(IReadOnlyList<StatementNode> body)
    {
        var mutated = new HashSet<string>();
        CollectMutatedParams(body, mutated);

        foreach (var name in mutated)
        {
            if (!_parameters.Contains(name) || !_locals.TryGetValue(name, out var localVal))
                continue;

            if (_byRefParams.Contains(name))
            {
                var innerType = ((IrPointer)localVal.IrType!).Pointee;
                var alloca = new LocalValue($"{name}_mut", new IrPointer(innerType));
                var tmpLoad = new LocalValue($"t{_tempCounter++}", innerType);
                _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, innerType.Size, alloca));
                _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, localVal, tmpLoad));
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, alloca, tmpLoad));
                _locals[name] = alloca;
                _parameters.Remove(name);
                _byRefParams.Remove(name);
            }
            else
            {
                var paramIrType = localVal.IrType ?? TypeLayoutService.IrVoidPrim;
                var allocaP = new LocalValue($"{name}_mut", new IrPointer(paramIrType));
                _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, paramIrType.Size, allocaP));
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, allocaP, localVal));
                _locals[name] = allocaP;
                _parameters.Remove(name);
            }
        }
    }

    private void CollectMutatedParams(IReadOnlyList<StatementNode> stmts, HashSet<string> mutated)
    {
        foreach (var stmt in stmts)
            CollectMutatedParamsStmt(stmt, mutated);
    }

    private void CollectMutatedParamsStmt(StatementNode stmt, HashSet<string> mutated)
    {
        switch (stmt)
        {
            case ExpressionStatementNode es:
                CollectMutatedParamsExpr(es.Expression, mutated);
                break;
            case ReturnStatementNode ret:
                if (ret.Expression != null) CollectMutatedParamsExpr(ret.Expression, mutated);
                break;
            case VariableDeclarationNode vd:
                if (vd.Initializer != null) CollectMutatedParamsExpr(vd.Initializer, mutated);
                break;
            case LoopNode loop:
                CollectMutatedParamsExpr(loop.Body, mutated);
                break;
            case ForLoopNode forLoop:
                CollectMutatedParamsExpr(forLoop.Body, mutated);
                break;
            case DeferStatementNode defer:
                CollectMutatedParamsExpr(defer.Expression, mutated);
                break;
        }
    }

    private void CollectMutatedParamsExpr(ExpressionNode expr, HashSet<string> mutated)
    {
        switch (expr)
        {
            case AssignmentExpressionNode assign:
                if (assign.Target is IdentifierExpressionNode id && _parameters.Contains(id.Name))
                    mutated.Add(id.Name);
                CollectMutatedParamsExpr(assign.Value, mutated);
                break;
            case IfExpressionNode ifExpr:
                CollectMutatedParamsExpr(ifExpr.Condition, mutated);
                CollectMutatedParamsExpr(ifExpr.ThenBranch, mutated);
                if (ifExpr.ElseBranch != null) CollectMutatedParamsExpr(ifExpr.ElseBranch, mutated);
                break;
            case BlockExpressionNode block:
                CollectMutatedParams(block.Statements, mutated);
                if (block.TrailingExpression != null) CollectMutatedParamsExpr(block.TrailingExpression, mutated);
                break;
            case MatchExpressionNode match:
                foreach (var arm in match.Arms)
                    CollectMutatedParamsExpr(arm.ResultExpr, mutated);
                break;
        }
    }

    // =========================================================================
    // LValue lowering — returns a pointer to the assignable location
    // =========================================================================

    /// <summary>
    /// Returns a pointer Value for an assignable expression (lvalue).
    /// Returns null if the expression cannot be assigned to.
    /// </summary>
    private Value? LowerLValue(ExpressionNode expr)
    {
        switch (expr)
        {
            case IdentifierExpressionNode id:
                {
                    if (_locals.TryGetValue(id.Name, out var localVal))
                    {
                        // For parameters, we need to create an alloca to make them assignable.
                        // Insert at the START of the entry block so it's visible in all branches
                        // and doesn't appear after branch instructions.
                        if (_parameters.Contains(id.Name))
                        {
                            if (_byRefParams.Contains(id.Name))
                            {
                                // By-ref param: load from pointer, then store into alloca (copy-on-write)
                                var innerType = ((IrPointer)localVal.IrType!).Pointee;
                                var alloca = new LocalValue($"{id.Name}_mut", new IrPointer(innerType));
                                var tmpLoad = new LocalValue($"t{_tempCounter++}", innerType);
                                var entryBlock = _currentFunction.BasicBlocks[0];
                                entryBlock.Instructions.Insert(0, new StorePointerInstruction(_currentSpan, alloca, tmpLoad));
                                entryBlock.Instructions.Insert(0, new LoadInstruction(_currentSpan, localVal, tmpLoad));
                                entryBlock.Instructions.Insert(0, new AllocaInstruction(_currentSpan, innerType.Size, alloca));
                                _locals[id.Name] = alloca;
                                _parameters.Remove(id.Name);
                                _byRefParams.Remove(id.Name);
                                return alloca;
                            }
                            var paramIrType = localVal.IrType ?? TypeLayoutService.IrVoidPrim;
                            var allocaP = new LocalValue($"{id.Name}_mut", new IrPointer(paramIrType));
                            var entryBlockP = _currentFunction.BasicBlocks[0];
                            entryBlockP.Instructions.Insert(0, new StorePointerInstruction(_currentSpan, allocaP, localVal));
                            entryBlockP.Instructions.Insert(0, new AllocaInstruction(_currentSpan, paramIrType.Size, allocaP));
                            _locals[id.Name] = allocaP;
                            _parameters.Remove(id.Name);
                            return allocaP;
                        }
                        return localVal; // Already an alloca pointer
                    }
                    _diagnostics.Add(Diagnostic.Error(
                        $"Cannot assign to unresolved identifier `{id.Name}`", id.Span, null, "E3003"));
                    return null;
                }

            case MemberAccessExpressionNode member:
                {
                    // For LValue member access, get a POINTER to the target (not the loaded value).
                    // LowerLValue returns the alloca/pointer for locals; LowerExpression would
                    // load the value, making GEP impossible (can't take address of a value in C).
                    var targetVal = LowerLValue(member.Target) ?? LowerExpression(member.Target);
                    var targetIrType = targetVal.IrType;

                    // Auto-dereference — for LValue, keep ONE pointer level so GEP
                    // can produce a writable pointer to the field. If we dereference
                    // fully, we'd get a local value copy that can't be written through.
                    var baseVal = targetVal;
                    var baseIrType = targetIrType;
                    var derefCount = member.AutoDerefCount;
                    // If fully dereffing would leave us with a value (not pointer), do one less
                    if (derefCount > 0 && baseIrType is IrPointer)
                    {
                        // Count how many pointer layers we have
                        var ptrDepth = 0;
                        var t = baseIrType;
                        while (t is IrPointer pp) { ptrDepth++; t = pp.Pointee; }
                        // Deref enough times to still have a pointer to the struct
                        var maxDeref = Math.Min(derefCount, ptrDepth - 1);
                        for (int i = 0; i < maxDeref; i++)
                        {
                            if (baseIrType is IrPointer ptrType)
                            {
                                var derefResult = new LocalValue($"autoderef_{_tempCounter++}", ptrType.Pointee);
                                _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, baseVal, derefResult));
                                baseVal = derefResult;
                                baseIrType = ptrType.Pointee;
                            }
                        }
                    }

                    // Niche-optimized Option[&T]: .value lvalue is the pointer itself.
                    // Only applies to Option-specific fields (value/has_value), not to
                    // struct fields accessed through a nullable pointer after unwrap.
                    // Check both direct niche option (from LowerExpression fallback) and
                    // pointer-to-niche-option (from LowerLValue, which adds an extra indirection).
                    if (member.FieldName is "value" or "has_value")
                    {
                        var isNiche = IsNicheOption(baseIrType);
                        var isNicheViaPtr = !isNiche
                            && baseIrType is IrPointer { Pointee: var innerPt }
                            && IsNicheOption(innerPt);
                        if (isNiche || isNicheViaPtr)
                        {
                            if (member.FieldName == "has_value")
                            {
                                _diagnostics.Add(Diagnostic.Error(
                                    "Cannot assign to `has_value` on niche-optimized Option", member.Span, null, "E3005"));
                                return null;
                            }
                            // .value — the nullable pointer IS the value; return the lvalue holding it
                            return baseVal;
                        }
                    }

                    IrStruct? structType = baseIrType switch
                    {
                        IrStruct s => s,
                        IrPointer { Pointee: IrStruct s } => s,
                        _ => null
                    };

                    if (structType == null)
                        throw new InternalCompilerError(
                            $"Cannot assign to member on non-struct type `{baseIrType}`", member.Span);

                    var field = FindField(structType, member.FieldName);

                    // Return pointer to field (GEP without final load)
                    var gepResult = new LocalValue($"field_ptr_{_tempCounter++}", new IrPointer(field.Type));
                    _currentBlock.Instructions.Add(
                        new GetElementPtrInstruction(_currentSpan, baseVal, field.ByteOffset, gepResult));
                    return gepResult;
                }

            case DereferenceExpressionNode deref:
                {
                    // Dereferencing gives us the pointer itself — it's already an lvalue
                    return LowerExpression(deref.Target);
                }

            case IndexExpressionNode index:
                {
                    var arrVal = LowerExpression(index.Base);
                    var idxVal = LowerExpression(index.Index);

                    // If base is a Slice struct, extract .ptr for pointer arithmetic
                    var basePtr = arrVal;
                    if (arrVal.IrType is IrStruct sliceBase2)
                    {
                        var ptrField2 = sliceBase2.Fields.FirstOrDefault(f => f.Name == "ptr");
                        if (ptrField2.Type != null)
                            basePtr = CoerceSliceToPointer(arrVal, sliceBase2, ptrField2);
                    }

                    var elementIrType = GetIrType(index);

                    // Compute byte offset = index * element_size
                    var elementSize = new IntConstantValue(elementIrType.Size, TypeLayoutService.IrUSize);
                    var byteOffset = new LocalValue($"idx_offset_{_tempCounter++}", TypeLayoutService.IrUSize);
                    _currentBlock.Instructions.Add(
                        new BinaryInstruction(_currentSpan, BinaryOp.Multiply, idxVal, elementSize, byteOffset));

                    var elemPtr = new LocalValue($"elem_ptr_{_tempCounter++}", new IrPointer(elementIrType));
                    _currentBlock.Instructions.Add(new GetElementPtrInstruction(_currentSpan, basePtr, byteOffset, elemPtr));
                    return elemPtr;
                }

            default:
                _diagnostics.Add(Diagnostic.Error(
                    $"Expression is not assignable: {expr.GetType().Name}",
                    expr.Span, null, "E3005"));
                return null;
        }
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// <summary>
    /// Get the lowered IR type for an AST node: resolves the inferred HM type and lowers to IrType.
    /// </summary>
    private IrType GetIrType(AstNode node) => _layout.Lower(_checker.GetInferredType(node));

    private FunctionType GetFunctionHmType(FunctionDeclarationNode fn)
    {
        var scheme = _checker.GetInferredType(fn);
        return (FunctionType)_engine.Resolve(scheme);
    }

    private BasicBlock CreateBlock(string label)
    {
        return new BasicBlock($"{label}_{_blockCounter++}");
    }

    private string GetUniqueVariableName(string sourceName)
    {
        if (!_shadowCounter.TryGetValue(sourceName, out var count))
        {
            _shadowCounter[sourceName] = 0;
            return sourceName;
        }

        _shadowCounter[sourceName] = count + 1;
        return $"{sourceName}__shadow{count + 1}";
    }

    private BinaryOp MapBinaryOp(BinaryOperatorKind kind)
    {
        return kind switch
        {
            BinaryOperatorKind.Add => BinaryOp.Add,
            BinaryOperatorKind.Subtract => BinaryOp.Subtract,
            BinaryOperatorKind.Multiply => BinaryOp.Multiply,
            BinaryOperatorKind.Divide => BinaryOp.Divide,
            BinaryOperatorKind.Modulo => BinaryOp.Modulo,
            BinaryOperatorKind.Equal => BinaryOp.Equal,
            BinaryOperatorKind.NotEqual => BinaryOp.NotEqual,
            BinaryOperatorKind.LessThan => BinaryOp.LessThan,
            BinaryOperatorKind.GreaterThan => BinaryOp.GreaterThan,
            BinaryOperatorKind.LessThanOrEqual => BinaryOp.LessThanOrEqual,
            BinaryOperatorKind.GreaterThanOrEqual => BinaryOp.GreaterThanOrEqual,
            BinaryOperatorKind.BitwiseAnd => BinaryOp.BitwiseAnd,
            BinaryOperatorKind.BitwiseOr => BinaryOp.BitwiseOr,
            BinaryOperatorKind.BitwiseXor => BinaryOp.BitwiseXor,
            BinaryOperatorKind.ShiftLeft => BinaryOp.ShiftLeft,
            BinaryOperatorKind.ShiftRight => BinaryOp.ShiftRight,
            BinaryOperatorKind.UnsignedShiftRight => BinaryOp.UnsignedShiftRight,
            _ => throw new InternalCompilerError($"Unsupported binary operator: {kind}", _currentSpan),
        };
    }

    private IrField FindField(IrStruct structType, string fieldName)
    {
        foreach (var f in structType.Fields)
        {
            if (f.Name == fieldName)
                return f;
        }
        throw new InternalCompilerError(
            $"Field `{fieldName}` not found in struct `{structType.Name}`", _currentSpan);
    }

    // =========================================================================
    // IrType-based name mangling (delegates to FLang.IR.IrNameMangling)
    // =========================================================================

    public static string MangleFunctionName(string baseName, IReadOnlyList<IrType> paramTypes)
        => IrNameMangling.MangleFunctionName(baseName, paramTypes);

    public static string MangleIrType(IrType type)
        => IrNameMangling.MangleIrType(type);
}
