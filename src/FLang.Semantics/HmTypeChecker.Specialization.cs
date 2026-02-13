using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;
using FLang.Frontend.Ast.Types;
using FunctionType = FLang.Core.Types.FunctionType;
using Type = FLang.Core.Types.Type;

namespace FLang.Semantics;

public partial class HmTypeChecker
{
    // =========================================================================
    // Generic Function Specialization (Monomorphization)
    // =========================================================================

    private static string BuildSpecKey(string name, Type[] paramTypes)
    {
        var sb = new System.Text.StringBuilder();
        sb.Append(name);
        sb.Append('|');
        for (var i = 0; i < paramTypes.Length; i++)
        {
            if (i > 0) sb.Append(',');
            sb.Append(paramTypes[i].ToString());
        }
        return sb.ToString();
    }

    /// <summary>
    /// Ensure a monomorphized specialization exists for a generic function with the given concrete types.
    /// Returns the specialized FunctionDeclarationNode (non-generic, with cloned body).
    /// </summary>
    private int _specDepth;
    private const int MaxSpecDepth = 32;

    private FunctionDeclarationNode? EnsureSpecialization(
        FunctionScheme scheme, Type[] concreteParamTypes, Type concreteReturnType, SourceSpan callSpan)
    {
        var key = BuildSpecKey(scheme.Name, concreteParamTypes);
        if (_emittedSpecs.TryGetValue(key, out var existing))
            return existing;

        // Guard against infinite specialization recursion (unresolved TypeVars producing unique keys)
        if (_specDepth >= MaxSpecDepth)
            return null;

        var originalFn = scheme.Node;

        // Deep clone the body to avoid shared mutable state between specializations
        var clonedBody = CloneStatements(originalFn.Body);

        // Create new parameter nodes with NamedTypeNode (non-generic) so IsGeneric returns false.
        // The actual types are recorded via Record() — lowering reads from _inferredTypes.
        var newParams = new List<FunctionParameterNode>();
        for (int i = 0; i < originalFn.Parameters.Count; i++)
        {
            var origParam = originalFn.Parameters[i];
            var typeNode = new NamedTypeNode(origParam.Span, "_specialized");
            var clonedDefault = origParam.DefaultValue != null ? CloneExpression(origParam.DefaultValue) : null;
            newParams.Add(new FunctionParameterNode(origParam.Span, origParam.NameSpan, origParam.Name, typeNode,
                clonedDefault, origParam.IsVariadic));
        }

        TypeNode? newRetNode = originalFn.ReturnType != null
            ? new NamedTypeNode(originalFn.ReturnType.Span, "_specialized")
            : null;

        var newFn = new FunctionDeclarationNode(
            originalFn.Span, originalFn.NameSpan, originalFn.Name, newParams, newRetNode,
            clonedBody, originalFn.Modifiers);

        // Register BEFORE checking body to prevent infinite recursion for recursive generics
        _specializations.Add(newFn);
        _emittedSpecs[key] = newFn;

        // Save and set module path for nominal type resolution
        var savedModulePath = _currentModulePath;
        _currentModulePath = scheme.ModulePath;

        // Type-check the specialized body
        PushScope();

        // Bind generic type params as fresh TypeVars and track as active type params
        var genericNames = originalFn.GetGenericParamNames();
        foreach (var name in genericNames)
        {
            _scopes.Bind(name, _engine.FreshVar());
            _activeTypeParams[name] = _activeTypeParams.GetValueOrDefault(name) + 1;
        }

        // Re-resolve parameter types from the original TypeNodes.
        // These contain GenericParameterTypeNode references that resolve to the fresh TypeVars.
        var resolvedParamTypes = new Type[originalFn.Parameters.Count];
        for (int i = 0; i < originalFn.Parameters.Count; i++)
            resolvedParamTypes[i] = ResolveTypeNode(originalFn.Parameters[i].Type);

        // Unify resolved params with concrete params -> binds generic TypeVars to concrete types
        for (int i = 0; i < resolvedParamTypes.Length && i < concreteParamTypes.Length; i++)
            _engine.Unify(resolvedParamTypes[i], concreteParamTypes[i], callSpan);

        // Resolve return type and unify
        if (originalFn.ReturnType != null)
        {
            var resolvedRetType = ResolveTypeNode(originalFn.ReturnType);
            _engine.Unify(resolvedRetType, concreteReturnType, callSpan);
        }

        // Record the function type on the new node
        var concreteFnType = new FunctionType(concreteParamTypes, concreteReturnType);
        Record(newFn, concreteFnType);

        // Bind parameters in scope and record their types on the new param nodes
        for (int i = 0; i < newParams.Count; i++)
        {
            _scopes.Bind(newParams[i].Name, concreteParamTypes[i]);
            Record(newParams[i], concreteParamTypes[i]);
        }

        // Push function context for return type checking
        _functionStack.Push(new FunctionContext(newFn, concreteReturnType));

        // Check cloned body (with recursion depth guard)
        _specDepth++;
        try
        {
            foreach (var stmt in clonedBody)
                CheckStatement(stmt);
        }
        finally
        {
            _specDepth--;
        }

        _functionStack.Pop();
        PopScope();

        // Remove active type params (decrement ref count)
        foreach (var name in genericNames)
        {
            if (_activeTypeParams.TryGetValue(name, out var count) && count > 1)
                _activeTypeParams[name] = count - 1;
            else
                _activeTypeParams.Remove(name);
        }

        _currentModulePath = savedModulePath;
        return newFn;
    }

    // =========================================================================
    // AST Deep Clone for Generic Specialization
    // =========================================================================

    private static List<StatementNode> CloneStatements(IReadOnlyList<StatementNode> statements)
    {
        return statements.Select(CloneStatement).ToList();
    }

    private static StatementNode CloneStatement(StatementNode stmt) => stmt switch
    {
        ReturnStatementNode ret => new ReturnStatementNode(ret.Span,
            ret.Expression != null ? CloneExpression(ret.Expression) : null),
        ExpressionStatementNode es => new ExpressionStatementNode(es.Span,
            CloneExpression(es.Expression)),
        VariableDeclarationNode vd => new VariableDeclarationNode(vd.Span, vd.NameSpan, vd.Name, vd.Type,
            vd.Initializer != null ? CloneExpression(vd.Initializer) : null),
        ForLoopNode fl => new ForLoopNode(fl.Span, fl.IteratorVariable,
            CloneExpression(fl.IterableExpression), CloneExpression(fl.Body)),
        LoopNode loop => new LoopNode(loop.Span, CloneExpression(loop.Body)),
        BreakStatementNode br => new BreakStatementNode(br.Span),
        ContinueStatementNode cont => new ContinueStatementNode(cont.Span),
        DeferStatementNode df => new DeferStatementNode(df.Span, CloneExpression(df.Expression)),
        _ => throw new NotSupportedException(
            $"Cloning not implemented for statement type: {stmt.GetType().Name}")
    };

    private static ExpressionNode CloneExpression(ExpressionNode expr) => expr switch
    {
        IntegerLiteralNode lit => new IntegerLiteralNode(lit.Span, lit.Value, lit.Suffix),
        BooleanLiteralNode bl => new BooleanLiteralNode(bl.Span, bl.Value),
        StringLiteralNode sl => new StringLiteralNode(sl.Span, sl.Value),
        NullLiteralNode nl => new NullLiteralNode(nl.Span),
        IdentifierExpressionNode id => new IdentifierExpressionNode(id.Span, id.Name),
        BinaryExpressionNode bin => new BinaryExpressionNode(bin.Span,
            CloneExpression(bin.Left), bin.Operator, CloneExpression(bin.Right)),
        CallExpressionNode call => new CallExpressionNode(call.Span, call.FunctionName,
            [.. call.Arguments.Select(CloneExpression)],
            call.UfcsReceiver != null ? CloneExpression(call.UfcsReceiver) : null,
            call.MethodName),
        IfExpressionNode ie => new IfExpressionNode(ie.Span, CloneExpression(ie.Condition),
            CloneExpression(ie.ThenBranch),
            ie.ElseBranch != null ? CloneExpression(ie.ElseBranch) : null),
        BlockExpressionNode blk => new BlockExpressionNode(blk.Span,
            CloneStatements(blk.Statements),
            blk.TrailingExpression != null ? CloneExpression(blk.TrailingExpression) : null),
        MemberAccessExpressionNode ma => new MemberAccessExpressionNode(ma.Span,
            CloneExpression(ma.Target), ma.FieldName),
        IndexExpressionNode ix => new IndexExpressionNode(ix.Span,
            CloneExpression(ix.Base), CloneExpression(ix.Index)),
        AssignmentExpressionNode ae => new AssignmentExpressionNode(ae.Span,
            CloneExpression(ae.Target), CloneExpression(ae.Value)),
        AddressOfExpressionNode addr => new AddressOfExpressionNode(addr.Span,
            CloneExpression(addr.Target)),
        DereferenceExpressionNode deref => new DereferenceExpressionNode(deref.Span,
            CloneExpression(deref.Target)),
        CastExpressionNode cast => new CastExpressionNode(cast.Span,
            CloneExpression(cast.Expression), cast.TargetType),
        RangeExpressionNode range => new RangeExpressionNode(range.Span,
            range.Start != null ? CloneExpression(range.Start) : null,
            range.End != null ? CloneExpression(range.End) : null),
        CoalesceExpressionNode coal => new CoalesceExpressionNode(coal.Span,
            CloneExpression(coal.Left), CloneExpression(coal.Right)),
        NullPropagationExpressionNode np => new NullPropagationExpressionNode(np.Span,
            CloneExpression(np.Target), np.MemberName),
        MatchExpressionNode match => new MatchExpressionNode(match.Span,
            CloneExpression(match.Scrutinee),
            [.. match.Arms.Select(a => new MatchArmNode(a.Span, a.Pattern,
                CloneExpression(a.ResultExpr)))]),
        ArrayLiteralExpressionNode arr => new ArrayLiteralExpressionNode(arr.Span,
            [.. arr.Elements!.Select(CloneExpression)]),
        AnonymousStructExpressionNode anon => new AnonymousStructExpressionNode(anon.Span,
            anon.Fields.Select(f => (f.FieldName, CloneExpression(f.Value))).ToList()),
        StructConstructionExpressionNode sc => new StructConstructionExpressionNode(sc.Span,
            sc.TypeName,
            sc.Fields.Select(f => (f.FieldName, CloneExpression(f.Value))).ToList()),
        ImplicitCoercionNode ic => new ImplicitCoercionNode(ic.Span,
            CloneExpression(ic.Inner), ic.TargetType, ic.Kind),
        NamedArgumentExpressionNode na => new NamedArgumentExpressionNode(na.Span,
            na.NameSpan, na.Name, CloneExpression(na.Value)),
        UnaryExpressionNode un => new UnaryExpressionNode(un.Span, un.Operator,
            CloneExpression(un.Operand)),
        LambdaExpressionNode lambda => new LambdaExpressionNode(lambda.Span,
            lambda.Parameters, lambda.ReturnType, CloneStatements(lambda.Body)),
        _ => throw new NotSupportedException(
            $"Cloning not implemented for expression type: {expr.GetType().Name}")
    };
}
