using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;
using FLang.Frontend.Ast.Types;
using ArrayType = FLang.Core.Types.ArrayType;
using FunctionType = FLang.Core.Types.FunctionType;
using PrimitiveType = FLang.Core.Types.PrimitiveType;
using ReferenceType = FLang.Core.Types.ReferenceType;
using Type = FLang.Core.Types.Type;
using TypeVar = FLang.Core.Types.TypeVar;

namespace FLang.Semantics;

public partial class HmTypeChecker
{
    // =========================================================================
    // Expression Inference — dispatches to specific handlers
    // =========================================================================

    private Type InferExpression(ExpressionNode expr)
    {
        var type = expr switch
        {
            IntegerLiteralNode lit => InferIntegerLiteral(lit),
            BooleanLiteralNode => WellKnown.Bool,
            StringLiteralNode => InferStringLiteral(),
            NullLiteralNode => InferNullLiteral(),
            IdentifierExpressionNode id => InferIdentifier(id),
            BinaryExpressionNode bin => InferBinary(bin),
            UnaryExpressionNode un => InferUnary(un),
            CallExpressionNode call => InferCall(call),
            IfExpressionNode ifExpr => InferIf(ifExpr),
            BlockExpressionNode block => InferBlock(block),
            MatchExpressionNode match => InferMatch(match),
            AssignmentExpressionNode assign => InferAssignment(assign),
            AddressOfExpressionNode addrOf => InferAddressOf(addrOf),
            DereferenceExpressionNode deref => InferDereference(deref),
            MemberAccessExpressionNode member => InferMemberAccess(member),
            StructConstructionExpressionNode structCon => InferStructConstruction(structCon),
            ArrayLiteralExpressionNode arr => InferArrayLiteral(arr),
            IndexExpressionNode idx => InferIndex(idx),
            CastExpressionNode cast => InferCast(cast),
            RangeExpressionNode range => InferRange(range),
            LambdaExpressionNode lambda => InferLambda(lambda),
            CoalesceExpressionNode coal => InferCoalesce(coal),
            NullPropagationExpressionNode nullProp => InferNullPropagation(nullProp),
            AnonymousStructExpressionNode anon => InferAnonymousStruct(anon),
            _ => InferUnknownExpression(expr)
        };

        return Record(expr, type);
    }

    private TypeVar InferUnknownExpression(ExpressionNode expr)
    {
        ReportError($"Unsupported expression kind: {expr.GetType().Name}", expr.Span);
        return _engine.FreshVar();
    }

    // =========================================================================
    // Literals
    // =========================================================================

    private Type InferIntegerLiteral(IntegerLiteralNode lit)
    {
        if (lit.Suffix != null)
        {
            var prim = ResolvePrimitive(lit.Suffix);
            if (prim != null) return prim;
            ReportError($"Unknown integer suffix `{lit.Suffix}`", lit.Span);
        }

        // Unsuffixed integer: fresh type variable (constrained by context)
        return _engine.FreshVar();
    }

    private NominalType InferStringLiteral()
    {
        return LookupNominalType(WellKnown.String)
               ?? throw new InvalidOperationException($"Well-known type `{WellKnown.String}` not registered");
    }

    private NominalType InferNullLiteral()
    {
        var option = LookupNominalType(WellKnown.Option)
                     ?? throw new InvalidOperationException($"Well-known type `{WellKnown.Option}` not registered");
        return new NominalType(option.Name, option.Kind, [_engine.FreshVar()], option.FieldsOrVariants);
    }

    // =========================================================================
    // Identifiers
    // =========================================================================

    private Type InferIdentifier(IdentifierExpressionNode id)
    {
        // Look up in type scope
        var scheme = _scopes.Lookup(id.Name);
        if (scheme != null)
            return _engine.Specialize(scheme);

        // Check if it's a function name
        var fns = LookupFunctions(id.Name);
        if (fns is { Count: 1 })
        {
            // Single overload: return its function type
            return _engine.Specialize(fns[0].Signature);
        }

        ReportError($"Unresolved identifier `{id.Name}`", id.Span, "E2001");
        return _engine.FreshVar();
    }

    // =========================================================================
    // Binary operators
    // =========================================================================

    private Type InferBinary(BinaryExpressionNode bin)
    {
        // Logical operators are always bool → bool → bool
        if (bin.Operator is BinaryOperatorKind.And or BinaryOperatorKind.Or)
        {
            var leftType = InferExpression(bin.Left);
            _engine.Unify(leftType, WellKnown.Bool, bin.Left.Span);
            var rightType = InferExpression(bin.Right);
            _engine.Unify(rightType, WellKnown.Bool, bin.Right.Span);
            return WellKnown.Bool;
        }

        var left = InferExpression(bin.Left);
        var right = InferExpression(bin.Right);

        // Try user-defined operator function
        var opName = OperatorFunctions.GetFunctionName(bin.Operator);
        var opResult = TryResolveOperatorFunction(opName, [left, right], bin.Span, out var resolvedNode);
        if (opResult != null)
        {
            _resolvedOperators[bin] = new ResolvedOperator(resolvedNode!);
            return opResult;
        }

        // Try derived operators: op_ne from op_eq, comparisons from op_cmp
        var derivedResult = TryResolveDerivedOperator(bin, left, right, bin.Span);
        if (derivedResult != null)
            return derivedResult;

        // Built-in operators
        return InferBuiltinBinary(bin.Operator, left, right, bin.Span);
    }

    private Type InferBuiltinBinary(BinaryOperatorKind op, Type left, Type right, SourceSpan span)
    {
        var resolvedLeft = _engine.Resolve(left);
        var resolvedRight = _engine.Resolve(right);

        // Pointer arithmetic: ref + int → ref, int + ref → ref, ref - int → ref
        if (op is BinaryOperatorKind.Add or BinaryOperatorKind.Subtract)
        {
            if (resolvedLeft is ReferenceType)
                return resolvedLeft;
            if (resolvedRight is ReferenceType && op == BinaryOperatorKind.Add)
                return resolvedRight;
        }

        // Unify operands (must be same numeric type)
        var unified = _engine.Unify(left, right, span);

        return op switch
        {
            // Arithmetic: result is same type
            BinaryOperatorKind.Add or BinaryOperatorKind.Subtract or
                BinaryOperatorKind.Multiply or BinaryOperatorKind.Divide or
                BinaryOperatorKind.Modulo => unified.Type,

            // Comparisons: result is bool
            BinaryOperatorKind.Equal or BinaryOperatorKind.NotEqual or
                BinaryOperatorKind.LessThan or BinaryOperatorKind.GreaterThan or
                BinaryOperatorKind.LessThanOrEqual or BinaryOperatorKind.GreaterThanOrEqual
                => WellKnown.Bool,

            // Bitwise: result is same type
            BinaryOperatorKind.BitwiseAnd or BinaryOperatorKind.BitwiseOr or
                BinaryOperatorKind.BitwiseXor => unified.Type,

            // Shifts: result is left operand type
            BinaryOperatorKind.ShiftLeft or BinaryOperatorKind.ShiftRight or
                BinaryOperatorKind.UnsignedShiftRight => unified.Type,

            _ => unified.Type
        };
    }

    /// <summary>
    /// Try to resolve a derived operator (e.g., != from ==, &lt; from op_cmp).
    /// </summary>
    private PrimitiveType? TryResolveDerivedOperator(BinaryExpressionNode bin, Type left, Type right, SourceSpan span)
    {
        switch (bin.Operator)
        {
            case BinaryOperatorKind.NotEqual:
            {
                var eq = TryResolveOperatorFunction("op_eq", [left, right], span, out var eqNode);
                if (eq != null)
                {
                    _resolvedOperators[bin] = new ResolvedOperator(eqNode!, NegateResult: true);
                    return WellKnown.Bool;
                }
                return null;
            }
            case BinaryOperatorKind.Equal:
            {
                var ne = TryResolveOperatorFunction("op_ne", [left, right], span, out var neNode);
                if (ne != null)
                {
                    _resolvedOperators[bin] = new ResolvedOperator(neNode!, NegateResult: true);
                    return WellKnown.Bool;
                }
                return null;
            }
            case BinaryOperatorKind.LessThan or BinaryOperatorKind.GreaterThan or
                BinaryOperatorKind.LessThanOrEqual or BinaryOperatorKind.GreaterThanOrEqual:
            {
                var cmp = TryResolveOperatorFunction("op_cmp", [left, right], span, out var cmpNode);
                if (cmp != null)
                {
                    _resolvedOperators[bin] = new ResolvedOperator(cmpNode!, CmpDerivedOperator: bin.Operator);
                    return WellKnown.Bool;
                }
                return null;
            }
            default:
                return null;
        }
    }

    // =========================================================================
    // Unary operators
    // =========================================================================

    private Type InferUnary(UnaryExpressionNode un)
    {
        var operand = InferExpression(un.Operand);

        // Not on booleans is built-in
        if (un.Operator == UnaryOperatorKind.Not)
        {
            var resolved = _engine.Resolve(operand);
            if (resolved is PrimitiveType { Name: "bool" })
                return WellKnown.Bool;
        }

        // Try operator function
        var opName = OperatorFunctions.GetFunctionName(un.Operator);
        var opResult = TryResolveOperatorFunction(opName, [operand], un.Span, out var resolvedNode);
        if (opResult != null)
        {
            _resolvedOperators[un] = new ResolvedOperator(resolvedNode!);
            return opResult;
        }

        // Built-in negate: same type
        if (un.Operator == UnaryOperatorKind.Negate)
            return operand;

        ReportError($"No operator `{OperatorFunctions.GetOperatorSymbol(un.Operator)}` for type", un.Span);
        return _engine.FreshVar();
    }

    // =========================================================================
    // Operator function resolution
    // =========================================================================

    /// <summary>
    /// Try to resolve an operator function by name with the given argument types.
    /// Uses TryUnify for speculative matching (no side effects on failure).
    /// </summary>
    private Type? TryResolveOperatorFunction(string opName, Type[] argTypes, SourceSpan span)
    {
        return TryResolveOperatorFunction(opName, argTypes, span, out _);
    }

    private Type? TryResolveOperatorFunction(string opName, Type[] argTypes, SourceSpan span,
        out FunctionDeclarationNode? resolvedNode)
    {
        resolvedNode = null;
        var candidates = LookupFunctions(opName);
        if (candidates == null) return null;

        FunctionScheme? bestCandidate = null;
        int bestCost = int.MaxValue;
        bool bestIsGeneric = true;
        bool[]? bestAdapted = null;

        foreach (var candidate in candidates)
        {
            var specialized = _engine.Specialize(candidate.Signature);
            var fnType = _engine.Resolve(specialized) as FunctionType;
            if (fnType == null) continue;
            if (fnType.ParameterTypes.Count != argTypes.Length) continue;

            // Try speculative unification with auto-ref-lifting
            int totalCost = 0;
            bool success = true;
            var adapted = new bool[argTypes.Length];
            for (int i = 0; i < argTypes.Length; i++)
            {
                var result = _engine.TryUnify(argTypes[i], fnType.ParameterTypes[i]);
                if (result == null)
                {
                    // Auto-lift: value T → &T when param expects a reference
                    var resolvedArg = _engine.Resolve(argTypes[i]);
                    if (resolvedArg is not ReferenceType)
                    {
                        var refArg = new ReferenceType(resolvedArg);
                        result = _engine.TryUnify(refArg, fnType.ParameterTypes[i]);
                        if (result != null) adapted[i] = true;
                    }
                }
                if (result == null)
                {
                    success = false;
                    break;
                }

                totalCost += result.Value.Cost;
            }

            if (!success) continue;

            bool isGeneric = candidate.Signature.QuantifiedVarIds.Count > 0;

            // Prefer non-generic, then lowest cost
            if (!isGeneric && bestIsGeneric)
            {
                bestCandidate = candidate;
                bestCost = totalCost;
                bestIsGeneric = false;
                bestAdapted = adapted;
            }
            else if (isGeneric == bestIsGeneric && totalCost < bestCost)
            {
                bestCandidate = candidate;
                bestCost = totalCost;
                bestIsGeneric = isGeneric;
                bestAdapted = adapted;
            }
        }

        if (bestCandidate == null) return null;

        // Re-run with commit (Unify, not TryUnify)
        var winnerType = _engine.Specialize(bestCandidate.Signature);
        var winnerFn = _engine.Resolve(winnerType) as FunctionType;
        if (winnerFn == null) return null;

        for (int i = 0; i < argTypes.Length; i++)
        {
            var arg = bestAdapted != null && bestAdapted[i]
                ? (Type)new ReferenceType(_engine.Resolve(argTypes[i]))
                : argTypes[i];
            _engine.Unify(arg, winnerFn.ParameterTypes[i], span);
        }

        resolvedNode = bestCandidate.Node;
        return winnerFn.ReturnType;
    }

    // =========================================================================
    // Function calls
    // =========================================================================

    private Type InferCall(CallExpressionNode call)
    {
        // Infer UFCS receiver if present
        Type? receiverType = null;
        if (call.UfcsReceiver != null)
            receiverType = InferExpression(call.UfcsReceiver);

        // Infer argument types
        var argTypes = new Type[call.Arguments.Count];
        for (int i = 0; i < call.Arguments.Count; i++)
            argTypes[i] = InferExpression(call.Arguments[i]);

        // Build full argument list (receiver prepended for UFCS)
        Type[] fullArgTypes;
        if (receiverType != null)
        {
            fullArgTypes = new Type[argTypes.Length + 1];
            fullArgTypes[0] = receiverType;
            Array.Copy(argTypes, 0, fullArgTypes, 1, argTypes.Length);
        }
        else
        {
            fullArgTypes = argTypes;
        }

        // Use MethodName for UFCS lookup, FunctionName for regular calls
        var lookupName = call.MethodName ?? call.FunctionName;

        // Try enum variant construction first
        var variantType = TryResolveVariantConstruction(lookupName, fullArgTypes, call.Span);
        if (variantType != null) return variantType;

        // Look up function candidates
        var candidates = LookupFunctions(lookupName);
        if (candidates == null || candidates.Count == 0)
        {
            // Try indirect call (variable with function type)
            return TryIndirectCall(call, fullArgTypes);
        }

        // Overload resolution (with UFCS receiver adaptation)
        return ResolveOverload(candidates, fullArgTypes, call, receiverType != null);
    }

    /// <summary>
    /// Try to resolve a call as an enum variant construction.
    /// Variant constructors are bound in scope as polymorphic types.
    /// </summary>
    private Type? TryResolveVariantConstruction(string name, Type[] argTypes, SourceSpan span)
    {
        var scheme = _scopes.Lookup(name);
        if (scheme == null) return null;

        var specialized = _engine.Specialize(scheme);
        var resolved = _engine.Resolve(specialized);

        // Payload-less variant: just the enum type
        if (resolved is NominalType && argTypes.Length == 0)
            return resolved;

        // Payload variant: function type whose return is a nominal (enum) type
        if (resolved is FunctionType fnType && fnType.ReturnType is NominalType)
        {
            if (fnType.ParameterTypes.Count != argTypes.Length)
                return null;

            // Speculative check — don't commit unless all args match
            for (int i = 0; i < argTypes.Length; i++)
            {
                if (_engine.TryUnify(argTypes[i], fnType.ParameterTypes[i]) == null)
                    return null;
            }

            // Commit
            for (int i = 0; i < argTypes.Length; i++)
                _engine.Unify(argTypes[i], fnType.ParameterTypes[i], span);

            return fnType.ReturnType;
        }

        return null;
    }

    /// <summary>
    /// Try calling through a variable that holds a function type.
    /// </summary>
    private Type TryIndirectCall(CallExpressionNode call, Type[] argTypes)
    {
        var scheme = _scopes.Lookup(call.FunctionName);
        if (scheme != null)
        {
            var specialized = _engine.Specialize(scheme);
            var resolved = _engine.Resolve(specialized);
            if (resolved is FunctionType fnType)
            {
                if (fnType.ParameterTypes.Count == argTypes.Length)
                {
                    for (int i = 0; i < argTypes.Length; i++)
                        _engine.Unify(argTypes[i], fnType.ParameterTypes[i], call.Span);
                    call.IsIndirectCall = true;
                    return fnType.ReturnType;
                }
            }
        }

        ReportError($"Unresolved function `{call.FunctionName}`", call.Span, "E2001");
        return _engine.FreshVar();
    }

    /// <summary>
    /// Multi-pass overload resolution: non-generic preferred, cost ranks within tier.
    /// For UFCS calls, adapts the receiver (argTypes[0]) between value/ref to match candidates.
    /// </summary>
    private Type ResolveOverload(List<FunctionScheme> candidates, Type[] argTypes,
        CallExpressionNode call, bool isUfcs = false)
    {
        FunctionScheme? bestCandidate = null;
        int bestCost = int.MaxValue;
        bool bestIsGeneric = true;
        FunctionType? bestFnType = null;

        foreach (var candidate in candidates)
        {
            var specialized = _engine.Specialize(candidate.Signature);
            var fnType = _engine.Resolve(specialized) as FunctionType;
            if (fnType == null) continue;
            if (fnType.ParameterTypes.Count != argTypes.Length) continue;

            // For UFCS, adapt receiver type to match what the candidate expects
            var effectiveArgs = argTypes;
            if (isUfcs && argTypes.Length > 0 && fnType.ParameterTypes.Count > 0)
                effectiveArgs = AdaptUfcsReceiver(argTypes, fnType.ParameterTypes[0]);

            // Try speculative unification of all arguments
            int totalCost = 0;
            bool success = true;
            for (int i = 0; i < effectiveArgs.Length; i++)
            {
                var result = _engine.TryUnify(effectiveArgs[i], fnType.ParameterTypes[i]);
                if (result == null)
                {
                    success = false;
                    break;
                }

                totalCost += result.Value.Cost;
            }

            if (!success) continue;

            bool isGeneric = candidate.Signature.QuantifiedVarIds.Count > 0;

            // Two-tier: non-generic preferred, cost ranks within tier
            if (!isGeneric && bestIsGeneric)
            {
                bestCandidate = candidate;
                bestCost = totalCost;
                bestIsGeneric = false;
                bestFnType = fnType;
            }
            else if (isGeneric == bestIsGeneric && totalCost < bestCost)
            {
                bestCandidate = candidate;
                bestCost = totalCost;
                bestIsGeneric = isGeneric;
                bestFnType = fnType;
            }
        }

        if (bestCandidate == null)
        {
            var displayName = call.MethodName ?? call.FunctionName;
            ReportError($"No matching overload for `{displayName}` with {argTypes.Length} arguments",
                call.Span, "E2010");
            return _engine.FreshVar();
        }

        // Re-specialize and commit unification
        var winnerSpec = _engine.Specialize(bestCandidate.Signature);
        var winnerFn = _engine.Resolve(winnerSpec) as FunctionType;
        if (winnerFn == null)
        {
            ReportError($"Internal: winner did not resolve to FunctionType", call.Span);
            return _engine.FreshVar();
        }

        // Re-adapt against the fresh winner (speculative adapted args are stale)
        var commitArgs = isUfcs && argTypes.Length > 0 && winnerFn.ParameterTypes.Count > 0
            ? AdaptUfcsReceiver(argTypes, winnerFn.ParameterTypes[0])
            : argTypes;
        for (int i = 0; i < commitArgs.Length; i++)
            _engine.Unify(commitArgs[i], winnerFn.ParameterTypes[i], call.Span);

        // Record resolved target for later phases
        call.ResolvedTarget = bestCandidate.Node;

        return winnerFn.ReturnType;
    }

    /// <summary>
    /// For UFCS calls, adapt the receiver (argTypes[0]) to match what the candidate's
    /// first parameter expects: value T ↔ &amp;T.
    /// </summary>
    private Type[] AdaptUfcsReceiver(Type[] argTypes, Type firstParamType)
    {
        var receiver = _engine.Resolve(argTypes[0]);
        var param = _engine.Resolve(firstParamType);

        bool receiverIsRef = receiver is ReferenceType;
        bool paramExpectsRef = param is ReferenceType;

        if (receiverIsRef == paramExpectsRef) return argTypes;

        var adapted = (Type[])argTypes.Clone();
        if (!receiverIsRef && paramExpectsRef)
        {
            // value → &T: lift to reference
            adapted[0] = new ReferenceType(receiver);
        }
        else if (receiverIsRef && !paramExpectsRef)
        {
            // &T → value: implicit deref
            adapted[0] = ((ReferenceType)receiver).InnerType;
        }

        return adapted;
    }

    // =========================================================================
    // If expression
    // =========================================================================

    private Type InferIf(IfExpressionNode ifExpr)
    {
        // Condition must be bool
        var condType = InferExpression(ifExpr.Condition);
        _engine.Unify(condType, WellKnown.Bool, ifExpr.Condition.Span);

        // Then branch
        var thenType = InferExpression(ifExpr.ThenBranch);

        if (ifExpr.ElseBranch != null)
        {
            // Both branches: unify
            var elseType = InferExpression(ifExpr.ElseBranch);
            var unified = _engine.Unify(thenType, elseType, ifExpr.Span);
            return unified.Type;
        }

        // No else: void
        return WellKnown.Void;
    }

    // =========================================================================
    // Block expression
    // =========================================================================

    private Type InferBlock(BlockExpressionNode block)
    {
        _scopes.PushScope();

        foreach (var stmt in block.Statements)
            CheckStatement(stmt);

        Type result;
        if (block.TrailingExpression != null)
            result = InferExpression(block.TrailingExpression);
        else
            result = WellKnown.Void;

        _scopes.PopScope();
        return result;
    }

    // =========================================================================
    // Match expression
    // =========================================================================

    private Type InferMatch(MatchExpressionNode match)
    {
        var scrutineeType = InferExpression(match.Scrutinee);
        Type resultType = _engine.FreshVar();

        foreach (var arm in match.Arms)
        {
            _scopes.PushScope();

            // Bind pattern variables
            CheckPattern(arm.Pattern, scrutineeType);

            // Infer arm body and unify with result type
            var armType = InferExpression(arm.ResultExpr);
            var unified = _engine.Unify(resultType, armType, arm.Span);
            resultType = unified.Type;

            _scopes.PopScope();
        }

        return resultType;
    }

    /// <summary>
    /// Check a pattern against the expected type and bind variables in scope.
    /// </summary>
    private void CheckPattern(PatternNode pattern, Type scrutineeType)
    {
        switch (pattern)
        {
            case VariablePatternNode varPat:
                _scopes.Bind(varPat.Name, scrutineeType);
                Record(varPat, scrutineeType);
                break;

            case WildcardPatternNode:
            case ElsePatternNode:
                // Match anything, bind nothing
                break;

            case EnumVariantPatternNode variantPat:
                CheckEnumVariantPattern(variantPat, scrutineeType);
                break;

            default:
                ReportError($"Unsupported pattern kind: {pattern.GetType().Name}", pattern.Span);
                break;
        }
    }

    private void CheckEnumVariantPattern(EnumVariantPatternNode pattern, Type scrutineeType)
    {
        var resolved = _engine.Resolve(scrutineeType);
        if (resolved is not NominalType enumType)
        {
            ReportError($"Cannot match variant pattern against non-nominal type", pattern.Span);
            return;
        }

        // Find the variant in the enum's FieldsOrVariants
        var variant = enumType.FieldsOrVariants
            .FirstOrDefault(f => f.Name == pattern.VariantName);

        if (variant == default)
        {
            ReportError($"Unknown variant `{pattern.VariantName}` for type `{enumType.Name}`", pattern.Span);
            return;
        }

        // Bind sub-patterns to variant payload
        if (variant.Type is PrimitiveType { Name: "void" })
        {
            // Payload-less variant: no sub-patterns expected
            if (pattern.SubPatterns.Count > 0)
                ReportError($"Variant `{pattern.VariantName}` has no payload", pattern.Span);
        }
        else if (pattern.SubPatterns.Count == 1)
        {
            // Single payload: bind directly
            CheckPattern(pattern.SubPatterns[0], variant.Type);
        }
        else if (variant.Type is NominalType tupleType && tupleType.Name.StartsWith("__tuple_"))
        {
            // Multi-payload: bind each sub-pattern to tuple field
            for (int i = 0; i < pattern.SubPatterns.Count && i < tupleType.FieldsOrVariants.Count; i++)
                CheckPattern(pattern.SubPatterns[i], tupleType.FieldsOrVariants[i].Type);
        }
        else if (pattern.SubPatterns.Count > 0)
        {
            // Single payload but multiple sub-patterns
            ReportError($"Variant `{pattern.VariantName}` expects 1 binding, got {pattern.SubPatterns.Count}",
                pattern.Span);
        }

        Record(pattern, scrutineeType);
    }

    // =========================================================================
    // Assignment
    // =========================================================================

    private PrimitiveType InferAssignment(AssignmentExpressionNode assign)
    {
        // Indexed assignment: arr[i] = val → op_set_index(&arr, i, val)
        if (assign.Target is IndexExpressionNode idx)
            return InferIndexedAssignment(assign, idx);

        var targetType = InferExpression(assign.Target);
        var valueType = InferExpression(assign.Value);
        _engine.Unify(valueType, targetType, assign.Value.Span);
        return WellKnown.Void;
    }

    private PrimitiveType InferIndexedAssignment(AssignmentExpressionNode assign, IndexExpressionNode idx)
    {
        var baseType = InferExpression(idx.Base);
        var indexType = InferExpression(idx.Index);
        var valueType = InferExpression(assign.Value);

        // Try op_set_index(&base, index, value) first, then op_set_index(base, index, value)
        var refBaseType = new ReferenceType(baseType);
        var opResult = TryResolveOperatorFunction("op_set_index", [refBaseType, indexType, valueType], assign.Span, out var setNode);
        if (opResult == null)
            opResult = TryResolveOperatorFunction("op_set_index", [baseType, indexType, valueType], assign.Span, out setNode);

        if (opResult != null)
        {
            _resolvedOperators[assign] = new ResolvedOperator(setNode!);
            return WellKnown.Void;
        }

        // Built-in array/slice indexed assignment
        var resolvedBase = _engine.Resolve(baseType);

        if (resolvedBase is ArrayType arrayType)
        {
            _engine.Unify(indexType, WellKnown.USize, idx.Index.Span);
            _engine.Unify(valueType, arrayType.ElementType, assign.Value.Span);
            return WellKnown.Void;
        }

        if (resolvedBase is NominalType { Name: WellKnown.Slice } sliceType
            && sliceType.TypeArguments.Count > 0)
        {
            _engine.Unify(indexType, WellKnown.USize, idx.Index.Span);
            _engine.Unify(valueType, sliceType.TypeArguments[0], assign.Value.Span);
            return WellKnown.Void;
        }

        ReportError("Type does not support indexed assignment", idx.Span);
        return WellKnown.Void;
    }

    // =========================================================================
    // Address-of and dereference
    // =========================================================================

    private ReferenceType InferAddressOf(AddressOfExpressionNode addrOf)
    {
        var inner = InferExpression(addrOf.Target);
        return new ReferenceType(inner);
    }

    private Type InferDereference(DereferenceExpressionNode deref)
    {
        var inner = InferExpression(deref.Target);
        var resolved = _engine.Resolve(inner);
        if (resolved is ReferenceType refType)
            return refType.InnerType;

        ReportError("Cannot dereference non-reference type", deref.Span);
        return _engine.FreshVar();
    }

    // =========================================================================
    // Member access
    // =========================================================================

    private Type InferMemberAccess(MemberAccessExpressionNode member)
    {
        var targetType = InferExpression(member.Target);
        return ResolveFieldAccess(targetType, member.FieldName, member, 0);
    }

    /// <summary>
    /// Resolve field access with auto-dereference through reference types.
    /// </summary>
    private Type ResolveFieldAccess(Type targetType, string fieldName,
        MemberAccessExpressionNode member, int derefCount)
    {
        var resolved = _engine.Resolve(targetType);

        // Auto-dereference through references
        if (resolved is ReferenceType refType)
        {
            member.AutoDerefCount = derefCount + 1;
            return ResolveFieldAccess(refType.InnerType, fieldName, member, derefCount + 1);
        }

        if (resolved is NominalType nominal)
        {
            // If the NominalType instance has no fields, look up the registered template
            var fieldsSource = nominal;
            if (nominal.FieldsOrVariants.Count == 0)
            {
                var template = LookupNominalType(nominal.Name);
                if (template != null)
                    fieldsSource = template;
            }

            // Look up field/variant by name
            var field = fieldsSource.FieldsOrVariants
                .FirstOrDefault(f => f.Name == fieldName);

            if (field != default)
                return field.Type;
        }

        // Fixed-size arrays have implicit .len and .ptr fields
        if (resolved is ArrayType arrayType)
        {
            if (fieldName == "len") return WellKnown.USize;
            if (fieldName == "ptr") return new ReferenceType(arrayType.ElementType);
        }

        ReportError($"No field `{fieldName}` on type", member.Span);
        return _engine.FreshVar();
    }

    // =========================================================================
    // Struct construction
    // =========================================================================

    private Type InferStructConstruction(StructConstructionExpressionNode structCon)
    {
        var structType = ResolveTypeNode(structCon.TypeName);
        var resolved = _engine.Resolve(structType);

        if (resolved is NominalType nominal)
        {
            // Check each field
            foreach (var (fieldName, valueExpr) in structCon.Fields)
            {
                var fieldDef = nominal.FieldsOrVariants
                    .FirstOrDefault(f => f.Name == fieldName);

                if (fieldDef == default)
                {
                    ReportError($"Unknown field `{fieldName}` in struct `{nominal.Name}`", valueExpr.Span);
                    InferExpression(valueExpr);
                    continue;
                }

                var valType = InferExpression(valueExpr);
                _engine.Unify(valType, fieldDef.Type, valueExpr.Span);
            }

            // Check for missing fields
            var provided = new HashSet<string>(structCon.Fields.Select(f => f.FieldName));
            foreach (var field in nominal.FieldsOrVariants)
                if (!provided.Contains(field.Name))
                    ReportError($"Missing field `{field.Name}` in struct construction", structCon.Span, "E2015");

            return nominal;
        }

        // Fallback: infer fields without constraint
        foreach (var (_, valueExpr) in structCon.Fields)
            InferExpression(valueExpr);

        return structType;
    }

    // =========================================================================
    // Anonymous struct
    // =========================================================================

    private NominalType InferAnonymousStruct(AnonymousStructExpressionNode anon)
    {
        // Infer from field values
        var fields = new (string Name, Type Type)[anon.Fields.Count];
        for (int i = 0; i < anon.Fields.Count; i++)
        {
            var (fieldName, valueExpr) = anon.Fields[i];
            fields[i] = (fieldName, InferExpression(valueExpr));
        }

        var name = $"__anon_{string.Join("_", fields.Select(f => f.Name))}";
        return new NominalType(name, NominalKind.Struct, [], fields);
    }

    // =========================================================================
    // Array literal
    // =========================================================================

    private ArrayType InferArrayLiteral(ArrayLiteralExpressionNode arr)
    {
        if (arr.IsRepeatSyntax && arr.RepeatValue != null)
        {
            // [value; count]
            var elemType = InferExpression(arr.RepeatValue);
            return new ArrayType(elemType, arr.RepeatCount ?? 0);
        }

        if (arr.Elements == null || arr.Elements.Count == 0)
        {
            // Empty array: element type solved by caller via Unify
            return new ArrayType(_engine.FreshVar(), 0);
        }

        // Infer element type from first element, unify rest
        var firstType = InferExpression(arr.Elements[0]);
        for (var i = 1; i < arr.Elements.Count; i++)
        {
            var elemType = InferExpression(arr.Elements[i]);
            _engine.Unify(firstType, elemType, arr.Elements[i].Span);
        }

        return new ArrayType(firstType, arr.Elements.Count);
    }

    // =========================================================================
    // Index expression
    // =========================================================================

    private Type InferIndex(IndexExpressionNode idx)
    {
        var baseType = InferExpression(idx.Base);
        var indexType = InferExpression(idx.Index);

        // Try op_index — auto-ref-lifting handled by TryResolveOperatorFunction
        var opResult = TryResolveOperatorFunction("op_index", [baseType, indexType], idx.Span, out var resolvedNode);
        if (opResult != null)
        {
            _resolvedOperators[idx] = new ResolvedOperator(resolvedNode!);
            return opResult;
        }

        // Built-in array/slice indexing
        var resolvedBase = _engine.Resolve(baseType);

        if (resolvedBase is ArrayType arrayType)
        {
            _engine.Unify(indexType, WellKnown.USize, idx.Index.Span);
            return arrayType.ElementType;
        }

        if (resolvedBase is NominalType { Name: WellKnown.Slice, TypeArguments.Count: > 0 } sliceType)
        {
            _engine.Unify(indexType, WellKnown.USize, idx.Index.Span);
            return sliceType.TypeArguments[0];
        }

        ReportError("Type does not support indexing", idx.Span);
        return _engine.FreshVar();
    }

    // =========================================================================
    // Cast expression
    // =========================================================================

    private Type InferCast(CastExpressionNode cast)
    {
        InferExpression(cast.Expression);
        return ResolveTypeNode(cast.TargetType);
    }

    // =========================================================================
    // Range expression
    // =========================================================================

    private NominalType InferRange(RangeExpressionNode range)
    {
        Type elemType;

        if (range.Start != null && range.End != null)
        {
            var startType = InferExpression(range.Start);
            var endType = InferExpression(range.End);
            var unified = _engine.Unify(startType, endType, range.Span);
            elemType = unified.Type;
        }
        else if (range.Start != null)
        {
            elemType = InferExpression(range.Start);
        }
        else if (range.End != null)
        {
            elemType = InferExpression(range.End);
        }
        else
        {
            elemType = _engine.FreshVar();
        }

        var rangeNominal = LookupNominalType(WellKnown.Range)
                           ?? throw new InvalidOperationException(
                               $"Well-known type `{WellKnown.Range}` not registered");
        return new NominalType(rangeNominal.Name, rangeNominal.Kind, [elemType], rangeNominal.FieldsOrVariants);
    }

    // =========================================================================
    // Lambda
    // =========================================================================

    private FunctionType InferLambda(LambdaExpressionNode lambda)
    {
        _scopes.PushScope();

        // 1. Resolve parameter types from annotations or FreshVar
        var paramTypes = new Type[lambda.Parameters.Count];
        var paramNodes = new List<FunctionParameterNode>();
        for (var i = 0; i < lambda.Parameters.Count; i++)
        {
            var param = lambda.Parameters[i];
            paramTypes[i] = param.Type != null
                ? ResolveTypeNode(param.Type)
                : _engine.FreshVar();

            _scopes.Bind(param.Name, paramTypes[i]);

            // Create FunctionParameterNode for synthesized function
            var typeNode = param.Type ?? new NamedTypeNode(param.Span, "_inferred");
            paramNodes.Add(new FunctionParameterNode(param.Span, param.Name, typeNode));
        }

        // 2. Resolve return type
        var returnType = lambda.ReturnType != null
            ? ResolveTypeNode(lambda.ReturnType)
            : _engine.FreshVar();

        // 3. Synthesize a FunctionDeclarationNode
        var lambdaName = $"__lambda_{_nextLambdaId++}";
        var synthesized = new FunctionDeclarationNode(lambda.Span, lambdaName, paramNodes, lambda.ReturnType, lambda.Body);

        // 4. Push function context for return statements inside lambda
        _functionStack.Push(new FunctionContext(synthesized, returnType));

        // Check body statements
        foreach (var stmt in lambda.Body)
            CheckStatement(stmt);

        // 5. Implicit return: rewrite tail expression to return statement
        if (lambda.Body.Count > 0
            && lambda.Body[^1] is ExpressionStatementNode tailExpr
            && lambda.Body is List<StatementNode> bodyList)
        {
            var returnStmt = new ReturnStatementNode(tailExpr.Span, tailExpr.Expression);
            bodyList[^1] = returnStmt;
            // Unify tail expression type with return type
            var tailType = _checker_GetInferredTypeOrFresh(tailExpr.Expression);
            _engine.Unify(tailType, returnType, tailExpr.Span);
        }

        _functionStack.Pop();
        _scopes.PopScope();

        // 6. Record inferred types on synthesized function parameters
        for (var i = 0; i < paramNodes.Count; i++)
            Record(paramNodes[i], paramTypes[i]);

        // Record the synthesized function itself with its function type
        var fnType = new FunctionType(paramTypes, returnType);
        Record(synthesized, fnType);

        // 7. Set lambda.SynthesizedFunction and register in _specializations
        lambda.SynthesizedFunction = synthesized;
        _specializations.Add(synthesized);

        return fnType;
    }

    /// <summary>
    /// Get the inferred type for an expression node, or return a fresh var if not yet recorded.
    /// </summary>
    private Type _checker_GetInferredTypeOrFresh(ExpressionNode expr)
    {
        if (_inferredTypes.TryGetValue(expr, out var type))
            return type;
        return _engine.FreshVar();
    }

    // =========================================================================
    // Coalesce (??)
    // =========================================================================

    private Type InferCoalesce(CoalesceExpressionNode coal)
    {
        var leftType = InferExpression(coal.Left);
        var resolved = _engine.Resolve(leftType);

        // Left must be Option[T], result is T
        if (resolved is NominalType { Name: WellKnown.Option } optType
            && optType.TypeArguments.Count > 0)
        {
            var innerType = optType.TypeArguments[0];
            var rightType = InferExpression(coal.Right);
            _engine.Unify(rightType, innerType, coal.Right.Span);
            return innerType;
        }

        // Try op_coalesce
        var rightType2 = InferExpression(coal.Right);
        var opResult = TryResolveOperatorFunction("op_coalesce", [leftType, rightType2], coal.Span, out var resolvedNode);
        if (opResult != null)
        {
            _resolvedOperators[coal] = new ResolvedOperator(resolvedNode!);
            return opResult;
        }

        ReportError("Left operand of `??` must be Option type", coal.Span);
        return _engine.FreshVar();
    }

    // =========================================================================
    // Null propagation (?.)
    // =========================================================================

    private Type InferNullPropagation(NullPropagationExpressionNode nullProp)
    {
        var targetType = InferExpression(nullProp.Target);
        var resolved = _engine.Resolve(targetType);

        if (resolved is NominalType { Name: WellKnown.Option } optType
            && optType.TypeArguments.Count > 0)
        {
            var innerType = optType.TypeArguments[0];
            var innerResolved = _engine.Resolve(innerType);

            if (innerResolved is NominalType nominal)
            {
                var field = nominal.FieldsOrVariants
                    .FirstOrDefault(f => f.Name == nullProp.MemberName);

                if (field != default)
                {
                    var opt = LookupNominalType(WellKnown.Option)
                              ?? throw new InvalidOperationException(
                                  $"Well-known type `{WellKnown.Option}` not registered");
                    return new NominalType(opt.Name, opt.Kind, [field.Type], opt.FieldsOrVariants);
                }

                ReportError($"No field `{nullProp.MemberName}` on inner type", nullProp.Span);
                return _engine.FreshVar();
            }
        }

        ReportError("Null propagation `?.` requires Option type", nullProp.Span);
        return _engine.FreshVar();
    }
}