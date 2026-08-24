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

    private string BuildSpecKey(string name, Type[] paramTypes, Type returnType)
    {
        var sb = new System.Text.StringBuilder();
        sb.Append(name);
        sb.Append('|');
        for (var i = 0; i < paramTypes.Length; i++)
        {
            if (i > 0) sb.Append(',');
            AppendTypeSpecKey(sb, paramTypes[i]);
        }
        sb.Append('|');
        AppendTypeSpecKey(sb, _ctx.Engine.Resolve(returnType));
        return sb.ToString();
    }

    /// <summary>
    /// Append a unique string representation of a type for specialization keys.
    /// For anonymous types (tuples), includes resolved field types to distinguish
    /// e.g. (i64, usize) from (u64, usize) which share the name __anon__0__1.
    /// </summary>
    /// <remarks>
    /// Nominals are keyed by FQN, never <see cref="NominalType.ShortName"/>: two
    /// modules may each declare a `Binding`, and a short-name key makes their
    /// specializations collide. The second call site then silently reuses a
    /// function specialized over the *first* module's type, and since IR struct
    /// names are FQN-derived, the emitted call names a symbol nothing defines —
    /// surfacing much later as E3002 against an unrelated file.
    ///
    /// Structural types recurse for the same reason: `Type.ToString()` renders
    /// nominals by short name, so `&a.Thing` and `&b.Thing` would collide too.
    /// </remarks>
    private void AppendTypeSpecKey(System.Text.StringBuilder sb, Type type)
    {
        switch (type)
        {
            case NominalType nt:
                sb.Append(nt.Name);
                if (nt.Name.StartsWith("__anon_") && nt.FieldsOrVariants.Count > 0 && nt.TypeArguments.Count == 0)
                {
                    sb.Append('{');
                    for (int i = 0; i < nt.FieldsOrVariants.Count; i++)
                    {
                        if (i > 0) sb.Append(',');
                        AppendTypeSpecKey(sb, _ctx.Engine.Resolve(nt.FieldsOrVariants[i].Type));
                    }
                    sb.Append('}');
                }
                else if (nt.TypeArguments.Count > 0)
                {
                    sb.Append('(');
                    for (int i = 0; i < nt.TypeArguments.Count; i++)
                    {
                        if (i > 0) sb.Append(", ");
                        AppendTypeSpecKey(sb, _ctx.Engine.Resolve(nt.TypeArguments[i]));
                    }
                    sb.Append(')');
                }
                return;

            case FLang.Core.Types.ReferenceType rt:
                sb.Append('&');
                AppendTypeSpecKey(sb, _ctx.Engine.Resolve(rt.InnerType));
                return;

            case FLang.Core.Types.ArrayType at:
                sb.Append('[');
                AppendTypeSpecKey(sb, _ctx.Engine.Resolve(at.ElementType));
                sb.Append(';');
                sb.Append(at.Length);
                sb.Append(']');
                return;

            case FunctionType ft:
                sb.Append("fn(");
                for (int i = 0; i < ft.ParameterTypes.Count; i++)
                {
                    if (i > 0) sb.Append(", ");
                    AppendTypeSpecKey(sb, _ctx.Engine.Resolve(ft.ParameterTypes[i]));
                }
                sb.Append(")->");
                AppendTypeSpecKey(sb, _ctx.Engine.Resolve(ft.ReturnType));
                return;

            default:
                sb.Append(type);
                return;
        }
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
        var key = BuildSpecKey(scheme.Name, concreteParamTypes, concreteReturnType);
        if (_results.EmittedSpecs.TryGetValue(key, out var existing))
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
            clonedBody, originalFn.Modifiers)
        {
            // The generic's defining module qualifies the specialization's
            // symbol, like every other function (SymbolBaseName).
            ModulePath = scheme.ModulePath,
        };

        // Register BEFORE checking body to prevent infinite recursion for recursive generics
        _results.Specializations.Add(newFn);
        _results.EmittedSpecs[key] = newFn;

        // Save and set module path for nominal type resolution.
        // Also push the caller's module onto the specialization stack so
        // visibility lookups can find user-defined overloads that the generic's
        // defining module doesn't import.
        var savedModulePath = _ctx.CurrentModulePath;
        if (savedModulePath != null)
            _ctx.SpecializationCallers.Push(savedModulePath);
        _ctx.CurrentModulePath = scheme.ModulePath;

        // Type-check the specialized body
        PushScope();

        // Bind generic type params as fresh TypeVars and track as active type params
        var genericNames = originalFn.GetGenericParamNames();
        foreach (var name in genericNames)
        {
            _ctx.Scopes.Bind(name, _ctx.Engine.FreshVar());
            _ctx.ActiveTypeParams[name] = _ctx.ActiveTypeParams.GetValueOrDefault(name) + 1;
        }

        // Re-resolve parameter types from the original TypeNodes.
        // These contain GenericParameterTypeNode references that resolve to the fresh TypeVars.
        var resolvedParamTypes = new Type[originalFn.Parameters.Count];
        for (int i = 0; i < originalFn.Parameters.Count; i++)
            resolvedParamTypes[i] = ResolveTypeNode(originalFn.Parameters[i].Type);

        // Unify resolved params with concrete params -> binds generic TypeVars to concrete types
        for (int i = 0; i < resolvedParamTypes.Length && i < concreteParamTypes.Length; i++)
            _ctx.Engine.Unify(resolvedParamTypes[i], concreteParamTypes[i], callSpan);

        // Resolve return type and unify
        if (originalFn.ReturnType != null)
        {
            var resolvedRetType = ResolveTypeNode(originalFn.ReturnType);
            _ctx.Engine.Unify(resolvedRetType, concreteReturnType, callSpan);
        }

        // Record the function type on the new node
        var concreteFnType = new FunctionType(concreteParamTypes, concreteReturnType);
        Record(newFn, concreteFnType);

        // Bind parameters in scope and record their types on the new param nodes
        for (int i = 0; i < newParams.Count; i++)
        {
            _ctx.Scopes.Bind(newParams[i].Name, concreteParamTypes[i]);
            Record(newParams[i], concreteParamTypes[i]);
        }

        // Push function context for return type checking
        _ctx.FunctionStack.Push(new FunctionContext(newFn, concreteReturnType));

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

        _ctx.FunctionStack.Pop();
        PopScope();

        // Remove active type params (decrement ref count)
        foreach (var name in genericNames)
        {
            if (_ctx.ActiveTypeParams.TryGetValue(name, out var count) && count > 1)
                _ctx.ActiveTypeParams[name] = count - 1;
            else
                _ctx.ActiveTypeParams.Remove(name);
        }

        _ctx.CurrentModulePath = savedModulePath;
        if (savedModulePath != null)
            _ctx.SpecializationCallers.Pop();
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
        ExpressionStatementNode es => new ExpressionStatementNode(es.Span,
            CloneExpression(es.Expression)),
        VariableDeclarationNode vd => new VariableDeclarationNode(vd.Span, vd.NameSpan, vd.Name, vd.Type,
            vd.Initializer != null ? CloneExpression(vd.Initializer) : null),
        ForLoopNode fl => new ForLoopNode(fl.Span, fl.IteratorVariable,
            CloneExpression(fl.IterableExpression), CloneExpression(fl.Body), fl.ByRef),
        LoopNode loop => new LoopNode(loop.Span, CloneExpression(loop.Body)),
        WhileNode wh => new WhileNode(wh.Span, CloneExpression(wh.Condition), CloneExpression(wh.Body)),
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
            call.MethodName, call.FunctionNameSpan),
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
        ArrayLiteralExpressionNode arr => arr.IsRepeatSyntax
            ? new ArrayLiteralExpressionNode(arr.Span,
                CloneExpression(arr.RepeatValue!),
                CloneExpression(arr.RepeatCountExpression!))
            : new ArrayLiteralExpressionNode(arr.Span,
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
        ReturnNode ret => new ReturnNode(ret.Span,
            ret.Expression != null ? CloneExpression(ret.Expression) : null),
        TryExpressionNode tryExpr => new TryExpressionNode(tryExpr.Span,
            CloneExpression(tryExpr.Operand))
        {
            DesugaredMatch = tryExpr.DesugaredMatch != null
                ? CloneExpression(tryExpr.DesugaredMatch)
                : null
        },
        BreakNode br => new BreakNode(br.Span),
        ContinueNode cont => new ContinueNode(cont.Span),
        // Segments are immutable and shareable; expression parts are mutable
        // (the checker rewrites Expression) so each gets a fresh part. The
        // desugared block is rebuilt when the specialization is checked.
        InterpolatedStringExpressionNode interp => new InterpolatedStringExpressionNode(
            interp.Span,
            interp.TargetIdentifier != null
                ? (IdentifierExpressionNode)CloneExpression(interp.TargetIdentifier)
                : null,
            interp.BuilderArgs?.Select(CloneExpression).ToList(),
            [.. interp.Parts.Select(p => p switch
            {
                InterpExpressionPart ep => new InterpExpressionPart(ep.Span, CloneExpression(ep.Expression), ep.FormatSpec),
                _ => p,
            })]),
        _ => throw new NotSupportedException(
            $"Cloning not implemented for expression type: {expr.GetType().Name}")
    };
}
