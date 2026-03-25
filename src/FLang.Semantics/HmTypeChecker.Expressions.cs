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
            FloatingPointLiteralNode flit => InferFloatingPointLiteral(flit),
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
            NamedArgumentExpressionNode namedArg => InferExpression(namedArg.Value),
            _ => InferUnknownExpression(expr)
        };

        return Record(expr, type);
    }

    private TypeVar InferUnknownExpression(ExpressionNode expr)
    {
        ReportError($"Unsupported expression kind: {expr.GetType().Name}", expr.Span);
        return _ctx.Engine.FreshVar();
    }

    // =========================================================================
    // Literals
    // =========================================================================

    private Type InferIntegerLiteral(IntegerLiteralNode lit)
    {
        if (lit.Suffix != null)
        {
            // Char literals with codepoints 0-255: allow contextual inference to u8 or char
            if (lit.Suffix == "char" && lit.Value >= 0 && lit.Value <= 255)
            {
                var charTv = _ctx.Engine.FreshVar();
                _unsuffixedLiterals.Add((lit, charTv));
                return charTv;
            }

            var prim = ResolvePrimitive(lit.Suffix);
            if (prim != null)
            {
                // E2029: Check literal value fits in the suffix type
                if (!FitsInType(lit.Value, lit.Suffix))
                    ReportError($"Literal `{lit.Value}{lit.Suffix}` out of range for type `{lit.Suffix}`", lit.Span, "E2029");
                return prim;
            }
            ReportError($"Unknown integer suffix `{lit.Suffix}`", lit.Span);
        }

        // Unsuffixed integer: fresh type variable (constrained by context)
        var tv = _ctx.Engine.FreshVar();
        _unsuffixedLiterals.Add((lit, tv));
        return tv;
    }

    private Type InferFloatingPointLiteral(FloatingPointLiteralNode lit)
    {
        if (lit.Suffix != null)
        {
            var prim = ResolvePrimitive(lit.Suffix);
            if (prim != null)
            {
                if (lit.Suffix == "f32" && (double.IsInfinity((float)lit.Value) && !double.IsInfinity(lit.Value)))
                    ReportError($"Literal `{lit.Value}f32` out of range for type `f32`", lit.Span, "E2029");
                return prim;
            }
            ReportError($"Unknown float suffix `{lit.Suffix}`", lit.Span);
        }

        // Unsuffixed float: fresh type variable (constrained by context)
        var tv = _ctx.Engine.FreshVar();
        _unsuffixedFloatLiterals.Add((lit, tv));
        return tv;
    }

    internal static bool FitsInType(System.Numerics.BigInteger value, string typeName) => typeName switch
    {
        "u8" => value >= 0 && value <= byte.MaxValue,
        "u16" => value >= 0 && value <= ushort.MaxValue,
        "u32" or "char" => value >= 0 && value <= uint.MaxValue,
        "u64" or "usize" => value >= 0 && value <= ulong.MaxValue,
        "i8" => value >= sbyte.MinValue && value <= sbyte.MaxValue,
        "i16" => value >= short.MinValue && value <= short.MaxValue,
        "i32" => value >= int.MinValue && value <= int.MaxValue,
        "i64" or "isize" => value >= long.MinValue && value <= long.MaxValue,
        _ => false
    };

    private NominalType InferStringLiteral()
    {
        return LookupNominalType(WellKnown.String)
               ?? throw new InvalidOperationException($"Well-known type `{WellKnown.String}` not registered");
    }

    private NominalType InferNullLiteral()
    {
        var option = LookupNominalType(WellKnown.Option)
                     ?? throw new InvalidOperationException($"Well-known type `{WellKnown.Option}` not registered");
        return new NominalType(option.Name, option.Kind, [_ctx.Engine.FreshVar()], option.FieldsOrVariants);
    }

    // =========================================================================
    // Identifiers
    // =========================================================================

    private Type InferIdentifier(IdentifierExpressionNode id)
    {
        // Look up in type scope (local variables, parameters, variant constructors)
        // With lambda scope barrier enforcement for non-capturing lambdas
        var scheme = _ctx.LambdaScopeBarrier > 0
            ? _ctx.Scopes.LookupWithBarrier(id.Name, _ctx.LambdaScopeBarrier)
            : _ctx.Scopes.Lookup(id.Name);
        if (scheme != null)
        {
            // Track usage for unused variable warnings
            _ctx.CurrentFnUsedVars?.Add(id.Name);

            // Track declaration for go-to-definition support
            var decl = _ctx.Scopes.LookupDeclaration(id.Name);
            if (decl is VariableDeclarationNode varDeclNode)
                id.ResolvedVariableDeclaration = varDeclNode;
            else if (decl is FunctionParameterNode paramDeclNode)
                id.ResolvedParameterDeclaration = paramDeclNode;

            // If this name is an active type parameter (inside a generic specialization),
            // it's being used as a type-as-value and should be wrapped in Type(T)
            if (_ctx.ActiveTypeParams.ContainsKey(id.Name))
            {
                var resolvedType = _ctx.Engine.Resolve(_ctx.Engine.Specialize(scheme));
                return WrapInTypeStruct(resolvedType);
            }
            return _ctx.Engine.Specialize(scheme);
        }

        // Check if it's a function name
        var fns = LookupFunctions(id.Name);
        if (fns is { Count: 1 })
        {
            // Single overload: resolve function target for go-to-definition
            id.ResolvedFunctionTarget = fns[0].Node;
            return _ctx.Engine.Specialize(fns[0].Signature);
        }

        // Check if it's a nominal type name
        var nominal = LookupNominalType(id.Name);
        if (nominal != null)
        {
            // Structs/tuples in expression context are type-as-value (e.g., size_of(Point))
            if (nominal.Kind == NominalKind.Struct || nominal.Kind == NominalKind.Tuple)
            {
                // Generic types used bare (without type args) are invalid in expression context
                if (nominal.TypeArguments.Count > 0
                    && nominal.TypeArguments.Any(a => _ctx.Engine.Resolve(a) is TypeVar))
                {
                    ReportError(
                        $"generic type `{id.Name}` requires type arguments in expression context, use `{id.Name}(...)`",
                        id.Span, "E2104");
                    return _ctx.Engine.FreshVar();
                }
                return WrapInTypeStruct(nominal);
            }
            // Enums returned directly for variant access (e.g., FileMode.Read)
            return nominal;
        }

        // Check if it's a primitive type name in expression context (e.g., align_of(u8))
        // Primitives are wrapped in Type(T) since they're only used as type-as-value args.
        var primitive = ResolvePrimitive(id.Name);
        if (primitive != null)
            return WrapInTypeStruct(primitive);

        ReportError($"Unresolved identifier `{id.Name}`", id.Span, "E2004");
        return _ctx.Engine.FreshVar();
    }

    /// <summary>
    /// Wrap a type in Type(T) for type-as-value expressions (e.g., align_of(u8)).
    /// Falls back to the raw type if the Type struct is not registered (rtti not imported).
    /// </summary>
    private Type WrapInTypeStruct(Type innerType)
    {
        var typeNominal = LookupNominalType("Type");
        if (typeNominal != null)
        {
            InstantiatedTypes.Add(innerType);
            return new NominalType(typeNominal.Name, typeNominal.Kind, [innerType], typeNominal.FieldsOrVariants);
        }
        return innerType;
    }

    // =========================================================================
    // Binary operators
    // =========================================================================

    private Type InferBinary(BinaryExpressionNode bin)
    {
        var left = InferExpression(bin.Left);
        var right = InferExpression(bin.Right);

        // Logical operators are always bool -> bool -> bool
        if (bin.Operator is BinaryOperatorKind.And or BinaryOperatorKind.Or)
        {
            _ctx.Engine.Unify(left, WellKnown.Bool, bin.Left.Span);
            _ctx.Engine.Unify(right, WellKnown.Bool, bin.Right.Span);
            return WellKnown.Bool;
        }

        // Try user-defined operator function
        var opName = OperatorFunctions.GetFunctionName(bin.Operator);
        var opResult = TryResolveOperator(opName, [left, right], bin.Span, out var resolvedNode);
        if (opResult != null)
        {
            _results.ResolvedOperators[bin] = new ResolvedOperator(resolvedNode!);
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
        var resolvedLeft = _ctx.Engine.Resolve(left);
        var resolvedRight = _ctx.Engine.Resolve(right);

        // Pointer arithmetic: ref + int -> ref, int + ref -> ref, ref - int -> ref
        if (op is BinaryOperatorKind.Add or BinaryOperatorKind.Subtract)
        {
            if (resolvedLeft is ReferenceType)
                return resolvedLeft;
            if (resolvedRight is ReferenceType && op == BinaryOperatorKind.Add)
                return resolvedRight;
        }

        // E2017: Non-primitive types with no operator implementation
        if (resolvedLeft is NominalType && resolvedLeft is not PrimitiveType
            && resolvedRight is not TypeVar)
        {
            var opSymbol = OperatorFunctions.GetOperatorSymbol(op);
            ReportError(
                $"No implementation for `{resolvedLeft} {opSymbol} {resolvedRight}`",
                span, "E2017");
            return _ctx.Engine.FreshVar();
        }

        // Unify operands (must be same numeric type)
        var unified = _ctx.Engine.Unify(left, right, span);

        // Reject bitwise/shift ops on float types
        if (op is BinaryOperatorKind.BitwiseAnd or BinaryOperatorKind.BitwiseOr or
            BinaryOperatorKind.BitwiseXor or BinaryOperatorKind.ShiftLeft or
            BinaryOperatorKind.ShiftRight or BinaryOperatorKind.UnsignedShiftRight)
        {
            var resolvedUnified = _ctx.Engine.Resolve(unified.Type);
            if (resolvedUnified is PrimitiveType pt && _floatTypeNames.Contains(pt.Name))
            {
                var opSymbol = OperatorFunctions.GetOperatorSymbol(op);
                ReportError(
                    $"Bitwise operation `{opSymbol}` is not supported on floating-point type `{pt.Name}`",
                    span, "E2017");
            }
        }

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
                    var eq = TryResolveOperator("op_eq", [left, right], span, out var eqNode);
                    if (eq != null)
                    {
                        _results.ResolvedOperators[bin] = new ResolvedOperator(eqNode!, NegateResult: true);
                        return WellKnown.Bool;
                    }
                    // Also try deriving from op_cmp: != means op_cmp(a,b) != 0
                    var cmpNe = TryResolveOperator("op_cmp", [left, right], span, out var cmpNeNode);
                    if (cmpNe != null)
                    {
                        _results.ResolvedOperators[bin] = new ResolvedOperator(cmpNeNode!, CmpDerivedOperator: bin.Operator);
                        return WellKnown.Bool;
                    }
                    return null;
                }
            case BinaryOperatorKind.Equal:
                {
                    var ne = TryResolveOperator("op_ne", [left, right], span, out var neNode);
                    if (ne != null)
                    {
                        _results.ResolvedOperators[bin] = new ResolvedOperator(neNode!, NegateResult: true);
                        return WellKnown.Bool;
                    }
                    // Also try deriving from op_cmp: == means op_cmp(a,b) == 0
                    var cmpEq = TryResolveOperator("op_cmp", [left, right], span, out var cmpEqNode);
                    if (cmpEq != null)
                    {
                        _results.ResolvedOperators[bin] = new ResolvedOperator(cmpEqNode!, CmpDerivedOperator: bin.Operator);
                        return WellKnown.Bool;
                    }
                    return null;
                }
            case BinaryOperatorKind.LessThan or BinaryOperatorKind.GreaterThan or
                BinaryOperatorKind.LessThanOrEqual or BinaryOperatorKind.GreaterThanOrEqual:
                {
                    var cmp = TryResolveOperator("op_cmp", [left, right], span, out var cmpNode);
                    if (cmp != null)
                    {
                        _results.ResolvedOperators[bin] = new ResolvedOperator(cmpNode!, CmpDerivedOperator: bin.Operator);
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
            var resolved = _ctx.Engine.Resolve(operand);
            if (resolved is PrimitiveType { Name: "bool" })
                return WellKnown.Bool;
        }

        // Try operator function
        var opName = OperatorFunctions.GetFunctionName(un.Operator);
        var opResult = TryResolveOperator(opName, [operand], un.Span, out var resolvedNode);
        if (opResult != null)
        {
            _results.ResolvedOperators[un] = new ResolvedOperator(resolvedNode!);
            return opResult;
        }

        // Built-in negate: same type
        if (un.Operator == UnaryOperatorKind.Negate)
            return operand;

        ReportError($"No operator `{OperatorFunctions.GetOperatorSymbol(un.Operator)}` for type", un.Span);
        return _ctx.Engine.FreshVar();
    }

    // =========================================================================
    // Overload resolution
    // =========================================================================

    /// <summary>
    /// Report E2011 with per-candidate notes explaining why each overload was rejected.
    /// </summary>
    private void ReportOverloadFailure(
        string displayName,
        List<FunctionScheme> candidates,
        Type[] fullPositionalTypes,
        List<NamedArgumentExpressionNode> namedArgs,
        Dictionary<string, Type> namedTypes,
        SourceSpan span,
        int ufcsOffset)
    {
        var userArgCount = fullPositionalTypes.Length - ufcsOffset + namedArgs.Count;
        var diag = Diagnostic.Error(
            $"No matching overload for `{displayName}` with {userArgCount} argument(s)",
            span, null, "E2011");

        foreach (var candidate in candidates)
        {
            var fn = candidate.Node;
            var paramCount = fn.Parameters.Count;
            var requiredCount = fn.RequiredParameterCount;
            var hasVariadic = fn.HasVariadicParam;
            var userParamCount = paramCount - ufcsOffset;

            // Specialize to get concrete types
            {
                var specialized = _ctx.Engine.Specialize(candidate.Signature);
                var fnType = _ctx.Engine.Resolve(specialized) as FunctionType;
                if (fnType == null) continue;

                // Format the candidate signature using resolved types
                var paramDescs = new List<string>();
                for (int p = ufcsOffset; p < fn.Parameters.Count; p++)
                {
                    var resolvedP = p < fnType.ParameterTypes.Count ? _ctx.Engine.Resolve(fnType.ParameterTypes[p]) : null;
                    paramDescs.Add($"{fn.Parameters[p].Name}: {resolvedP ?? (object)fn.Parameters[p].Type}");
                }
                var sig = $"{fn.Name}({string.Join(", ", paramDescs)})";

                // Check named arg validity
                foreach (var na in namedArgs)
                {
                    bool found = false;
                    for (int p = ufcsOffset; p < paramCount; p++)
                    {
                        if (fn.Parameters[p].Name == na.Name) { found = true; break; }
                    }
                    if (!found)
                    {
                        diag.Notes.Add(Diagnostic.Hint(
                            $"`{sig}`: no parameter named `{na.Name}`", fn.Span));
                        goto nextCandidate;
                    }
                }

                // Arity check (with defaults/variadics awareness)
                int totalSupplied = (fullPositionalTypes.Length - ufcsOffset) + namedArgs.Count;
                int nonVariadicParams = hasVariadic ? paramCount - 1 : paramCount;

                if (!hasVariadic && totalSupplied + ufcsOffset > paramCount)
                {
                    diag.Notes.Add(Diagnostic.Hint(
                        $"`{sig}`: expected at most {userParamCount} argument(s), got {userArgCount}", fn.Span));
                    continue;
                }
                if (totalSupplied + ufcsOffset < requiredCount)
                {
                    var requiredUserCount = requiredCount - ufcsOffset;
                    diag.Notes.Add(Diagnostic.Hint(
                        $"`{sig}`: expected at least {requiredUserCount} argument(s), got {userArgCount}", fn.Span));
                    continue;
                }

                // Check positional type mismatches
                for (int i = 0; i < fullPositionalTypes.Length && i < fnType.ParameterTypes.Count; i++)
                {
                    Type expectedType;
                    if (i >= ufcsOffset && (i - ufcsOffset) >= (nonVariadicParams - ufcsOffset) && hasVariadic)
                    {
                        var variadicParamType = fnType.ParameterTypes[paramCount - 1];
                        var resolvedVP = _ctx.Engine.Resolve(variadicParamType);
                        expectedType = resolvedVP is NominalType { Name: WellKnown.Slice } sliceType
                            && sliceType.TypeArguments.Count > 0
                            ? sliceType.TypeArguments[0] : variadicParamType;
                    }
                    else
                    {
                        expectedType = fnType.ParameterTypes[i];
                    }

                    var result = _ctx.Engine.TryUnify(fullPositionalTypes[i], expectedType);
                    if (result == null)
                    {
                        var resolvedArg = _ctx.Engine.Resolve(fullPositionalTypes[i]);
                        var resolvedParam = _ctx.Engine.Resolve(expectedType);
                        var paramName = i < fn.Parameters.Count ? fn.Parameters[i].Name : $"arg{i}";
                        diag.Notes.Add(Diagnostic.Hint(
                            $"`{sig}`: parameter `{paramName}` expects `{resolvedParam}`, got `{resolvedArg}`",
                            fn.Span));
                        goto nextCandidate;
                    }
                }

                // Check named arg type mismatches
                foreach (var na in namedArgs)
                {
                    int paramIdx = -1;
                    for (int p = ufcsOffset; p < paramCount; p++)
                    {
                        if (fn.Parameters[p].Name == na.Name) { paramIdx = p; break; }
                    }
                    if (paramIdx < 0 || paramIdx >= fnType.ParameterTypes.Count) continue;

                    var naResult = _ctx.Engine.TryUnify(namedTypes[na.Name], fnType.ParameterTypes[paramIdx]);
                    if (naResult == null)
                    {
                        var resolvedArg = _ctx.Engine.Resolve(namedTypes[na.Name]);
                        var resolvedParam = _ctx.Engine.Resolve(fnType.ParameterTypes[paramIdx]);
                        diag.Notes.Add(Diagnostic.Hint(
                            $"`{sig}`: parameter `{na.Name}` expects `{resolvedParam}`, got `{resolvedArg}`",
                            fn.Span));
                        goto nextCandidate;
                    }
                }
            }

        nextCandidate:;
        }

        _diagnostics.Add(diag);
    }

    /// <summary>
    /// Unified overload resolution: pick the best candidate from a list of overloads
    /// for the given argument types. Returns null winner on no match.
    /// Caller is responsible for candidate collection, arg adaptation, error reporting,
    /// and wiring up the resolved target.
    /// </summary>
    private (FunctionScheme Winner, FunctionType FnType, FunctionDeclarationNode Node)?
        ResolveOverload(List<FunctionScheme> candidates, Type[] argTypes, SourceSpan span)
    {
        FunctionScheme? bestCandidate = null;
        int bestCost = int.MaxValue;
        int bestGenericCount = int.MaxValue;

        foreach (var candidate in candidates)
        {
            var specialized = _ctx.Engine.Specialize(candidate.Signature);
            var fnType = _ctx.Engine.Resolve(specialized) as FunctionType;
            if (fnType == null) continue;
            if (fnType.ParameterTypes.Count != argTypes.Length) continue;

            // Try speculative unification of all arguments
            int totalCost = 0;
            bool success = true;
            for (int i = 0; i < argTypes.Length; i++)
            {
                var result = _ctx.Engine.TryUnify(argTypes[i], fnType.ParameterTypes[i]);
                if (result == null)
                {
                    success = false;
                    break;
                }
                totalCost += result.Value.Cost;
            }

            if (!success) continue;

            int genericCount = candidate.Signature.QuantifiedVarIds.Count;

            // Prefer fewer quantified type vars (0 = non-generic), then lower coercion cost
            if (genericCount < bestGenericCount
                || (genericCount == bestGenericCount && totalCost < bestCost))
            {
                bestCandidate = candidate;
                bestCost = totalCost;
                bestGenericCount = genericCount;
            }
        }

        if (bestCandidate == null) return null;

        // Re-specialize and commit unification
        var winnerSpec = _ctx.Engine.Specialize(bestCandidate.Signature);
        var winnerFn = _ctx.Engine.Resolve(winnerSpec) as FunctionType;
        if (winnerFn == null) return null;

        for (int i = 0; i < argTypes.Length; i++)
            _ctx.Engine.Unify(argTypes[i], winnerFn.ParameterTypes[i], span);

        // Generic monomorphization
        _ctx.DeferredSpecInfo = null;
        FunctionDeclarationNode node;
        if (bestCandidate.Signature.QuantifiedVarIds.Count > 0)
        {
            var concreteParams = winnerFn.ParameterTypes.Select(p => _ctx.Engine.Resolve(p)).ToArray();
            var concreteReturn = _ctx.Engine.Resolve(winnerFn.ReturnType);

            if (concreteParams.Any(p => p is TypeVar) || concreteReturn is TypeVar)
            {
                // Defer specialization — TypeVars not yet resolved
                _ctx.DeferredSpecInfo = (bestCandidate, concreteParams, concreteReturn);
                node = bestCandidate.Node;
            }
            else
            {
                var specialized = EnsureSpecialization(bestCandidate, concreteParams, concreteReturn, span);
                node = specialized ?? bestCandidate.Node;
            }
        }
        else
        {
            node = bestCandidate.Node;
        }

        return (bestCandidate, winnerFn, node);
    }

    /// <summary>
    /// Try to resolve an operator function by name. Returns null on no match.
    /// Thin wrapper: LookupFunctions + ResolveOverload.
    /// </summary>
    private Type? TryResolveOperator(string opName, Type[] argTypes, SourceSpan span, out FunctionDeclarationNode? resolvedNode)
    {
        resolvedNode = null;

        // Don't resolve user-defined operators when all arguments are unresolved TypeVars.
        // This prevents incorrect TypeVar binding (e.g., op_eq(String,String) binding
        // unsuffixed integer TypeVars to String). The builtin operator path handles these.
        if (argTypes.Length > 0 && argTypes.All(a => _ctx.Engine.Resolve(a) is TypeVar))
            return null;

        var candidates = LookupFunctions(opName);
        if (candidates == null) return null;

        var result = ResolveOverload(candidates, argTypes, span);
        _ctx.DeferredSpecInfo = null; // Operators don't use deferred specialization
        if (result == null) return null;

        var (_, fnType, node) = result.Value;
        resolvedNode = node;
        return fnType!.ReturnType;
    }

    /// <summary>
    /// Generalized overload resolution that supports default params, named args, and variadics.
    /// Arity check is relaxed: requiredCount &lt;= positional + named &lt;= totalCount (or unbounded for variadic).
    /// </summary>
    private (FunctionScheme Winner, FunctionType FnType, FunctionDeclarationNode Node)?
        ResolveOverloadWithDefaults(
            List<FunctionScheme> candidates,
            Type[] fullPositionalTypes,
            List<NamedArgumentExpressionNode> namedArgs,
            Dictionary<string, Type> namedTypes,
            SourceSpan span,
            int ufcsOffset)
    {
        FunctionScheme? bestCandidate = null;
        int bestCost = int.MaxValue;
        int bestGenericCount = int.MaxValue;

        foreach (var candidate in candidates)
        {
            var fn = candidate.Node;
            var paramCount = fn.Parameters.Count;
            var requiredCount = fn.RequiredParameterCount;
            var hasVariadic = fn.HasVariadicParam;

            // Check named arg names are valid for this candidate (skip UFCS receiver params)
            bool validNames = true;
            foreach (var na in namedArgs)
            {
                bool found = false;
                for (int p = ufcsOffset; p < paramCount; p++)
                {
                    if (fn.Parameters[p].Name == na.Name) { found = true; break; }
                }
                if (!found) { validNames = false; break; }
            }
            if (!validNames) continue;

            // Arity check:
            // positionalCount (excluding UFCS receiver) + namedCount must cover required params
            // and not exceed total non-variadic params (excess positionals go to variadic)
            int userPositionalCount = fullPositionalTypes.Length - ufcsOffset;
            int totalSupplied = userPositionalCount + namedArgs.Count;
            int nonVariadicParamCount = hasVariadic ? paramCount - 1 : paramCount;

            if (!hasVariadic && totalSupplied + ufcsOffset > paramCount) continue;
            if (totalSupplied + ufcsOffset < requiredCount) continue;

            // Speculative unification
            var specialized = _ctx.Engine.Specialize(candidate.Signature);
            var fnType = _ctx.Engine.Resolve(specialized) as FunctionType;
            if (fnType == null) continue;

            int totalCost = 0;
            bool success = true;

            // Unify positional args with corresponding params
            for (int i = 0; i < fullPositionalTypes.Length && i < fnType.ParameterTypes.Count; i++)
            {
                // For variadic param: unify positional args past last non-variadic with element type
                if (i >= ufcsOffset && i - ufcsOffset >= nonVariadicParamCount - ufcsOffset && hasVariadic)
                {
                    // Get the variadic param's slice type -> extract element type
                    var variadicParamType = fnType.ParameterTypes[paramCount - 1];
                    var resolvedVP = _ctx.Engine.Resolve(variadicParamType);
                    Type elemType;
                    if (resolvedVP is NominalType { Name: WellKnown.Slice } sliceType && sliceType.TypeArguments.Count > 0)
                        elemType = sliceType.TypeArguments[0];
                    else
                        elemType = variadicParamType;

                    var result = _ctx.Engine.TryUnify(fullPositionalTypes[i], elemType);
                    if (result == null) { success = false; break; }
                    totalCost += result.Value.Cost;
                }
                else if (i < fnType.ParameterTypes.Count)
                {
                    var result = _ctx.Engine.TryUnify(fullPositionalTypes[i], fnType.ParameterTypes[i]);
                    if (result == null) { success = false; break; }
                    totalCost += result.Value.Cost;
                }
            }
            if (!success) continue;

            // Unify named args by matching to parameter index
            foreach (var na in namedArgs)
            {
                int paramIdx = -1;
                for (int p = ufcsOffset; p < paramCount; p++)
                {
                    if (fn.Parameters[p].Name == na.Name) { paramIdx = p; break; }
                }
                if (paramIdx < 0 || paramIdx >= fnType.ParameterTypes.Count) { success = false; break; }

                var result = _ctx.Engine.TryUnify(namedTypes[na.Name], fnType.ParameterTypes[paramIdx]);
                if (result == null) { success = false; break; }
                totalCost += result.Value.Cost;
            }
            if (!success) continue;

            // Cost penalty for each defaulted param (prefer overloads that use fewer defaults)
            int suppliedParamIndices = fullPositionalTypes.Length + namedArgs.Count;
            int defaultsUsed = paramCount - suppliedParamIndices;
            if (hasVariadic) defaultsUsed = Math.Max(0, defaultsUsed - 1); // variadic itself is optional
            totalCost += defaultsUsed * 100;

            int genericCount = candidate.Signature.QuantifiedVarIds.Count;

            // Prefer fewer quantified type vars (0 = non-generic), then lower coercion cost
            if (genericCount < bestGenericCount
                || (genericCount == bestGenericCount && totalCost < bestCost))
            {
                bestCandidate = candidate;
                bestCost = totalCost;
                bestGenericCount = genericCount;
            }
        }

        if (bestCandidate == null) return null;

        // Re-specialize and commit unification
        var winnerSpec = _ctx.Engine.Specialize(bestCandidate.Signature);
        var winnerFn = _ctx.Engine.Resolve(winnerSpec) as FunctionType;
        if (winnerFn == null) return null;

        // Commit positional unification
        var fn2 = bestCandidate.Node;
        var nonVarCount = fn2.HasVariadicParam ? fn2.Parameters.Count - 1 : fn2.Parameters.Count;

        for (int i = 0; i < fullPositionalTypes.Length; i++)
        {
            if (i >= ufcsOffset && (i - ufcsOffset) >= (nonVarCount - ufcsOffset) && fn2.HasVariadicParam)
            {
                var variadicParamType = winnerFn.ParameterTypes[fn2.Parameters.Count - 1];
                var resolvedVP = _ctx.Engine.Resolve(variadicParamType);
                Type elemType;
                if (resolvedVP is NominalType { Name: WellKnown.Slice } sliceType && sliceType.TypeArguments.Count > 0)
                    elemType = sliceType.TypeArguments[0];
                else
                    elemType = variadicParamType;
                _ctx.Engine.Unify(fullPositionalTypes[i], elemType, span);
            }
            else if (i < winnerFn.ParameterTypes.Count)
            {
                _ctx.Engine.Unify(fullPositionalTypes[i], winnerFn.ParameterTypes[i], span);
            }
        }

        // Commit named arg unification
        foreach (var na in namedArgs)
        {
            for (int p = ufcsOffset; p < fn2.Parameters.Count; p++)
            {
                if (fn2.Parameters[p].Name == na.Name)
                {
                    _ctx.Engine.Unify(namedTypes[na.Name], winnerFn.ParameterTypes[p], span);
                    break;
                }
            }
        }

        // Generic monomorphization
        _ctx.DeferredSpecInfo = null;
        FunctionDeclarationNode node;
        if (bestCandidate.Signature.QuantifiedVarIds.Count > 0)
        {
            var concreteParams = winnerFn.ParameterTypes.Select(p => _ctx.Engine.Resolve(p)).ToArray();
            var concreteReturn = _ctx.Engine.Resolve(winnerFn.ReturnType);

            if (concreteParams.Any(p => p is TypeVar) || concreteReturn is TypeVar)
            {
                // Defer specialization — TypeVars not yet resolved
                _ctx.DeferredSpecInfo = (bestCandidate, concreteParams, concreteReturn);
                node = bestCandidate.Node;
            }
            else
            {
                var spec = EnsureSpecialization(bestCandidate, concreteParams, concreteReturn, span);
                node = spec ?? bestCandidate.Node;
            }
        }
        else
        {
            node = bestCandidate.Node;
        }

        return (bestCandidate, winnerFn, node);
    }

    /// <summary>
    /// Build the fully resolved argument list in parameter order, filling defaults and packing variadics.
    /// Sets call.ResolvedArguments. Does NOT include the UFCS receiver (lowering handles that separately).
    /// </summary>
    private void BuildResolvedArguments(
        CallExpressionNode call,
        FunctionDeclarationNode target,
        FunctionType winnerFnType,
        List<ExpressionNode> positionalArgs,
        List<NamedArgumentExpressionNode> namedArgs,
        int ufcsOffset)
    {
        var resolved = new List<ExpressionNode>();
        int positionalIdx = 0; // index into user's positional args (excluding UFCS receiver)

        // Build a lookup for named args
        var namedLookup = new Dictionary<string, ExpressionNode>();
        foreach (var na in namedArgs)
        {
            if (namedLookup.ContainsKey(na.Name))
            {
                ReportError($"duplicate named argument `{na.Name}`", na.Span, "E2066");
                continue;
            }
            namedLookup[na.Name] = na.Value;
        }

        for (int p = ufcsOffset; p < target.Parameters.Count; p++)
        {
            var param = target.Parameters[p];
            var paramType = p < winnerFnType.ParameterTypes.Count ? winnerFnType.ParameterTypes[p] : null;

            if (param.IsVariadic)
            {
                // Collect remaining positional args into an array literal
                var variadicElements = new List<ExpressionNode>();
                while (positionalIdx < positionalArgs.Count)
                    variadicElements.Add(positionalArgs[positionalIdx++]);

                var arrLiteral = new ArrayLiteralExpressionNode(call.Span, variadicElements);
                // Infer the array literal type so lowering can handle it
                var arrType = InferExpression(arrLiteral);
                // Unify the array element type with the variadic element type (from Slice[T])
                if (paramType != null)
                {
                    var resolvedPT = _ctx.Engine.Resolve(paramType);
                    if (resolvedPT is NominalType { Name: WellKnown.Slice } sliceType
                        && sliceType.TypeArguments.Count > 0
                        && arrType is ArrayType arrT)
                    {
                        _ctx.Engine.Unify(arrT.ElementType, sliceType.TypeArguments[0], call.Span);
                    }
                }
                resolved.Add(arrLiteral);
            }
            else if (namedLookup.TryGetValue(param.Name, out var namedValue))
            {
                resolved.Add(namedValue);
                namedLookup.Remove(param.Name);
            }
            else if (positionalIdx < positionalArgs.Count)
            {
                resolved.Add(positionalArgs[positionalIdx++]);
            }
            else if (param.DefaultValue != null)
            {
                // Clone the default expression (fresh eval per call site)
                var cloned = CloneExpression(param.DefaultValue);
                var defaultType = InferExpression(cloned);
                // Unify with parameter type to give the literal a concrete type
                if (paramType != null)
                    _ctx.Engine.Unify(defaultType, paramType, call.Span);
                resolved.Add(cloned);
            }
            else
            {
                ReportError($"missing argument for required parameter `{param.Name}`",
                    call.Span, "E2067");
            }
        }

        // Check for excess positional args
        if (positionalIdx < positionalArgs.Count)
        {
            ReportError($"too many positional arguments (expected {target.Parameters.Count - ufcsOffset}, got {positionalArgs.Count})",
                call.Span, "E2068");
        }

        // Check for unknown named args
        foreach (var remaining in namedLookup)
        {
            ReportError($"unknown named argument `{remaining.Key}`",
                call.Span, "E2069");
        }

        call.ResolvedArguments = resolved;
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

        // Separate arguments into positional and named
        var positionalArgs = new List<ExpressionNode>();
        var namedArgs = new List<NamedArgumentExpressionNode>();
        foreach (var arg in call.Arguments)
        {
            if (arg is NamedArgumentExpressionNode named)
                namedArgs.Add(named);
            else
                positionalArgs.Add(arg);
        }

        // Infer types for all argument values
        var positionalTypes = new Type[positionalArgs.Count];
        for (int i = 0; i < positionalArgs.Count; i++)
            positionalTypes[i] = InferExpression(positionalArgs[i]);

        var namedTypes = new Dictionary<string, Type>();
        foreach (var na in namedArgs)
            namedTypes[na.Name] = InferExpression(na.Value);

        // Use MethodName for UFCS lookup, FunctionName for regular calls
        var lookupName = call.MethodName ?? call.FunctionName;

        // Check for vtable/field-call pattern: receiver.field(args)
        if (receiverType != null && call.MethodName != null)
        {
            var fieldArgTypes = positionalTypes;
            var fieldCallResult = TryFieldCall(call, receiverType, call.MethodName, fieldArgTypes);
            if (fieldCallResult != null)
            {
                if (namedArgs.Count > 0)
                    ReportError("named arguments are not supported for indirect/field calls",
                        namedArgs[0].Span, "E2065");
                return fieldCallResult;
            }
        }

        // Build full positional argument types (receiver prepended for UFCS)
        Type[] fullPositionalTypes;
        if (receiverType != null)
        {
            fullPositionalTypes = new Type[positionalTypes.Length + 1];
            fullPositionalTypes[0] = receiverType;
            Array.Copy(positionalTypes, 0, fullPositionalTypes, 1, positionalTypes.Length);
        }
        else
        {
            fullPositionalTypes = positionalTypes;
        }

        // Try enum variant construction: EnumType.Variant(args)
        if (receiverType != null && namedArgs.Count == 0)
        {
            var resolvedReceiver = _ctx.Engine.Resolve(receiverType);
            if (resolvedReceiver is NominalType { Kind: NominalKind.Enum } enumNominal)
            {
                // For non-generic enums, resolve variant directly from the enum type
                // to avoid name collisions with variants of other enums in scope
                // (e.g. TypeKind.Array vs JsonValue.Array).
                // Generic enums use scope-based lookup to get fresh TypeVars via Specialize.
                var isGeneric = enumNominal.TypeArguments.Any(a => _ctx.Engine.Resolve(a) is TypeVar);
                Type? variantType;
                if (isGeneric)
                    variantType = TryResolveVariantConstruction(lookupName, positionalTypes, call.Span);
                else
                    variantType = TryResolveQualifiedVariant(enumNominal, lookupName, positionalTypes, call.Span);
                if (variantType != null) return variantType;
            }
        }

        // Look up function candidates FIRST — regular functions take priority over variant constructors.
        var candidates = LookupFunctions(lookupName);
        if (candidates != null && candidates.Count > 0)
        {
            bool hasNamedOrDefaults = namedArgs.Count > 0
                || candidates.Any(c => c.Node.Parameters.Any(p => p.DefaultValue != null || p.IsVariadic));

            (FunctionScheme Winner, FunctionType FnType, FunctionDeclarationNode Node)? result;

            if (hasNamedOrDefaults)
            {
                var ufcsOffset = receiverType != null ? 1 : 0;
                result = ResolveOverloadWithDefaults(candidates, fullPositionalTypes, namedArgs, namedTypes, call.Span, ufcsOffset);

                // For UFCS, try adapting receiver (value ↔ &T) if direct match failed
                if (result == null && receiverType != null && fullPositionalTypes.Length > 0)
                {
                    var resolvedReceiver = _ctx.Engine.Resolve(fullPositionalTypes[0]);
                    var adapted = (Type[])fullPositionalTypes.Clone();
                    if (resolvedReceiver is ReferenceType rt)
                        adapted[0] = rt.InnerType;
                    else
                        adapted[0] = new ReferenceType(resolvedReceiver);
                    result = ResolveOverloadWithDefaults(candidates, adapted, namedArgs, namedTypes, call.Span, ufcsOffset);
                }

                if (result != null)
                {
                    var (winner, fnType, node) = result.Value;
                    call.ResolvedTarget = node;
                    if (_ctx.DeferredSpecInfo != null)
                    {
                        var (scheme, dParams, dReturn) = _ctx.DeferredSpecInfo.Value;
                        _pendingSpecializations.Add((scheme, dParams, dReturn, call.Span, call));
                        _ctx.DeferredSpecInfo = null;
                    }
                    BuildResolvedArguments(call, winner.Node, fnType, positionalArgs, namedArgs, ufcsOffset);
                    CheckDeprecatedCall(node, call.Span);
                    return fnType.ReturnType;
                }
            }
            else
            {
                // Fast path: no named args or defaults — use original overload resolution
                result = ResolveOverload(candidates, fullPositionalTypes, call.Span);

                // For UFCS, try adapting receiver (value ↔ &T) if direct match failed
                if (result == null && receiverType != null && fullPositionalTypes.Length > 0)
                {
                    var resolvedReceiver = _ctx.Engine.Resolve(fullPositionalTypes[0]);
                    var adapted = (Type[])fullPositionalTypes.Clone();
                    if (resolvedReceiver is ReferenceType rt)
                        adapted[0] = rt.InnerType;
                    else
                        adapted[0] = new ReferenceType(resolvedReceiver);
                    result = ResolveOverload(candidates, adapted, call.Span);
                }

                if (result != null)
                {
                    var (_, fnType, node) = result.Value;
                    call.ResolvedTarget = node;
                    if (_ctx.DeferredSpecInfo != null)
                    {
                        var (scheme, dParams, dReturn) = _ctx.DeferredSpecInfo.Value;
                        _pendingSpecializations.Add((scheme, dParams, dReturn, call.Span, call));
                        _ctx.DeferredSpecInfo = null;
                    }
                    CheckDeprecatedCall(node, call.Span);
                    return fnType.ReturnType;
                }
            }

            var displayName = call.MethodName ?? call.FunctionName;
            var ufcsOff = receiverType != null ? 1 : 0;
            ReportOverloadFailure(displayName, candidates, fullPositionalTypes, namedArgs, namedTypes, call.Span, ufcsOff);
            return _ctx.IsCheckingGenericBody
                ? GuessReturnTypeFromCandidates(candidates)
                : _ctx.Engine.FreshVar();
        }

        // Try generic type instantiation in expression context: TypeName(TypeArgs)
        // e.g., allocator.new(RcInner(T)) — RcInner is a type, not a function
        if (receiverType == null && namedArgs.Count == 0)
        {
            var nominal = LookupNominalType(lookupName);
            if (nominal != null && (nominal.Kind == NominalKind.Struct || nominal.Kind == NominalKind.Tuple))
            {
                var typeNominal = LookupNominalType("Type");
                var typeArgs = new Type[positionalTypes.Length];
                bool allTypeArgs = positionalTypes.Length > 0;
                for (int i = 0; i < positionalTypes.Length; i++)
                {
                    var resolved = _ctx.Engine.Resolve(positionalTypes[i]);
                    // Unwrap Type(X) wrapper from type-as-value expressions
                    if (typeNominal != null && resolved is NominalType nt
                        && nt.Name == typeNominal.Name && nt.TypeArguments.Count == 1)
                    {
                        typeArgs[i] = _ctx.Engine.Resolve(nt.TypeArguments[0]);
                    }
                    else
                    {
                        allTypeArgs = false;
                        break;
                    }
                }

                if (allTypeArgs)
                {
                    // Build substitution from template TypeVars to concrete type args
                    var subst = new Dictionary<int, Type>();
                    for (int i = 0; i < Math.Min(typeArgs.Length, nominal.TypeArguments.Count); i++)
                    {
                        var templateArg = _ctx.Engine.Resolve(nominal.TypeArguments[i]);
                        if (templateArg is TypeVar tv)
                            subst[tv.Id] = typeArgs[i];
                    }

                    var fields = subst.Count > 0
                        ? nominal.FieldsOrVariants
                            .Select(f => (f.Name, SubstituteTypeVars(f.Type, subst)))
                            .ToArray()
                        : nominal.FieldsOrVariants;

                    var instantiated = new NominalType(nominal.Name, nominal.Kind, typeArgs, fields);
                    call.IsTypeInstantiation = true;
                    return WrapInTypeStruct(instantiated);
                }
            }
        }

        // Try enum variant construction (non-UFCS: bare variant name)
        if (namedArgs.Count == 0)
        {
            var variantType2 = TryResolveVariantConstruction(lookupName, fullPositionalTypes, call.Span);
            if (variantType2 != null) return variantType2;
        }

        // Try indirect call (variable with function type)
        if (namedArgs.Count > 0)
        {
            ReportError("named arguments are not supported for indirect calls",
                namedArgs[0].Span, "E2065");
        }
        return TryIndirectCall(call, fullPositionalTypes);
    }

    /// <summary>
    /// Try to resolve a call as a field-call (vtable pattern): receiver.field(args)
    /// where the receiver is a struct with a function-typed field matching the method name.
    /// </summary>
    private Type? TryFieldCall(CallExpressionNode call, Type receiverType, string fieldName, Type[] argTypes)
    {
        var resolved = _ctx.Engine.Resolve(receiverType);

        // Auto-deref through references
        while (resolved is ReferenceType refType)
            resolved = _ctx.Engine.Resolve(refType.InnerType);

        if (resolved is not NominalType { Kind: NominalKind.Struct or NominalKind.Tuple } nominal)
            return null;

        // Look up the registered template if needed
        var fieldsSource = nominal;
        if (nominal.FieldsOrVariants.Count == 0)
        {
            var template = LookupNominalType(nominal.Name);
            if (template != null) fieldsSource = template;
        }

        // Find the field
        var field = fieldsSource.FieldsOrVariants.FirstOrDefault(f => f.Name == fieldName);
        if (field == default) return null;

        // Check if it's a function type
        var fieldType = _ctx.Engine.Resolve(field.Type);
        if (fieldType is not FunctionType fnType)
        {
            // E2011: Field exists but is not callable
            ReportError($"Field `{fieldName}` is not a function and cannot be called", call.Span, "E2011");
            foreach (var arg in call.Arguments) InferExpression(arg);
            return fieldType;
        }

        // It's a function-typed field — treat as indirect call
        if (fnType.ParameterTypes.Count != argTypes.Length)
        {
            ReportError($"No matching overload for `{fieldName}` with {argTypes.Length} arguments",
                call.Span, "E2011");
            return _ctx.Engine.FreshVar();
        }

        for (int i = 0; i < argTypes.Length; i++)
            _ctx.Engine.Unify(argTypes[i], fnType.ParameterTypes[i], call.Span);

        call.IsIndirectCall = true;
        return fnType.ReturnType;
    }

    /// <summary>
    /// Resolve a variant construction from a qualified EnumType.Variant(args) call.
    /// Uses the enum type's FieldsOrVariants directly to avoid name collisions with
    /// variants of other enums in scope.
    /// </summary>
    private Type? TryResolveQualifiedVariant(NominalType enumType, string variantName, Type[] argTypes, SourceSpan span)
    {
        // Look up the registered enum (may have more complete field info)
        var registered = LookupNominalType(enumType.Name) ?? enumType;

        var variant = registered.FieldsOrVariants.FirstOrDefault(f => f.Name == variantName);
        if (variant == default) return null;

        // Payload-less variant
        if (variant.Type.Equals(WellKnown.Void) && argTypes.Length == 0)
            return enumType;

        // Payload variant
        if (argTypes.Length == 1)
        {
            if (_ctx.Engine.TryUnify(argTypes[0], variant.Type) == null)
                return null;
            _ctx.Engine.Unify(argTypes[0], variant.Type, span);
            return enumType;
        }

        // Multi-payload variant (tuple)
        if (variant.Type is NominalType { Kind: NominalKind.Tuple } tupleType)
        {
            if (tupleType.FieldsOrVariants.Count != argTypes.Length)
                return null;
            for (int i = 0; i < argTypes.Length; i++)
            {
                if (_ctx.Engine.TryUnify(argTypes[i], tupleType.FieldsOrVariants[i].Type) == null)
                    return null;
            }
            for (int i = 0; i < argTypes.Length; i++)
                _ctx.Engine.Unify(argTypes[i], tupleType.FieldsOrVariants[i].Type, span);
            return enumType;
        }

        return null;
    }

    /// <summary>
    /// Try to resolve a call as an enum variant construction.
    /// Variant constructors are bound in scope as polymorphic types.
    /// </summary>
    private Type? TryResolveVariantConstruction(string name, Type[] argTypes, SourceSpan span)
    {
        var scheme = _ctx.Scopes.Lookup(name);
        if (scheme == null) return null;

        var specialized = _ctx.Engine.Specialize(scheme);
        var resolved = _ctx.Engine.Resolve(specialized);

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
                if (_ctx.Engine.TryUnify(argTypes[i], fnType.ParameterTypes[i]) == null)
                    return null;
            }

            // Commit
            for (int i = 0; i < argTypes.Length; i++)
                _ctx.Engine.Unify(argTypes[i], fnType.ParameterTypes[i], span);

            return fnType.ReturnType;
        }

        return null;
    }

    /// <summary>
    /// Try calling through a variable that holds a function type.
    /// </summary>
    private Type TryIndirectCall(CallExpressionNode call, Type[] argTypes)
    {
        var scheme = _ctx.Scopes.Lookup(call.FunctionName);
        if (scheme != null)
        {
            var specialized = _ctx.Engine.Specialize(scheme);
            var resolved = _ctx.Engine.Resolve(specialized);
            if (resolved is FunctionType fnType)
            {
                if (fnType.ParameterTypes.Count == argTypes.Length)
                {
                    for (int i = 0; i < argTypes.Length; i++)
                        _ctx.Engine.Unify(argTypes[i], fnType.ParameterTypes[i], call.Span);
                    call.IsIndirectCall = true;
                    return fnType.ReturnType;
                }
            }
        }

        var fnName = call.MethodName ?? call.FunctionName;
        ReportError($"Unresolved function `{fnName}`", call.Span, "E2004");
        if (_ctx.IsCheckingGenericBody)
        {
            var fallbackCandidates = LookupFunctions(fnName);
            if (fallbackCandidates != null)
                return GuessReturnTypeFromCandidates(fallbackCandidates);
        }
        return _ctx.Engine.FreshVar();
    }

    // =========================================================================
    // If expression
    // =========================================================================

    private Type InferIf(IfExpressionNode ifExpr)
    {
        // Condition must be bool
        var condType = InferExpression(ifExpr.Condition);
        _ctx.Engine.Unify(condType, WellKnown.Bool, ifExpr.Condition.Span);

        // Then branch
        var thenType = InferExpression(ifExpr.ThenBranch);

        if (ifExpr.ElseBranch != null)
        {
            // Both branches: unify
            var elseType = InferExpression(ifExpr.ElseBranch);

            // Pre-bind Option TypeVars for T vs null coercion
            PreBindOptionTypeVar(thenType, elseType, ifExpr.Span);

            using (_ctx.Engine.OverrideErrors("E2074",
                () => "if/else branches have different types: then is `{expected}`, else is `{actual}`"))
            {
                var unified = _ctx.Engine.Unify(thenType, elseType, ifExpr.Span);
                return unified.Type;
            }
        }

        // No else: void
        return WellKnown.Void;
    }

    /// <summary>
    /// Infer an if/else in statement context — try to unify branches, but if they
    /// differ, silently record void instead of reporting an error.
    /// </summary>
    private void InferIfAsStatement(IfExpressionNode ifExpr)
    {
        var condType = InferExpression(ifExpr.Condition);
        _ctx.Engine.Unify(condType, WellKnown.Bool, ifExpr.Condition.Span);

        var thenType = InferExpression(ifExpr.ThenBranch);

        if (ifExpr.ElseBranch != null)
        {
            var elseType = InferExpression(ifExpr.ElseBranch);
            PreBindOptionTypeVar(thenType, elseType, ifExpr.Span);

            if (_ctx.Engine.TryUnify(thenType, elseType) != null)
            {
                var unified = _ctx.Engine.Unify(thenType, elseType, ifExpr.Span);
                Record(ifExpr, unified.Type);
                return;
            }
        }

        Record(ifExpr, WellKnown.Void);
    }

    // =========================================================================
    // Block expression
    // =========================================================================

    private Type InferBlock(BlockExpressionNode block)
    {
        PushScope();

        foreach (var stmt in block.Statements)
            CheckStatement(stmt);

        Type result;
        if (block.TrailingExpression != null)
            result = InferExpression(block.TrailingExpression);
        else
            result = WellKnown.Void;

        PopScope();
        return result;
    }

    // =========================================================================
    // Match expression
    // =========================================================================

    private Type InferMatch(MatchExpressionNode match)
    {
        var scrutineeType = InferExpression(match.Scrutinee);
        Type resultType = _ctx.Engine.FreshVar();

        foreach (var arm in match.Arms)
        {
            PushScope();

            // Bind pattern variables
            CheckPattern(arm.Pattern, scrutineeType);

            // Infer arm body and unify with result type
            var armType = InferExpression(arm.ResultExpr);

            // Pre-bind Option TypeVars for T vs null coercion:
            // When one side is concrete T and the other is Option(TypeVar), bind the
            // TypeVar so the OptionWrappingCoercionRule can match T -> Option(T).
            PreBindOptionTypeVar(resultType, armType, arm.Span);

            using (_ctx.Engine.OverrideErrors("E2075",
                () => "match arm returns `{actual}`, but previous arms return `{expected}`"))
            {
                var unified = _ctx.Engine.Unify(resultType, armType, arm.Span);
                resultType = unified.Type;
            }

            PopScope();
        }

        // E2030/E2031: Check match exhaustiveness for enum types
        var resolvedScrutinee = _ctx.Engine.Resolve(scrutineeType);
        // Auto-deref for exhaustiveness check
        while (resolvedScrutinee is ReferenceType refScrutinee)
            resolvedScrutinee = _ctx.Engine.Resolve(refScrutinee.InnerType);

        if (resolvedScrutinee is NominalType { Kind: NominalKind.Enum } enumScrutinee)
        {
            // Check exhaustiveness only if there are variant patterns and no catch-all
            bool hasElse = match.Arms.Any(a => a.Pattern is ElsePatternNode or VariablePatternNode or WildcardPatternNode);
            if (!hasElse)
            {
                var coveredVariants = new HashSet<string>();
                foreach (var arm in match.Arms)
                {
                    if (arm.Pattern is EnumVariantPatternNode vp)
                        coveredVariants.Add(vp.VariantName);
                }

                var allVariants = enumScrutinee.FieldsOrVariants.Select(f => f.Name).ToHashSet();
                var missing = allVariants.Except(coveredVariants).ToList();
                if (missing.Count > 0)
                    ReportError($"Non-exhaustive match: missing variant(s) {string.Join(", ", missing.Select(m => $"`{m}`"))}", match.Span, "E2031");
            }
        }
        else if (resolvedScrutinee is not TypeVar && match.Arms.Any(a => a.Pattern is EnumVariantPatternNode))
        {
            // E2030: Match variant pattern on non-enum type
            ReportError($"Cannot match on non-enum type `{resolvedScrutinee}`", match.Span, "E2030");
        }

        return resultType;
    }

    /// <summary>
    /// When one side is a concrete type T and the other is Option(TypeVar),
    /// pre-bind the TypeVar to T so the OptionWrappingCoercionRule can match.
    /// This enables T-to-Option(T) coercion in match arms and if/else branches
    /// where one branch returns T and another returns null.
    /// </summary>
    private void PreBindOptionTypeVar(Type a, Type b, SourceSpan span)
    {
        a = _ctx.Engine.Resolve(a);
        b = _ctx.Engine.Resolve(b);

        // a is concrete T, b is Option(TypeVar) → bind TypeVar = T
        if (b is NominalType { Name: WellKnown.Option } optB && optB.TypeArguments.Count > 0)
        {
            var inner = _ctx.Engine.Resolve(optB.TypeArguments[0]);
            if (inner is TypeVar && a is not TypeVar && !(a is NominalType { Name: WellKnown.Option }))
                _ctx.Engine.Unify(a, inner, span);
        }
        // b is concrete T, a is Option(TypeVar) → bind TypeVar = T
        else if (a is NominalType { Name: WellKnown.Option } optA && optA.TypeArguments.Count > 0)
        {
            var inner = _ctx.Engine.Resolve(optA.TypeArguments[0]);
            if (inner is TypeVar && b is not TypeVar && !(b is NominalType { Name: WellKnown.Option }))
                _ctx.Engine.Unify(b, inner, span);
        }
    }

    /// <summary>
    /// Check a pattern against the expected type and bind variables in scope.
    /// </summary>
    private void CheckPattern(PatternNode pattern, Type scrutineeType)
    {
        switch (pattern)
        {
            case VariablePatternNode varPat:
                _ctx.Scopes.Bind(varPat.Name, scrutineeType);
                Record(varPat, scrutineeType);
                break;

            case WildcardPatternNode:
            case ElsePatternNode:
                // Match anything, bind nothing
                break;

            case EnumVariantPatternNode variantPat:
                CheckEnumVariantPattern(variantPat, scrutineeType);
                break;

            case LiteralPatternNode litPat:
                var litType = InferExpression(litPat.Literal);
                _ctx.Engine.Unify(litType, scrutineeType, litPat.Span);
                // Resolve op_eq using the same rules as binary ==
                var eqResult = TryResolveOperator("op_eq", [scrutineeType, litType], litPat.Span, out var eqNode);
                if (eqResult != null)
                    _results.ResolvedOperators[litPat] = new ResolvedOperator(eqNode!);
                Record(litPat, scrutineeType);
                break;

            default:
                ReportError($"Unsupported pattern kind: {pattern.GetType().Name}", pattern.Span);
                break;
        }
    }

    private void CheckEnumVariantPattern(EnumVariantPatternNode pattern, Type scrutineeType)
    {
        var resolved = _ctx.Engine.Resolve(scrutineeType);

        // Auto-dereference through references (e.g., &List -> List)
        while (resolved is ReferenceType refType)
            resolved = _ctx.Engine.Resolve(refType.InnerType);

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
            ReportError($"Unknown variant `{pattern.VariantName}` for type `{enumType.Name}`", pattern.Span, "E2037");
            return;
        }

        // Substitute template TypeVars with concrete type arguments
        var variantType = variant.Type;
        if (enumType.TypeArguments.Count > 0)
        {
            var template = LookupNominalType(enumType.Name);
            if (template != null && template.TypeArguments.Count == enumType.TypeArguments.Count)
                variantType = SubstituteTypeArgs(variantType, template.TypeArguments, enumType.TypeArguments);
        }

        // Bind sub-patterns to variant payload
        if (variantType is PrimitiveType { Name: "void" })
        {
            // E2032: Payload-less variant: no sub-patterns expected
            if (pattern.SubPatterns.Count > 0)
                ReportError($"Variant `{pattern.VariantName}` expects 0 bindings, got {pattern.SubPatterns.Count}", pattern.Span, "E2032");
        }
        else if (variantType is NominalType { Kind: NominalKind.Tuple } tupleType
                 && tupleType.Name.StartsWith("__tuple_")
                 && tupleType.FieldsOrVariants.Count > 0)
        {
            // Multi-payload variant (synthetic tuple): check ARITY first, then bind
            // E2032: Arity mismatch
            if (pattern.SubPatterns.Count != tupleType.FieldsOrVariants.Count)
            {
                ReportError($"Variant `{pattern.VariantName}` expects {tupleType.FieldsOrVariants.Count} bindings, got {pattern.SubPatterns.Count}", pattern.Span, "E2032");
            }
            else
            {
                // Multi-payload: bind each sub-pattern to tuple field
                for (int i = 0; i < pattern.SubPatterns.Count; i++)
                    CheckPattern(pattern.SubPatterns[i], tupleType.FieldsOrVariants[i].Type);
            }
        }
        else if (pattern.SubPatterns.Count == 1)
        {
            // Single payload: bind directly
            CheckPattern(pattern.SubPatterns[0], variantType);
        }
        else if (pattern.SubPatterns.Count > 1)
        {
            // E2032: Single payload but multiple sub-patterns
            ReportError($"Variant `{pattern.VariantName}` expects 1 binding, got {pattern.SubPatterns.Count}",
                pattern.Span, "E2032");
        }

        Record(pattern, scrutineeType);
    }

    // =========================================================================
    // Assignment
    // =========================================================================

    private PrimitiveType InferAssignment(AssignmentExpressionNode assign)
    {
        // Indexed assignment: arr[i] = val -> op_set_index(&arr, i, val)
        if (assign.Target is IndexExpressionNode idx)
            return InferIndexedAssignment(assign, idx);

        // E2038: Cannot assign to const variable
        if (assign.Target is IdentifierExpressionNode targetId && IsConst(targetId.Name))
            ReportError($"Cannot assign to constant `{targetId.Name}`", assign.Span, "E2038");

        var targetType = InferExpression(assign.Target);
        var valueType = InferExpression(assign.Value);
        var diagCount = _ctx.Engine.DiagnosticCount;
        _ctx.Engine.Unify(valueType, targetType, assign.Value.Span);
        if (_ctx.Engine.DiagnosticCount > diagCount
            && assign.Target is IdentifierExpressionNode targetId2)
        {
            var decl = _ctx.Scopes.LookupDeclaration(targetId2.Name);
            if (decl != null)
                _ctx.Engine.GetDiagnostic(diagCount).Notes.Add(
                    Diagnostic.Info($"`{targetId2.Name}` declared here", decl.Span));
        }
        return WellKnown.Void;
    }

    private PrimitiveType InferIndexedAssignment(AssignmentExpressionNode assign, IndexExpressionNode idx)
    {
        var baseType = InferExpression(idx.Base);
        var indexType = InferExpression(idx.Index);
        var valueType = InferExpression(assign.Value);

        // Built-in array/slice indexed assignment takes priority (matches InferIndex pattern)
        var resolvedBase = _ctx.Engine.Resolve(baseType);

        if (resolvedBase is ArrayType arrayType)
        {
            _ctx.Engine.Unify(indexType, WellKnown.USize, idx.Index.Span);
            _ctx.Engine.Unify(valueType, arrayType.ElementType, assign.Value.Span);
            Record(idx, arrayType.ElementType);
            return WellKnown.Void;
        }

        if (resolvedBase is NominalType { Name: WellKnown.Slice } sliceType
            && sliceType.TypeArguments.Count > 0)
        {
            _ctx.Engine.Unify(indexType, WellKnown.USize, idx.Index.Span);
            _ctx.Engine.Unify(valueType, sliceType.TypeArguments[0], assign.Value.Span);
            Record(idx, sliceType.TypeArguments[0]);
            return WellKnown.Void;
        }

        // Try op_set_index(&base, index, value) for user-defined types
        var refBaseType = new ReferenceType(baseType);
        var opResult = TryResolveOperator("op_set_index", [refBaseType, indexType, valueType], assign.Span, out var setNode);
        if (opResult == null)
            opResult = TryResolveOperator("op_set_index", [baseType, indexType, valueType], assign.Span, out setNode);

        if (opResult != null)
        {
            _results.ResolvedOperators[assign] = new ResolvedOperator(setNode!);
            Record(idx, valueType);
            return WellKnown.Void;
        }

        ReportError("Type does not support indexed assignment", idx.Span);
        Record(idx, _ctx.Engine.FreshVar());
        return WellKnown.Void;
    }

    // =========================================================================
    // Address-of and dereference
    // =========================================================================

    private ReferenceType InferAddressOf(AddressOfExpressionNode addrOf)
    {
        // E2040: Cannot take address of temporaries (only identifiers, member access, index, deref, calls)
        if (addrOf.Target is not (IdentifierExpressionNode or MemberAccessExpressionNode
            or IndexExpressionNode or DereferenceExpressionNode or CallExpressionNode))
        {
            ReportError("Cannot take address of temporary value", addrOf.Span, "E2040");
        }

        var inner = InferExpression(addrOf.Target);
        return new ReferenceType(inner);
    }

    private Type InferDereference(DereferenceExpressionNode deref)
    {
        var inner = InferExpression(deref.Target);
        var resolved = _ctx.Engine.Resolve(inner);
        if (resolved is ReferenceType refType)
            return refType.InnerType;

        // If the type is still a TypeVar (e.g., unannotated lambda parameter),
        // create a reference constraint: inner must be &resultType.
        // Unification will propagate this when the TypeVar gets bound.
        if (resolved is TypeVar)
        {
            var resultType = _ctx.Engine.FreshVar();
            _ctx.Engine.Unify(inner, new ReferenceType(resultType), deref.Span);
            return resultType;
        }

        ReportError("Cannot dereference non-reference type", deref.Span, "E2012");
        return _ctx.Engine.FreshVar();
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
        var resolved = _ctx.Engine.Resolve(targetType);

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

            // Type(T) is a phantom type — field access resolves against TypeInfo
            if (field == default && nominal.Name == "core.rtti.Type")
            {
                var typeInfo = LookupNominalType("core.rtti.TypeInfo");
                if (typeInfo != null)
                    field = typeInfo.FieldsOrVariants.FirstOrDefault(f => f.Name == fieldName);
            }

            if (field != default)
            {
                // For enum variants, return the enum type (payload-less) or a
                // constructor function type (payload), not the raw payload type
                if (fieldsSource.Kind == NominalKind.Enum)
                {
                    // Substitute generic type args for variant payload types
                    var payloadType = field.Type;
                    if (nominal.TypeArguments.Count > 0)
                    {
                        var tmpl = LookupNominalType(nominal.Name);
                        if (tmpl != null && tmpl.TypeArguments.Count == nominal.TypeArguments.Count)
                            payloadType = SubstituteTypeArgs(payloadType, tmpl.TypeArguments, nominal.TypeArguments);
                    }

                    if (payloadType is PrimitiveType { Name: "void" })
                    {
                        // Payload-less variant: value IS the enum type
                        return nominal;
                    }
                    else
                    {
                        // Payload variant: fn(payload) -> EnumType
                        return new FunctionType([payloadType], nominal);
                    }
                }

                // For generic types, substitute template TypeVars with instance type args
                var fieldType = field.Type;
                if (nominal.TypeArguments.Count > 0)
                {
                    var template = LookupNominalType(nominal.Name);
                    if (template != null && template.TypeArguments.Count == nominal.TypeArguments.Count)
                        fieldType = SubstituteTypeArgs(fieldType, template.TypeArguments, nominal.TypeArguments);
                }

                return fieldType;
            }
        }

        // Fixed-size arrays have implicit .len and .ptr fields
        if (resolved is ArrayType arrayType)
        {
            if (fieldName == "len") return WellKnown.USize;
            if (fieldName == "ptr") return new ReferenceType(arrayType.ElementType);
        }

        // "did you mean?" for field names
        string? fieldHint = null;
        if (resolved is NominalType nomForHint)
        {
            var fieldsSource = nomForHint;
            if (nomForHint.FieldsOrVariants.Count == 0)
            {
                var tmpl = LookupNominalType(nomForHint.Name);
                if (tmpl != null) fieldsSource = tmpl;
            }
            var fieldNames = fieldsSource.FieldsOrVariants.Select(f => f.Name);
            var suggestion = StringDistance.FindClosestMatch(fieldName, fieldNames);
            if (suggestion != null) fieldHint = $"did you mean `{suggestion}`?";
        }
        ReportError($"No field `{fieldName}` on type", member.Span, "E2014", fieldHint);
        return _ctx.Engine.FreshVar();
    }

    // =========================================================================
    // Struct construction
    // =========================================================================

    private Type InferStructConstruction(StructConstructionExpressionNode structCon)
    {
        var structType = ResolveTypeNode(structCon.TypeName);
        var resolved = _ctx.Engine.Resolve(structType);

        // E2018: Non-nominal types (primitives, references, etc.) can't be constructed
        if (resolved is not NominalType nominal)
        {
            ReportError($"Cannot construct non-struct type `{resolved}`", structCon.Span, "E2018");
            foreach (var (_, valueExpr) in structCon.Fields)
                InferExpression(valueExpr);
            return resolved;
        }

        // E2018: Cannot construct non-struct type (enums, etc.)
        if (nominal.Kind != NominalKind.Struct && nominal.Kind != NominalKind.Tuple)
        {
            ReportError($"Cannot construct non-struct type `{nominal.Name}`", structCon.Span, "E2018");
            foreach (var (_, valueExpr) in structCon.Fields)
                InferExpression(valueExpr);
            return nominal;
        }

        // Generic structs constructed by name must include type arguments.
        // e.g., `Rc(i32) { ... }` is valid, `Rc { ... }` is not — use `.{ ... }` for inference.
        if (nominal.TypeArguments.Count > 0 && structCon.TypeName is NamedTypeNode namedType)
        {
            ReportError(
                $"generic struct `{namedType.Name}` requires type arguments, use `{namedType.Name}(...)` or `.{{ ... }}`",
                structCon.TypeName.Span, "E2019");
        }

        // Instantiate fresh TypeVars for the struct's generic type parameters.
        // This prevents field unification from contaminating the template's
        // shared TypeVars (which would corrupt all subsequent uses of the struct).
        if (nominal.TypeArguments.Count > 0)
        {
            var subst = new Dictionary<int, Type>();
            var freshArgs = new Type[nominal.TypeArguments.Count];

            // Look up the template to get the original TypeVars for field substitution.
            // When type args are concrete (e.g., Foo(i32)), we need to map the template's
            // TypeVars to the concrete args so fields get properly substituted.
            var template = LookupNominalType(nominal.Name);

            for (int i = 0; i < nominal.TypeArguments.Count; i++)
            {
                var ta = _ctx.Engine.Resolve(nominal.TypeArguments[i]);
                if (ta is TypeVar tv)
                {
                    var fresh = _ctx.Engine.FreshVar();
                    freshArgs[i] = fresh;
                    subst[tv.Id] = fresh;
                }
                else
                {
                    freshArgs[i] = ta;
                    // Map the template's TypeVar to the concrete type arg
                    if (template != null && i < template.TypeArguments.Count)
                    {
                        var templateArg = _ctx.Engine.Resolve(template.TypeArguments[i]);
                        if (templateArg is TypeVar templateTv)
                            subst[templateTv.Id] = ta;
                    }
                }
            }
            if (subst.Count > 0)
            {
                // Use the template's fields as the base for substitution
                var baseFields = template?.FieldsOrVariants ?? nominal.FieldsOrVariants;
                var freshFields = baseFields
                    .Select(f => (f.Name, SubstituteTypeVars(f.Type, subst)))
                    .ToArray();
                nominal = new NominalType(nominal.Name, nominal.Kind, freshArgs, freshFields);
            }
        }

        // Check each field
        foreach (var (fieldName, valueExpr) in structCon.Fields)
        {
            var fieldDef = nominal.FieldsOrVariants
                .FirstOrDefault(f => f.Name == fieldName);

            if (fieldDef == default)
            {
                ReportError($"Unknown field `{fieldName}` in struct `{nominal.Name}`", valueExpr.Span, "E2014");
                InferExpression(valueExpr);
                continue;
            }

            var valType = InferExpression(valueExpr);
            _ctx.Engine.Unify(valType, fieldDef.Type, valueExpr.Span);
        }

        // Unspecified fields are zero-initialized (codegen memsets the struct to 0)

        return nominal;
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
        // Detect tuples: field names are _0, _1, _2, ... (from parser desugaring)
        var isTuple = fields.Length == 0 || fields.Select((f, i) => f.Name == $"_{i}").All(b => b);
        return new NominalType(name, isTuple ? NominalKind.Tuple : NominalKind.Struct, [], fields);
    }

    // =========================================================================
    // Array literal
    // =========================================================================

    private ArrayType InferArrayLiteral(ArrayLiteralExpressionNode arr)
    {
        if (arr.IsRepeatSyntax && arr.RepeatValue != null && arr.RepeatCountExpression != null)
        {
            // [value; count]
            var elemType = InferExpression(arr.RepeatValue);

            // Try to resolve count to a compile-time integer
            int? staticCount = TryEvalConstantInt(arr.RepeatCountExpression);

            // Count must be usize
            var countType = InferExpression(arr.RepeatCountExpression);
            _ctx.Engine.Unify(countType, WellKnown.USize, arr.RepeatCountExpression.Span);

            return new ArrayType(elemType, staticCount ?? 0);
        }

        if (arr.Elements == null || arr.Elements.Count == 0)
        {
            // Empty array: element type solved by caller via Unify.
            // E2026 is checked during variable declaration when we can verify no type context exists.
            return new ArrayType(_ctx.Engine.FreshVar(), 0);
        }

        // Infer element type from first element, unify rest
        var firstType = InferExpression(arr.Elements[0]);
        for (var i = 1; i < arr.Elements.Count; i++)
        {
            var elemType = InferExpression(arr.Elements[i]);
            _ctx.Engine.Unify(firstType, elemType, arr.Elements[i].Span);
        }

        return new ArrayType(firstType, arr.Elements.Count);
    }

    /// <summary>
    /// Tries to evaluate an expression as a compile-time integer constant.
    /// Handles integer literals and const variable references.
    /// </summary>
    private int? TryEvalConstantInt(ExpressionNode expr)
    {
        if (expr is IntegerLiteralNode intLit)
            return (int)intLit.Value;

        if (expr is IdentifierExpressionNode id)
        {
            var decl = _ctx.Scopes.LookupDeclaration(id.Name);
            if (decl is VariableDeclarationNode { IsConst: true, Initializer: not null } constVar)
                return TryEvalConstantInt(constVar.Initializer);
        }

        return null;
    }

    // =========================================================================
    // Index expression
    // =========================================================================

    private Type InferIndex(IndexExpressionNode idx)
    {
        var baseType = InferExpression(idx.Base);
        var indexType = InferExpression(idx.Index);

        // Built-in array/slice indexing takes priority over user-defined op_index.
        // This prevents false matches where op_index(String, Range) matches Slice[u8]
        // through StringToByteSlice bidirectional coercion.
        var resolvedBase = _ctx.Engine.Resolve(baseType);
        var resolvedIndex = _ctx.Engine.Resolve(indexType);

        // Check if index is a Range — range indexing returns a Slice
        var isRangeIndex = resolvedIndex is NominalType { Kind: NominalKind.Struct } nomIdx
                           && nomIdx.Name.EndsWith("Range");

        // E2027: Check that index type is not bool (common mistake)
        if (!isRangeIndex && resolvedIndex is PrimitiveType { Name: "bool" })
        {
            ReportError("Cannot use `bool` as an index type", idx.Index.Span, "E2027");
            return _ctx.Engine.FreshVar();
        }

        if (resolvedBase is ArrayType arrayType)
        {
            if (isRangeIndex)
            {
                // Range indexing: array[range] -> Slice[T]
                // Unify range element type with usize
                if (resolvedIndex is NominalType rangeNom && rangeNom.TypeArguments.Count > 0)
                    _ctx.Engine.Unify(rangeNom.TypeArguments[0], WellKnown.USize, idx.Index.Span);
                var sliceNominal = LookupNominalType(WellKnown.Slice)
                    ?? throw new InvalidOperationException($"Well-known type `{WellKnown.Slice}` not registered");
                return new NominalType(sliceNominal.Name, sliceNominal.Kind,
                    [arrayType.ElementType], sliceNominal.FieldsOrVariants);
            }
            _ctx.Engine.Unify(indexType, WellKnown.USize, idx.Index.Span);
            return arrayType.ElementType;
        }

        if (resolvedBase is NominalType { Name: WellKnown.Slice, TypeArguments.Count: > 0 } sliceType)
        {
            if (isRangeIndex)
            {
                // Range indexing: slice[range] -> Slice[T]
                // Unify range element type with usize
                if (resolvedIndex is NominalType rangeNom2 && rangeNom2.TypeArguments.Count > 0)
                    _ctx.Engine.Unify(rangeNom2.TypeArguments[0], WellKnown.USize, idx.Index.Span);
                return sliceType;
            }
            _ctx.Engine.Unify(indexType, WellKnown.USize, idx.Index.Span);
            return sliceType.TypeArguments[0];
        }

        // Try op_index for user-defined types (Dict, String, etc.)
        var refBaseType = new ReferenceType(baseType);
        var opResult = TryResolveOperator("op_index", [refBaseType, indexType], idx.Span, out var resolvedNode)
                    ?? TryResolveOperator("op_index", [baseType, indexType], idx.Span, out resolvedNode);
        if (opResult != null)
        {
            _results.ResolvedOperators[idx] = new ResolvedOperator(resolvedNode!);
            return opResult;
        }

        ReportError("Type does not support indexing", idx.Span, "E2028");
        return _ctx.Engine.FreshVar();
    }

    // =========================================================================
    // Cast expression
    // =========================================================================

    private Type InferCast(CastExpressionNode cast)
    {
        var innerType = InferExpression(cast.Expression);
        var targetType = ResolveTypeNode(cast.TargetType);

        // For numeric casts (e.g. `10 as i32`), unify the inner expression's type
        // with the target so unsuffixed integer literals get their TypeVar resolved.
        if (innerType is TypeVar && targetType is PrimitiveType)
            _ctx.Engine.Unify(innerType, targetType, cast.Span);

        // E2020: Validate cast compatibility
        var resolvedInner = _ctx.Engine.Resolve(innerType);
        var resolvedTarget = _ctx.Engine.Resolve(targetType);
        if (resolvedInner is not TypeVar && resolvedTarget is not TypeVar)
        {
            if (!IsCastValid(resolvedInner, resolvedTarget))
                ReportError($"Invalid cast from `{resolvedInner}` to `{resolvedTarget}`", cast.Span, "E2020");
        }

        return targetType;
    }

    /// <summary>
    /// Validates explicit `as` casts only — implicit coercions are handled by unification.
    /// </summary>
    private static bool IsCastValid(Type from, Type to)
    {
        // Same type is always valid
        if (from.Equals(to)) return true;

        // Numeric -> numeric is valid (including bool and char)
        if (from is PrimitiveType pFrom && to is PrimitiveType pTo)
        {
            return IsNumericPrimitive(pFrom) && IsNumericPrimitive(pTo);
        }

        // Reference -> reference is valid (reinterpret cast)
        if (from is ReferenceType && to is ReferenceType) return true;

        // Reference -> usize (pointer to int)
        if (from is ReferenceType && to is PrimitiveType { Name: "usize" or "isize" }) return true;

        // usize -> reference (int to pointer)
        if (from is PrimitiveType { Name: "usize" or "isize" } && to is ReferenceType) return true;

        // Nominal -> nominal casts are allowed (reinterpret/binary-compatible casts)
        // This covers String ↔ Slice[u8], array -> slice, etc.
        if (from is NominalType && to is NominalType) return true;

        // Array -> nominal (array -> slice cast)
        if (from is ArrayType && to is NominalType) return true;

        // Enum -> primitive (tag extraction) or primitive -> enum
        if (from is NominalType { Kind: NominalKind.Enum } && to is PrimitiveType) return true;
        if (from is PrimitiveType && to is NominalType { Kind: NominalKind.Enum }) return true;

        return false;
    }

    private static bool IsNumericPrimitive(PrimitiveType p) => p.Name is not ("void" or "never") && ResolvePrimitive(p.Name) != null;

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
            var unified = _ctx.Engine.Unify(startType, endType, range.Span);
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
            elemType = _ctx.Engine.FreshVar();
        }

        var rangeNominal = LookupNominalType(WellKnown.Range)
            ?? throw new InvalidOperationException($"Well-known type `{WellKnown.Range}` not registered");
        return new NominalType(rangeNominal.Name, rangeNominal.Kind, [elemType], rangeNominal.FieldsOrVariants);
    }

    // =========================================================================
    // Lambda
    // =========================================================================

    private FunctionType InferLambda(LambdaExpressionNode lambda)
    {
        // Set scope barrier for non-capturing lambda (all FLang lambdas are non-capturing)
        var savedBarrier = _ctx.LambdaScopeBarrier;
        _ctx.LambdaScopeBarrier = _ctx.Scopes.Depth;

        PushScope();

        // 1. Resolve parameter types from annotations or FreshVar
        var paramTypes = new Type[lambda.Parameters.Count];
        var paramNodes = new List<FunctionParameterNode>();
        for (var i = 0; i < lambda.Parameters.Count; i++)
        {
            var param = lambda.Parameters[i];
            paramTypes[i] = param.Type != null
                ? ResolveTypeNode(param.Type)
                : _ctx.Engine.FreshVar();

            _ctx.Scopes.Bind(param.Name, paramTypes[i]);

            // Create FunctionParameterNode for synthesized function
            var typeNode = param.Type ?? new NamedTypeNode(param.Span, "_inferred");
            paramNodes.Add(new FunctionParameterNode(param.Span, param.Span, param.Name, typeNode));
        }

        // 2. Resolve return type
        var returnType = lambda.ReturnType != null
            ? ResolveTypeNode(lambda.ReturnType)
            : _ctx.Engine.FreshVar();

        // 3. Synthesize a FunctionDeclarationNode
        var lambdaName = $"__lambda_{_ctx.NextLambdaId++}";
        var synthesized = new FunctionDeclarationNode(lambda.Span, lambda.Span, lambdaName, paramNodes, lambda.ReturnType, lambda.Body);

        // 4. Push function context for return statements inside lambda
        _ctx.FunctionStack.Push(new FunctionContext(synthesized, returnType));

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
            _ctx.Engine.Unify(tailType, returnType, tailExpr.Span);
        }

        _ctx.FunctionStack.Pop();
        PopScope();

        // Restore scope barrier
        _ctx.LambdaScopeBarrier = savedBarrier;

        // 6. Record inferred types on synthesized function parameters
        for (var i = 0; i < paramNodes.Count; i++)
            Record(paramNodes[i], paramTypes[i]);

        // Record the synthesized function itself with its function type
        var fnType = new FunctionType(paramTypes, returnType);
        Record(synthesized, fnType);

        // 7. Set lambda.SynthesizedFunction and register in _results.Specializations
        lambda.SynthesizedFunction = synthesized;
        _results.Specializations.Add(synthesized);

        return fnType;
    }

    /// <summary>
    /// Get the inferred type for an expression node, or return a fresh var if not yet recorded.
    /// </summary>
    private Type _checker_GetInferredTypeOrFresh(ExpressionNode expr)
    {
        if (_results.InferredTypes.TryGetValue(expr, out var type))
            return type;
        return _ctx.Engine.FreshVar();
    }

    // =========================================================================
    // Coalesce (??)
    // =========================================================================

    private Type InferCoalesce(CoalesceExpressionNode coal)
    {
        var leftType = InferExpression(coal.Left);
        var resolved = _ctx.Engine.Resolve(leftType);

        // Left must be Option[T]
        if (resolved is NominalType { Name: WellKnown.Option } optType
            && optType.TypeArguments.Count > 0)
        {
            var innerType = optType.TypeArguments[0];
            var rightType = InferExpression(coal.Right);
            var resolvedRight = _ctx.Engine.Resolve(rightType);

            // Option[T] ?? Option[T] -> Option[T]
            if (resolvedRight is NominalType { Name: WellKnown.Option } rightOpt
                && rightOpt.TypeArguments.Count > 0)
            {
                _ctx.Engine.Unify(innerType, rightOpt.TypeArguments[0], coal.Right.Span);
                return resolved; // return Option[T]
            }

            // Option[T] ?? T -> T
            _ctx.Engine.Unify(rightType, innerType, coal.Right.Span);
            return innerType;
        }

        // Try op_coalesce
        var rightType2 = InferExpression(coal.Right);
        var opResult = TryResolveOperator("op_coalesce", [leftType, rightType2], coal.Span, out var resolvedNode);
        if (opResult != null)
        {
            _results.ResolvedOperators[coal] = new ResolvedOperator(resolvedNode!);
            return opResult;
        }

        ReportError("Left operand of `??` must be Option type", coal.Span);
        return _ctx.Engine.FreshVar();
    }

    // =========================================================================
    // Null propagation (?.)
    // =========================================================================

    private Type InferNullPropagation(NullPropagationExpressionNode nullProp)
    {
        var targetType = InferExpression(nullProp.Target);
        var resolved = _ctx.Engine.Resolve(targetType);

        if (resolved is NominalType { Name: WellKnown.Option } optType
            && optType.TypeArguments.Count > 0)
        {
            var innerType = optType.TypeArguments[0];
            var innerResolved = _ctx.Engine.Resolve(innerType);

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
                return _ctx.Engine.FreshVar();
            }
        }

        ReportError("Null propagation `?.` requires Option type", nullProp.Span);
        return _ctx.Engine.FreshVar();
    }
}
