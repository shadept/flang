using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Statements;
using FunctionType = FLang.Core.Types.FunctionType;
using Type = FLang.Core.Types.Type;
using TypeVar = FLang.Core.Types.TypeVar;

namespace FLang.Semantics;

public partial class HmTypeChecker
{
    // =========================================================================
    // Phase 1: Collect nominal type names (placeholder NominalTypes, no fields)
    // =========================================================================

    public void CollectNominalTypes(ModuleNode module, string modulePath)
    {
        _currentModulePath = modulePath;

        foreach (var structDecl in module.Structs)
        {
            var fqn = $"{modulePath}.{structDecl.Name}";
            if (_nominalTypes.ContainsKey(fqn))
            {
                var diag = Diagnostic.Error($"Duplicate type declaration `{structDecl.Name}`", structDecl.Span, code: "E2005");
                if (_nominalSpans.TryGetValue(fqn, out var originalSpan))
                    diag.Notes.Add(Diagnostic.Info($"`{structDecl.Name}` first declared here", originalSpan));
                _diagnostics.Add(diag);
                continue;
            }

            var placeholder = new NominalType(fqn, NominalKind.Struct);
            _nominalTypes[fqn] = placeholder;
            _nominalSpans[fqn] = structDecl.Span;
        }

        foreach (var enumDecl in module.Enums)
        {
            var fqn = $"{modulePath}.{enumDecl.Name}";
            if (_nominalTypes.ContainsKey(fqn))
            {
                var diag = Diagnostic.Error($"Duplicate type declaration `{enumDecl.Name}`", enumDecl.Span, code: "E2005");
                if (_nominalSpans.TryGetValue(fqn, out var originalSpan))
                    diag.Notes.Add(Diagnostic.Info($"`{enumDecl.Name}` first declared here", originalSpan));
                _diagnostics.Add(diag);
                continue;
            }

            var placeholder = new NominalType(fqn, NominalKind.Enum);
            _nominalTypes[fqn] = placeholder;
            _nominalSpans[fqn] = enumDecl.Span;
        }
    }

    // =========================================================================
    // Phase 2: Resolve nominal type fields and variants
    // =========================================================================

    public void ResolveNominalTypes(ModuleNode module, string modulePath)
    {
        _currentModulePath = modulePath;

        // Resolve struct fields
        foreach (var structDecl in module.Structs)
        {
            var fqn = $"{modulePath}.{structDecl.Name}";
            if (!_nominalTypes.ContainsKey(fqn)) continue;

            _scopes.PushScope();
            var typeArgs = BindTypeParameters(structDecl.TypeParameters);

            var fields = new (string Name, Type Type)[structDecl.Fields.Count];
            for (var i = 0; i < structDecl.Fields.Count; i++)
            {
                var field = structDecl.Fields[i];
                fields[i] = (field.Name, ResolveTypeNode(field.Type));
            }

            _scopes.PopScope();

            _nominalTypes[fqn] = new NominalType(fqn, NominalKind.Struct, typeArgs, fields);
        }

        // Resolve enum variants
        foreach (var enumDecl in module.Enums)
        {
            var fqn = $"{modulePath}.{enumDecl.Name}";
            if (!_nominalTypes.ContainsKey(fqn)) continue;

            _scopes.PushScope();
            var typeArgs = BindTypeParameters(enumDecl.TypeParameters);

            var variants = new (string Name, Type Type)[enumDecl.Variants.Count];
            for (var i = 0; i < enumDecl.Variants.Count; i++)
            {
                var variant = enumDecl.Variants[i];
                if (variant.PayloadTypes.Count == 0)
                {
                    variants[i] = (variant.Name, WellKnown.Void);
                }
                else if (variant.PayloadTypes.Count == 1)
                {
                    variants[i] = (variant.Name, ResolveTypeNode(variant.PayloadTypes[0]));
                }
                else
                {
                    var payloadFields = variant.PayloadTypes
                        .Select((pt, idx) => ($"_{idx}", ResolveTypeNode(pt)))
                        .ToArray();
                    var tupleName = $"__tuple_{variant.PayloadTypes.Count}";
                    variants[i] = (variant.Name, new NominalType(tupleName, NominalKind.Struct, [], payloadFields));
                }
            }

            _scopes.PopScope();

            var enumType = new NominalType(fqn, NominalKind.Enum, typeArgs, variants);
            _nominalTypes[fqn] = enumType;

            BindVariantConstructors(enumDecl, enumType, typeArgs);
        }
    }

    /// <summary>
    /// Bind enum variant constructors as functions in the type scope.
    /// - Payload variant: forall typeVars . fn(payload) -> EnumType
    /// - Payload-less variant: forall typeVars . EnumType
    /// </summary>
    private void BindVariantConstructors(EnumDeclarationNode enumDecl, NominalType enumType,
        IReadOnlyList<Type> typeArgs)
    {
        // Collect the TypeVar IDs from typeArgs for quantification
        var quantifiedIds = new HashSet<int>();
        foreach (var ta in typeArgs)
        {
            if (ta is TypeVar tv)
                quantifiedIds.Add(tv.Id);
        }

        foreach (var variant in enumDecl.Variants)
        {
            var variantField = enumType.FieldsOrVariants
                .FirstOrDefault(f => f.Name == variant.Name);

            Type constructorType;
            if (variant.PayloadTypes.Count == 0)
            {
                // Payload-less: just the enum type itself
                constructorType = enumType;
            }
            else if (variant.PayloadTypes.Count == 1)
            {
                // Single payload: fn(T) -> EnumType
                constructorType = new FunctionType([variantField.Type], enumType);
            }
            else
            {
                // Multi payload: fn(T1, T2, ...) -> EnumType
                var paramTypes = variant.PayloadTypes
                    .Select(ResolveTypeNode)
                    .ToArray();
                constructorType = new FunctionType(paramTypes, enumType);
            }

            var scheme = quantifiedIds.Count > 0
                ? new PolymorphicType(quantifiedIds, constructorType)
                : new PolymorphicType(constructorType);

            _scopes.Bind(variant.Name, scheme);
        }
    }

    // =========================================================================
    // Phase 5: Collect function signatures
    // =========================================================================

    public void CollectFunctionSignatures(ModuleNode module, string modulePath)
    {
        _currentModulePath = modulePath;
        foreach (var fn in module.Functions)
            CollectFunctionSignature(fn, modulePath);
    }

    private void CollectFunctionSignature(FunctionDeclarationNode fn, string modulePath)
    {
        _engine.EnterLevel();
        _scopes.PushScope();

        // Bind generic type parameters as TypeVars
        var genericNames = fn.GetGenericParamNames();
        foreach (var name in genericNames)
            _scopes.Bind(name, _engine.FreshVar());

        // Resolve parameter types
        var paramTypes = new Type[fn.Parameters.Count];
        for (var i = 0; i < fn.Parameters.Count; i++)
            paramTypes[i] = ResolveTypeNode(fn.Parameters[i].Type);

        // Resolve return type
        var returnType = fn.ReturnType != null
            ? ResolveTypeNode(fn.ReturnType)
            : WellKnown.Void;

        var fnType = new FunctionType(paramTypes, returnType);

        // Record function type on declaration node for lowering
        Record(fn, fnType);

        _scopes.PopScope();
        _engine.ExitLevel();

        var scheme = _engine.Generalize(fnType);
        var isForeign = fn.Modifiers.HasFlag(FunctionModifiers.Foreign);

        RegisterFunction(new FunctionScheme(fn.Name, scheme, fn, isForeign, modulePath));

        // Also bind in scope for recursive calls and identifier references
        _scopes.Bind(fn.Name, scheme);
    }

    // =========================================================================
    // Phase 6: Check module bodies
    // =========================================================================

    public void CheckModuleBodies(ModuleNode module, string modulePath)
    {
        _currentModulePath = modulePath;

        // Check global constants
        foreach (var globalConst in module.GlobalConstants)
            CheckStatement(globalConst);

        // Check non-generic function bodies
        foreach (var fn in module.Functions)
        {
            if (fn.IsGeneric) continue;
            if (fn.Modifiers.HasFlag(FunctionModifiers.Foreign)) continue;
            CheckFunctionBody(fn);
        }

        // Check tests
        foreach (var test in module.Tests)
            CheckTestBody(test);
    }

    private void CheckFunctionBody(FunctionDeclarationNode fn)
    {
        _scopes.PushScope();

        // Specialize the function's own signature to get concrete param/return types
        var overloads = LookupFunctions(fn.Name);
        var scheme = overloads?.FirstOrDefault(o => ReferenceEquals(o.Node, fn))?.Signature;
        if (scheme == null)
        {
            ReportError($"Internal: function `{fn.Name}` not registered", fn.Span);
            _scopes.PopScope();
            return;
        }

        var specialized = _engine.Specialize(scheme);
        var fnType = _engine.Resolve(specialized) as FunctionType;
        if (fnType == null)
        {
            ReportError($"Internal: function `{fn.Name}` signature did not resolve to FunctionType", fn.Span);
            _scopes.PopScope();
            return;
        }

        // Record the function type on the declaration node for lowering
        Record(fn, fnType);

        // Push function context for return type checking
        _functionStack.Push(new FunctionContext(fn, fnType.ReturnType));

        // Bind parameters in scope
        for (var i = 0; i < fn.Parameters.Count; i++)
        {
            var param = fn.Parameters[i];
            var paramType = fnType.ParameterTypes[i];
            _scopes.Bind(param.Name, paramType);
            Record(param, paramType);
        }

        // Check body statements
        foreach (var stmt in fn.Body)
            CheckStatement(stmt);

        _functionStack.Pop();
        _scopes.PopScope();
    }

    private void CheckTestBody(TestDeclarationNode test)
    {
        _scopes.PushScope();
        _functionStack.Push(new FunctionContext(null!, WellKnown.Void));

        foreach (var stmt in test.Body)
            CheckStatement(stmt);

        _functionStack.Pop();
        _scopes.PopScope();
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// <summary>
    /// Bind type parameters as fresh TypeVars in scope. Returns the TypeVar list.
    /// </summary>
    private Type[] BindTypeParameters(IReadOnlyList<string> typeParamNames)
    {
        var typeArgs = new Type[typeParamNames.Count];
        for (var i = 0; i < typeParamNames.Count; i++)
        {
            var tv = _engine.FreshVar();
            typeArgs[i] = tv;
            _scopes.Bind(typeParamNames[i], tv);
        }
        return typeArgs;
    }

}
