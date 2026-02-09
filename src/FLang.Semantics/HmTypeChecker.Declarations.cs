using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;
using FLang.Frontend.Ast.Types;
using FunctionType = FLang.Core.Types.FunctionType;
using PrimitiveType = FLang.Core.Types.PrimitiveType;
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

            PushScope();
            var typeArgs = BindTypeParameters(structDecl.TypeParameters);

            var fields = new (string Name, Type Type)[structDecl.Fields.Count];
            for (var i = 0; i < structDecl.Fields.Count; i++)
            {
                var field = structDecl.Fields[i];
                fields[i] = (field.Name, ResolveTypeNode(field.Type));
            }

            PopScope();

            _nominalTypes[fqn] = new NominalType(fqn, NominalKind.Struct, typeArgs, fields);
        }

        // Make Type(T) share TypeInfo's fields so Type(T) values carry size/align/kind/etc.
        if (_nominalTypes.TryGetValue("core.rtti.Type", out var rttiType)
            && _nominalTypes.TryGetValue("core.rtti.TypeInfo", out var rttiTypeInfo))
        {
            _nominalTypes["core.rtti.Type"] = rttiType with { FieldsOrVariants = rttiTypeInfo.FieldsOrVariants };
        }

        // Resolve enum variants
        foreach (var enumDecl in module.Enums)
        {
            var fqn = $"{modulePath}.{enumDecl.Name}";
            if (!_nominalTypes.ContainsKey(fqn)) continue;

            // E2034: Check for duplicate variant names
            var seenVariantNames = new HashSet<string>();
            foreach (var variant in enumDecl.Variants)
            {
                if (!seenVariantNames.Add(variant.Name))
                    ReportError($"Duplicate variant `{variant.Name}` in enum `{enumDecl.Name}`", variant.Span, "E2034");
            }

            PushScope();
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

            PopScope();

            var enumType = new NominalType(fqn, NominalKind.Enum, typeArgs, variants);

            // Resolve explicit tag values for naked enums (e.g., Less = -1, Equal = 0, Greater = 1)
            Dictionary<string, long>? tagValues = null;
            bool hasExplicitTags = enumDecl.Variants.Any(v => v.ExplicitTagValue.HasValue);
            long nextTag = 0;
            for (var i = 0; i < enumDecl.Variants.Count; i++)
            {
                var variant = enumDecl.Variants[i];
                if (variant.ExplicitTagValue.HasValue)
                {
                    tagValues ??= new Dictionary<string, long>();
                    nextTag = variant.ExplicitTagValue.Value;
                }
                if (tagValues != null)
                    tagValues[variant.Name] = nextTag;

                // E2047: Naked enum (has explicit tags) variants must not have payloads
                if (hasExplicitTags && variant.PayloadTypes.Count > 0)
                    ReportError($"Naked enum variant `{variant.Name}` cannot have a payload", variant.Span, "E2047");

                nextTag++;
            }

            // E2048: Duplicate tag values in naked enums
            if (tagValues != null)
            {
                var seenTags = new Dictionary<long, string>();
                foreach (var (name, tag) in tagValues)
                {
                    if (seenTags.TryGetValue(tag, out var existing))
                        ReportError($"Duplicate tag value `{tag}` in enum `{enumDecl.Name}` (already used by `{existing}`)", enumDecl.Span, "E2048");
                    else
                        seenTags[tag] = name;
                }
            }

            if (tagValues != null)
                enumType = enumType with { TagValues = tagValues };

            // E2035: Check for infinite-size recursive variants (direct self-reference without indirection)
            foreach (var variant in enumDecl.Variants)
            {
                foreach (var payloadType in variant.PayloadTypes)
                {
                    if (ContainsDirectSelfReference(payloadType, enumDecl.Name))
                        ReportError($"Recursive variant `{variant.Name}` creates infinite-size type (use `&{enumDecl.Name}` for indirection)", variant.Span, "E2035");
                }
            }

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
                // Use already-resolved types from the tuple struct (variantField.Type)
                // instead of re-resolving TypeNodes (scope may not have type params in scope)
                if (variantField.Type is NominalType tupleType)
                {
                    var paramTypes = tupleType.FieldsOrVariants.Select(f => f.Type).ToArray();
                    constructorType = new FunctionType(paramTypes, enumType);
                }
                else
                {
                    constructorType = new FunctionType([variantField.Type], enumType);
                }
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
        PushScope();

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

        PopScope();
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

    /// <summary>
    /// Phase 5b: Check global constants only, so they are in scope for all modules' function bodies.
    /// Must be called for ALL modules before CheckModuleBodies.
    /// </summary>
    public void CheckGlobalConstants(ModuleNode module, string modulePath)
    {
        _currentModulePath = modulePath;
        foreach (var globalConst in module.GlobalConstants)
            CheckStatement(globalConst);
    }

    public void CheckModuleBodies(ModuleNode module, string modulePath)
    {
        _currentModulePath = modulePath;

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
        PushScope();

        // Specialize the function's own signature to get concrete param/return types
        var overloads = LookupFunctions(fn.Name);
        var scheme = overloads?.FirstOrDefault(o => ReferenceEquals(o.Node, fn))?.Signature;
        if (scheme == null)
        {
            ReportError($"Internal: function `{fn.Name}` not registered", fn.Span);
            PopScope();
            return;
        }

        var specialized = _engine.Specialize(scheme);
        var fnType = _engine.Resolve(specialized) as FunctionType;
        if (fnType == null)
        {
            ReportError($"Internal: function `{fn.Name}` signature did not resolve to FunctionType", fn.Span);
            PopScope();
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

        // E2049: Check non-void functions have a return statement or implicit return
        if (fnType.ReturnType is not PrimitiveType { Name: "void" or "never" })
        {
            if (!HasReturnOrImplicitReturn(fn.Body))
                ReportError($"Function `{fn.Name}` must return a value", fn.Span, "E2049");
        }

        _functionStack.Pop();
        PopScope();
    }

    private void CheckTestBody(TestDeclarationNode test)
    {
        PushScope();
        _functionStack.Push(new FunctionContext(null!, WellKnown.Void));

        foreach (var stmt in test.Body)
            CheckStatement(stmt);

        _functionStack.Pop();
        PopScope();
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// <summary>
    /// Check if a block has a return statement or ends with an implicit return (trailing expression).
    /// </summary>
    private static bool HasReturnOrImplicitReturn(IReadOnlyList<StatementNode> statements)
    {
        if (statements.Count == 0) return false;

        foreach (var stmt in statements)
        {
            if (stmt is ReturnStatementNode)
                return true;

            if (stmt is ExpressionStatementNode { Expression: IfExpressionNode ifExpr })
            {
                if (ifExpr.ElseBranch != null)
                {
                    var thenReturns = HasReturnInExpression(ifExpr.ThenBranch);
                    var elseReturns = HasReturnInExpression(ifExpr.ElseBranch);
                    if (thenReturns && elseReturns)
                        return true;
                }
            }

            if (stmt is ExpressionStatementNode { Expression: BlockExpressionNode block })
            {
                if (HasReturnOrImplicitReturn(block.Statements))
                    return true;
            }

            if (stmt is ExpressionStatementNode { Expression: MatchExpressionNode match })
            {
                if (match.Arms.Count > 0 && match.Arms.All(a => HasReturnInExpression(a.ResultExpr)))
                    return true;
            }
        }

        // Check if the last statement is an expression (implicit return)
        var last = statements[^1];
        if (last is ExpressionStatementNode)
            return true;

        return false;
    }

    private static bool HasReturnInExpression(ExpressionNode expr)
    {
        return expr switch
        {
            BlockExpressionNode block => HasReturnOrImplicitReturn(block.Statements),
            IfExpressionNode ifExpr => ifExpr.ElseBranch != null
                && HasReturnInExpression(ifExpr.ThenBranch)
                && HasReturnInExpression(ifExpr.ElseBranch),
            _ => false
        };
    }

    /// <summary>
    /// Check if a TypeNode references the given type name directly (not through a reference &amp;).
    /// </summary>
    private static bool ContainsDirectSelfReference(TypeNode typeNode, string typeName) => typeNode switch
    {
        NamedTypeNode named => named.Name == typeName,
        GenericTypeNode generic => generic.Name == typeName,
        ReferenceTypeNode => false, // Reference adds indirection, so not infinite size
        _ => false
    };

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
