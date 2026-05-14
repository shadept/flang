using System.Text;
using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend;
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
    private readonly TypeCheckResult _types;
    private readonly TypeLayoutService _layout;
    private readonly Compilation _compilation;
    private readonly IrModule _module = new();
    private readonly List<Diagnostic> _diagnostics = [];

    // Per-function state
    private readonly Dictionary<string, Value> _locals = [];
    private readonly HashSet<string> _parameters = [];
    private readonly HashSet<string> _byRefParams = [];
    private readonly Dictionary<string, int> _shadowCounter = [];
    private BasicBlock _currentBlock = null!;
    private IrFunction _currentFunction = null!;
    private BlockBuildContext _ctx = null!;
    private readonly Dictionary<string, int> _stringTableIndices = [];

    // Loop control flow. `DeferDepthAtEntry` is the defer-stack count when the
    // loop body was entered, used by `break`/`continue` to fire only the defers
    // belonging to scopes they escape.
    private readonly Stack<(BasicBlock BodyBlock, BasicBlock ExitBlock, int DeferDepthAtEntry)> _loopStack = new();

    // Defer stack — per-function, stores deferred expressions in LIFO order.
    // `_deferScopeMarks` records the defer-stack count at each block-scope
    // entry, so a scope exit knows which defers to emit and pop.
    private readonly Stack<ExpressionNode> _deferStack = new();
    private readonly Stack<int> _deferScopeMarks = new();

    // Global constants — name -> lowered Value
    private readonly Dictionary<string, Value> _globalConstants = [];

    // Type table — maps type cache key -> GlobalValue for Type(T) RTTI
    private Dictionary<string, GlobalValue>? _typeTableGlobals;

    // Project info table — one GlobalValue per project participating in this
    // compilation (the consuming project + each direct dep + a `stdlib` fallback).
    // Populated lazily the first time a call to `project_info()` is lowered.
    private Dictionary<string, GlobalValue>? _projectInfoGlobals;

    public IReadOnlyList<Diagnostic> Diagnostics => _diagnostics;

    public HmAstLowering(TypeCheckResult types, TypeLayoutService layout, Compilation compilation)
    {
        _types = types;
        _layout = layout;
        _compilation = compilation;
    }

    // =========================================================================
    // Niche optimization helpers: Option(&T) -> nullable pointer
    // =========================================================================

    /// <summary>
    /// Returns true when the IrType is a niche-optimized Option(&T) (nullable pointer).
    /// </summary>
    private static bool IsNicheOption(IrType? t) => t is IrPointer { IsNullable: true };

    /// <summary>
    /// Returns true when the IrType is the tagged-enum form of Option(T)
    /// (i.e. an IrEnum produced from `core.option.Option`).
    /// </summary>
    private static bool IsEnumOption(IrType? t) =>
        t is IrEnum e && e.Name == WellKnown.Option;

    /// <summary>
    /// True when the IrType is an Option(T) in either niche-optimized or
    /// tagged-enum form.
    /// </summary>
    private static bool IsAnyOption(IrType? t) => IsNicheOption(t) || IsEnumOption(t);

    /// <summary>
    /// Strip the nullable flag from a nullable pointer to get the non-nullable equivalent.
    /// </summary>
    private static IrPointer StripNullable(IrPointer p) => new(p.Pointee, false);

    /// <summary>
    /// Look up a variant by name in an IrEnum, throwing if missing.
    /// </summary>
    private static IrVariant FindVariant(IrEnum e, string name)
    {
        foreach (var v in e.Variants)
            if (v.Name == name) return v;
        throw new InvalidOperationException($"Variant `{name}` not found in enum `{e.Name}`");
    }

    // =========================================================================
    // Option enum construction / inspection helpers
    //
    // These centralize the Some/None construction and tag-checking logic so
    // we don't repeat the niche-vs-tagged-enum branching at every call site.
    // =========================================================================

    /// <summary>
    /// Construct an Option(T) holding `payload`. Handles both niche-optimized
    /// (nullable pointer) and tagged-enum representations.
    /// </summary>
    private Value EmitOptionSome(Value payload, IrType optionIrType)
    {
        if (optionIrType is IrPointer { IsNullable: true } nichePtr)
        {
            // Niche: just retype the pointer as nullable.
            payload.IrType = nichePtr;
            return payload;
        }

        if (optionIrType is IrEnum optionEnum)
        {
            var someVariant = FindVariant(optionEnum, "Some");
            var enumPtr = _currentBlock.EmitAlloca(optionEnum);
            EmitStoreToOffset(enumPtr, 0,
                new IntConstantValue(someVariant.TagValue, TypeLayoutService.IrI32),
                TypeLayoutService.IrI32);
            if (someVariant.PayloadType != null)
                EmitStoreToOffset(enumPtr, someVariant.PayloadOffset, payload, someVariant.PayloadType);
            return _currentBlock.EmitLoad(enumPtr, optionEnum);
        }

        throw new InvalidOperationException($"EmitOptionSome: unsupported Option representation `{optionIrType}`");
    }

    /// <summary>
    /// Construct an Option(T) holding None.
    /// </summary>
    private Value EmitOptionNone(IrType optionIrType)
    {
        if (optionIrType is IrPointer { IsNullable: true })
            return new IntConstantValue(0, optionIrType);

        if (optionIrType is IrEnum optionEnum)
        {
            var noneVariant = FindVariant(optionEnum, "None");
            var enumPtr = _currentBlock.EmitAlloca(optionEnum);
            EmitStoreToOffset(enumPtr, 0,
                new IntConstantValue(noneVariant.TagValue, TypeLayoutService.IrI32),
                TypeLayoutService.IrI32);
            return _currentBlock.EmitLoad(enumPtr, optionEnum);
        }

        throw new InvalidOperationException($"EmitOptionNone: unsupported Option representation `{optionIrType}`");
    }

    /// <summary>
    /// Materialize an Option value to a pointer (for tag-loading / payload-extracting).
    /// If `optionVal` is already a pointer to the option type, returns it as-is.
    /// Otherwise, allocates a slot, stores the value, returns the slot pointer.
    /// </summary>
    private Value MaterializeOptionPtr(Value optionVal, IrType optionIrType)
    {
        if (optionVal.IrType is IrPointer p && p.Pointee.Equals(optionIrType))
            return optionVal;
        var slot = _currentBlock.EmitAlloca(optionIrType);
        _currentBlock.EmitStorePtr(slot, optionVal);
        return slot;
    }

    /// <summary>
    /// Emit a bool: is this Option a Some?
    /// Handles niche (ptr != NULL) and tagged-enum (tag == Some.TagValue).
    /// </summary>
    private Value EmitOptionIsSome(Value optionVal, IrType optionIrType)
    {
        if (optionIrType is IrPointer { IsNullable: true } nichePtr)
        {
            var nullVal = new IntConstantValue(0, nichePtr);
            return _currentBlock.EmitBinary(BinaryOp.NotEqual, optionVal, nullVal, TypeLayoutService.IrBool);
        }

        if (optionIrType is IrEnum optionEnum)
        {
            var someVariant = FindVariant(optionEnum, "Some");
            var optPtr = MaterializeOptionPtr(optionVal, optionEnum);
            var tag = EmitLoadFromOffset(optPtr, 0, TypeLayoutService.IrI32, "opt_tag");
            return _currentBlock.EmitBinary(BinaryOp.Equal, tag,
                new IntConstantValue(someVariant.TagValue, TypeLayoutService.IrI32),
                TypeLayoutService.IrBool);
        }

        throw new InvalidOperationException($"EmitOptionIsSome: unsupported Option representation `{optionIrType}`");
    }

    /// <summary>
    /// Extract the payload of a Some Option. Caller must have already
    /// checked IsSome (otherwise behavior is undefined for None).
    /// </summary>
    private Value EmitOptionUnwrap(Value optionVal, IrType optionIrType, IrType payloadIrType)
    {
        if (optionIrType is IrPointer { IsNullable: true } nichePtr)
        {
            var stripped = StripNullable(nichePtr);
            return _currentBlock.EmitCast(optionVal, stripped);
        }

        if (optionIrType is IrEnum optionEnum)
        {
            var someVariant = FindVariant(optionEnum, "Some");
            var optPtr = MaterializeOptionPtr(optionVal, optionEnum);
            return EmitLoadFromOffset(optPtr, someVariant.PayloadOffset, payloadIrType, "opt_payload");
        }

        throw new InvalidOperationException($"EmitOptionUnwrap: unsupported Option representation `{optionIrType}`");
    }

    // =========================================================================
    // Fused offset helpers — emit CopyFromOffset / CopyToOffset directly
    // =========================================================================

    /// <summary>
    /// Load a field from basePtr + constant byte offset (replaces GEP+Load).
    /// </summary>
    private LocalValue EmitLoadFromOffset(Value basePtr, int byteOffset, IrType fieldType, string nameHint)
    {
        var offset = new IntConstantValue(byteOffset, TypeLayoutService.IrUSize);
        return _currentBlock.EmitCopyFromOffset(basePtr, offset, fieldType);
    }

    /// <summary>
    /// Load a field from basePtr + dynamic byte offset (replaces GEP+Load).
    /// </summary>
    private LocalValue EmitLoadFromOffset(Value basePtr, Value byteOffset, IrType fieldType, string nameHint)
    {
        return _currentBlock.EmitCopyFromOffset(basePtr, byteOffset, fieldType);
    }

    /// <summary>
    /// Store a value to basePtr + constant byte offset (replaces GEP+StorePointer).
    /// </summary>
    private void EmitStoreToOffset(Value basePtr, int byteOffset, Value val, IrType valueType)
    {
        var offset = new IntConstantValue(byteOffset, TypeLayoutService.IrUSize);
        _currentBlock.EmitCopyToOffset(basePtr, offset, val, valueType);
    }

    /// <summary>
    /// Store a value to basePtr + dynamic byte offset (replaces GEP+StorePointer).
    /// </summary>
    private void EmitStoreToOffset(Value basePtr, Value byteOffset, Value val, IrType valueType)
    {
        _currentBlock.EmitCopyToOffset(basePtr, byteOffset, val, valueType);
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

        // Track emitted function semantic keys to deduplicate across modules
        var emittedFunctions = new HashSet<string>();

        // Lower non-generic, non-foreign functions
        foreach (var (modulePath, module) in moduleList)
        {
            foreach (var fn in module.Functions)
            {
                if ((fn.Modifiers & FunctionModifiers.Foreign) != 0) continue;
                if (fn.IsGeneric) continue;
                var irFn = LowerFunction(fn);
                irFn.ComputeAndStoreSemanticKey();
                var key = irFn.IsEntryPoint ? "main" : irFn.SemanticKey!;
                if (emittedFunctions.Add(key))
                    _module.Functions.Add(irFn);
            }
        }

        // Lower specialized/synthesized functions (lambdas, monomorphized generics)
        foreach (var fn in _types.SpecializedFunctions)
        {
            var irFn = LowerFunction(fn);
            irFn.ComputeAndStoreSemanticKey();
            var key = irFn.IsEntryPoint ? "main" : irFn.SemanticKey!;
            if (emittedFunctions.Add(key))
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
        _deferScopeMarks.Clear();

        var fnName = $"__test_{index}__";
        var irFn = new IrFunction(fnName, TypeLayoutService.IrVoidPrim);
        _currentFunction = irFn;
        _ctx = new BlockBuildContext(irFn, _layout);

        _currentBlock = _ctx.CreateBlock("entry");

        foreach (var stmt in test.Body)
            LowerStatement(stmt);

        // Fire any defers registered directly in the test body (not inside a
        // nested block — those have already been handled by `PopDeferScope`).
        if (!_currentBlock.IsTerminated)
        {
            EmitDefersDownTo(0);
        }

        // Add implicit void return to unterminated blocks
        foreach (var block in irFn.BasicBlocks)
        {
            if (!block.IsTerminated)
                block.EmitReturn(new IntConstantValue(0, TypeLayoutService.IrVoidPrim));
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
        _deferScopeMarks.Clear();

        var irFn = new IrFunction("main", TypeLayoutService.IrI32);
        irFn.IsEntryPoint = true;
        _currentFunction = irFn;
        _ctx = new BlockBuildContext(irFn, _layout);

        _currentBlock = _ctx.CreateBlock("entry");

        // Print header
        AddStringPrintf($"Running {testFunctions.Count} test(s)...\\n");

        for (int i = 0; i < testFunctions.Count; i++)
        {
            var (name, testFn) = testFunctions[i];

            // Print: "test N/total: name... "
            AddStringPrintf($"test {i + 1}/{testFunctions.Count}: {EscapeCString(name)}... ");

            // Call the test function
            _currentBlock.EmitCall(testFn.Name, [], TypeLayoutService.IrVoidPrim, null);

            // Print "ok\n"
            AddStringPrintf("ok\\n");
        }

        // Print summary
        AddStringPrintf($"\\nAll {testFunctions.Count} test(s) passed.\\n");

        // return 0
        _currentBlock.EmitReturn(new IntConstantValue(0, TypeLayoutService.IrI32));

        return irFn;
    }

    private void AddStringPrintf(string text)
    {
        var fmtStr = new RawCStringValue(text);
        _currentBlock.EmitCall("printf", [fmtStr], TypeLayoutService.IrI32, null, isForeign: true);
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
            var hmType = _types.GetResolvedType(globalConst);
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
            var idType = _types.GetResolvedType(id);
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
            var innerType = _types.GetResolvedType(addrOf.Target);
            var innerIrType = _layout.Lower(innerType);
            var innerVal = LowerGlobalInitializer(addrOf.Target, innerIrType, name);
            if (innerVal is GlobalValue)
                return innerVal; // GlobalValue is already a pointer
            return innerVal;
        }

        // Cast — unwrap and use target type
        if (expr is CastExpressionNode cast)
        {
            var castTargetType = _types.GetResolvedType(cast);
            var castIrType = _layout.Lower(castTargetType);
            return LowerGlobalInitializer(cast.Expression, castIrType, name);
        }

        return null;
    }

    // =========================================================================
    // Project info intrinsic — `project_info()` returns metadata for the
    // project the call site lexically lives in.
    // =========================================================================

    private bool IsProjectInfoIntrinsic(CallExpressionNode call)
    {
        if (call.ResolvedTarget == null) return false;
        if (call.ResolvedTarget.Name != WellKnown.ProjectInfoFn) return false;
        if (call.ResolvedTarget.Parameters.Count != 0) return false;

        // Confirm the resolved target was declared in core.rtti — guards
        // against name collisions with a user function called `project_info`.
        var fileId = call.ResolvedTarget.Span.FileId;
        if (fileId < 0 || fileId >= _compilation.Sources.Count) return false;
        var declFile = _compilation.Sources[fileId].FileName;
        var declModule = TemplateExpander.DeriveModulePath(declFile, _compilation);
        return declModule == WellKnown.RttiModulePath;
    }

    private Value LowerProjectInfoIntrinsic(CallExpressionNode call, IrType retIrType)
    {
        EnsureProjectInfoTableExists();

        var key = ResolveProjectKeyForSpan(call.Span);
        if (_projectInfoGlobals != null && _projectInfoGlobals.TryGetValue(key, out var global))
            return _currentBlock.EmitLoad(global, retIrType);

        // Fallback should be unreachable — EnsureProjectInfoTableExists always
        // creates the `stdlib` sentinel. Returning zero is defensive only.
        return new IntConstantValue(0, retIrType);
    }

    private string ResolveProjectKeyForSpan(SourceSpan span)
    {
        if (span.FileId < 0 || span.FileId >= _compilation.Sources.Count) return "stdlib";
        var file = Path.GetFullPath(_compilation.Sources[span.FileId].FileName);
        var cmp = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        foreach (var (name, meta) in _compilation.ProjectMetadata)
        {
            var root = Path.GetFullPath(meta.SourceRoot);
            if (file.Equals(root, cmp) || file.StartsWith(root + Path.DirectorySeparatorChar, cmp))
                return name;
        }
        return "stdlib";
    }

    private void EnsureProjectInfoTableExists()
    {
        if (_projectInfoGlobals != null) return;
        _projectInfoGlobals = new Dictionary<string, GlobalValue>();

        var projectInfoNominal = _types.LookupNominal(WellKnown.ProjectInfo);
        if (projectInfoNominal == null) return;
        if (_layout.Lower(projectInfoNominal) is not IrStruct projectInfoIr) return;

        var stringNominal = _types.LookupNominal(WellKnown.String);
        if (stringNominal == null || _layout.Lower(stringNominal) is not IrStruct stringIr) return;

        StructConstantValue MakeStringConstant(string text)
        {
            var bytes = System.Text.Encoding.UTF8.GetBytes(text + "\0");
            var arr = new ArrayConstantValue(bytes, TypeLayoutService.IrU8)
            {
                StringRepresentation = text,
            };
            return new StructConstantValue(stringIr, new Dictionary<string, Value>
            {
                ["ptr"] = arr,
                ["len"] = new IntConstantValue(text.Length, TypeLayoutService.IrUSize),
            });
        }

        void AddGlobal(string key, string name, string version)
        {
            if (_projectInfoGlobals!.ContainsKey(key)) return;
            var fields = new Dictionary<string, Value>
            {
                ["name"] = MakeStringConstant(name),
                ["version"] = MakeStringConstant(version),
            };
            var konst = new StructConstantValue(projectInfoIr, fields);
            var global = new GlobalValue($"__project_info_{key}", konst, projectInfoIr);
            _projectInfoGlobals[key] = global;
            _module.GlobalValues.Add(global);
        }

        foreach (var (name, meta) in _compilation.ProjectMetadata)
            AddGlobal(name, meta.Name, meta.Version);

        // Always provide a sentinel for stdlib (or any module outside a known
        // project). Callers fall back to this key when source-root matching
        // returns nothing.
        AddGlobal("stdlib", "stdlib", "");
    }

    // =========================================================================
    // Type table (RTTI) — builds GlobalValue entries for each Type(T)
    // =========================================================================

    private void EnsureTypeTableExists()
    {
        if (_typeTableGlobals != null) return;
        _typeTableGlobals = new Dictionary<string, GlobalValue>();

        // Get the IrStruct for TypeInfo
        var typeInfoNominal = _types.LookupNominal("core.rtti.TypeInfo");
        if (typeInfoNominal == null) return;
        var typeInfoIr = _layout.Lower(typeInfoNominal) as IrStruct;
        if (typeInfoIr == null) return;

        // Get the IrStruct for FieldInfo
        var fieldInfoNominal = _types.LookupNominal("core.rtti.FieldInfo");
        var fieldInfoIr = fieldInfoNominal != null ? _layout.Lower(fieldInfoNominal) as IrStruct : null;

        // Get the IrStruct for ParamInfo
        var paramInfoNominal = _types.LookupNominal("core.rtti.ParamInfo");
        var paramInfoIr = paramInfoNominal != null ? _layout.Lower(paramInfoNominal) as IrStruct : null;

        // Get the IrStruct for String
        var stringNominal = _types.LookupNominal(WellKnown.String);
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
        var allTypes = new HashSet<Type>(_types.InstantiatedTypes);
        bool changed = true;
        while (changed)
        {
            changed = false;
            foreach (var type in allTypes.ToList())
            {
                if (type is NominalType { Kind: NominalKind.Struct or NominalKind.Tuple or NominalKind.Enum } nt
                    && !nt.Name.StartsWith(WellKnown.RttiPrefix) && nt.Name != WellKnown.String)
                {
                    foreach (var (_, ft) in nt.FieldsOrVariants)
                    {
                        var fieldType = _types.Resolve(ft);
                        if (fieldType is Core.Types.ReferenceType refT) fieldType = _types.Resolve(refT.InnerType);
                        if (fieldType is Core.Types.TypeVar) continue;
                        if (allTypes.Add(fieldType)) changed = true;
                    }
                }
                // Expand function types: include parameter types and return type
                else if (type is FunctionType fnType)
                {
                    foreach (var pt in fnType.ParameterTypes)
                    {
                        var paramType = _types.Resolve(pt);
                        if (paramType is Core.Types.ReferenceType refT) paramType = _types.Resolve(refT.InnerType);
                        if (paramType is Core.Types.TypeVar) continue;
                        if (allTypes.Add(paramType)) changed = true;
                    }
                    var retType = _types.Resolve(fnType.ReturnType);
                    if (retType is Core.Types.ReferenceType retRef) retType = _types.Resolve(retRef.InnerType);
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
                    $"fn({string.Join(", ", ft2.ParameterTypes.Select(p => _types.Resolve(p).ToString()))}) {_types.Resolve(ft2.ReturnType)}",
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
                    var resolvedFieldType = _types.Resolve(fieldType);
                    if (resolvedFieldType is Core.Types.ReferenceType refFT)
                        resolvedFieldType = _types.Resolve(refFT.InnerType);
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
                    var resolvedParamType = _types.Resolve(fnType2.ParameterTypes[i]);
                    if (resolvedParamType is Core.Types.ReferenceType refPT)
                        resolvedParamType = _types.Resolve(refPT.InnerType);
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
                var resolvedRetType = _types.Resolve(fnType2.ReturnType);
                if (resolvedRetType is Core.Types.ReferenceType refRT)
                    resolvedRetType = _types.Resolve(refRT.InnerType);
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
        var resolved = _types.Resolve(type);
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
            if (fn.SemanticKey != null)
                knownFunctions.Add(fn.SemanticKey);
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
                        var callKey = call.CalleeSemanticKey;
                        if (callKey != null && !knownFunctions.Contains(callKey))
                        {
                            _diagnostics.Add(Diagnostic.Error(
                                $"Unknown call target `{call.FunctionName}` in function `{fn.Name}`",
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
                var resolvedEnum = _layout.ResolveEnum(e);
                if (collected.Add(resolvedEnum.CName))
                {
                    foreach (var v in resolvedEnum.Variants)
                        if (v.PayloadType != null)
                            CollectIrType(v.PayloadType, collected);
                    _module.TypeDefs.Add(resolvedEnum);
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
        _deferScopeMarks.Clear();

        var fnType = GetFunctionHmType(fn);
        var retIrType = _layout.Lower(fnType.ReturnType);

        var irFn = new IrFunction(fn.Name, retIrType);
        _currentFunction = irFn;
        _ctx = new BlockBuildContext(irFn, _layout);

        if (fn.Name == "main")
            irFn.IsEntryPoint = true;

        // Create entry block
        _currentBlock = _ctx.CreateBlock("entry");

        // Setup callee ABI (parameter promotion for large values, return slot)
        var declaredParams = new List<(string Name, IrType Type)>();
        if (fnType != null)
            for (int i = 0; i < fn.Parameters.Count; i++)
                declaredParams.Add((fn.Parameters[i].Name, _layout.Lower(fnType.ParameterTypes[i])));

        var abi = BasicBlock.SetupCalleeAbi(declaredParams, retIrType, fn.Name == "main");
        irFn.UsesReturnSlot = abi.UsesReturnSlot;
        foreach (var p in abi.Params) irFn.Params.Add(p);
        foreach (var (name, localVal) in abi.Locals)
        {
            _locals[name] = localVal;
            _parameters.Add(name);
        }
        foreach (var name in abi.ByRefParams)
            _byRefParams.Add(name);

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
            if (si == fn.Body.Count - 1 && isNonVoid && stmt is ExpressionStatementNode lastExpr
                && lastExpr.Expression is not ReturnNode)
            {
                var val = LowerExpression(lastExpr.Expression, retIrType);
                _ctx.Span = stmt.Span;
                _currentBlock.EmitFunctionReturn(val, _currentFunction,
                    _currentFunction.UsesReturnSlot ? _locals["__ret"] : null);
                continue;
            }
            LowerStatement(stmt);
        }

        // Fire any defers registered directly in the function body (i.e. not
        // inside a nested block — inner-block defers already fired via their
        // own `PopDeferScope`). Skip if the final statement already terminated
        // the block with `return`.
        if (!_currentBlock.IsTerminated)
        {
            EmitDefersDownTo(0);
        }

        // Add implicit return to any unterminated block
        foreach (var block in irFn.BasicBlocks)
        {
            if (!block.IsTerminated)
            {
                var retType = irFn.UsesReturnSlot ? TypeLayoutService.IrVoidPrim
                    : (isNonVoid ? retIrType : TypeLayoutService.IrVoidPrim);
                block.EmitReturn(new IntConstantValue(0, retType));
            }
        }

        return irFn;
    }

    // =========================================================================
    // Statement lowering
    // =========================================================================

    private void LowerStatement(StatementNode stmt)
    {
        _ctx.Span = stmt.Span;
        switch (stmt)
        {
            case ExpressionStatementNode exprStmt:
                LowerExpression(exprStmt.Expression);
                break;
            case VariableDeclarationNode varDecl:
                LowerVariableDeclaration(varDecl);
                break;
            case LoopNode loop:
                LowerLoop(loop);
                break;
            case WhileNode whileLoop:
                LowerWhileLoop(whileLoop);
                break;
            case ForLoopNode forLoop:
                LowerForLoop(forLoop);
                break;
            case DeferStatementNode defer:
                LowerDefer(defer);
                break;
            case IfDirectiveStatementNode directive:
            {
                var active = TemplateEngine.EvaluateCondition(directive.Condition, _types.CompileTimeContext);
                var branch = active ? directive.ThenBody : directive.ElseBody;
                if (branch != null)
                    foreach (var s in branch)
                        LowerStatement(s);
                break;
            }
        }
    }

    /// <summary>
    /// Apply implicit coercions when the lowered value doesn't match the expected type.
    /// Mirrors the coercion rules in the type checker (CoercionRules.cs).
    /// Includes Option wrapping (T -> Option(T) via Some(val)) and the niche-pointer
    /// short-circuit for Option(&T).
    /// </summary>
    private Value ApplyCoercions(Value val, IrType expectedType)
    {
        var actualType = val.IrType;
        if (actualType == null || actualType == expectedType) return val;
        // Never-returning expressions need no coercion — code after them is unreachable
        if (actualType == TypeLayoutService.IrNeverPrim) return val;
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

        // 5. T -> Option(T): wrap in Some
        //    Handles: same-size value, integer widening, pointer->Option[pointer]
        if (IsEnumOption(expectedType))
        {
            var optionEnum = (IrEnum)expectedType;
            var someVariant = FindVariant(optionEnum, "Some");
            var payloadType = someVariant.PayloadType;
            if (payloadType != null)
            {
                if (actualType.Size == payloadType.Size)
                    return EmitOptionSome(val, optionEnum);

                if (actualType is IrPrimitive && payloadType is IrPrimitive)
                {
                    var widened = _currentBlock.EmitCast(val, payloadType);
                    return EmitOptionSome(widened, optionEnum);
                }

                if (actualType is IrPointer && payloadType is IrPointer)
                    return EmitOptionSome(val, optionEnum);
            }
        }

        // 6. Primitive widening: e.g. i32 -> usize
        if (actualType is IrPrimitive && expectedType is IrPrimitive && actualType.Size < expectedType.Size)
        {
            return _currentBlock.EmitCast(val, expectedType);
        }

        return val;
    }

    private Value CoerceArrayToSlice(Value val, IrArray arrType, IrStruct sliceStruct,
        IrField ptrField, IrField lenField)
    {
        var tmpPtr = _currentBlock.EmitAlloca(sliceStruct);

        // ptr = (element_type*)array
        var elemPtrType = new IrPointer(arrType.Element);
        var castResult = _currentBlock.EmitCast(val, elemPtrType);

        EmitStoreToOffset(tmpPtr, ptrField.ByteOffset, castResult, ptrField.Type);

        // len = array_length
        EmitStoreToOffset(tmpPtr, lenField.ByteOffset,
            new IntConstantValue(arrType.Length ?? 0, TypeLayoutService.IrUSize), lenField.Type);

        return _currentBlock.EmitLoad(tmpPtr, sliceStruct);
    }

    private Value CoerceSliceToPointer(Value val, IrStruct sliceStruct, IrField ptrField)
    {
        // Spill to alloca, GEP to ptr field, load
        var tmpPtr = _currentBlock.EmitAlloca(sliceStruct);
        _currentBlock.EmitStorePtr(tmpPtr, val);

        return EmitLoadFromOffset(tmpPtr, ptrField.ByteOffset, ptrField.Type, "slice_ptr_val");
    }

    private Value ReinterpretCast(Value val, IrStruct srcType, IrStruct dstType)
    {
        var tmpPtr = _currentBlock.EmitAlloca(srcType);
        _currentBlock.EmitStorePtr(tmpPtr, val);
        return _currentBlock.EmitLoad(tmpPtr, dstType);
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
        var allocaResult = _currentBlock.EmitAlloca(irType, isArrayStorage: isArray);

        // Store initializer if present, otherwise zero-initialize
        if (varDecl.Initializer != null)
        {
            var initVal = LowerExpression(varDecl.Initializer, irType);
            _currentBlock.EmitStorePtr(allocaResult, initVal);
        }
        else
        {
            // Zero-initialize variables declared without an initializer (e.g. `let sb: StringBuilder`)
            _currentBlock.EmitCall("memset",
                [allocaResult, new IntConstantValue(0, TypeLayoutService.IrI32), new IntConstantValue(irType.Size, TypeLayoutService.IrUSize)],
                TypeLayoutService.IrVoidPrim, calleeParamTypes: null, isForeign: true);
        }

        _locals[varDecl.Name] = allocaResult;
    }

    private void LowerLoop(LoopNode loop)
    {
        var bodyBlock = CreateBlock("loop_body");
        var exitBlock = CreateBlock("loop_exit");

        // Jump from current block into the loop body
        _currentBlock.EmitJump(bodyBlock);
        _currentBlock = bodyBlock;

        // Push loop context for break/continue
        _loopStack.Push((bodyBlock, exitBlock, _deferStack.Count));

        // Lower loop body — the body is an ExpressionNode (typically a BlockExpression)
        LowerExpression(loop.Body);

        // Pop loop context
        _loopStack.Pop();

        // Back-edge: jump back to loop body (if not already terminated)
        _currentBlock.EmitJumpIfNotTerminated(bodyBlock);

        // Continue after the loop
        _currentBlock = exitBlock;
    }

    private void LowerWhileLoop(WhileNode whileLoop)
    {
        var condBlock = CreateBlock("while_cond");
        var bodyBlock = CreateBlock("while_body");
        var exitBlock = CreateBlock("while_exit");

        // Jump into condition check
        _currentBlock.EmitJump(condBlock);

        // Condition block: evaluate cond, branch to body or exit
        _currentBlock = condBlock;
        var condVal = LowerExpression(whileLoop.Condition);
        _currentBlock.EmitBranch(condVal, bodyBlock, exitBlock);

        // Body block
        _currentBlock = bodyBlock;
        // continue -> re-check condition, break -> exit
        _loopStack.Push((condBlock, exitBlock, _deferStack.Count));
        LowerExpression(whileLoop.Body);
        _loopStack.Pop();

        // Back-edge to condition
        _currentBlock.EmitJumpIfNotTerminated(condBlock);

        // Continue after the loop
        _currentBlock = exitBlock;
    }

    private Value LowerReturnExpr(ReturnNode ret)
    {
        // Lower the return expression FIRST, then fire defers, then emit the
        // return instruction. Firing defers before the return expression is
        // evaluated lets a `defer x.deinit()` zero `x` before a subsequent
        // `return x.as_view()` reads its fields — observed as zero-length
        // OwnedStrings (see docs/known-issues.md). For large returns the
        // value has already been stored into `__ret` by `LowerExpression`,
        // so defers running afterwards cannot clobber it.
        if (ret.Expression != null)
        {
            var fnRetType = _currentFunction.ReturnType;
            var val = LowerExpression(ret.Expression, fnRetType);
            EmitDefersDownTo(0);
            _currentBlock.EmitFunctionReturn(val, _currentFunction,
                _currentFunction.UsesReturnSlot ? _locals["__ret"] : null);
        }
        else
        {
            EmitDefersDownTo(0);
            var voidVal = new IntConstantValue(0, TypeLayoutService.IrVoidPrim);
            _currentBlock.EmitReturn(voidVal);
        }

        return new IntConstantValue(0, TypeLayoutService.IrNeverPrim);
    }

    private Value LowerBreakExpr(BreakNode brk)
    {
        if (_loopStack.Count == 0)
        {
            _diagnostics.Add(Diagnostic.Error("break outside of loop", brk.Span, "break can only be used inside for/while loops", "E3006"));
            return new IntConstantValue(0, TypeLayoutService.IrNeverPrim);
        }

        var (_, exitBlock, deferDepth) = _loopStack.Peek();
        // Fire every defer registered after the loop was entered — i.e. all
        // defers belonging to scopes this `break` escapes through.
        EmitDefersDownTo(deferDepth);
        _currentBlock.EmitJump(exitBlock);

        // Start a dead block — subsequent code is unreachable but we need a valid block
        var deadBlock = CreateBlock("dead");
        _currentBlock = deadBlock;

        return new IntConstantValue(0, TypeLayoutService.IrNeverPrim);
    }

    private Value LowerContinueExpr(ContinueNode cont)
    {
        if (_loopStack.Count == 0)
        {
            _diagnostics.Add(Diagnostic.Error("continue outside of loop", cont.Span, "continue can only be used inside for/while loops", "E3007"));
            return new IntConstantValue(0, TypeLayoutService.IrNeverPrim);
        }

        var (bodyBlock, _2, deferDepth) = _loopStack.Peek();
        // Same reasoning as `break`: escape fires the defers we're jumping past.
        EmitDefersDownTo(deferDepth);
        _currentBlock.EmitJump(bodyBlock);

        // Start a dead block
        var deadBlock = CreateBlock("dead");
        _currentBlock = deadBlock;

        return new IntConstantValue(0, TypeLayoutService.IrNeverPrim);
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
        //
        // If the iterable is a plain local (`for x in it`), pass its alloca
        // pointer directly to `iter()` rather than loading its value and
        // stuffing it into a fresh temp. This matters whenever the iterator's
        // `iter(&Self)` returns `&Self` (the conventional pattern for in-place
        // iterators like `DirIter` / `WalkIter` / `GlobIter`): callers can
        // inspect post-iteration state on the same variable they looped over
        // (`it.err()`, `it.done`). With the old copy-based lowering those
        // fields stayed frozen at their pre-loop values, silently swallowing
        // iterator errors.
        Value iterableVal;
        if (forLoop.IterableExpression is IdentifierExpressionNode idExpr
            && _locals.TryGetValue(idExpr.Name, out var idLocal)
            && !_parameters.Contains(idExpr.Name))
        {
            iterableVal = idLocal;
        }
        else
        {
            iterableVal = LowerExpression(forLoop.IterableExpression);

            // Materialize iterable to alloca if not already a pointer (iter takes &T)
            if (iterableVal.IrType is not IrPointer)
            {
                var iterableIrType = iterableVal.IrType ?? TypeLayoutService.IrVoidPrim;
                var temp = _currentBlock.EmitAlloca(iterableIrType);
                _currentBlock.EmitStorePtr(temp, iterableVal);
                iterableVal = temp;
            }
        }

        // 2. Call iter(&iterable) -> IteratorStruct
        var iterCalleeParamTypes = new List<IrType>();
        foreach (var p in forLoop.ResolvedIterFunction.Parameters)
            iterCalleeParamTypes.Add(GetIrType(p));
        var iterResult = _currentBlock.EmitCall("iter", [iterableVal], iteratorIrType, iterCalleeParamTypes);

        // 3. Set up the pointer we pass to next(). If iter returned a reference,
        //    the returned value IS the pointer — use it directly. Otherwise
        //    allocate a stack slot, store the returned struct, and pass &slot.
        Value iteratorPtr;
        if (iteratorIrType is IrPointer)
        {
            iteratorPtr = iterResult;
        }
        else
        {
            iteratorPtr = _currentBlock.EmitAlloca(iteratorIrType);
            _currentBlock.EmitStorePtr(iteratorPtr, iterResult);
        }

        // 4. Allocate loop variable on stack
        var loopVarPtr = _currentBlock.EmitAlloca(elementIrType);
        _locals[forLoop.IteratorVariable] = loopVarPtr;

        // Jump to condition block
        _currentBlock.EmitJump(condBlock);

        // 5. Condition block: call next(&iterator), check is_some
        _currentBlock = condBlock;

        var nextCalleeParamTypes = new List<IrType>();
        foreach (var p in forLoop.ResolvedNextFunction.Parameters)
            nextCalleeParamTypes.Add(GetIrType(p));
        var nextResult = _currentBlock.EmitCall("next", [iteratorPtr], optionIrType, nextCalleeParamTypes);

        if (IsNicheOption(optionIrType))
        {
            // Niche-optimized: nextResult is a nullable pointer; NULL = None
            var isSome = EmitOptionIsSome(nextResult, optionIrType);
            _currentBlock.EmitBranch(isSome, bodyBlock, exitBlock);

            // Body: extract payload (non-nullable pointer), store to loop var
            _currentBlock = bodyBlock;
            _loopStack.Push((condBlock, exitBlock, _deferStack.Count));

            var nichePtr = (IrPointer)optionIrType;
            var stripped = StripNullable(nichePtr);
            var castVal = _currentBlock.EmitCast(nextResult, stripped);
            // If element type differs from stripped pointer (e.g. loop var is the inner pointee), load
            if (elementIrType is IrPointer)
            {
                _currentBlock.EmitStorePtr(loopVarPtr, castVal);
            }
            else
            {
                var loaded = _currentBlock.EmitLoad(castVal, elementIrType);
                _currentBlock.EmitStorePtr(loopVarPtr, loaded);
            }
        }
        else if (IsEnumOption(optionIrType))
        {
            // Tagged-enum Option: branch on tag, extract payload from Some variant.
            var nextPtr = MaterializeOptionPtr(nextResult, optionIrType);
            var isSome = EmitOptionIsSome(nextPtr, optionIrType);
            _currentBlock.EmitBranch(isSome, bodyBlock, exitBlock);

            _currentBlock = bodyBlock;
            _loopStack.Push((condBlock, exitBlock, _deferStack.Count));

            var payload = EmitOptionUnwrap(nextPtr, optionIrType, elementIrType);
            _currentBlock.EmitStorePtr(loopVarPtr, payload);
        }
        else
        {
            throw new InvalidOperationException(
                $"For-loop iterator next() returned non-Option type `{optionIrType}`");
        }

        // Lower loop body
        LowerExpression(forLoop.Body);

        _loopStack.Pop();

        // Back-edge to condition
        _currentBlock.EmitJumpIfNotTerminated(condBlock);

        // 7. Exit block
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
                var temp = _currentBlock.EmitAlloca(baseIrType);
                _currentBlock.EmitStorePtr(temp, iterableVal);
                arrayPtr = temp;
            }
        }
        else
        {
            throw new InternalCompilerError(
                $"Unsupported direct iteration over {baseIrType}", forLoop.Span);
        }

        // Allocate index counter (usize, init to 0)
        var indexPtr = _currentBlock.EmitAlloca(usizeType);
        _currentBlock.EmitStorePtr(indexPtr, new IntConstantValue(0, usizeType));

        // Allocate loop variable
        var loopVarPtr = _currentBlock.EmitAlloca(elementIrType);
        _locals[forLoop.IteratorVariable] = loopVarPtr;

        // Create blocks
        var condBlock = CreateBlock("for_cond");
        var bodyBlock = CreateBlock("for_body");
        var exitBlock = CreateBlock("for_exit");

        _currentBlock.EmitJump(condBlock);

        // Condition block: load index, compare < length
        _currentBlock = condBlock;

        var indexVal = _currentBlock.EmitLoad(indexPtr, usizeType);

        var cmpResult = _currentBlock.EmitBinary(BinaryOp.LessThan, indexVal, lengthVal, TypeLayoutService.IrBool);

        _currentBlock.EmitBranch(cmpResult, bodyBlock, exitBlock);

        // Body block: GEP to array[index], load element, store to loop var
        _currentBlock = bodyBlock;

        _loopStack.Push((condBlock, exitBlock, _deferStack.Count));

        // Compute byte offset: index * element_size
        var elemSize = new IntConstantValue(elementIrType.Size, usizeType);
        var byteOffset = _currentBlock.EmitBinary(BinaryOp.Multiply, indexVal, elemSize, usizeType);

        // Load element at dynamic offset
        var elemVal = EmitLoadFromOffset(arrayPtr, byteOffset, elementIrType, "for_elem");
        _currentBlock.EmitStorePtr(loopVarPtr, elemVal);

        // Lower loop body
        LowerExpression(forLoop.Body);

        _loopStack.Pop();

        // Increment index: index = index + 1
        var one = new IntConstantValue(1, usizeType);
        var indexVal2 = _currentBlock.EmitLoad(indexPtr, usizeType);
        var nextIndex = _currentBlock.EmitBinary(BinaryOp.Add, indexVal2, one, usizeType);
        _currentBlock.EmitStorePtr(indexPtr, nextIndex);

        // Back-edge to condition
        _currentBlock.EmitJumpIfNotTerminated(condBlock);

        // Exit block
        _currentBlock = exitBlock;
    }

    private void LowerDefer(DeferStatementNode defer)
    {
        // Register the expression in the active scope; it fires at scope exit
        // (block fall-through) and at any escaping jump that passes through
        // this scope (return/break/continue).
        _deferStack.Push(defer.Expression);
    }

    /// <summary>
    /// Mark the start of a defer scope. Every `BlockExpressionNode` opens one;
    /// the matching <see cref="PopDeferScope"/> fires and drops the scope's
    /// defers on normal fall-through.
    /// </summary>
    private void PushDeferScope()
    {
        _deferScopeMarks.Push(_deferStack.Count);
    }

    /// <summary>
    /// End the current defer scope on a normal (fall-through) exit path: emit
    /// the scope's defers in LIFO order, then pop them off the stack.
    ///
    /// If the current block is already terminated (e.g. by an early `return`
    /// or `break` inside the scope), defers already fired at that transition
    /// — skip emission but still pop the stack slots so outer scopes stay in
    /// sync.
    /// </summary>
    private void PopDeferScope()
    {
        var mark = _deferScopeMarks.Pop();
        EmitDefersDownTo(mark);
        while (_deferStack.Count > mark)
            _deferStack.Pop();
    }

    /// <summary>
    /// Emit every defer from the top of the stack down to (exclusive)
    /// <paramref name="targetDepth"/>, in LIFO order. Does NOT mutate the
    /// stack - callers decide whether a transition is a pop (scope exit) or
    /// just a traversal (`return`/`break`/`continue`, which terminate the
    /// current block but leave the stack for the enclosing scopes' own
    /// exits).
    /// </summary>
    private void EmitDefersDownTo(int targetDepth)
    {
        if (_currentBlock.IsTerminated) return;
        if (_deferStack.Count <= targetDepth) return;

        // Stack<T> enumerates top-to-bottom — LIFO is the natural iteration.
        var count = _deferStack.Count - targetDepth;
        foreach (var expr in _deferStack.Take(count))
        {
            if (_currentBlock.IsTerminated) break;
            LowerExpression(expr);
        }
    }

    // =========================================================================
    // Expression lowering
    // =========================================================================

    private Value LowerExpression(ExpressionNode expr, IrType? expectedType = null)
    {
        _ctx.Span = expr.Span;
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
            InterpolatedStringExpressionNode interp when interp.DesugaredBlock != null
                => LowerExpression(interp.DesugaredBlock, expectedType),
            TryExpressionNode tryExpr when tryExpr.DesugaredMatch != null
                => LowerExpression(tryExpr.DesugaredMatch, expectedType),
            ReturnNode ret => LowerReturnExpr(ret),
            BreakNode brk => LowerBreakExpr(brk),
            ContinueNode cont => LowerContinueExpr(cont),
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
        var stringNominal = _types.LookupNominal(WellKnown.String)
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
        // `null` desugars to Option.None. The expected type was filled in
        // by inference; here we emit the appropriate None representation.
        var irType = GetIrType(nullLit);
        if (IsAnyOption(irType))
            return EmitOptionNone(irType);

        // Fallback: unable to resolve as Option (should have been caught
        // by the type checker — emits zero of the expected type to keep
        // codegen well-formed).
        return new IntConstantValue(0, irType);
    }

    /// <summary>
    /// Lower a generic type instantiation in expression context (e.g., Foo(i32) used as type-as-value).
    /// Emits a reference to the RTTI type info global, same as bare type identifiers like i32 or Point.
    /// </summary>
    private Value LowerTypeInstantiation(CallExpressionNode call)
    {
        var resolvedType = _types.GetResolvedType(call);
        if (resolvedType is NominalType { Name: "core.rtti.Type" } typeNom
            && typeNom.TypeArguments.Count > 0)
        {
            EnsureTypeTableExists();
            var key = BuildTypeKey(typeNom.TypeArguments[0]);
            if (_typeTableGlobals != null && _typeTableGlobals.TryGetValue(key, out var typeInfoGlobal))
            {
                var typeIrType = _layout.Lower(resolvedType);
                return _currentBlock.EmitLoad(typeInfoGlobal, typeIrType);
            }
        }
        // Fallback: should not happen for correctly typed code
        return new IntConstantValue(0, _layout.Lower(resolvedType));
    }

    /// <summary>
    /// Lower a large-value argument. Returns an <c>IrPointer</c> when the
    /// source expression is already backed by a stack slot (local variable or
    /// by-ref parameter) so the call site can forward that pointer directly.
    /// For rvalue expressions falls back to <see cref="LowerExpression"/> — the
    /// caller then allocas a slot and stores the value into it.
    /// </summary>
    private Value LowerLargeValueArg(ExpressionNode expr, IrType expectedType)
    {
        if (expr is IdentifierExpressionNode id
            && _locals.TryGetValue(id.Name, out var localVal)
            && localVal.IrType is IrPointer ptrType
            && ptrType.Pointee.Equals(expectedType))
        {
            // Local variables, by-ref parameters, and parameters promoted by
            // PromoteMutatedParameters all store an IrPointer in _locals. We
            // can forward it directly only when the pointed-to type matches
            // the callee's expected param type — mismatches (e.g. array → slice
            // coercion) must go through LowerExpression so coercions still fire.
            return localVal;
        }
        return LowerExpression(expr, expectedType);
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
                    return _currentBlock.EmitLoad(localVal, innerType);
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

            return _currentBlock.EmitLoad(localVal, irType);
        }

        var inferredType = _types.GetResolvedType(id);

        // Check for function reference
        if (inferredType is FunctionType)
            return new FunctionReferenceValue(id.Name, GetIrType(id));

        // Check for global constant
        if (_globalConstants.TryGetValue(id.Name, out var globalVal))
            return globalVal;

        // Check for type-as-value (e.g., u8 in size_of(u8)) — Type(T) with RTTI
        var resolvedType = _types.Resolve(inferredType);
        if (resolvedType is NominalType { Name: "core.rtti.Type" } typeNom
            && typeNom.TypeArguments.Count > 0)
        {
            EnsureTypeTableExists();
            var key = BuildTypeKey(typeNom.TypeArguments[0]);
            if (_typeTableGlobals != null && _typeTableGlobals.TryGetValue(key, out var typeInfoGlobal))
            {
                var typeIrType = GetIrType(id);
                return _currentBlock.EmitLoad(typeInfoGlobal, typeIrType);
            }
        }

        // Check for bare enum variant (payload-less variant constructor used as identifier)
        var idIrType = _layout.Lower(inferredType);
        if (idIrType is IrEnum irEnum)
        {
            return LowerBareVariant(id.Name, irEnum);
        }

        // `None` of an Option(&T) lowers to a NULL nullable pointer (niche
        // representation). Without this branch, niche-typed `None` falls
        // through to the E3002 path because `idIrType` is IrPointer, not
        // IrEnum.
        if (id.Name == "None" && IsAnyOption(idIrType))
        {
            return EmitOptionNone(idIrType);
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
            var fnContext = _currentFunction?.Name ?? "(unknown)";
            _diagnostics.Add(Diagnostic.Error(
                $"Variant `{variantName}` not found in enum `{irEnum.Name}` (in function `{fnContext}`)",
                default, hint, "E3037"));
            return new IntConstantValue(0, irEnum);
        }

        var variant = foundVariant.Value;

        // Alloca + store tag + load
        var enumPtr = _currentBlock.EmitAlloca(irEnum);

        EmitStoreToOffset(enumPtr, 0, new IntConstantValue(variant.TagValue, TypeLayoutService.IrI32), TypeLayoutService.IrI32);

        return _currentBlock.EmitLoad(enumPtr, irEnum);
    }

    private Value LowerCall(CallExpressionNode call)
    {
        var retIrType = GetIrType(call);

        // Intrinsic: `core.rtti.project_info()` — substituted at lowering with
        // a load of the global ProjectInfo constant for the project that owns
        // this call site's source file. The function's declared body is never
        // executed.
        if (IsProjectInfoIntrinsic(call))
            return LowerProjectInfoIntrinsic(call, retIrType);

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
            // op_deref chain: transform receiver through op_deref calls before passing to callee
            if (call.UfcsOpDerefChain is { Count: > 0 })
            {
                // For local-variable receivers, pass the alloca pointer directly to the first
                // op_deref so mutations through the chain (e.g. RFC-014 op_call on Owned(Counter))
                // hit the original storage. LowerExpression(id) loads the value, which would
                // make op_deref operate on a copy.
                Value receiverVal;
                if (call.UfcsReceiver is IdentifierExpressionNode receiverIdent
                    && _locals.TryGetValue(receiverIdent.Name, out var receiverAlloca)
                    && (!_parameters.Contains(receiverIdent.Name) || _byRefParams.Contains(receiverIdent.Name))
                    && receiverAlloca.IrType is IrPointer recvPtrTy
                    && recvPtrTy.Pointee is not IrPointer)
                {
                    receiverVal = receiverAlloca;
                }
                else
                {
                    receiverVal = LowerExpression(call.UfcsReceiver);
                }

                foreach (var derefFn in call.UfcsOpDerefChain)
                {
                    // op_deref expects &Self — ensure we have a pointer
                    if (receiverVal.IrType is not IrPointer)
                    {
                        var temp = _currentBlock.EmitAlloca(receiverVal.IrType ?? TypeLayoutService.IrVoidPrim);
                        _currentBlock.EmitStorePtr(temp, receiverVal);
                        receiverVal = temp;
                    }

                    var calleeParams = new List<IrType>();
                    foreach (var param in derefFn.Parameters)
                        calleeParams.Add(GetIrType(param));

                    var derefHmType = GetFunctionHmType(derefFn);
                    var derefRetIrType = _layout.Lower(derefHmType.ReturnType);

                    var isForeignDeref = (derefFn.Modifiers & FunctionModifiers.Foreign) != 0;
                    receiverVal = _currentBlock.EmitCall(derefFn.Name, [receiverVal], derefRetIrType, calleeParams,
                        isForeign: isForeignDeref);
                }

                // receiverVal is now &T from the last op_deref. Pass it directly as the first arg.
                args.Add(receiverVal);
                // Skip the normal receiver processing below
                goto AfterUfcsReceiver;
            }

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
                             (!isForeignCheck && firstParamIrType != null && TypeLayoutService.IsLargeValue(firstParamIrType) && !TypeLayoutService.UsesCCallingConvention(firstParamIrType));

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
                        baseVal = _currentBlock.EmitLoad(baseVal, derefPtrType.Pointee);
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
                        var fieldPtr = _currentBlock.EmitGEP(baseVal, field.ByteOffset, field.Type);
                        args.Add(fieldPtr);
                    }
                }
                else
                {
                    // Fallback: base is a value, copy + materialize pointer
                    var receiverVal = LowerExpression(call.UfcsReceiver);
                    var receiverIrType = receiverVal.IrType ?? TypeLayoutService.IrVoidPrim;
                    var temp = _currentBlock.EmitAlloca(receiverIrType);
                    _currentBlock.EmitStorePtr(temp, receiverVal);
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
                    var temp = _currentBlock.EmitAlloca(receiverIrType);
                    _currentBlock.EmitStorePtr(temp, receiverVal);
                    args.Add(temp);
                }
                else if (!needsByRef && receiverVal.IrType is IrPointer recvPtr)
                {
                    // Callee expects value but receiver is a pointer (e.g. self: &List(T)
                    // calling as_slice(self: List(T))) — deref the pointer
                    args.Add(_currentBlock.EmitLoad(receiverVal, recvPtr.Pointee));
                }
                else
                {
                    args.Add(receiverVal);
                }
            }
        }
        AfterUfcsReceiver:

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
                    var tmpPtr = _currentBlock.EmitAlloca(sliceStruct);
                    // ptr = NULL (0 cast to pointer)
                    EmitStoreToOffset(tmpPtr, ptrField.ByteOffset,
                        new IntConstantValue(0, ptrField.Type), ptrField.Type);
                    // len = 0
                    EmitStoreToOffset(tmpPtr, lenField.ByteOffset,
                        new IntConstantValue(0, TypeLayoutService.IrUSize), lenField.Type);
                    var loaded = _currentBlock.EmitLoad(tmpPtr, sliceStruct);

                    if (!isForeign && TypeLayoutService.IsLargeValue(expectedParamType) && !TypeLayoutService.UsesCCallingConvention(expectedParamType))
                    {
                        var temp = _currentBlock.EmitAlloca(sliceStruct);
                        _currentBlock.EmitStorePtr(temp, loaded);
                        args.Add(temp);
                    }
                    else
                    {
                        args.Add(loaded);
                    }
                    continue;
                }
            }

            var needsByRef = !isForeign && expectedParamType != null
                && TypeLayoutService.IsLargeValue(expectedParamType)
                && !TypeLayoutService.UsesCCallingConvention(expectedParamType);

            // Fast path for large-value arguments: if the expression is already
            // backed by a stack slot (local variable, by-ref parameter), forward
            // that pointer directly instead of loading and re-materializing into
            // a fresh alloca. The callee's copy-before-mutate semantics make this
            // safe — reads go through the pointer directly, writes trigger a COW
            // copy inside the callee.
            var argVal = needsByRef
                ? LowerLargeValueArg(callArguments[i], expectedParamType!)
                : LowerExpression(callArguments[i], expectedParamType);

            if (needsByRef && argVal.IrType is not IrPointer)
            {
                var argIrType = argVal.IrType ?? expectedParamType!;
                var temp = _currentBlock.EmitAlloca(argIrType);
                _currentBlock.EmitStorePtr(temp, argVal);
                args.Add(temp);
            }
            else
            {
                args.Add(argVal);
            }
        }

        // For foreign calls returning Option(T) in the tagged-enum form,
        // wrap the raw pointer return in Some/None based on null check.
        // Option(&T) is already niche-optimized to IrPointer{IsNullable:true}
        // so no wrap is needed there — the C function returns a raw pointer
        // and the IR type is already the nullable pointer.
        IrEnum? foreignOptionEnum = null;
        var actualRetType = retIrType;
        if (isForeign && IsEnumOption(retIrType))
        {
            var optionEnum = (IrEnum)retIrType;
            var someVariant = FindVariant(optionEnum, "Some");
            if (someVariant.PayloadType is IrPointer payloadPtr)
            {
                actualRetType = payloadPtr;
                foreignOptionEnum = optionEnum;
            }
        }

        // Return slot: non-foreign, non-indirect call returning large value
        if (!isForeign && !call.IsIndirectCall && TypeLayoutService.IsLargeValue(retIrType) && !TypeLayoutService.UsesCCallingConvention(retIrType) && foreignOptionEnum == null)
        {
            return _currentBlock.EmitCall(targetName, args, retIrType, calleeIrParamTypes);
        }

        var result = _currentBlock.EmitCall(targetName, args, actualRetType, calleeIrParamTypes,
            isForeign: isForeign, isIndirect: call.IsIndirectCall);

        // Wrap foreign raw-pointer return into Option enum: ptr != NULL -> Some(ptr), else None.
        if (foreignOptionEnum != null)
        {
            var someVariant = FindVariant(foreignOptionEnum, "Some");
            var noneVariant = FindVariant(foreignOptionEnum, "None");
            var nullVal = new IntConstantValue(0, result.IrType!);
            var isNonNull = _currentBlock.EmitBinary(BinaryOp.NotEqual, result, nullVal, TypeLayoutService.IrBool);

            var slot = _currentBlock.EmitAlloca(foreignOptionEnum);
            var thenBlock = CreateBlock("foreign_opt_some");
            var elseBlock = CreateBlock("foreign_opt_none");
            var contBlock = CreateBlock("foreign_opt_cont");
            _currentBlock.EmitBranch(isNonNull, thenBlock, elseBlock);

            _currentBlock = thenBlock;
            EmitStoreToOffset(slot, 0,
                new IntConstantValue(someVariant.TagValue, TypeLayoutService.IrI32),
                TypeLayoutService.IrI32);
            EmitStoreToOffset(slot, someVariant.PayloadOffset, result, someVariant.PayloadType!);
            _currentBlock.EmitJump(contBlock);

            _currentBlock = elseBlock;
            EmitStoreToOffset(slot, 0,
                new IntConstantValue(noneVariant.TagValue, TypeLayoutService.IrI32),
                TypeLayoutService.IrI32);
            _currentBlock.EmitJump(contBlock);

            _currentBlock = contBlock;
            return _currentBlock.EmitLoad(slot, foreignOptionEnum);
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
            baseVal = _currentBlock.EmitLoad(baseVal, ptrType.Pointee);
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
                var tmpPtr = _currentBlock.EmitAlloca(baseIrType);
                _currentBlock.EmitStorePtr(tmpPtr, baseVal);
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

        // Lower arguments
        var args = new List<Value>();
        var fnPtrSig = funcPtrVal.IrType as IrFunctionPtr;
        for (int i = 0; i < call.Arguments.Count; i++)
            args.Add(LowerIndirectArg(call.Arguments[i], fnPtrSig, i));

        return _currentBlock.EmitIndirectCall(funcPtrVal, args, retIrType);
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
                funcPtrVal = _currentBlock.EmitLoad(localPtr, ptrToFn.Pointee);
            else
                funcPtrVal = localPtr;
        }
        else
        {
            // Fall back to a named reference (e.g. global function pointer)
            funcPtrVal = new LocalValue(call.FunctionName, retIrType);
        }

        // Lower arguments
        var args = new List<Value>();
        var fnPtrSig = funcPtrVal.IrType as IrFunctionPtr;
        for (int i = 0; i < call.Arguments.Count; i++)
            args.Add(LowerIndirectArg(call.Arguments[i], fnPtrSig, i));

        return _currentBlock.EmitIndirectCall(funcPtrVal, args, retIrType);
    }

    private Value LowerIndirectArg(ExpressionNode arg, IrFunctionPtr? sig, int paramIdx)
    {
        if (sig != null && paramIdx < sig.Params.Length)
        {
            var expected = sig.Params[paramIdx];
            if (TypeLayoutService.IsLargeValue(expected) && !TypeLayoutService.UsesCCallingConvention(expected))
                return LowerLargeValueArg(arg, expected);
        }
        return LowerExpression(arg);
    }

    private Value LowerShortCircuitLogical(BinaryExpressionNode binary)
    {
        var isAnd = binary.Operator == BinaryOperatorKind.And;
        var left = LowerExpression(binary.Left);

        // Allocate result on stack
        var resultPtr = _currentBlock.EmitAlloca(TypeLayoutService.IrBool);

        // Store short-circuit default: false for 'and', true for 'or'
        var defaultVal = new IntConstantValue(isAnd ? 0 : 1, TypeLayoutService.IrBool);
        _currentBlock.EmitStorePtr(resultPtr, defaultVal);

        var rhsBlock = CreateBlock(isAnd ? "and_rhs" : "or_rhs");
        var mergeBlock = CreateBlock(isAnd ? "and_merge" : "or_merge");

        // For 'and': if LHS is true, evaluate RHS; else skip (result stays false)
        // For 'or':  if LHS is false, evaluate RHS; else skip (result stays true)
        if (isAnd)
            _currentBlock.EmitBranch(left, rhsBlock, mergeBlock);
        else
            _currentBlock.EmitBranch(left, mergeBlock, rhsBlock);

        // RHS block: evaluate right side and store
        _currentBlock = rhsBlock;
        var right = LowerExpression(binary.Right);
        _currentBlock.EmitStorePtr(resultPtr, right);
        _currentBlock.EmitJump(mergeBlock);

        // Merge block: load and return result
        _currentBlock = mergeBlock;
        return _currentBlock.EmitLoad(resultPtr, TypeLayoutService.IrBool);
    }

    private Value LowerBinary(BinaryExpressionNode binary)
    {
        var resolved = _types.GetResolvedOperator(binary);
        if (resolved != null)
            return LowerOperatorFunctionCall(binary, resolved);

        var left = LowerExpression(binary.Left);
        var right = LowerExpression(binary.Right);

        // Bare-enum `==` / `!=`: extract and compare tags (i32 at offset 0).
        // The typechecker only routes this path for bare enums (no payloads),
        // so the enum value is just its tag — no need to compare payload bytes.
        if (binary.Operator is BinaryOperatorKind.Equal or BinaryOperatorKind.NotEqual
            && left.IrType is IrEnum && right.IrType is IrEnum)
        {
            var lt = ExtractEnumTag(left, "eq_tag_l");
            var rt = ExtractEnumTag(right, "eq_tag_r");
            var cmpOp = binary.Operator == BinaryOperatorKind.Equal ? BinaryOp.Equal : BinaryOp.NotEqual;
            return _currentBlock.EmitBinary(cmpOp, lt, rt, TypeLayoutService.IrBool);
        }

        var irType = GetIrType(binary);

        var op = MapBinaryOp(binary.Operator);
        return _currentBlock.EmitBinary(op, left, right, irType);
    }

    /// <summary>
    /// Materialize an enum value to stack if needed, then load its tag field
    /// (always i32 at offset 0). Used by bare-enum equality and other call
    /// sites that need to peek the discriminant.
    /// </summary>
    private Value ExtractEnumTag(Value enumVal, string label)
    {
        Value ptr;
        if (enumVal.IrType is IrPointer)
        {
            ptr = enumVal;
        }
        else
        {
            ptr = _currentBlock.EmitAlloca(enumVal.IrType!);
            _currentBlock.EmitStorePtr(ptr, enumVal);
        }
        return EmitLoadFromOffset(ptr, 0, TypeLayoutService.IrI32, label);
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
                var temp = _currentBlock.EmitAlloca(argIrType);
                _currentBlock.EmitStorePtr(temp, args[i]);
                args[i] = temp;
            }
        }

        // Determine return type: for CmpDerived, the call returns the function's return type (Ord/i32)
        var fnHmType = GetFunctionHmType(fn);
        var callRetIrType = _layout.Lower(fnHmType.ReturnType);

        var isForeignOp = (fn.Modifiers & FunctionModifiers.Foreign) != 0;
        var callResult = _currentBlock.EmitCall(fn.Name, args, callRetIrType, calleeIrParamTypes,
            isForeign: isForeignOp);

        // Auto-derived op_eq/op_ne: negate the complement's result
        if (resolved.NegateResult)
            return _currentBlock.EmitUnary(UnaryOp.Not, callResult, callRetIrType);

        // Auto-derived from op_cmp: extract tag from Ord enum, compare against 0
        if (resolved.CmpDerivedOperator is { } cmpOp)
        {
            var ordPtr = _currentBlock.EmitAlloca(callRetIrType);
            _currentBlock.EmitStorePtr(ordPtr, callResult);

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
            return _currentBlock.EmitBinary(irOp, tagValue, zero, TypeLayoutService.IrBool);
        }

        return callResult;
    }

    private Value LowerUnary(UnaryExpressionNode unary)
    {
        // Check table for resolved operator function
        var resolved = _types.GetResolvedOperator(unary);
        if (resolved != null)
            return LowerOperatorFunctionCall(unary, resolved);

        var operand = LowerExpression(unary.Operand);
        var irType = GetIrType(unary);

        var op = unary.Operator switch
        {
            UnaryOperatorKind.Negate => UnaryOp.Negate,
            UnaryOperatorKind.Not => UnaryOp.Not,
            UnaryOperatorKind.BitwiseNot => UnaryOp.BitwiseNot,
            _ => UnaryOp.Negate
        };

        return _currentBlock.EmitUnary(op, operand, irType);
    }

    private Value LowerMemberAccess(MemberAccessExpressionNode member)
    {
        var fieldName = member.FieldName;

        // Check if this is an enum variant access (e.g., FileMode.Read)
        // The target's inferred type is the enum type, and the member is a variant name.
        var resolvedTarget = _types.GetResolvedType(member.Target);
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
                return _currentBlock.EmitCast(targetVal, elemPtrType);
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
                baseVal = _currentBlock.EmitLoad(baseVal, ptrType.Pointee);
                baseIrType = ptrType.Pointee;
            }
        }

        // op_deref chain: call each op_deref function to transparently unwrap smart pointers
        if (member.OpDerefChain is { Count: > 0 })
        {
            foreach (var derefFn in member.OpDerefChain)
            {
                // op_deref expects &Self — ensure baseVal is a pointer
                if (baseVal.IrType is not IrPointer)
                {
                    var temp = _currentBlock.EmitAlloca(baseVal.IrType ?? TypeLayoutService.IrVoidPrim);
                    _currentBlock.EmitStorePtr(temp, baseVal);
                    baseVal = temp;
                }

                // Build callee param types for name mangling
                var calleeParams = new List<IrType>();
                foreach (var param in derefFn.Parameters)
                    calleeParams.Add(GetIrType(param));

                // Get return type (&T)
                var fnHmType = GetFunctionHmType(derefFn);
                var retIrType = _layout.Lower(fnHmType.ReturnType);

                var isForeign = (derefFn.Modifiers & FunctionModifiers.Foreign) != 0;
                baseVal = _currentBlock.EmitCall(derefFn.Name, [baseVal], retIrType, calleeParams,
                    isForeign: isForeign);
                baseIrType = retIrType;

                // Result is &T (a pointer). For the next op_deref or for GEP field access,
                // we need the pointee. If pointee is a struct, GEP operates on the pointer directly.
                if (baseIrType is IrPointer derefPtr)
                {
                    if (derefPtr.Pointee is IrStruct or IrEnum)
                    {
                        baseIrType = derefPtr.Pointee;
                        // Keep baseVal as pointer — GEP needs pointer base
                    }
                    else
                    {
                        // Peel through to get the struct pointer for next iteration
                        baseVal = _currentBlock.EmitLoad(baseVal, derefPtr.Pointee);
                        baseIrType = derefPtr.Pointee;
                    }
                }
            }

            // Refresh fieldIrType — the type checker resolved it after the full chain
            fieldIrType = GetIrType(member);
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
            var targetHmType = _types.GetResolvedType(member.Target);
            if (targetHmType is NominalType { Name: "core.rtti.Type" })
            {
                var typeInfo = _types.LookupNominal("core.rtti.TypeInfo");
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
                var tmpPtr = _currentBlock.EmitAlloca(baseIrType);
                _currentBlock.EmitStorePtr(tmpPtr, baseVal);
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
                var hmSrcType = _types.GetResolvedType(cast.Expression);
                int length = 0;
                if (hmSrcType is Core.Types.ArrayType arrHm)
                    length = arrHm.Length;

                var tmpPtr = _currentBlock.EmitAlloca(sliceTarget);

                EmitStoreToOffset(tmpPtr, ptrField.ByteOffset, srcVal, ptrField.Type);
                EmitStoreToOffset(tmpPtr, lenField.ByteOffset,
                    new IntConstantValue(length, TypeLayoutService.IrUSize), lenField.Type);

                return _currentBlock.EmitLoad(tmpPtr, sliceTarget);
            }
        }

        // Constant folding for primitive casts
        if (srcVal is IntConstantValue constSrc && targetIrType is IrPrimitive)
            return new IntConstantValue(constSrc.IntValue, targetIrType);

        // Emit cast instruction — pass null! for TypeBase, codegen uses IrType
        return _currentBlock.EmitCast(srcVal, targetIrType);
    }

    private Value LowerBlock(BlockExpressionNode block)
    {
        // Each block is a defer scope: defers registered inside it fire on
        // exit (normal fall-through, or on any escaping jump). `PopDeferScope`
        // handles both cases — it emits+pops on fall-through, and just pops
        // if the block is already terminated by an inner return/break/continue.
        PushDeferScope();
        try
        {
            foreach (var stmt in block.Statements)
                LowerStatement(stmt);

            if (block.TrailingExpression != null)
            {
                var result = LowerExpression(block.TrailingExpression);
                PopDeferScope();
                return result;
            }
        }
        catch
        {
            // Keep the scope stack balanced on lowering errors.
            if (_deferScopeMarks.Count > 0)
            {
                var mark = _deferScopeMarks.Pop();
                while (_deferStack.Count > mark) _deferStack.Pop();
            }
            throw;
        }

        PopDeferScope();
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
            resultPtr = _currentBlock.EmitAlloca(resultIrType);

        _currentBlock.EmitBranch(condVal, thenBlock, elseBlock);

        // Then branch
        _currentBlock = thenBlock;
        var thenVal = LowerExpression(ifExpr.ThenBranch, isVoid ? null : resultIrType);
        if (!isVoid && resultPtr != null)
            _currentBlock.EmitStorePtr(resultPtr, thenVal);
        _currentBlock.EmitJumpIfNotTerminated(mergeBlock);

        // Else branch
        _currentBlock = elseBlock;
        if (ifExpr.ElseBranch != null)
        {
            var elseVal = LowerExpression(ifExpr.ElseBranch, isVoid ? null : resultIrType);
            if (!isVoid && resultPtr != null)
                _currentBlock.EmitStorePtr(resultPtr, elseVal);
        }
        _currentBlock.EmitJumpIfNotTerminated(mergeBlock);

        // Merge
        _currentBlock = mergeBlock;

        if (!isVoid && resultPtr != null)
            return _currentBlock.EmitLoad(resultPtr, resultIrType);

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

        // &container[i] with a ref-form op_index_ref — call op_index_ref(&base, idx) &T
        // directly and return the resulting pointer, skipping the dereference
        // that LowerIndex would perform in read position.
        if (addrOf.Target is IndexExpressionNode refIdxTarget
            && _types.GetResolvedOperator(refIdxTarget) is { IsRefForm: true } refResolved)
        {
            return LowerIndexAddress(refIdxTarget, refResolved);
        }

        // &arr[i] — compute element address directly via GEP instead of load+address-of
        if (addrOf.Target is IndexExpressionNode indexTarget
            && _types.GetResolvedOperator(indexTarget) == null)
        {
            var arrVal = LowerExpression(indexTarget.Base);
            var idxVal = LowerExpression(indexTarget.Index);
            var elemIrType = GetIrType(indexTarget);

            // If base is a Slice struct, extract .ptr field
            var basePtr = arrVal;
            if (arrVal.IrType is IrStruct sliceBase2)
            {
                var ptrField = sliceBase2.Fields.FirstOrDefault(f => f.Name == "ptr");
                if (ptrField.Type != null)
                    basePtr = CoerceSliceToPointer(arrVal, sliceBase2, ptrField);
            }

            var elementSize = new IntConstantValue(elemIrType.Size, TypeLayoutService.IrUSize);
            var byteOffset = _currentBlock.EmitBinary(BinaryOp.Multiply, idxVal, elementSize, TypeLayoutService.IrUSize);
            return _currentBlock.EmitGEP(basePtr, byteOffset, elemIrType);
        }

        // &target.field — compute a GEP pointer to the field in-place instead of
        // loading the field value and taking its address (which would be a dangling pointer).
        if (addrOf.Target is MemberAccessExpressionNode memberTarget)
        {
            var targetVal = LowerExpression(memberTarget.Target);
            var baseVal = targetVal;
            var baseIrType = targetVal.IrType;

            // Auto-deref through pointer layers (keep the last struct pointer)
            for (int i = 0; i < memberTarget.AutoDerefCount; i++)
            {
                if (baseIrType is IrPointer derefPtrType)
                {
                    if (derefPtrType.Pointee is IrStruct or IrEnum)
                    {
                        baseIrType = derefPtrType.Pointee;
                        break;
                    }
                    baseVal = _currentBlock.EmitLoad(baseVal, derefPtrType.Pointee);
                    baseIrType = derefPtrType.Pointee;
                }
            }

            // op_deref chain
            if (memberTarget.OpDerefChain is { Count: > 0 })
            {
                foreach (var derefFn in memberTarget.OpDerefChain)
                {
                    if (baseVal.IrType is not IrPointer)
                    {
                        var temp = _currentBlock.EmitAlloca(baseVal.IrType ?? TypeLayoutService.IrVoidPrim);
                        _currentBlock.EmitStorePtr(temp, baseVal);
                        baseVal = temp;
                    }

                    var calleeParams = new List<IrType>();
                    foreach (var param in derefFn.Parameters)
                        calleeParams.Add(GetIrType(param));

                    var derefHmType = GetFunctionHmType(derefFn);
                    var derefRetIrType = _layout.Lower(derefHmType.ReturnType);

                    var isForeignDeref = (derefFn.Modifiers & FunctionModifiers.Foreign) != 0;
                    baseVal = _currentBlock.EmitCall(derefFn.Name, [baseVal], derefRetIrType, calleeParams,
                        isForeign: isForeignDeref);
                    baseIrType = derefRetIrType;

                    if (baseIrType is IrPointer dp && dp.Pointee is IrStruct or IrEnum)
                        baseIrType = dp.Pointee;
                }
            }

            // Ensure we have a pointer base for GEP
            if (baseVal.IrType is not IrPointer && baseIrType is IrStruct or IrEnum)
            {
                // value on stack — use original alloca if possible
                if (memberTarget.Target is IdentifierExpressionNode tid
                    && _locals.TryGetValue(tid.Name, out var lp)
                    && lp.IrType is IrPointer
                    && (!_parameters.Contains(tid.Name) || _byRefParams.Contains(tid.Name))
                    && memberTarget.AutoDerefCount == 0
                    && memberTarget.OpDerefChain is null or { Count: 0 })
                {
                    baseVal = lp;
                }
                else
                {
                    var tmp = _currentBlock.EmitAlloca(baseVal.IrType ?? TypeLayoutService.IrVoidPrim);
                    _currentBlock.EmitStorePtr(tmp, baseVal);
                    baseVal = tmp;
                }
            }

            IrStruct? structType = baseIrType switch
            {
                IrStruct s => s,
                IrPointer { Pointee: IrStruct s } => s,
                _ => null
            };

            if (structType != null)
            {
                var field = FindField(structType, memberTarget.FieldName);
                return _currentBlock.EmitGEP(baseVal, field.ByteOffset, field.Type);
            }
        }

        // Temporary promotion: if target is a call result, materialize on the stack
        // so we can take its address (same pattern as UFCS temp materialization).
        if (addrOf.Target is CallExpressionNode)
        {
            var targetVal = LowerExpression(addrOf.Target);
            var valType = targetVal.IrType ?? TypeLayoutService.IrVoidPrim;
            var temp = _currentBlock.EmitAlloca(valType);
            _currentBlock.EmitStorePtr(temp, targetVal);
            return temp;
        }

        // General case: emit AddressOfInstruction
        var targetVal2 = LowerExpression(addrOf.Target);
        var irType = GetIrType(addrOf);
        return _currentBlock.EmitAddressOf(targetVal2.Name, irType is IrPointer ptr2 ? ptr2.Pointee : irType);
    }

    private Value LowerDereference(DereferenceExpressionNode deref)
    {
        // op_deref: call the resolved function instead of pointer load
        if (deref.ResolvedOpDeref is { } opDerefFn)
        {
            var targetVal = LowerExpression(deref.Target);

            // op_deref expects &Self — ensure target is a pointer
            if (targetVal.IrType is not IrPointer)
            {
                var temp = _currentBlock.EmitAlloca(targetVal.IrType ?? TypeLayoutService.IrVoidPrim);
                _currentBlock.EmitStorePtr(temp, targetVal);
                targetVal = temp;
            }

            var calleeParams = new List<IrType>();
            foreach (var param in opDerefFn.Parameters)
                calleeParams.Add(GetIrType(param));

            var fnHmType = GetFunctionHmType(opDerefFn);
            var retIrType = _layout.Lower(fnHmType.ReturnType);

            var isForeign = (opDerefFn.Modifiers & FunctionModifiers.Foreign) != 0;
            var callResult = _currentBlock.EmitCall(opDerefFn.Name, [targetVal], retIrType, calleeParams,
                isForeign: isForeign);

            // op_deref returns &T, load to get T (the dereference)
            var resultIrType = GetIrType(deref);
            return _currentBlock.EmitLoad(callResult, resultIrType);
        }

        var ptrVal = LowerExpression(deref.Target);
        var irType = GetIrType(deref);
        return _currentBlock.EmitLoad(ptrVal, irType);
    }

    private IntConstantValue LowerAssignment(AssignmentExpressionNode assign)
    {
        // Indexed assignment — two paths:
        //   ref-form:    op_index_ref(&base, idx) returns &T; store through it.
        //   value-form:  op_set_index(&base, idx, v) is an explicit setter call.
        // The type checker records the choice; ambiguity is rejected with E2077.
        if (assign.Target is IndexExpressionNode idx)
        {
            var idxResolved = _types.GetResolvedOperator(idx);
            if (idxResolved is { IsRefForm: true })
            {
                var ptrRef = LowerIndexAddress(idx, idxResolved);
                var pointeeIrType = (ptrRef.IrType as IrPointer)?.Pointee ?? GetIrType(idx);
                var rhsVal = LowerExpression(assign.Value, pointeeIrType);
                _currentBlock.EmitStorePtr(ptrRef, rhsVal);
                return new IntConstantValue(0, TypeLayoutService.IrVoidPrim);
            }

            var resolved = _types.GetResolvedOperator(assign);
            if (resolved != null)
                return LowerSetIndexCall(idx, assign.Value, resolved);
        }

        var ptr = LowerLValue(assign.Target);
        // Determine expected type from LValue's pointee type
        IrType? expectedType = ptr?.IrType is IrPointer ptrType ? ptrType.Pointee : null;
        var val = LowerExpression(assign.Value, expectedType);

        if (ptr != null)
            _currentBlock.EmitStorePtr(ptr, val);

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
                var temp = _currentBlock.EmitAlloca(baseIrType);
                _currentBlock.EmitStorePtr(temp, baseVal);
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

        _currentBlock.EmitCall(resolved.Function.Name, [baseVal, indexVal, val], TypeLayoutService.IrVoidPrim, calleeIrParamTypes);
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
        var resultPtr = _currentBlock.EmitAlloca(structIrType);

        // Zero-initialize the struct so unspecified fields get default values
        _currentBlock.EmitCall("memset",
            [resultPtr, new IntConstantValue(0, TypeLayoutService.IrI32), new IntConstantValue(structIrType.Size, TypeLayoutService.IrUSize)],
            TypeLayoutService.IrVoidPrim, calleeParamTypes: null, isForeign: true);

        foreach (var (fieldName, fieldExpr) in fields)
        {
            var irField = FindField(structIrType, fieldName);
            var fieldVal = LowerExpression(fieldExpr, irField.Type);

            EmitStoreToOffset(resultPtr, irField.ByteOffset, fieldVal, irField.Type);
        }

        return _currentBlock.EmitLoad(resultPtr, structIrType);
    }

    /// <summary>
    /// Construct a struct value from pre-lowered field values (alloca + GEP/store per field + load).
    /// </summary>
    private LocalValue BuildStruct(IrStruct structType, Dictionary<string, Value> fieldValues)
    {
        var resultPtr = _currentBlock.EmitAlloca(structType);

        // Zero-initialize the struct so unspecified fields get default values
        _currentBlock.EmitCall("memset",
            [resultPtr, new IntConstantValue(0, TypeLayoutService.IrI32), new IntConstantValue(structType.Size, TypeLayoutService.IrUSize)],
            TypeLayoutService.IrVoidPrim, calleeParamTypes: null, isForeign: true);

        foreach (var field in structType.Fields)
        {
            if (!fieldValues.TryGetValue(field.Name, out var val)) continue;
            EmitStoreToOffset(resultPtr, field.ByteOffset, val, field.Type);
        }

        return _currentBlock.EmitLoad(resultPtr, structType);
    }

    private LocalValue LowerArrayLiteral(ArrayLiteralExpressionNode arrLit)
    {
        var irType = GetIrType(arrLit);

        if (irType is not IrArray arrayIrType)
            throw new InternalCompilerError(
                $"Array literal target is not an array type: `{irType}`", arrLit.Span);

        var elementIrType = arrayIrType.Element;
        var allocaResult = _currentBlock.EmitAlloca(irType, isArrayStorage: true);

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
                _currentBlock.EmitCall("memset",
                    [allocaResult, new IntConstantValue(memsetByte, TypeLayoutService.IrI32),
                     new IntConstantValue(totalSize, TypeLayoutService.IrUSize)],
                    TypeLayoutService.IrVoidPrim, calleeParamTypes: null, isForeign: true);
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
                        var destPtr = _currentBlock.EmitGEP(allocaResult, filled * elemSize, elementIrType);
                        _currentBlock.EmitCall("memcpy",
                            [destPtr, allocaResult, new IntConstantValue(chunk * elemSize, TypeLayoutService.IrUSize)],
                            TypeLayoutService.IrVoidPrim, calleeParamTypes: null, isForeign: true);
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

    /// <summary>
    /// Emit a call to a ref-form <c>op_index_ref(&amp;Self, Idx) &amp;T</c> and return
    /// the resulting pointer. Shared by read position (load after), assignment
    /// (store through), and address-of (use pointer directly). Materializes
    /// the base as a pointer when it isn't already one.
    /// </summary>
    private Value LowerIndexAddress(IndexExpressionNode index, ResolvedOperator resolved)
    {
        var baseSemType = _types.GetResolvedType(index.Base);
        Value baseLv;
        if (baseSemType is Core.Types.ReferenceType)
        {
            baseLv = LowerExpression(index.Base);
        }
        else
        {
            baseLv = LowerLValue(index.Base) ?? LowerExpression(index.Base);
            if (baseLv.IrType is not IrPointer)
            {
                var baseIrType = baseLv.IrType ?? TypeLayoutService.IrVoidPrim;
                var temp = _currentBlock.EmitAlloca(baseIrType);
                _currentBlock.EmitStorePtr(temp, baseLv);
                baseLv = temp;
            }
        }

        var idxV = LowerExpression(index.Index);
        var calleeParamTypes = new List<IrType>();
        foreach (var param in resolved.Function.Parameters)
            calleeParamTypes.Add(GetIrType(param));

        var fnHmType = GetFunctionHmType(resolved.Function);
        var retIrType = _layout.Lower(fnHmType.ReturnType);

        var isForeign = (resolved.Function.Modifiers & FunctionModifiers.Foreign) != 0;
        return _currentBlock.EmitCall(resolved.Function.Name, [baseLv, idxV], retIrType, calleeParamTypes,
            isForeign: isForeign);
    }

    private Value LowerIndex(IndexExpressionNode index)
    {
        // If resolved to an op_index / op_index_ref function, emit as call
        var resolved = _types.GetResolvedOperator(index);
        if (resolved != null)
        {
            // Ref-form path: emit call that returns &T, then load *p for the value.
            if (resolved.IsRefForm)
            {
                var ptr = LowerIndexAddress(index, resolved);
                var retIrType = GetIrType(index);
                return _currentBlock.EmitLoad(ptr, retIrType);
            }

            // Value-form path: emit the call directly and use its return value.
            var baseVal = LowerExpression(index.Base);
            var indexVal = LowerExpression(index.Index);

            var retIrTypeV = GetIrType(index);

            var calleeIrParamTypes = new List<IrType>();
            foreach (var param in resolved.Function.Parameters)
                calleeIrParamTypes.Add(GetIrType(param));

            // Materialize base to a temp pointer if the callee expects a pointer
            // or if it's a large value type (implicit by-ref)
            var firstParamIsPtr = calleeIrParamTypes.Count > 0 && calleeIrParamTypes[0] is IrPointer;
            var firstParamNeedsByRef = firstParamIsPtr ||
                (calleeIrParamTypes.Count > 0 && TypeLayoutService.IsLargeValue(calleeIrParamTypes[0]) && !TypeLayoutService.UsesCCallingConvention(calleeIrParamTypes[0]));
            if (firstParamNeedsByRef && baseVal.IrType is not IrPointer)
            {
                var baseIrType = baseVal.IrType ?? TypeLayoutService.IrVoidPrim;
                var temp = _currentBlock.EmitAlloca(baseIrType);
                _currentBlock.EmitStorePtr(temp, baseVal);
                baseVal = temp;
            }

            return _currentBlock.EmitCall(resolved.Function.Name, [baseVal, indexVal], retIrTypeV, calleeIrParamTypes);
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
                var baseSemanticType = _types.GetResolvedType(index.Base);
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
        var byteOffset = _currentBlock.EmitBinary(BinaryOp.Multiply, idxVal, elementSize, TypeLayoutService.IrUSize);

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
        var rangePtr = _currentBlock.EmitAlloca(rangeStruct);
        _currentBlock.EmitStorePtr(rangePtr, rangeVal);

        var startVal = EmitLoadFromOffset(rangePtr, startField.ByteOffset, startField.Type, "rng_start");
        var endVal = EmitLoadFromOffset(rangePtr, endField.ByteOffset, endField.Type, "rng_end");

        // Get base pointer: for Slice, extract .ptr; for array, use array pointer directly
        Value basePtrVal;
        if (baseVal.IrType is IrStruct baseStruct && baseStruct.Name == WellKnown.Slice)
        {
            // Slice: extract .ptr field
            var ptrField = FindField(baseStruct, "ptr");
            var baseSpill = _currentBlock.EmitAlloca(baseStruct);
            _currentBlock.EmitStorePtr(baseSpill, baseVal);
            basePtrVal = EmitLoadFromOffset(baseSpill, ptrField.ByteOffset, ptrField.Type, "base_raw_ptr");
        }
        else
        {
            basePtrVal = baseVal;
        }

        // Compute new_ptr = base_ptr + start (byte offset, element is u8-sized for slices)
        var newPtr = _currentBlock.EmitBinary(BinaryOp.Add, basePtrVal, startVal, basePtrVal.IrType!);

        // Compute new_len = end - start
        var newLen = _currentBlock.EmitBinary(BinaryOp.Subtract, endVal, startVal, TypeLayoutService.IrUSize);

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
                var tmpPtr = _currentBlock.EmitAlloca(sliceStruct);
                _currentBlock.EmitStorePtr(tmpPtr, sliceVal);
                return EmitLoadFromOffset(tmpPtr, lenField.ByteOffset, lenField.Type, "slen_val");
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
            var baseSpill = _currentBlock.EmitAlloca(baseStruct);
            _currentBlock.EmitStorePtr(baseSpill, baseVal);
            basePtrVal = EmitLoadFromOffset(baseSpill, ptrField.ByteOffset, ptrField.Type, "base_raw_ptr");
        }
        else
        {
            basePtrVal = baseVal;
        }

        // Compute new_ptr = base_ptr + start
        var newPtr = _currentBlock.EmitBinary(BinaryOp.Add, basePtrVal, startVal, basePtrVal.IrType!);

        // Compute new_len = end - start
        var newLen = _currentBlock.EmitBinary(BinaryOp.Subtract, endVal, startVal, TypeLayoutService.IrUSize);

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

        var resultPtr = _currentBlock.EmitAlloca(rangeStruct);

        var startField = FindField(rangeStruct, "start");
        var endField = FindField(rangeStruct, "end");

        // Stack allocas are not zero-initialized at this layer. Omitted bounds
        // in partial ranges (`..n`, `n..`, `..`) would otherwise read garbage —
        // explicitly fill both fields with sensible defaults: 0 for missing
        // start, the field-type's max value for missing end (so user-defined
        // op_index that clamps `end` against `base.len` produces the slice the
        // caller expects).
        //
        // CAVEAT: built-in slicing of a non-literal `Range` value goes through
        // `LowerRangeSlicing`, which computes `len = end - start` with no
        // clamp. A Range constructed with `..` or `0..` and later used as
        // `arr[r]` therefore yields `len = USIZE_MAX`. The literal path
        // (`arr[..n]` directly) is unaffected — it uses
        // `LowerRangeSlicingWithBounds` with a properly-substituted end. Until
        // `LowerRangeSlicing` learns to clamp at runtime, callers indexing
        // built-in slices/arrays with stored Range values must provide
        // explicit bounds.
        if (range.Start != null)
        {
            var startVal = LowerExpression(range.Start);
            EmitStoreToOffset(resultPtr, startField.ByteOffset, startVal, startField.Type);
        }
        else
        {
            var zero = new IntConstantValue(0, startField.Type);
            EmitStoreToOffset(resultPtr, startField.ByteOffset, zero, startField.Type);
        }

        if (range.End != null)
        {
            var endVal = LowerExpression(range.End);
            EmitStoreToOffset(resultPtr, endField.ByteOffset, endVal, endField.Type);
        }
        else
        {
            // Largest representable value for the end-field type. For unsigned
            // ints that's all-ones; for signed it's the positive max. Either
            // way, user op_index implementations clamp against `len`.
            ulong maxBits = endField.Type.Size switch
            {
                1 => 0xFFUL,
                2 => 0xFFFFUL,
                4 => 0xFFFFFFFFUL,
                _ => 0xFFFFFFFFFFFFFFFFUL,
            };
            var maxVal = new IntConstantValue((long)maxBits, endField.Type);
            EmitStoreToOffset(resultPtr, endField.ByteOffset, maxVal, endField.Type);
        }

        return _currentBlock.EmitLoad(resultPtr, rangeStruct);
    }

    private Value LowerImplicitCoercion(ImplicitCoercionNode coercion)
    {
        var innerVal = LowerExpression(coercion.Inner);

        var targetIrType = GetIrType(coercion);

        switch (coercion.Kind)
        {
            case CoercionKind.IntegerWidening:
                return _currentBlock.EmitCast(innerVal, targetIrType);

            case CoercionKind.ReinterpretCast:
                {
                    // No-op: same binary representation, just change the IrType
                    innerVal.IrType = targetIrType;
                    return innerVal;
                }

            case CoercionKind.Wrap:
                {
                    // Wrap T -> Option(T) — handles both niche-optimized and tagged-enum forms.
                    if (IsAnyOption(targetIrType))
                        return EmitOptionSome(innerVal, targetIrType);

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
        var resolved = _types.GetResolvedOperator(coalesce);
        if (resolved != null)
        {
            var leftVal = LowerExpression(coalesce.Left);
            var rightVal = LowerExpression(coalesce.Right);

            var retIrType = GetIrType(coalesce);

            var calleeIrParamTypes = new List<IrType>();
            foreach (var param in resolved.Function.Parameters)
                calleeIrParamTypes.Add(GetIrType(param));

            return _currentBlock.EmitCall(resolved.Function.Name, [leftVal, rightVal], retIrType, calleeIrParamTypes);
        }

        // Inline Option(T) ?? T: if Some(v) then v else right
        var leftOption = LowerExpression(coalesce.Left);
        var resultIrType = GetIrType(coalesce);

        // Niche-optimized Option(&T): ptr != NULL ? ptr : right
        if (IsNicheOption(leftOption.IrType))
            return LowerCoalesceNiche(coalesce, leftOption, resultIrType);

        var leftIrType = leftOption.IrType;
        if (leftIrType is IrPointer ptrToOpt && ptrToOpt.Pointee is IrEnum)
            leftIrType = ptrToOpt.Pointee;

        if (!IsEnumOption(leftIrType))
            throw new InternalCompilerError(
                $"Coalesce left operand is not an Option: `{leftOption.IrType}`", coalesce.Span);

        var optionEnum = (IrEnum)leftIrType!;
        var leftPtr = MaterializeOptionPtr(leftOption, optionEnum);
        var isSome = EmitOptionIsSome(leftPtr, optionEnum);

        var resultPtr = _currentBlock.EmitAlloca(resultIrType);

        var thenBlock = CreateBlock("coal_then");
        var elseBlock = CreateBlock("coal_else");
        var mergeBlock = CreateBlock("coal_merge");

        _currentBlock.EmitBranch(isSome, thenBlock, elseBlock);

        // Then: left is Some
        _currentBlock = thenBlock;

        // Result is also Option => store the whole left Option (don't unwrap).
        bool resultIsOption = IsAnyOption(resultIrType);

        if (resultIsOption)
        {
            var leftLoaded = _currentBlock.EmitLoad(leftPtr, optionEnum);
            _currentBlock.EmitStorePtr(resultPtr, leftLoaded);
        }
        else
        {
            var someVariant = FindVariant(optionEnum, "Some");
            var payloadType = someVariant.PayloadType ?? resultIrType;
            var payload = EmitOptionUnwrap(leftPtr, optionEnum, payloadType);
            _currentBlock.EmitStorePtr(resultPtr, payload);
        }
        _currentBlock.EmitJump(mergeBlock);

        // Else: right
        _currentBlock = elseBlock;
        var rightVal2 = LowerExpression(coalesce.Right);
        _currentBlock.EmitStorePtr(resultPtr, rightVal2);
        _currentBlock.EmitJump(mergeBlock);

        // Merge
        _currentBlock = mergeBlock;
        return _currentBlock.EmitLoad(resultPtr, resultIrType);
    }

    private LocalValue LowerCoalesceNiche(CoalesceExpressionNode coalesce, Value leftOption, IrType resultIrType)
    {
        var nichePtr = (IrPointer)leftOption.IrType!;
        var nullVal = new IntConstantValue(0, nichePtr);
        var isNonNull = _currentBlock.EmitBinary(BinaryOp.NotEqual, leftOption, nullVal, TypeLayoutService.IrBool);

        var resultPtr = _currentBlock.EmitAlloca(resultIrType);

        var thenBlock = CreateBlock("coal_niche_then");
        var elseBlock = CreateBlock("coal_niche_else");
        var mergeBlock = CreateBlock("coal_niche_merge");
        _currentBlock.EmitBranch(isNonNull, thenBlock, elseBlock);

        // Then: use the pointer (strip nullable if result is non-option)
        _currentBlock = thenBlock;
        if (IsNicheOption(resultIrType))
        {
            _currentBlock.EmitStorePtr(resultPtr, leftOption);
        }
        else
        {
            var stripped = StripNullable(nichePtr);
            var castResult = _currentBlock.EmitCast(leftOption, stripped);
            _currentBlock.EmitStorePtr(resultPtr, castResult);
        }
        _currentBlock.EmitJump(mergeBlock);

        // Else: evaluate right
        _currentBlock = elseBlock;
        var rightVal = LowerExpression(coalesce.Right);
        _currentBlock.EmitStorePtr(resultPtr, rightVal);
        _currentBlock.EmitJump(mergeBlock);

        // Merge
        _currentBlock = mergeBlock;
        return _currentBlock.EmitLoad(resultPtr, resultIrType);
    }

    private LocalValue LowerNullPropagation(NullPropagationExpressionNode nullProp)
    {
        // target?.field — if target is Some(v): Some(v.field), else None
        var targetVal = LowerExpression(nullProp.Target);

        var resultIrType = GetIrType(nullProp);

        // Niche-optimized Option(&T): ptr != NULL ? ptr.field : null
        if (IsNicheOption(targetVal.IrType))
            return LowerNullPropagationNiche(nullProp, targetVal, resultIrType);

        // Resolve the target Option enum (possibly via pointer-to-enum).
        var targetIrType = targetVal.IrType;
        IrEnum? optionEnum = targetIrType as IrEnum;
        if (optionEnum == null && targetIrType is IrPointer { Pointee: IrEnum pe })
            optionEnum = pe;

        if (optionEnum == null || !IsEnumOption(optionEnum))
            throw new InternalCompilerError(
                $"Null propagation target is not an Option: `{targetIrType}`", nullProp.Span);

        var targetPtr = MaterializeOptionPtr(targetVal, optionEnum);
        var isSome = EmitOptionIsSome(targetPtr, optionEnum);

        var thenBlock = CreateBlock("np_then");
        var elseBlock = CreateBlock("np_else");
        var mergeBlock = CreateBlock("np_merge");

        var resultPtr = _currentBlock.EmitAlloca(resultIrType);
        _currentBlock.EmitBranch(isSome, thenBlock, elseBlock);

        // Then: access payload.field, wrap in new Option (if result is Option)
        _currentBlock = thenBlock;
        var someVariant = FindVariant(optionEnum, "Some");
        var payloadType = someVariant.PayloadType ?? throw new InternalCompilerError(
            $"Option.Some has no payload in `{optionEnum.Name}`", nullProp.Span);

        var payloadPtr = _currentBlock.EmitGEP(targetPtr, someVariant.PayloadOffset, payloadType);

        if (payloadType is not IrStruct innerStruct)
            throw new InternalCompilerError(
                $"Null propagation payload `{payloadType}` is not a struct", nullProp.Span);

        var memberField = FindField(innerStruct, nullProp.MemberName);
        var memberVal = EmitLoadFromOffset(payloadPtr, memberField.ByteOffset, memberField.Type, "np_member");

        // RFC-010 flattening: if the projected field is already an Option of
        // the right shape, store it directly instead of wrapping in Some(...).
        if (IsAnyOption(resultIrType) && !IsAnyOption(memberField.Type))
        {
            var someResult = EmitOptionSome(memberVal, resultIrType);
            _currentBlock.EmitStorePtr(resultPtr, someResult);
        }
        else
        {
            _currentBlock.EmitStorePtr(resultPtr, memberVal);
        }
        _currentBlock.EmitJump(mergeBlock);

        // Else: return None Option
        _currentBlock = elseBlock;
        if (IsAnyOption(resultIrType))
        {
            var noneResult = EmitOptionNone(resultIrType);
            _currentBlock.EmitStorePtr(resultPtr, noneResult);
        }
        _currentBlock.EmitJump(mergeBlock);

        // Merge
        _currentBlock = mergeBlock;
        return _currentBlock.EmitLoad(resultPtr, resultIrType);
    }

    private LocalValue LowerNullPropagationNiche(NullPropagationExpressionNode nullProp, Value targetVal, IrType resultIrType)
    {
        var nichePtr = (IrPointer)targetVal.IrType!;
        var nullVal = new IntConstantValue(0, nichePtr);
        var isNonNull = _currentBlock.EmitBinary(BinaryOp.NotEqual, targetVal, nullVal, TypeLayoutService.IrBool);

        var resultPtr = _currentBlock.EmitAlloca(resultIrType);

        var thenBlock = CreateBlock("np_niche_then");
        var elseBlock = CreateBlock("np_niche_else");
        var mergeBlock = CreateBlock("np_niche_merge");
        _currentBlock.EmitBranch(isNonNull, thenBlock, elseBlock);

        // Then: dereference the pointer, access field, wrap result
        _currentBlock = thenBlock;
        var strippedPtr = StripNullable(nichePtr);
        var castVal = _currentBlock.EmitCast(targetVal, strippedPtr);

        var innerType = strippedPtr.Pointee;
        if (innerType is IrStruct innerStruct)
        {
            var memberField = FindField(innerStruct, nullProp.MemberName);
            var memberVal = EmitLoadFromOffset(castVal, memberField.ByteOffset, memberField.Type, "np_member");

            // RFC-010 flattening: skip Some-wrap when the field is itself Option.
            if (IsAnyOption(resultIrType) && !IsAnyOption(memberField.Type))
            {
                var someResult = EmitOptionSome(memberVal, resultIrType);
                _currentBlock.EmitStorePtr(resultPtr, someResult);
            }
            else
            {
                _currentBlock.EmitStorePtr(resultPtr, memberVal);
            }
        }
        _currentBlock.EmitJump(mergeBlock);

        // Else: return None
        _currentBlock = elseBlock;
        if (IsAnyOption(resultIrType))
        {
            var noneResult = EmitOptionNone(resultIrType);
            _currentBlock.EmitStorePtr(resultPtr, noneResult);
        }
        _currentBlock.EmitJump(mergeBlock);

        // Merge
        _currentBlock = mergeBlock;
        return _currentBlock.EmitLoad(resultPtr, resultIrType);
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
        var hmType = _types.GetResolvedType(call);
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
        var enumPtr = _currentBlock.EmitAlloca(irEnum);

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
        return _currentBlock.EmitLoad(enumPtr, irEnum);
    }

    // =========================================================================
    // Match expression lowering
    // =========================================================================

    private Value LowerMatch(MatchExpressionNode match)
    {
        // 1. Lower scrutinee and resolve to enum type.
        // If scrutinee is a dereference (e.g. self.*), keep the original pointer
        // so match arm bindings (e.g. &obj) point into the original struct, not a dangling local copy.
        Value? originalEnumPtr = null;
        Value scrutineeValue;

        if (match.Scrutinee is DereferenceExpressionNode derefExpr)
        {
            var ptrVal = LowerExpression(derefExpr.Target);
            if (ptrVal.IrType is IrPointer { Pointee: IrEnum })
            {
                originalEnumPtr = ptrVal;
                // Load the value from the pointer for tag checks
                scrutineeValue = _currentBlock.EmitLoad(ptrVal, ((IrPointer)ptrVal.IrType).Pointee);
            }
            else
            {
                scrutineeValue = LowerExpression(match.Scrutinee);
            }
        }
        else
        {
            scrutineeValue = LowerExpression(match.Scrutinee);
        }

        var scrutineeHmType = _types.GetResolvedType(match.Scrutinee);
        var scrutineeIrType = _layout.Lower(scrutineeHmType);

        // Auto-deref `&MyEnum`. Skip nullable IrPointers — those are niche
        // `Option(&T)` and must keep their Option semantics for the tag check.
        if (scrutineeIrType is IrPointer ptrType
            && ptrType.Pointee is IrEnum
            && !ptrType.IsNullable)
        {
            if (originalEnumPtr == null)
                originalEnumPtr = scrutineeValue;
            scrutineeValue = _currentBlock.EmitLoad(scrutineeValue, ptrType.Pointee);
            scrutineeIrType = ptrType.Pointee;
        }

        var irEnum = scrutineeIrType as IrEnum;

        // Non-enum scrutinee: match directly against literal/wildcard/variable patterns
        if (irEnum == null)
            return LowerMatchNonEnum(match, scrutineeValue, scrutineeIrType);

        var resultIrType = GetIrType(match);
        var isVoid = resultIrType == TypeLayoutService.IrVoidPrim;

        // 2. Store scrutinee to alloca (need addressable for GEP).
        // If the scrutinee came from a pointer deref, use the original pointer
        // so that bound variables point into the original struct (not a dangling local copy).
        Value scrutineePtr;
        if (originalEnumPtr != null)
        {
            scrutineePtr = originalEnumPtr;
        }
        else
        {
            scrutineePtr = _currentBlock.EmitAlloca(irEnum);
            _currentBlock.EmitStorePtr(scrutineePtr, scrutineeValue);
        }

        // 3. Extract tag: load i32 at offset 0
        var tagValue = EmitLoadFromOffset(scrutineePtr, 0, TypeLayoutService.IrI32, "match_tag");

        // 4. Alloca result (phi-via-alloca pattern)
        Value? resultPtr = null;
        if (!isVoid)
            resultPtr = _currentBlock.EmitAlloca(resultIrType);

        // 5. Create basic blocks
        var armBlocks = new List<BasicBlock>();
        for (int i = 0; i < match.Arms.Count; i++)
            armBlocks.Add(_currentBlock.CreateBlock($"match_arm_{i}"));

        var checkBlocks = new List<BasicBlock>();
        for (int i = 0; i < match.Arms.Count - 1; i++)
            checkBlocks.Add(_currentBlock.CreateBlock($"match_check_{i}"));

        var mergeBlock = _currentBlock.CreateBlock("match_merge");

        // 6. For each arm: emit check + arm body
        for (int armIndex = 0; armIndex < match.Arms.Count; armIndex++)
        {
            var arm = match.Arms[armIndex];
            var armBlock = armBlocks[armIndex];

            // First arm uses current block for check, others use their check block
            var checkBlock = armIndex == 0 ? _currentBlock : checkBlocks[armIndex - 1];
            _currentBlock = checkBlock;

            // Emit condition check
            var armMissTarget = armIndex < match.Arms.Count - 1
                ? checkBlocks[armIndex]
                : mergeBlock;

            if (arm.Pattern is ElsePatternNode or WildcardPatternNode)
            {
                // Unconditional match
                _currentBlock.EmitJump(armBlock);
            }
            else if (arm.Pattern is VariablePatternNode)
            {
                // Variable pattern: matches everything (binds whole scrutinee)
                _currentBlock.EmitJump(armBlock);
            }
            else if (arm.Pattern is EnumVariantPatternNode evpCheck)
            {
                EmitEnumVariantTagCheck(evpCheck, irEnum, tagValue, armBlock, armMissTarget);
            }
            else if (arm.Pattern is OrPatternNode orArmEnum)
            {
                EmitEnumOrPatternCheck(orArmEnum, irEnum, tagValue, scrutineePtr, scrutineeValue, armBlock, armMissTarget, armIndex);
            }

            // Fill in arm block
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
                    // Determine fallthrough target for literal sub-pattern mismatches
                    var litFallthrough = armIndex < match.Arms.Count - 1
                        ? checkBlocks[armIndex]
                        : mergeBlock;

                    if (armVariant.Value.PayloadType is IrStruct payloadStruct
                        && payloadStruct.Name.StartsWith("__tuple_")
                        && payloadStruct.Fields.Length > 1)
                    {
                        // Multi-payload (synthetic tuple): bind/check each sub-pattern
                        for (int i = 0; i < evp.SubPatterns.Count && i < payloadStruct.Fields.Length; i++)
                        {
                            var fieldOffset = armVariant.Value.PayloadOffset
                                              + payloadStruct.Fields[i].ByteOffset;
                            var fieldPtr = _currentBlock.EmitGEP(scrutineePtr, fieldOffset, payloadStruct.Fields[i].Type);

                            if (evp.SubPatterns[i] is VariablePatternNode vp)
                            {
                                _locals[vp.Name] = fieldPtr;
                            }
                            else if (evp.SubPatterns[i] is LiteralPatternNode litSubPat)
                            {
                                var payloadVal = _currentBlock.EmitLoad(fieldPtr, payloadStruct.Fields[i].Type);
                                var literalVal = LowerExpression(litSubPat.Literal);
                                var cmp = EmitPatternComparison(litSubPat, payloadVal, literalVal);

                                var contBlock = _currentBlock.CreateBlock($"match_arm_{armIndex}_cont_{i}");
                                _currentBlock.EmitBranch(cmp, contBlock, litFallthrough);
                                _currentBlock = contBlock;
                            }
                        }
                    }
                    else if (evp.SubPatterns.Count > 0)
                    {
                        // Single payload — recurse via the unified sub-pattern
                        // binder so tuple / struct / range / wildcard / nested
                        // forms work as variant payloads (RFC-010).
                        var payloadPtr = _currentBlock.EmitGEP(scrutineePtr, armVariant.Value.PayloadOffset, armVariant.Value.PayloadType);
                        EmitTupleSubPatternBind(evp.SubPatterns[0], payloadPtr, armVariant.Value.PayloadType, litFallthrough);
                    }
                }
            }
            else if (arm.Pattern is VariablePatternNode varPat)
            {
                // Bind entire scrutinee to variable
                _locals[varPat.Name] = scrutineePtr;
            }

            // Guard (RFC-010): `pat if cond => body` evaluates `cond` after the
            // pattern matches and bindings are in scope. False falls through.
            if (arm.Guard != null)
            {
                var guardVal = LowerExpression(arm.Guard);
                var bodyBlock = _currentBlock.CreateBlock($"match_arm_{armIndex}_body");
                _currentBlock.EmitBranch(guardVal, bodyBlock, armMissTarget);
                _currentBlock = bodyBlock;
            }

            // Lower arm result expression
            var armResultVal = LowerExpression(arm.ResultExpr, isVoid ? null : resultIrType);
            var armIsNever = armResultVal.IrType == TypeLayoutService.IrNeverPrim;
            if (!isVoid && !armIsNever && resultPtr != null)
                _currentBlock.EmitStorePtr(resultPtr, armResultVal);

            // Jump to merge (unreachable after never-returning calls)
            if (!armIsNever)
                _currentBlock.EmitJumpIfNotTerminated(mergeBlock);
        }

        // 7. Merge block
        _currentBlock = mergeBlock;

        if (!isVoid && resultPtr != null)
            return _currentBlock.EmitLoad(resultPtr, resultIrType);

        return new IntConstantValue(0, TypeLayoutService.IrVoidPrim);
    }

    /// <summary>
    /// Handles match expressions where the scrutinee is NOT an enum (e.g., u8, i32, String).
    /// Supports literal, wildcard, variable, and else patterns.
    /// </summary>
    private Value LowerMatchNonEnum(MatchExpressionNode match, Value scrutineeValue, IrType scrutineeIrType)
    {
        var resultIrType = GetIrType(match);
        var isVoid = resultIrType == TypeLayoutService.IrVoidPrim;

        // Store scrutinee to alloca for variable binding
        var scrutineePtr = _currentBlock.EmitAlloca(scrutineeIrType);
        _currentBlock.EmitStorePtr(scrutineePtr, scrutineeValue);

        // Alloca result
        Value? resultPtr = null;
        if (!isVoid)
            resultPtr = _currentBlock.EmitAlloca(resultIrType);

        // Create blocks
        var armBlocks = new List<BasicBlock>();
        for (int i = 0; i < match.Arms.Count; i++)
            armBlocks.Add(_currentBlock.CreateBlock($"match_arm_{i}"));

        var checkBlocks = new List<BasicBlock>();
        for (int i = 0; i < match.Arms.Count - 1; i++)
            checkBlocks.Add(_currentBlock.CreateBlock($"match_check_{i}"));

        var mergeBlock = _currentBlock.CreateBlock("match_merge");

        // Niche-Option scrutinee: Some/None patterns route through nullability check.
        bool isNicheOption = IsNicheOption(scrutineeIrType);

        for (int armIndex = 0; armIndex < match.Arms.Count; armIndex++)
        {
            var arm = match.Arms[armIndex];
            var armBlock = armBlocks[armIndex];
            var checkBlock = armIndex == 0 ? _currentBlock : checkBlocks[armIndex - 1];
            _currentBlock = checkBlock;

            var elseTarget = armIndex < match.Arms.Count - 1
                ? checkBlocks[armIndex]
                : mergeBlock;

            if (arm.Pattern is ElsePatternNode or WildcardPatternNode)
            {
                _currentBlock.EmitJump(armBlock);
            }
            else if (arm.Pattern is VariablePatternNode)
            {
                _currentBlock.EmitJump(armBlock);
            }
            else if (isNicheOption && arm.Pattern is EnumVariantPatternNode evpNiche)
            {
                EmitNicheOptionTagCheck(evpNiche, scrutineeValue, scrutineeIrType, armBlock, elseTarget);
            }
            else if (arm.Pattern is LiteralPatternNode litPat)
            {
                EmitLiteralCheck(litPat, scrutineeValue, armBlock, elseTarget);
            }
            else if (arm.Pattern is RangePatternNode rangePat)
            {
                EmitRangeCheck(rangePat, scrutineeValue, scrutineeIrType, armBlock, elseTarget);
            }
            else if (arm.Pattern is OrPatternNode orArmNonEnum)
            {
                EmitNonEnumOrPatternCheck(orArmNonEnum, scrutineeValue, scrutineeIrType, isNicheOption, armBlock, elseTarget, armIndex);
            }
            else if (arm.Pattern is TuplePatternNode or StructPatternNode)
            {
                // Tuple/struct patterns are shape-checked at TC; jump
                // unconditionally. Sub-pattern literal checks happen inside
                // armBlock and may jump back to elseTarget on miss.
                _currentBlock.EmitJump(armBlock);
            }

            _currentBlock = armBlock;

            // Bind variable pattern
            if (arm.Pattern is VariablePatternNode varPat)
                _locals[varPat.Name] = scrutineePtr;

            // Niche Some(x): bind x to the stripped (non-nullable) pointer.
            if (isNicheOption
                && arm.Pattern is EnumVariantPatternNode evp
                && evp.VariantName == "Some"
                && evp.SubPatterns.Count == 1
                && evp.SubPatterns[0] is VariablePatternNode someBind)
            {
                var stripped = StripNullable((IrPointer)scrutineeIrType);
                var castVal = _currentBlock.EmitCast(scrutineeValue, stripped);
                // Materialize the cast value to a slot so _locals has a pointer-to-payload.
                var bindSlot = _currentBlock.EmitAlloca(stripped);
                _currentBlock.EmitStorePtr(bindSlot, castVal);
                _locals[someBind.Name] = bindSlot;
            }

            // Tuple pattern bindings: GEP each element, recurse on sub-patterns.
            // Literal sub-patterns may branch to elseTarget on miss.
            if (arm.Pattern is TuplePatternNode tupPat
                && scrutineeIrType is IrStruct tupleIrStruct)
            {
                EmitTuplePatternBindings(tupPat, scrutineePtr, tupleIrStruct, elseTarget);
            }

            // Struct pattern bindings: GEP each named field, recurse.
            if (arm.Pattern is StructPatternNode structPat
                && scrutineeIrType is IrStruct structIrType)
            {
                EmitStructPatternBindings(structPat, scrutineePtr, structIrType, elseTarget);
            }

            // Guard (RFC-010): `pat if cond => body`.
            if (arm.Guard != null)
            {
                var guardVal = LowerExpression(arm.Guard);
                var bodyBlock = _currentBlock.CreateBlock($"match_arm_{armIndex}_body");
                _currentBlock.EmitBranch(guardVal, bodyBlock, elseTarget);
                _currentBlock = bodyBlock;
            }

            // Lower arm result
            var armResultVal = LowerExpression(arm.ResultExpr, isVoid ? null : resultIrType);
            var armIsNever = armResultVal.IrType == TypeLayoutService.IrNeverPrim;
            if (!isVoid && !armIsNever && resultPtr != null)
                _currentBlock.EmitStorePtr(resultPtr, armResultVal);

            if (!armIsNever)
                _currentBlock.EmitJumpIfNotTerminated(mergeBlock);
        }

        _currentBlock = mergeBlock;

        if (!isVoid && resultPtr != null)
            return _currentBlock.EmitLoad(resultPtr, resultIrType);

        return new IntConstantValue(0, TypeLayoutService.IrVoidPrim);
    }

    /// <summary>
    /// Emit `tag == variant.tag ? matchBlock : missBlock`. Used for both
    /// single-arm tag checks and or-pattern alternatives.
    /// </summary>
    private void EmitEnumVariantTagCheck(
        EnumVariantPatternNode pat,
        IrEnum irEnum,
        Value tagValue,
        BasicBlock matchBlock,
        BasicBlock missBlock)
    {
        IrVariant? variant = null;
        foreach (var v in irEnum.Variants)
        {
            if (v.Name == pat.VariantName)
            {
                variant = v;
                break;
            }
        }

        if (variant == null)
        {
            // Unknown variant — diagnostic emitted in type checker
            _currentBlock.EmitJump(matchBlock);
            return;
        }

        var expectedTag = new IntConstantValue(variant.Value.TagValue, TypeLayoutService.IrI32);
        var cmp = _currentBlock.EmitBinary(BinaryOp.Equal, tagValue, expectedTag, TypeLayoutService.IrBool);
        _currentBlock.EmitBranch(cmp, matchBlock, missBlock);
    }

    /// <summary>
    /// Niche-Option tag check: pointer != null ? Some-arm : None-arm.
    /// </summary>
    private void EmitNicheOptionTagCheck(
        EnumVariantPatternNode pat,
        Value scrutineeValue,
        IrType scrutineeIrType,
        BasicBlock matchBlock,
        BasicBlock missBlock)
    {
        var isSome = EmitOptionIsSome(scrutineeValue, scrutineeIrType);
        if (pat.VariantName == "Some")
            _currentBlock.EmitBranch(isSome, matchBlock, missBlock);
        else if (pat.VariantName == "None")
            _currentBlock.EmitBranch(isSome, missBlock, matchBlock);
        else
            _currentBlock.EmitJump(missBlock); // Unknown variant — diagnostic emitted in TC
    }

    /// <summary>
    /// Emit a literal-pattern check: scrutinee == literal ? matchBlock : missBlock.
    /// </summary>
    private void EmitLiteralCheck(
        LiteralPatternNode litPat,
        Value scrutineeValue,
        BasicBlock matchBlock,
        BasicBlock missBlock)
    {
        var literalVal = LowerExpression(litPat.Literal);
        var cmp = EmitPatternComparison(litPat, scrutineeValue, literalVal);
        _currentBlock.EmitBranch(cmp, matchBlock, missBlock);
    }

    /// <summary>
    /// Lower an or-pattern arm against an enum scrutinee. Each alternative is
    /// a separate check that jumps to <paramref name="armBlock"/> on match;
    /// the chain falls through to <paramref name="missBlock"/> when none match.
    ///
    /// Phase-1 limit: alternatives must not introduce variable bindings
    /// (enforced by E2105 in the type checker).
    /// </summary>
    private void EmitEnumOrPatternCheck(
        OrPatternNode orPat,
        IrEnum irEnum,
        Value tagValue,
        Value scrutineePtr,
        Value scrutineeValue,
        BasicBlock armBlock,
        BasicBlock missBlock,
        int armIndex)
    {
        for (int altIdx = 0; altIdx < orPat.Alternatives.Count; altIdx++)
        {
            var alt = orPat.Alternatives[altIdx];
            var nextMiss = altIdx < orPat.Alternatives.Count - 1
                ? _currentBlock.CreateBlock($"or_alt_{armIndex}_{altIdx + 1}_check")
                : missBlock;

            switch (alt)
            {
                case ElsePatternNode:
                case WildcardPatternNode:
                    _currentBlock.EmitJump(armBlock);
                    break;

                case EnumVariantPatternNode evp:
                    EmitEnumVariantTagCheck(evp, irEnum, tagValue, armBlock, nextMiss);
                    break;

                case LiteralPatternNode litPat:
                    EmitLiteralCheck(litPat, scrutineeValue, armBlock, nextMiss);
                    break;

                default:
                    // Unsupported alternative — diagnostic emitted in TC; fall through.
                    _currentBlock.EmitJump(nextMiss);
                    break;
            }

            _currentBlock = nextMiss;
        }
    }

    /// <summary>
    /// Lower an or-pattern arm against a non-enum scrutinee.
    /// </summary>
    private void EmitNonEnumOrPatternCheck(
        OrPatternNode orPat,
        Value scrutineeValue,
        IrType scrutineeIrType,
        bool isNicheOption,
        BasicBlock armBlock,
        BasicBlock missBlock,
        int armIndex)
    {
        for (int altIdx = 0; altIdx < orPat.Alternatives.Count; altIdx++)
        {
            var alt = orPat.Alternatives[altIdx];
            var nextMiss = altIdx < orPat.Alternatives.Count - 1
                ? _currentBlock.CreateBlock($"or_alt_{armIndex}_{altIdx + 1}_check")
                : missBlock;

            switch (alt)
            {
                case ElsePatternNode:
                case WildcardPatternNode:
                    _currentBlock.EmitJump(armBlock);
                    break;

                case LiteralPatternNode litPat:
                    EmitLiteralCheck(litPat, scrutineeValue, armBlock, nextMiss);
                    break;

                case RangePatternNode rangePat:
                    EmitRangeCheck(rangePat, scrutineeValue, scrutineeIrType, armBlock, nextMiss);
                    break;

                case EnumVariantPatternNode evp when isNicheOption:
                    EmitNicheOptionTagCheck(evp, scrutineeValue, scrutineeIrType, armBlock, nextMiss);
                    break;

                default:
                    _currentBlock.EmitJump(nextMiss);
                    break;
            }

            _currentBlock = nextMiss;
        }
    }

    /// <summary>
    /// Emit a range-pattern check (RFC-010, half-open). All forms reduce to
    /// a chain of comparisons: lower bound (when present) `scrut &gt;= lo`,
    /// upper bound (when present) `scrut &lt; hi`. Empty/missing-both is
    /// rejected at type-check time.
    /// </summary>
    private void EmitRangeCheck(
        RangePatternNode rangePat,
        Value scrutineeValue,
        IrType scrutineeIrType,
        BasicBlock matchBlock,
        BasicBlock missBlock)
    {
        // Upper-bound comparison: `<=` for inclusive (`..=hi`), `<` for half-open (`..hi`).
        var upperOp = rangePat.IsInclusive ? BinaryOp.LessThanOrEqual : BinaryOp.LessThan;

        if (rangePat.Lo != null && rangePat.Hi != null)
        {
            var loVal = LowerExpression(rangePat.Lo);
            var loCmp = _currentBlock.EmitBinary(BinaryOp.GreaterThanOrEqual, scrutineeValue, loVal, TypeLayoutService.IrBool);
            var checkHi = _currentBlock.CreateBlock("range_check_hi");
            _currentBlock.EmitBranch(loCmp, checkHi, missBlock);
            _currentBlock = checkHi;

            var hiVal = LowerExpression(rangePat.Hi);
            var hiCmp = _currentBlock.EmitBinary(upperOp, scrutineeValue, hiVal, TypeLayoutService.IrBool);
            _currentBlock.EmitBranch(hiCmp, matchBlock, missBlock);
        }
        else if (rangePat.Lo != null)
        {
            var loVal = LowerExpression(rangePat.Lo);
            var loCmp = _currentBlock.EmitBinary(BinaryOp.GreaterThanOrEqual, scrutineeValue, loVal, TypeLayoutService.IrBool);
            _currentBlock.EmitBranch(loCmp, matchBlock, missBlock);
        }
        else if (rangePat.Hi != null)
        {
            var hiVal = LowerExpression(rangePat.Hi);
            var hiCmp = _currentBlock.EmitBinary(upperOp, scrutineeValue, hiVal, TypeLayoutService.IrBool);
            _currentBlock.EmitBranch(hiCmp, matchBlock, missBlock);
        }
        else
        {
            _currentBlock.EmitJump(matchBlock); // Bare `..` — diagnostic emitted at parse.
        }
    }

    /// <summary>
    /// Emit bindings and inline literal-checks for a tuple destructuring
    /// pattern (RFC-010). On any literal sub-pattern miss, jumps to
    /// <paramref name="missBlock"/>. Variable sub-patterns bind to the
    /// element's GEP'd pointer; nested tuple sub-patterns recurse.
    /// </summary>
    private void EmitTuplePatternBindings(
        TuplePatternNode tupPat,
        Value tuplePtr,
        IrStruct tupleStruct,
        BasicBlock missBlock)
    {
        for (int i = 0; i < tupPat.Elements.Count && i < tupleStruct.Fields.Length; i++)
        {
            var field = tupleStruct.Fields[i];
            var fieldPtr = _currentBlock.EmitGEP(tuplePtr, field.ByteOffset, field.Type);
            EmitTupleSubPatternBind(tupPat.Elements[i], fieldPtr, field.Type, missBlock);
        }
    }

    private void EmitTupleSubPatternBind(
        PatternNode sub,
        Value slotPtr,
        IrType slotType,
        BasicBlock missBlock)
    {
        switch (sub)
        {
            case VariablePatternNode vp:
                _locals[vp.Name] = slotPtr;
                break;

            case WildcardPatternNode:
            case ElsePatternNode:
                break;

            case LiteralPatternNode litPat:
                var actual = _currentBlock.EmitLoad(slotPtr, slotType);
                var literal = LowerExpression(litPat.Literal);
                var cmp = EmitPatternComparison(litPat, actual, literal);
                var cont = _currentBlock.CreateBlock("subpat_cont");
                _currentBlock.EmitBranch(cmp, cont, missBlock);
                _currentBlock = cont;
                break;

            case RangePatternNode rangePat:
                var rangeVal = _currentBlock.EmitLoad(slotPtr, slotType);
                var rangeCont = _currentBlock.CreateBlock("subpat_range_cont");
                EmitRangeCheck(rangePat, rangeVal, slotType, rangeCont, missBlock);
                _currentBlock = rangeCont;
                break;

            case TuplePatternNode innerTup:
                if (slotType is IrStruct innerStruct)
                    EmitTuplePatternBindings(innerTup, slotPtr, innerStruct, missBlock);
                break;

            case StructPatternNode innerStructPat:
                if (slotType is IrStruct innerStructTy)
                    EmitStructPatternBindings(innerStructPat, slotPtr, innerStructTy, missBlock);
                break;

            // Other sub-pattern kinds in tuples are not supported in this phase.
        }
    }

    /// <summary>
    /// Emit bindings and inline literal-checks for a struct destructuring
    /// pattern (RFC-010). On any literal sub-pattern miss, jumps to
    /// <paramref name="missBlock"/>.
    /// </summary>
    private void EmitStructPatternBindings(
        StructPatternNode structPat,
        Value structPtr,
        IrStruct structIrType,
        BasicBlock missBlock)
    {
        foreach (var fieldPat in structPat.Fields)
        {
            int fieldIdx = -1;
            for (int i = 0; i < structIrType.Fields.Length; i++)
            {
                if (structIrType.Fields[i].Name == fieldPat.FieldName)
                {
                    fieldIdx = i;
                    break;
                }
            }
            if (fieldIdx < 0)
                continue; // Diagnostic emitted in TC.

            var field = structIrType.Fields[fieldIdx];
            var fieldPtr = _currentBlock.EmitGEP(structPtr, field.ByteOffset, field.Type);
            EmitTupleSubPatternBind(fieldPat.Pattern, fieldPtr, field.Type, missBlock);
        }
    }

    /// <summary>
    /// Emits a comparison between a value and a literal pattern value.
    /// Uses op_eq resolution from the type checker (same rules as binary ==).
    /// Primitives use BinaryInstruction(Equal), structs use resolved op_eq.
    /// </summary>
    private Value EmitPatternComparison(LiteralPatternNode litPat, Value actual, Value literal)
    {
        var resolved = _types.GetResolvedOperator(litPat);
        if (resolved != null)
        {
            // Struct type with op_eq — call it exactly like binary ==
            var fn = resolved.Function;
            var calleeIrParamTypes = new List<IrType>();
            foreach (var param in fn.Parameters)
                calleeIrParamTypes.Add(GetIrType(param));

            var fnHmType = GetFunctionHmType(fn);
            var callRetIrType = _layout.Lower(fnHmType.ReturnType);

            return _currentBlock.EmitCall(fn.Name, [actual, literal], callRetIrType, calleeIrParamTypes);
        }

        // Primitive type — use built-in equality
        return _currentBlock.EmitBinary(BinaryOp.Equal, actual, literal, TypeLayoutService.IrBool);
    }

    // =========================================================================
    // Lambda lowering
    // =========================================================================

    private Value LowerLambda(LambdaExpressionNode lambda)
    {
        if (lambda.SynthesizedFunction == null)
            throw new InternalCompilerError(
                "Lambda has no synthesized function", lambda.Span);

        // Non-capturing lambda: same as before — function pointer to the synthesized body.
        if (lambda.Captures.Count == 0)
        {
            var irType = GetIrType(lambda);
            return new FunctionReferenceValue(lambda.SynthesizedFunction.Name, irType);
        }

        // Capturing closure: build the closure struct value by reading each
        // captured name from the current lowering scope. The struct's IR type
        // is the layout of the synthesized __Closure_N nominal.
        var closureIrType = GetIrType(lambda);
        if (closureIrType is not IrStruct closureStruct)
            throw new InternalCompilerError(
                $"Capturing lambda lowered to non-struct IR type `{closureIrType}`", lambda.Span);

        var resultPtr = _currentBlock.EmitAlloca(closureStruct);
        _currentBlock.EmitCall("memset",
            [resultPtr, new IntConstantValue(0, TypeLayoutService.IrI32), new IntConstantValue(closureStruct.Size, TypeLayoutService.IrUSize)],
            TypeLayoutService.IrVoidPrim, calleeParamTypes: null, isForeign: true);

        foreach (var capture in lambda.Captures)
        {
            var irField = FindField(closureStruct, capture.Name);
            var captureVal = LoadCapturedLocal(capture.Name, irField.Type, lambda.Span);
            EmitStoreToOffset(resultPtr, irField.ByteOffset, captureVal, irField.Type);
        }

        return _currentBlock.EmitLoad(resultPtr, closureStruct);
    }

    /// <summary>
    /// Reads a captured local for closure struct construction. Mirrors the
    /// param/alloca handling in <see cref="LowerIdentifier"/> without needing
    /// a synthetic AST node (which would lack a recorded inferred type).
    /// </summary>
    private Value LoadCapturedLocal(string name, IrType expectedType, SourceSpan span)
    {
        if (!_locals.TryGetValue(name, out var localVal))
            throw new InternalCompilerError(
                $"Captured local `{name}` not found at closure construction site", span);

        if (_parameters.Contains(name))
        {
            if (_byRefParams.Contains(name))
            {
                var innerType = ((IrPointer)localVal.IrType!).Pointee;
                return _currentBlock.EmitLoad(localVal, innerType);
            }
            return localVal;
        }

        return _currentBlock.EmitLoad(localVal, expectedType);
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
                var alloca = _currentBlock.EmitAlloca(innerType);
                var tmpLoad = _currentBlock.EmitLoad(localVal, innerType);
                _currentBlock.EmitStorePtr(alloca, tmpLoad);
                _locals[name] = alloca;
                _parameters.Remove(name);
                _byRefParams.Remove(name);
            }
            else
            {
                var paramIrType = localVal.IrType ?? TypeLayoutService.IrVoidPrim;
                var allocaP = _currentBlock.EmitAlloca(paramIrType);
                _currentBlock.EmitStorePtr(allocaP, localVal);
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
            case VariableDeclarationNode vd:
                if (vd.Initializer != null) CollectMutatedParamsExpr(vd.Initializer, mutated);
                break;
            case LoopNode loop:
                CollectMutatedParamsExpr(loop.Body, mutated);
                break;
            case WhileNode whileLoop:
                CollectMutatedParamsExpr(whileLoop.Condition, mutated);
                CollectMutatedParamsExpr(whileLoop.Body, mutated);
                break;
            case ForLoopNode forLoop:
                CollectMutatedParamsExpr(forLoop.Body, mutated);
                break;
            case DeferStatementNode defer:
                CollectMutatedParamsExpr(defer.Expression, mutated);
                break;
            case IfDirectiveStatementNode directive:
            {
                var active = TemplateEngine.EvaluateCondition(directive.Condition, _types.CompileTimeContext);
                var branch = active ? directive.ThenBody : directive.ElseBody;
                if (branch != null)
                    CollectMutatedParams(branch, mutated);
                break;
            }
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
            case ReturnNode ret:
                if (ret.Expression != null) CollectMutatedParamsExpr(ret.Expression, mutated);
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
                                var tmpLoad = _ctx.FreshLocal("t", innerType);
                                var entryBlock = _currentFunction.BasicBlocks[0];
                                entryBlock.Instructions.Insert(0, new StorePointerInstruction(_ctx.Span, alloca, tmpLoad));
                                entryBlock.Instructions.Insert(0, new LoadInstruction(_ctx.Span, localVal, tmpLoad));
                                entryBlock.Instructions.Insert(0, new AllocaInstruction(_ctx.Span, innerType.Size, alloca));
                                _locals[id.Name] = alloca;
                                _parameters.Remove(id.Name);
                                _byRefParams.Remove(id.Name);
                                return alloca;
                            }
                            var paramIrType = localVal.IrType ?? TypeLayoutService.IrVoidPrim;
                            var allocaP = new LocalValue($"{id.Name}_mut", new IrPointer(paramIrType));
                            var entryBlockP = _currentFunction.BasicBlocks[0];
                            entryBlockP.Instructions.Insert(0, new StorePointerInstruction(_ctx.Span, allocaP, localVal));
                            entryBlockP.Instructions.Insert(0, new AllocaInstruction(_ctx.Span, paramIrType.Size, allocaP));
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
                                baseVal = _currentBlock.EmitLoad(baseVal, ptrType.Pointee);
                                baseIrType = ptrType.Pointee;
                            }
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
                    return _currentBlock.EmitGEP(baseVal, field.ByteOffset, field.Type);
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
                    var byteOffset = _currentBlock.EmitBinary(BinaryOp.Multiply, idxVal, elementSize, TypeLayoutService.IrUSize);
                    return _currentBlock.EmitGEP(basePtr, byteOffset, elementIrType);
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
    private IrType GetIrType(AstNode node) => _layout.Lower(_types.GetResolvedType(node));

    private FunctionType GetFunctionHmType(FunctionDeclarationNode fn)
    {
        return (FunctionType)_types.GetResolvedType(fn);
    }

    private BasicBlock CreateBlock(string label) => _ctx.CreateBlock(label);

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
            _ => throw new InternalCompilerError($"Unsupported binary operator: {kind}", _ctx.Span),
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
            $"Field `{fieldName}` not found in struct `{structType.Name}`", _ctx.Span);
    }

    // =========================================================================
    // IrType-based name mangling (delegates to FLang.IR.IrNameMangling)
}
