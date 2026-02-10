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
        var tv = _engine.FreshVar();
        _unsuffixedLiterals.Add((lit, tv));
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
        return new NominalType(option.Name, option.Kind, [_engine.FreshVar()], option.FieldsOrVariants);
    }

    // =========================================================================
    // Identifiers
    // =========================================================================

    private Type InferIdentifier(IdentifierExpressionNode id)
    {
        // Look up in type scope (local variables, parameters, variant constructors)
        // With lambda scope barrier enforcement for non-capturing lambdas
        var scheme = _lambdaScopeBarrier > 0
            ? _scopes.LookupWithBarrier(id.Name, _lambdaScopeBarrier)
            : _scopes.Lookup(id.Name);
        if (scheme != null)
        {
            // If this name is an active type parameter (inside a generic specialization),
            // it's being used as a type-as-value and should be wrapped in Type(T)
            if (_activeTypeParams.ContainsKey(id.Name))
            {
                var resolvedType = _engine.Resolve(_engine.Specialize(scheme));
                return WrapInTypeStruct(resolvedType);
            }
            return _engine.Specialize(scheme);
        }

        // Check if it's a function name
        var fns = LookupFunctions(id.Name);
        if (fns is { Count: 1 })
        {
            // Single overload: return its function type
            return _engine.Specialize(fns[0].Signature);
        }

        // Check if it's a nominal type name
        var nominal = LookupNominalType(id.Name);
        if (nominal != null)
        {
            // Structs in expression context are type-as-value (e.g., size_of(Point))
            if (nominal.Kind == NominalKind.Struct)
                return WrapInTypeStruct(nominal);
            // Enums returned directly for variant access (e.g., FileMode.Read)
            return nominal;
        }

        // Check if it's a primitive type name in expression context (e.g., align_of(u8))
        // Primitives are wrapped in Type(T) since they're only used as type-as-value args.
        var primitive = ResolvePrimitive(id.Name);
        if (primitive != null)
            return WrapInTypeStruct(primitive);

        ReportError($"Unresolved identifier `{id.Name}`", id.Span, "E2004");
        return _engine.FreshVar();
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

        // Logical operators are always bool → bool → bool
        if (bin.Operator is BinaryOperatorKind.And or BinaryOperatorKind.Or)
        {
            _engine.Unify(left, WellKnown.Bool, bin.Left.Span);
            _engine.Unify(right, WellKnown.Bool, bin.Right.Span);
            return WellKnown.Bool;
        }

        // Try user-defined operator function
        var opName = OperatorFunctions.GetFunctionName(bin.Operator);
        var opResult = TryResolveOperator(opName, [left, right], bin.Span, out var resolvedNode);
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

        // E2017: Non-primitive types with no operator implementation
        if (resolvedLeft is NominalType && resolvedLeft is not PrimitiveType
            && resolvedRight is not TypeVar)
        {
            var opSymbol = OperatorFunctions.GetOperatorSymbol(op);
            ReportError(
                $"No implementation for `{resolvedLeft} {opSymbol} {resolvedRight}`",
                span, "E2017");
            return _engine.FreshVar();
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
                    var eq = TryResolveOperator("op_eq", [left, right], span, out var eqNode);
                    if (eq != null)
                    {
                        _resolvedOperators[bin] = new ResolvedOperator(eqNode!, NegateResult: true);
                        return WellKnown.Bool;
                    }
                    // Also try deriving from op_cmp: != means op_cmp(a,b) != 0
                    var cmpNe = TryResolveOperator("op_cmp", [left, right], span, out var cmpNeNode);
                    if (cmpNe != null)
                    {
                        _resolvedOperators[bin] = new ResolvedOperator(cmpNeNode!, CmpDerivedOperator: bin.Operator);
                        return WellKnown.Bool;
                    }
                    return null;
                }
            case BinaryOperatorKind.Equal:
                {
                    var ne = TryResolveOperator("op_ne", [left, right], span, out var neNode);
                    if (ne != null)
                    {
                        _resolvedOperators[bin] = new ResolvedOperator(neNode!, NegateResult: true);
                        return WellKnown.Bool;
                    }
                    // Also try deriving from op_cmp: == means op_cmp(a,b) == 0
                    var cmpEq = TryResolveOperator("op_cmp", [left, right], span, out var cmpEqNode);
                    if (cmpEq != null)
                    {
                        _resolvedOperators[bin] = new ResolvedOperator(cmpEqNode!, CmpDerivedOperator: bin.Operator);
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
        var opResult = TryResolveOperator(opName, [operand], un.Span, out var resolvedNode);
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
    // Overload resolution
    // =========================================================================

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
        bool bestIsGeneric = true;

        foreach (var candidate in candidates)
        {
            var specialized = _engine.Specialize(candidate.Signature);
            var fnType = _engine.Resolve(specialized) as FunctionType;
            if (fnType == null) continue;
            if (fnType.ParameterTypes.Count != argTypes.Length) continue;

            // Try speculative unification of all arguments
            int totalCost = 0;
            bool success = true;
            for (int i = 0; i < argTypes.Length; i++)
            {
                var result = _engine.TryUnify(argTypes[i], fnType.ParameterTypes[i]);
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
            }
            else if (isGeneric == bestIsGeneric && totalCost < bestCost)
            {
                bestCandidate = candidate;
                bestCost = totalCost;
                bestIsGeneric = isGeneric;
            }
        }

        if (bestCandidate == null) return null;

        // Re-specialize and commit unification
        var winnerSpec = _engine.Specialize(bestCandidate.Signature);
        var winnerFn = _engine.Resolve(winnerSpec) as FunctionType;
        if (winnerFn == null) return null;

        for (int i = 0; i < argTypes.Length; i++)
            _engine.Unify(argTypes[i], winnerFn.ParameterTypes[i], span);

        // Generic monomorphization
        FunctionDeclarationNode node;
        if (bestCandidate.Signature.QuantifiedVarIds.Count > 0)
        {
            var concreteParams = winnerFn.ParameterTypes.Select(p => _engine.Resolve(p)).ToArray();
            var concreteReturn = _engine.Resolve(winnerFn.ReturnType);
            var specialized = EnsureSpecialization(bestCandidate, concreteParams, concreteReturn, span);
            node = specialized ?? bestCandidate.Node;
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
        var candidates = LookupFunctions(opName);
        if (candidates == null) return null;

        var result = ResolveOverload(candidates, argTypes, span);
        if (result == null) return null;

        var (_, fnType, node) = result.Value;
        resolvedNode = node;
        return fnType!.ReturnType;
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

        // Use MethodName for UFCS lookup, FunctionName for regular calls
        var lookupName = call.MethodName ?? call.FunctionName;

        // Check for vtable/field-call pattern: receiver.field(args)
        // When the receiver is a struct with a function-typed field matching the method name,
        // this is an indirect call through a function pointer, NOT a UFCS method call.
        if (receiverType != null && call.MethodName != null)
        {
            var fieldCallResult = TryFieldCall(call, receiverType, call.MethodName, argTypes);
            if (fieldCallResult != null) return fieldCallResult;
        }

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

        // Try enum variant construction: EnumType.Variant(args)
        // When the UFCS receiver is an enum type and the method is a variant,
        // use only the actual args (not the receiver) for construction.
        if (receiverType != null)
        {
            var resolvedReceiver = _engine.Resolve(receiverType);
            if (resolvedReceiver is NominalType { Kind: NominalKind.Enum })
            {
                var variantType = TryResolveVariantConstruction(lookupName, argTypes, call.Span);
                if (variantType != null) return variantType;
            }
        }

        // Look up function candidates FIRST — regular functions take priority over variant constructors.
        // Variant constructors (Ok, Err, etc.) only exist in _scopes, not _functions.
        // Regular functions exist in both. If we tried variant construction first, any function
        // returning an enum type (e.g., open_file → Result) would be misidentified as a variant.
        var candidates = LookupFunctions(lookupName);
        if (candidates != null && candidates.Count > 0)
        {
            // Try with args as-is first
            var result = ResolveOverload(candidates, fullArgTypes, call.Span);

            // For UFCS, try adapting receiver (value ↔ &T) if direct match failed
            if (result == null && receiverType != null && fullArgTypes.Length > 0)
            {
                var resolvedReceiver = _engine.Resolve(fullArgTypes[0]);
                var adapted = (Type[])fullArgTypes.Clone();
                if (resolvedReceiver is ReferenceType rt)
                    adapted[0] = rt.InnerType; // &T → T
                else
                    adapted[0] = new ReferenceType(resolvedReceiver); // T → &T
                result = ResolveOverload(candidates, adapted, call.Span);
            }

            if (result == null)
            {
                var displayName = call.MethodName ?? call.FunctionName;
                ReportError($"No matching overload for `{displayName}` with {fullArgTypes.Length} arguments",
                    call.Span, "E2011");
                return _engine.FreshVar();
            }

            var (_, fnType, node) = result.Value;
            call.ResolvedTarget = node;
            return fnType!.ReturnType;
        }

        // Try enum variant construction (non-UFCS: bare variant name)
        var variantType2 = TryResolveVariantConstruction(lookupName, fullArgTypes, call.Span);
        if (variantType2 != null) return variantType2;

        // Try indirect call (variable with function type)
        return TryIndirectCall(call, fullArgTypes);
    }

    /// <summary>
    /// Try to resolve a call as a field-call (vtable pattern): receiver.field(args)
    /// where the receiver is a struct with a function-typed field matching the method name.
    /// </summary>
    private Type? TryFieldCall(CallExpressionNode call, Type receiverType, string fieldName, Type[] argTypes)
    {
        var resolved = _engine.Resolve(receiverType);

        // Auto-deref through references
        while (resolved is ReferenceType refType)
            resolved = _engine.Resolve(refType.InnerType);

        if (resolved is not NominalType { Kind: NominalKind.Struct } nominal)
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
        var fieldType = _engine.Resolve(field.Type);
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
            return _engine.FreshVar();
        }

        for (int i = 0; i < argTypes.Length; i++)
            _engine.Unify(argTypes[i], fnType.ParameterTypes[i], call.Span);

        call.IsIndirectCall = true;
        return fnType.ReturnType;
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

        ReportError($"Unresolved function `{call.FunctionName}`", call.Span, "E2004");
        return _engine.FreshVar();
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
        Type resultType = _engine.FreshVar();

        foreach (var arm in match.Arms)
        {
            PushScope();

            // Bind pattern variables
            CheckPattern(arm.Pattern, scrutineeType);

            // Infer arm body and unify with result type
            var armType = InferExpression(arm.ResultExpr);
            var unified = _engine.Unify(resultType, armType, arm.Span);
            resultType = unified.Type;

            PopScope();
        }

        // E2030/E2031: Check match exhaustiveness for enum types
        var resolvedScrutinee = _engine.Resolve(scrutineeType);
        // Auto-deref for exhaustiveness check
        while (resolvedScrutinee is ReferenceType refScrutinee)
            resolvedScrutinee = _engine.Resolve(refScrutinee.InnerType);

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

        // Auto-dereference through references (e.g., &List → List)
        while (resolved is ReferenceType refType)
            resolved = _engine.Resolve(refType.InnerType);

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
        else if (variantType is NominalType tupleType && tupleType.Name.StartsWith("__tuple_"))
        {
            // Multi-payload variant: check ARITY first, then bind
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
        // Indexed assignment: arr[i] = val → op_set_index(&arr, i, val)
        if (assign.Target is IndexExpressionNode idx)
            return InferIndexedAssignment(assign, idx);

        // E2038: Cannot assign to const variable
        if (assign.Target is IdentifierExpressionNode targetId && IsConst(targetId.Name))
            ReportError($"Cannot assign to constant `{targetId.Name}`", assign.Span, "E2038");

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

        // Built-in array/slice indexed assignment takes priority (matches InferIndex pattern)
        var resolvedBase = _engine.Resolve(baseType);

        if (resolvedBase is ArrayType arrayType)
        {
            _engine.Unify(indexType, WellKnown.USize, idx.Index.Span);
            _engine.Unify(valueType, arrayType.ElementType, assign.Value.Span);
            Record(idx, arrayType.ElementType);
            return WellKnown.Void;
        }

        if (resolvedBase is NominalType { Name: WellKnown.Slice } sliceType
            && sliceType.TypeArguments.Count > 0)
        {
            _engine.Unify(indexType, WellKnown.USize, idx.Index.Span);
            _engine.Unify(valueType, sliceType.TypeArguments[0], assign.Value.Span);
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
            _resolvedOperators[assign] = new ResolvedOperator(setNode!);
            Record(idx, valueType);
            return WellKnown.Void;
        }

        ReportError("Type does not support indexed assignment", idx.Span);
        Record(idx, _engine.FreshVar());
        return WellKnown.Void;
    }

    // =========================================================================
    // Address-of and dereference
    // =========================================================================

    private ReferenceType InferAddressOf(AddressOfExpressionNode addrOf)
    {
        // E2040: Cannot take address of temporaries (only identifiers, member access, index, deref)
        if (addrOf.Target is not (IdentifierExpressionNode or MemberAccessExpressionNode
            or IndexExpressionNode or DereferenceExpressionNode))
        {
            ReportError("Cannot take address of temporary value", addrOf.Span, "E2040");
        }

        var inner = InferExpression(addrOf.Target);
        return new ReferenceType(inner);
    }

    private Type InferDereference(DereferenceExpressionNode deref)
    {
        var inner = InferExpression(deref.Target);
        var resolved = _engine.Resolve(inner);
        if (resolved is ReferenceType refType)
            return refType.InnerType;

        ReportError("Cannot dereference non-reference type", deref.Span, "E2012");
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

        ReportError($"No field `{fieldName}` on type", member.Span, "E2014");
        return _engine.FreshVar();
    }

    // =========================================================================
    // Struct construction
    // =========================================================================

    private Type InferStructConstruction(StructConstructionExpressionNode structCon)
    {
        var structType = ResolveTypeNode(structCon.TypeName);
        var resolved = _engine.Resolve(structType);

        // E2018: Non-nominal types (primitives, references, etc.) can't be constructed
        if (resolved is not NominalType nominal)
        {
            ReportError($"Cannot construct non-struct type `{resolved}`", structCon.Span, "E2018");
            foreach (var (_, valueExpr) in structCon.Fields)
                InferExpression(valueExpr);
            return resolved;
        }

        // E2018: Cannot construct non-struct type (enums, etc.)
        if (nominal.Kind != NominalKind.Struct)
        {
            ReportError($"Cannot construct non-struct type `{nominal.Name}`", structCon.Span, "E2018");
            foreach (var (_, valueExpr) in structCon.Fields)
                InferExpression(valueExpr);
            return nominal;
        }

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

        // E2015: Check for missing fields
        var provided = new HashSet<string>(structCon.Fields.Select(f => f.FieldName));
        foreach (var field in nominal.FieldsOrVariants)
            if (!provided.Contains(field.Name))
                ReportError($"Missing field `{field.Name}` in struct construction", structCon.Span, "E2015");

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
            // Empty array: element type solved by caller via Unify.
            // E2026 is checked during variable declaration when we can verify no type context exists.
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

        // Built-in array/slice indexing takes priority over user-defined op_index.
        // This prevents false matches where op_index(String, Range) matches Slice[u8]
        // through StringToByteSlice bidirectional coercion.
        var resolvedBase = _engine.Resolve(baseType);
        var resolvedIndex = _engine.Resolve(indexType);

        // Check if index is a Range — range indexing returns a Slice
        var isRangeIndex = resolvedIndex is NominalType { Kind: NominalKind.Struct } nomIdx
                           && nomIdx.Name.EndsWith("Range");

        // E2027: Check that index type is not bool (common mistake)
        if (!isRangeIndex && resolvedIndex is PrimitiveType { Name: "bool" })
        {
            ReportError("Cannot use `bool` as an index type", idx.Index.Span, "E2027");
            return _engine.FreshVar();
        }

        if (resolvedBase is ArrayType arrayType)
        {
            if (isRangeIndex)
            {
                // Range indexing: array[range] → Slice[T]
                // Unify range element type with usize
                if (resolvedIndex is NominalType rangeNom && rangeNom.TypeArguments.Count > 0)
                    _engine.Unify(rangeNom.TypeArguments[0], WellKnown.USize, idx.Index.Span);
                var sliceNominal = LookupNominalType(WellKnown.Slice)
                    ?? throw new InvalidOperationException($"Well-known type `{WellKnown.Slice}` not registered");
                return new NominalType(sliceNominal.Name, sliceNominal.Kind,
                    [arrayType.ElementType], sliceNominal.FieldsOrVariants);
            }
            _engine.Unify(indexType, WellKnown.USize, idx.Index.Span);
            return arrayType.ElementType;
        }

        if (resolvedBase is NominalType { Name: WellKnown.Slice, TypeArguments.Count: > 0 } sliceType)
        {
            if (isRangeIndex)
            {
                // Range indexing: slice[range] → Slice[T]
                // Unify range element type with usize
                if (resolvedIndex is NominalType rangeNom2 && rangeNom2.TypeArguments.Count > 0)
                    _engine.Unify(rangeNom2.TypeArguments[0], WellKnown.USize, idx.Index.Span);
                return sliceType;
            }
            _engine.Unify(indexType, WellKnown.USize, idx.Index.Span);
            return sliceType.TypeArguments[0];
        }

        // Try op_index for user-defined types (Dict, String, etc.)
        var refBaseType = new ReferenceType(baseType);
        var opResult = TryResolveOperator("op_index", [refBaseType, indexType], idx.Span, out var resolvedNode)
                    ?? TryResolveOperator("op_index", [baseType, indexType], idx.Span, out resolvedNode);
        if (opResult != null)
        {
            _resolvedOperators[idx] = new ResolvedOperator(resolvedNode!);
            return opResult;
        }

        ReportError("Type does not support indexing", idx.Span, "E2028");
        return _engine.FreshVar();
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
            _engine.Unify(innerType, targetType, cast.Span);

        // E2020: Validate cast compatibility
        var resolvedInner = _engine.Resolve(innerType);
        var resolvedTarget = _engine.Resolve(targetType);
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

        // Numeric → numeric is valid (including bool and char)
        if (from is PrimitiveType pFrom && to is PrimitiveType pTo)
        {
            return IsNumericPrimitive(pFrom) && IsNumericPrimitive(pTo);
        }

        // Reference → reference is valid (reinterpret cast)
        if (from is ReferenceType && to is ReferenceType) return true;

        // Reference → usize (pointer to int)
        if (from is ReferenceType && to is PrimitiveType { Name: "usize" or "isize" }) return true;

        // usize → reference (int to pointer)
        if (from is PrimitiveType { Name: "usize" or "isize" } && to is ReferenceType) return true;

        // Nominal → nominal casts are allowed (reinterpret/binary-compatible casts)
        // This covers String ↔ Slice[u8], array → slice, etc.
        if (from is NominalType && to is NominalType) return true;

        // Array → nominal (array → slice cast)
        if (from is ArrayType && to is NominalType) return true;

        // Enum → primitive (tag extraction) or primitive → enum
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
            ?? throw new InvalidOperationException($"Well-known type `{WellKnown.Range}` not registered");
        return new NominalType(rangeNominal.Name, rangeNominal.Kind, [elemType], rangeNominal.FieldsOrVariants);
    }

    // =========================================================================
    // Lambda
    // =========================================================================

    private FunctionType InferLambda(LambdaExpressionNode lambda)
    {
        // Set scope barrier for non-capturing lambda (all FLang lambdas are non-capturing)
        var savedBarrier = _lambdaScopeBarrier;
        _lambdaScopeBarrier = _scopes.Depth;

        PushScope();

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
        PopScope();

        // Restore scope barrier
        _lambdaScopeBarrier = savedBarrier;

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

        // Left must be Option[T]
        if (resolved is NominalType { Name: WellKnown.Option } optType
            && optType.TypeArguments.Count > 0)
        {
            var innerType = optType.TypeArguments[0];
            var rightType = InferExpression(coal.Right);
            var resolvedRight = _engine.Resolve(rightType);

            // Option[T] ?? Option[T] → Option[T]
            if (resolvedRight is NominalType { Name: WellKnown.Option } rightOpt
                && rightOpt.TypeArguments.Count > 0)
            {
                _engine.Unify(innerType, rightOpt.TypeArguments[0], coal.Right.Span);
                return resolved; // return Option[T]
            }

            // Option[T] ?? T → T
            _engine.Unify(rightType, innerType, coal.Right.Span);
            return innerType;
        }

        // Try op_coalesce
        var rightType2 = InferExpression(coal.Right);
        var opResult = TryResolveOperator("op_coalesce", [leftType, rightType2], coal.Span, out var resolvedNode);
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
