using System.Numerics;
using FLang.Core;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;
using FLang.Frontend.Ast.Types;
using Microsoft.Extensions.Logging;

namespace FLang.Semantics;

public partial class TypeChecker
{
    // --- Colocated utilities (only used by expression methods) ---

    /// <summary>
    /// Creates a new TypeVar for a literal, soft-bound to the given comptime type.
    /// Tracks the TypeVar and its value for later verification.
    /// </summary>
    private TypeVar CreateLiteralTypeVar(string id, SourceSpan span, TypeBase comptimeType, BigInteger value)
    {
        var tv = new TypeVar(id, span)
        {
            Instance = comptimeType
        };
        _literalTypeVars.Add((tv, value));
        return tv;
    }

    /// <summary>
    /// Attempts to build a dotted path string from a member access chain.
    /// Returns null if the chain contains non-identifier/member-access nodes.
    /// Example: a.b.c → "a.b.c"
    /// </summary>
    private static string? TryBuildMemberAccessPath(MemberAccessExpressionNode ma)
    {
        var parts = new List<string>();
        ExpressionNode current = ma;

        // Walk the chain backwards, collecting parts
        while (current is MemberAccessExpressionNode memberAccess)
        {
            parts.Insert(0, memberAccess.FieldName);
            current = memberAccess.Target;
        }

        // Base must be an identifier
        if (current is IdentifierExpressionNode identifier)
        {
            parts.Insert(0, identifier.Name);
            return string.Join(".", parts);
        }

        return null; // Complex expression, can't build simple path
    }

    /// <summary>
    /// Checks if built-in operator handling is applicable for the given operand types.
    /// Built-in operators only work on numeric primitives, booleans (for equality),
    /// and pointer arithmetic (&T + integer, &T - integer).
    /// </summary>
    private static bool IsBuiltinOperatorApplicable(TypeBase left, TypeBase right, BinaryOperatorKind op)
    {
        // Both must be primitive or comptime types
        var leftIsNumeric = TypeRegistry.IsNumericType(left);
        var rightIsNumeric = TypeRegistry.IsNumericType(right);
        var leftIsBool = left.Equals(TypeRegistry.Bool);
        var rightIsBool = right.Equals(TypeRegistry.Bool);
        var leftIsPointer = left is ReferenceType;
        var rightIsPointer = right is ReferenceType;

        // Arithmetic operators require numeric types
        if (op >= BinaryOperatorKind.Add && op <= BinaryOperatorKind.Modulo)
        {
            // Pointer arithmetic: &T + integer or &T - integer
            if (op == BinaryOperatorKind.Add || op == BinaryOperatorKind.Subtract)
            {
                if (leftIsPointer && rightIsNumeric) return true;
            }
            return leftIsNumeric && rightIsNumeric;
        }

        // Comparison operators work on numeric types
        if (op >= BinaryOperatorKind.LessThan && op <= BinaryOperatorKind.GreaterThanOrEqual)
        {
            return leftIsNumeric && rightIsNumeric;
        }

        // Equality operators work on numeric types, booleans, and pointers
        if (op == BinaryOperatorKind.Equal || op == BinaryOperatorKind.NotEqual)
        {
            if (leftIsPointer && rightIsPointer) return true;
            return (leftIsNumeric && rightIsNumeric) || (leftIsBool && rightIsBool);
        }

        // Bitwise operators require integer types (not floats, not bools)
        if (op is BinaryOperatorKind.BitwiseAnd or BinaryOperatorKind.BitwiseOr or BinaryOperatorKind.BitwiseXor)
        {
            return TypeRegistry.IsIntegerType(left) && TypeRegistry.IsIntegerType(right);
        }

        return false;
    }

    /// <summary>
    /// Result of operator function resolution.
    /// </summary>
    private readonly struct OperatorFunctionResult
    {
        public FunctionDeclarationNode Function { get; init; }
        public TypeBase ReturnType { get; init; }
    }

    /// <summary>
    /// Attempts to resolve an operator function for the given operand types.
    /// Returns null if no matching operator function is found.
    /// </summary>
    private OperatorFunctionResult? TryResolveOperatorFunction(string opFuncName, TypeBase leftType, TypeBase rightType, SourceSpan span)
    {
        if (!_functions.TryGetValue(opFuncName, out var candidates))
            return null;

        // Prune types to ensure we're comparing concrete types
        var argTypes = new List<TypeBase> { leftType.Prune(), rightType.Prune() };

        FunctionEntry? bestNonGeneric = null;
        var bestNonGenericCost = int.MaxValue;

        foreach (var cand in candidates)
        {
            if (cand.IsGeneric) continue;
            if (cand.ParameterTypes.Count != 2) continue;
            if (!TryComputeCoercionCost(argTypes, cand.ParameterTypes, out var cost))
                continue;

            if (cost < bestNonGenericCost)
            {
                bestNonGeneric = cand;
                bestNonGenericCost = cost;
            }
        }

        FunctionEntry? bestGeneric = null;
        Dictionary<string, TypeBase>? bestBindings = null;
        var bestGenericCost = int.MaxValue;

        foreach (var cand in candidates)
        {
            if (!cand.IsGeneric) continue;
            if (cand.ParameterTypes.Count != 2) continue;

            var bindings = new Dictionary<string, TypeBase>();
            var okGen = true;
            for (var i = 0; i < 2; i++)
            {
                if (!TryBindGeneric(cand.ParameterTypes[i], argTypes[i], bindings, out _, out _))
                {
                    okGen = false;
                    break;
                }
            }

            if (!okGen) continue;

            var concreteParams = cand.ParameterTypes
                .Select(pt => SubstituteGenerics(pt, bindings))
                .ToList();

            if (!TryComputeCoercionCost(argTypes, concreteParams, out var genCost))
                continue;

            if (genCost < bestGenericCost)
            {
                bestGeneric = cand;
                bestBindings = bindings;
                bestGenericCost = genCost;
            }
        }

        FunctionEntry? chosen;
        Dictionary<string, TypeBase>? chosenBindings = null;

        if (bestNonGeneric != null && (bestGeneric == null || bestNonGenericCost <= bestGenericCost))
        {
            chosen = bestNonGeneric;
        }
        else
        {
            chosen = bestGeneric;
            chosenBindings = bestBindings;
        }

        if (chosen == null)
            return null;

        // Get the actual function to call (specialized if generic)
        FunctionDeclarationNode resolvedFunction;
        TypeBase returnType;

        if (chosen.IsGeneric && chosenBindings != null)
        {
            resolvedFunction = EnsureSpecialization(chosen, chosenBindings, argTypes, span)!;
            returnType = SubstituteGenerics(chosen.ReturnType, chosenBindings);
        }
        else
        {
            resolvedFunction = chosen.AstNode;
            returnType = chosen.ReturnType;
        }

        return new OperatorFunctionResult
        {
            Function = resolvedFunction,
            ReturnType = returnType
        };
    }

    private OperatorFunctionResult? TryResolveUnaryOperatorFunction(string opFuncName, TypeBase operandType, SourceSpan span)
    {
        if (!_functions.TryGetValue(opFuncName, out var candidates))
            return null;

        var argTypes = new List<TypeBase> { operandType.Prune() };

        FunctionEntry? bestNonGeneric = null;
        var bestNonGenericCost = int.MaxValue;

        foreach (var cand in candidates)
        {
            if (cand.IsGeneric) continue;
            if (cand.ParameterTypes.Count != 1) continue;
            if (!TryComputeCoercionCost(argTypes, cand.ParameterTypes, out var cost))
                continue;

            if (cost < bestNonGenericCost)
            {
                bestNonGeneric = cand;
                bestNonGenericCost = cost;
            }
        }

        FunctionEntry? bestGeneric = null;
        Dictionary<string, TypeBase>? bestBindings = null;
        var bestGenericCost = int.MaxValue;

        foreach (var cand in candidates)
        {
            if (!cand.IsGeneric) continue;
            if (cand.ParameterTypes.Count != 1) continue;

            var bindings = new Dictionary<string, TypeBase>();
            if (!TryBindGeneric(cand.ParameterTypes[0], argTypes[0], bindings, out _, out _))
                continue;

            var concreteParams = cand.ParameterTypes
                .Select(pt => SubstituteGenerics(pt, bindings))
                .ToList();

            if (!TryComputeCoercionCost(argTypes, concreteParams, out var genCost))
                continue;

            if (genCost < bestGenericCost)
            {
                bestGeneric = cand;
                bestBindings = bindings;
                bestGenericCost = genCost;
            }
        }

        FunctionEntry? chosen;
        Dictionary<string, TypeBase>? chosenBindings = null;

        if (bestNonGeneric != null && (bestGeneric == null || bestNonGenericCost <= bestGenericCost))
        {
            chosen = bestNonGeneric;
        }
        else
        {
            chosen = bestGeneric;
            chosenBindings = bestBindings;
        }

        if (chosen == null)
            return null;

        FunctionDeclarationNode resolvedFunction;
        TypeBase returnType;

        if (chosen.IsGeneric && chosenBindings != null)
        {
            resolvedFunction = EnsureSpecialization(chosen, chosenBindings, argTypes, span)!;
            returnType = SubstituteGenerics(chosen.ReturnType, chosenBindings);
        }
        else
        {
            resolvedFunction = chosen.AstNode;
            returnType = chosen.ReturnType;
        }

        return new OperatorFunctionResult
        {
            Function = resolvedFunction,
            ReturnType = returnType
        };
    }

    /// <summary>
    /// Attempts to resolve an op_set_index function for indexed assignment.
    /// op_set_index takes 3 arguments: (&amp;base, index, value)
    /// </summary>
    private OperatorFunctionResult? TryResolveSetIndexFunction(
        string opFuncName, TypeBase baseReTypeBase, TypeBase indexType, TypeBase valueType, SourceSpan span)
    {
        if (!_functions.TryGetValue(opFuncName, out var candidates))
            return null;

        var argTypes = new List<TypeBase> { baseReTypeBase.Prune(), indexType.Prune(), valueType.Prune() };

        FunctionEntry? bestNonGeneric = null;
        var bestNonGenericCost = int.MaxValue;

        foreach (var cand in candidates)
        {
            if (cand.IsGeneric) continue;
            if (cand.ParameterTypes.Count != 3) continue;
            if (!TryComputeCoercionCost(argTypes, cand.ParameterTypes, out var cost))
                continue;

            if (cost < bestNonGenericCost)
            {
                bestNonGeneric = cand;
                bestNonGenericCost = cost;
            }
        }

        FunctionEntry? bestGeneric = null;
        Dictionary<string, TypeBase>? bestBindings = null;
        var bestGenericCost = int.MaxValue;

        foreach (var cand in candidates)
        {
            if (!cand.IsGeneric) continue;
            if (cand.ParameterTypes.Count != 3) continue;

            var bindings = new Dictionary<string, TypeBase>();
            var okGen = true;
            for (var i = 0; i < 3; i++)
            {
                if (!TryBindGeneric(cand.ParameterTypes[i], argTypes[i], bindings, out _, out _))
                {
                    okGen = false;
                    break;
                }
            }

            if (!okGen) continue;

            var concreteParams = cand.ParameterTypes
                .Select(pt => SubstituteGenerics(pt, bindings))
                .ToList();

            if (!TryComputeCoercionCost(argTypes, concreteParams, out var genCost))
                continue;

            if (genCost < bestGenericCost)
            {
                bestGeneric = cand;
                bestBindings = bindings;
                bestGenericCost = genCost;
            }
        }

        FunctionEntry? chosen;
        Dictionary<string, TypeBase>? chosenBindings = null;

        if (bestNonGeneric != null && (bestGeneric == null || bestNonGenericCost <= bestGenericCost))
        {
            chosen = bestNonGeneric;
        }
        else
        {
            chosen = bestGeneric;
            chosenBindings = bestBindings;
        }

        if (chosen == null)
            return null;

        FunctionDeclarationNode resolvedFunction;
        TypeBase returnType;

        if (chosen.IsGeneric && chosenBindings != null)
        {
            resolvedFunction = EnsureSpecialization(chosen, chosenBindings, argTypes, span)!;
            returnType = SubstituteGenerics(chosen.ReturnType, chosenBindings);
        }
        else
        {
            resolvedFunction = chosen.AstNode;
            returnType = chosen.ReturnType;
        }

        return new OperatorFunctionResult
        {
            Function = resolvedFunction,
            ReturnType = returnType
        };
    }

    private void ValidateStructLiteralFields(StructType structType,
        List<(string FieldName, ExpressionNode Value)> fields, SourceSpan span)
    {
        var provided = new HashSet<string>();
        for (var i = 0; i < fields.Count; i++)
        {
            var (fieldName, expr) = fields[i];
            provided.Add(fieldName);
            var fieldType = structType.GetFieldType(fieldName);
            if (fieldType == null)
            {
                ReportError(
                    $"struct `{structType.Name}` does not have a field named `{fieldName}`",
                    expr.Span,
                    "unknown field",
                    "E2014");
                continue;
            }

            var valueType = CheckExpression(expr, fieldType);
            var unified = UnifyTypes(valueType, fieldType, expr.Span);
            fields[i] = (fieldName, WrapWithCoercionIfNeeded(expr, valueType.Prune(), fieldType.Prune()));
        }

        foreach (var (fieldName, _) in structType.Fields)
            if (!provided.Contains(fieldName))
                ReportError(
                    $"missing field `{fieldName}` in struct construction",
                    span,
                    $"struct `{structType.Name}` requires field `{fieldName}`",
                    "E2015");
    }

    private TypeBase ApplyOptionExpectation(ExpressionNode expression, TypeBase type, TypeBase? expectedType)
    {
        if (expectedType is StructType expectedOption && TypeRegistry.IsOption(expectedOption))
        {
            if (type is StructType actualOption && TypeRegistry.IsOption(actualOption))
            {
                if (actualOption.TypeArguments.Count > 0 && expectedOption.TypeArguments.Count > 0 &&
                    !actualOption.TypeArguments[0].Equals(expectedOption.TypeArguments[0]))
                {
                    ReportError(
                        "mismatched option types",
                        expression.Span,
                        $"expected `{expectedOption}`, found `{actualOption}`",
                        "E2002");
                }

                return expectedOption;
            }

            // NOTE: Do NOT change type from T to Option<T> here!
            // The actual coercion (wrapping T in Option) must be done via WrapWithCoercionIfNeeded
            // which creates an ImplicitCoercionNode. If we change the type here without a coercion node,
            // the lowering phase will emit code that assigns T to Option<T> directly, causing C errors.
            // Just return the actual type and let the caller handle coercion.
        }

        return type;
    }

    /// <summary>
    /// Adapts the UFCS receiver type (argTypes[0]) to match the expected parameter type.
    /// UFCS semantics:
    /// - value receiver, value expected: pass as-is
    /// - value receiver, &T expected: lift to reference
    /// - &T receiver, value expected: allow (implicit dereference)
    /// - &T receiver, &T expected: pass as-is
    /// </summary>
    private List<TypeBase> TryAdaptUfcsReceiverType(List<TypeBase> argTypes, TypeBase firstParamType)
    {
        if (argTypes.Count == 0) return argTypes;

        var receiverType = argTypes[0].Prune();
        var paramType = firstParamType.Prune();

        var receiverIsRef = receiverType is ReferenceType;
        var paramExpectsRef = paramType is ReferenceType;

        // No adaptation needed if types already match structurally
        if (receiverIsRef == paramExpectsRef) return argTypes;

        // value receiver, &T expected: lift to reference
        if (!receiverIsRef && paramExpectsRef)
        {
            var adapted = new List<TypeBase>(argTypes);
            adapted[0] = new ReferenceType(receiverType);
            return adapted;
        }

        // &T receiver, value expected: allow pass-through (implicit dereference happens at codegen)
        // The underlying type should match, so we expose the inner type for matching
        if (receiverIsRef && !paramExpectsRef)
        {
            var reTypeBase = (ReferenceType)receiverType;
            var adapted = new List<TypeBase>(argTypes);
            adapted[0] = reTypeBase.InnerType;
            return adapted;
        }

        return argTypes;
    }

    private bool TryComputeCoercionCost(IReadOnlyList<TypeBase> sources, IReadOnlyList<TypeBase> targets, out int cost)
    {
        cost = 0;
        if (sources.Count != targets.Count) return false;
        for (var i = 0; i < sources.Count; i++)
        {
            if (sources[i].Equals(targets[i])) continue;
            if (!_unificationEngine.CanUnify(sources[i], targets[i])) return false;
            cost++;
        }

        return true;
    }

    // --- Expression checking methods ---

    private TypeBase CheckStringLiteral(StringLiteralNode strLit)
    {
        if (_compilation.Structs.TryGetValue("String", out var st))
            return st;

        ReportError(
            "String type not found",
            strLit.Span,
            "make sure to import core.string",
            "E2013");
        return TypeRegistry.Never;
    }

    private TypeBase CheckIdentifierExpression(IdentifierExpressionNode id)
    {
        // First try variable lookup
        if (TryLookupVariable(id.Name, out var t))
        {
            // If the variable has an enum type and its name is a variant of that enum,
            // this is an unqualified variant reference (e.g., `Red` for `Color.Red`)
            if (t is EnumType enumType && enumType.Variants.Any(v => v.VariantName == id.Name))
            {
                // This is a unit variant - construct it with no payload
                return CheckEnumVariantConstruction(enumType, id.Name, new List<ExpressionNode>(), id.Span);
            }

            return t;
        }

        // Check if this identifier is a function name (function reference)
        if (_functions.TryGetValue(id.Name, out var candidates))
        {
            // For now, only support non-overloaded, non-generic functions as values
            var nonGenericCandidates = candidates.Where(c => !c.IsGeneric).ToList();
            if (nonGenericCandidates.Count == 1)
            {
                var entry = nonGenericCandidates[0];
                // Set the resolved target for IR lowering
                id.ResolvedFunctionTarget = entry.AstNode;
                return new FunctionType(entry.ParameterTypes, entry.ReturnType);
            }
            else if (nonGenericCandidates.Count > 1)
            {
                ReportError(
                    $"cannot take address of overloaded function `{id.Name}`",
                    id.Span,
                    "function has multiple overloads",
                    "E2004");
                return TypeRegistry.Never;
            }
            else if (candidates.Count > 0)
            {
                ReportError(
                    $"cannot take address of generic function `{id.Name}`",
                    id.Span,
                    "generic functions cannot be used as values directly",
                    "E2004");
                return TypeRegistry.Never;
            }
        }

        // Check if this identifier is a type name used as a value (type literal)
        var resolvedType = ResolveTypeName(id.Name);
        if (resolvedType != null)
        {
            // This is a type literal: i32, Point, etc. used as a value
            // It has type Type(T) where T is the referenced type
            var typeStruct = TypeRegistry.MakeType(resolvedType);

            // Track that this type is used as a literal
            _compilation.InstantiatedTypes.Add(resolvedType);
            return typeStruct;
        }

        // Check if identifier is a generic type parameter in scope (e.g., T in List(T))
        // This handles cases like size_of(T) where T is a generic parameter
        if (IsGenericNameInScope(id.Name))
        {
            // Create generic parameter type and substitute with bound type if available
            TypeBase genericType = new GenericParameterType(id.Name);
            if (_currentBindings != null && _currentBindings.TryGetValue(id.Name, out var boundType))
            {
                genericType = boundType;
            }
            // Return as type literal: T → Type(T) or Type(i32) if bound
            var typeStruct = TypeRegistry.MakeType(genericType);
            _compilation.InstantiatedTypes.Add(genericType);
            return typeStruct;
        }

        // Not found as variable or type
        ReportError(
            $"cannot find value or type `{id.Name}` in this scope",
            id.Span,
            "not found in this scope",
            "E2004");
        return TypeRegistry.Never;
    }

    private TypeBase CheckMemberAccessExpression(MemberAccessExpressionNode ma, TypeBase? expectedType = null)
    {
        // Try to resolve as full type FQN first (e.g., std.result.Result)
        var pathString = TryBuildMemberAccessPath(ma);
        if (pathString != null)
        {
            var resolvedType = ResolveTypeName(pathString);
            if (resolvedType != null)
            {
                // This entire chain resolves to a type - return Type(T)
                var typeLiteral = TypeRegistry.MakeType(resolvedType);
                _compilation.InstantiatedTypes.Add(resolvedType);
                return typeLiteral;
            }
        }

        // Evaluate target expression
        var obj = CheckExpression(ma.Target);
        if (IsNever(obj)) return TypeRegistry.Never;
        var prunedObj = obj.Prune();

        // Check if target is an enum type (accessing variant): EnumType.Variant
        if (prunedObj is StructType typeStruct && TypeRegistry.IsType(typeStruct))
        {
            // Extract the referenced type from Type(T)
            if (typeStruct.TypeArguments.Count > 0 && typeStruct.TypeArguments[0] is EnumType enumType)
            {
                // Check if field name matches a variant
                if (enumType.Variants.Any(v => v.VariantName == ma.FieldName))
                {
                    // If the enum has type parameters and we have an expected type, use it
                    // This handles cases like: let nil: List(i32) = List.Nil
                    var enumToUse = enumType;
                    if (enumType.TypeArguments.Any(t => t is GenericParameterType) && expectedType is EnumType expectedEnum)
                    {
                        // Expected type has concrete type arguments - use that
                        if (expectedEnum.Name == enumType.Name)
                            enumToUse = expectedEnum;
                    }

                    // This is enum variant construction: EnumType.Variant
                    return CheckEnumVariantConstruction(enumToUse, ma.FieldName, new List<ExpressionNode>(),
                        ma.Span);
                }

                // Not a valid variant
                ReportError(
                    $"enum `{enumType.Name}` has no variant `{ma.FieldName}`",
                    ma.Span,
                    null,
                    "E2037");
                return enumType;
            }
        }

        // Runtime field access on struct values
        // Convert arrays and slices to their canonical struct representations
        // Auto-dereference references recursively to allow field access on &T, &&T, etc.
        var currentType = prunedObj;
        int autoDerefCount = 0;

        // Unwrap references recursively until we find a struct or non-reference type
        while (currentType is ReferenceType reTypeBase)
        {
            autoDerefCount++;
            currentType = reTypeBase.InnerType.Prune();
        }

        // Convert arrays and fieldless slices to proper slice representation for field access (.ptr, .len)
        var structType = currentType switch
        {
            StructType st when TypeRegistry.IsSlice(st) && st.Fields.Count == 0 && st.TypeArguments.Count > 0
                => TypeRegistry.MakeSlice(st.TypeArguments[0]),
            StructType st => st,
            ArrayType array => MakeSliceType(array.ElementType, ma.Span),
            _ => null
        };

        if (structType != null)
        {
            var ft = structType.GetFieldType(ma.FieldName);
            if (ft == null)
            {
                ReportError(
                    $"no field `{ma.FieldName}` on type `{prunedObj.Name}`",
                    ma.Span,
                    $"type `{prunedObj.Name}` does not have a field named `{ma.FieldName}`",
                    "E2014");
                return TypeRegistry.Never;
            }

            // Store the auto-deref count for lowering
            ma.AutoDerefCount = autoDerefCount;

            return ft;
        }
        else
        {
            ReportError(
                "cannot access field on non-struct type",
                ma.Span,
                $"expected struct type, found `{obj}`",
                "E2014");
            return TypeRegistry.Never;
        }
    }

    private TypeBase CheckBinaryExpression(BinaryExpressionNode be)
    {
        var lt = CheckExpression(be.Left);
        if (IsNever(lt)) return TypeRegistry.Never;
        var rt = CheckExpression(be.Right, lt);
        if (IsNever(rt)) return TypeRegistry.Never;

        // Logical operators: both operands must be bool, no operator overloading
        if (be.Operator is BinaryOperatorKind.And or BinaryOperatorKind.Or)
        {
            var opSymbol = OperatorFunctions.GetOperatorSymbol(be.Operator);
            var leftPruned = lt.Prune();
            var rightPruned = rt.Prune();
            if (!leftPruned.Equals(TypeRegistry.Bool))
            {
                ReportError(
                    $"cannot apply `{opSymbol}` to non-bool type `{FormatTypeNameForDisplay(leftPruned)}`",
                    be.Left.Span,
                    $"expected `bool`, found `{FormatTypeNameForDisplay(leftPruned)}`",
                    "E2046");
                return TypeRegistry.Never;
            }
            if (!rightPruned.Equals(TypeRegistry.Bool))
            {
                ReportError(
                    $"cannot apply `{opSymbol}` to non-bool type `{FormatTypeNameForDisplay(rightPruned)}`",
                    be.Right.Span,
                    $"expected `bool`, found `{FormatTypeNameForDisplay(rightPruned)}`",
                    "E2046");
                return TypeRegistry.Never;
            }
            return TypeRegistry.Bool;
        }

        // Try to find an operator function for this operation
        var opFuncName = OperatorFunctions.GetFunctionName(be.Operator);
        var operatorFuncResult = TryResolveOperatorFunction(opFuncName, lt, rt, be.Span);

        if (operatorFuncResult != null)
        {
            // Use operator function
            be.ResolvedOperatorFunction = operatorFuncResult.Value.Function;
            return operatorFuncResult.Value.ReturnType;
        }

        // Auto-derive op_eq from op_ne or vice versa by negating the complement
        if (be.Operator is BinaryOperatorKind.Equal or BinaryOperatorKind.NotEqual)
        {
            var complementName = be.Operator == BinaryOperatorKind.Equal ? "op_ne" : "op_eq";
            var complementResult = TryResolveOperatorFunction(complementName, lt, rt, be.Span);
            if (complementResult != null)
            {
                be.ResolvedOperatorFunction = complementResult.Value.Function;
                be.NegateOperatorResult = true;
                return complementResult.Value.ReturnType;
            }
        }

        // Auto-derive comparison operators from op_cmp
        // op_cmp returns Ord (naked enum: Less=-1, Equal=0, Greater=1)
        // So op_cmp(a,b) < 0 means a < b, etc.
        if (be.Operator is BinaryOperatorKind.LessThan or BinaryOperatorKind.GreaterThan
            or BinaryOperatorKind.LessThanOrEqual or BinaryOperatorKind.GreaterThanOrEqual
            or BinaryOperatorKind.Equal or BinaryOperatorKind.NotEqual)
        {
            var cmpResult = TryResolveOperatorFunction("op_cmp", lt, rt, be.Span);
            if (cmpResult != null)
            {
                be.ResolvedOperatorFunction = cmpResult.Value.Function;
                be.CmpDerivedOperator = be.Operator;
                return TypeRegistry.Bool;
            }
        }

        // Fall back to built-in handling for primitive types
        var prunedLt = lt.Prune();
        var prunedRt = rt.Prune();

        // Built-in operators only work on numeric primitives
        if (!IsBuiltinOperatorApplicable(prunedLt, prunedRt, be.Operator))
        {
            var opSymbol = OperatorFunctions.GetOperatorSymbol(be.Operator);
            ReportError(
                $"cannot apply binary operator `{opSymbol}` to types `{FormatTypeNameForDisplay(prunedLt)}` and `{FormatTypeNameForDisplay(prunedRt)}`",
                be.Span,
                $"no implementation for `{FormatTypeNameForDisplay(prunedLt)} {opSymbol} {FormatTypeNameForDisplay(prunedRt)}`",
                "E2017");
            return TypeRegistry.Never;
        }

        // Handle pointer arithmetic specially - result type is the pointer type
        if (prunedLt is ReferenceType reTypeBase && TypeRegistry.IsNumericType(prunedRt))
        {
            // Ensure the index is resolved to a concrete integer type
            if (prunedRt is ComptimeInt)
            {
                UnifyTypes(rt, TypeRegistry.ISize, be.Span);
            }
            return reTypeBase;
        }

        // Unify operand types - TypeVar.Prune() handles propagation automatically
        var unified = UnifyTypes(lt, rt, be.Span);

        if (be.Operator >= BinaryOperatorKind.Equal && be.Operator <= BinaryOperatorKind.GreaterThanOrEqual)
        {
            return TypeRegistry.Bool;
        }
        else
        {
            return unified;
        }
    }

    private TypeBase CheckUnaryExpression(UnaryExpressionNode ue)
    {
        var operandType = CheckExpression(ue.Operand);
        if (IsNever(operandType)) return TypeRegistry.Never;

        // Try to find an operator function for this operation
        var opFuncName = OperatorFunctions.GetFunctionName(ue.Operator);
        var operatorFuncResult = TryResolveUnaryOperatorFunction(opFuncName, operandType, ue.Span);

        if (operatorFuncResult != null)
        {
            ue.ResolvedOperatorFunction = operatorFuncResult.Value.Function;
            return operatorFuncResult.Value.ReturnType;
        }

        // Fall back to built-in handling for primitive types
        var pruned = operandType.Prune();

        switch (ue.Operator)
        {
            case UnaryOperatorKind.Negate:
                if (TypeRegistry.IsNumericType(pruned) || pruned is ComptimeInt)
                    return operandType;
                break;

            case UnaryOperatorKind.Not:
                if (pruned.Equals(TypeRegistry.Bool))
                    return TypeRegistry.Bool;
                break;
        }

        var opSymbol = OperatorFunctions.GetOperatorSymbol(ue.Operator);
        ReportError(
            $"cannot apply unary operator `{opSymbol}` to type `{FormatTypeNameForDisplay(pruned)}`",
            ue.Span,
            $"no implementation for `{opSymbol}{FormatTypeNameForDisplay(pruned)}`",
            "E2017");
        return TypeRegistry.Never;
    }

    /// <summary>
    /// Type checks a null-coalescing expression (a ?? b).
    /// Resolves to op_coalesce(a, b) function call.
    /// </summary>
    private TypeBase CheckCoalesceExpression(CoalesceExpressionNode coalesce)
    {
        var lt = CheckExpression(coalesce.Left);
        if (IsNever(lt)) return TypeRegistry.Never;

        // For op_coalesce, we need to determine the expected type for the right side
        // based on the available overloads. If left is Option(T), the right could be T or Option(T).
        // We check the right side without an expected type and let overload resolution pick.
        var rt = CheckExpression(coalesce.Right);
        if (IsNever(rt)) return TypeRegistry.Never;

        // Try to find op_coalesce function for this operation
        const string opFuncName = "op_coalesce";
        var operatorFuncResult = TryResolveOperatorFunction(opFuncName, lt, rt, coalesce.Span);

        if (operatorFuncResult != null)
        {
            coalesce.ResolvedCoalesceFunction = operatorFuncResult.Value.Function;
            return operatorFuncResult.Value.ReturnType;
        }

        // No op_coalesce function found - report error
        var prunedLt = lt.Prune();
        var prunedRt = rt.Prune();
        ReportError(
            $"cannot apply `??` operator to types `{FormatTypeNameForDisplay(prunedLt)}` and `{FormatTypeNameForDisplay(prunedRt)}`",
            coalesce.Span,
            $"no `op_coalesce` implementation for `{FormatTypeNameForDisplay(prunedLt)} ?? {FormatTypeNameForDisplay(prunedRt)}`",
            "E2017");
        return TypeRegistry.Never;
    }

    /// <summary>
    /// Type checks a null-propagation expression (target?.field).
    /// If target is Option(T), unwraps T, accesses field, and wraps result in Option.
    /// </summary>
    private TypeBase CheckNullPropagationExpression(NullPropagationExpressionNode nullProp)
    {
        var targetType = CheckExpression(nullProp.Target);
        if (IsNever(targetType)) return TypeRegistry.Never;
        var prunedTarget = targetType.Prune();

        // Target must be Option(T)
        if (prunedTarget is not StructType optionType || !TypeRegistry.IsOption(optionType))
        {
            ReportError(
                $"cannot use `?.` on non-optional type `{FormatTypeNameForDisplay(prunedTarget)}`",
                nullProp.Target.Span,
                "expected `Option(T)` or `T?`",
                "E2002");
            return TypeRegistry.Never;
        }

        // Get the inner type T from Option(T)
        if (optionType.TypeArguments.Count == 0)
        {
            ReportError(
                "Option type has no inner type",
                nullProp.Target.Span,
                null,
                "E2002");
            return TypeRegistry.Never;
        }

        var innerType = optionType.TypeArguments[0];

        // Inner type must be a struct with the requested field
        if (innerType is not StructType innerStruct)
        {
            ReportError(
                $"cannot access field `{nullProp.MemberName}` on non-struct type `{FormatTypeNameForDisplay(innerType)}`",
                nullProp.Span,
                null,
                "E2014");
            return TypeRegistry.Never;
        }

        // Look up the field
        var fieldType = innerStruct.GetFieldType(nullProp.MemberName);
        if (fieldType == null)
        {
            ReportError(
                $"struct `{innerStruct.Name}` does not have a field named `{nullProp.MemberName}`",
                nullProp.Span,
                "unknown field",
                "E2014");
            return TypeRegistry.Never;
        }

        // Result is Option(fieldType)
        return TypeRegistry.MakeOption(fieldType);
    }

    private TypeBase CheckAssignmentExpression(AssignmentExpressionNode ae)
    {
        // Check for const reassignment
        if (ae.Target is IdentifierExpressionNode id)
        {
            if (TryLookupVariableInfo(id.Name, out var varInfo) && varInfo.IsConst)
            {
                ReportError(
                    $"cannot assign to const variable `{id.Name}`",
                    ae.Target.Span,
                    "const variables cannot be reassigned after initialization",
                    "E2038");
                // Continue type checking for better error recovery
            }
        }

        // Handle indexed assignment: expr[index] = value
        if (ae.Target is IndexExpressionNode ix)
        {
            return CheckIndexedAssignment(ae, ix);
        }

        // Get the type of the assignment target (lvalue)
        TypeBase targetType = ae.Target switch
        {
            IdentifierExpressionNode idExpr => LookupVariable(idExpr.Name, ae.Target.Span),
            MemberAccessExpressionNode fa => CheckExpression(fa),
            DereferenceExpressionNode dr => CheckExpression(dr),
            _ => throw new Exception($"Invalid assignment target: {ae.Target.GetType().Name}")
        };
        if (IsNever(targetType)) return TypeRegistry.Never;

        // Check the value expression against the target type
        var val = CheckExpression(ae.Value, targetType);
        if (IsNever(val)) return TypeRegistry.Never;

        // Unify value with target type - TypeVar.Prune() handles propagation
        var unified = UnifyTypes(val, targetType, ae.Value.Span);

        return targetType;
    }

    /// <summary>
    /// Handles indexed assignment: expr[index] = value
    /// For slices/custom types, resolves op_set_index(&amp;base, index, value)
    /// For arrays, validates element type and uses native store
    /// </summary>
    private TypeBase CheckIndexedAssignment(AssignmentExpressionNode ae, IndexExpressionNode ix)
    {
        var bt = CheckExpression(ix.Base);
        if (IsNever(bt)) return TypeRegistry.Never;

        var it = CheckExpression(ix.Index);
        if (IsNever(it)) return TypeRegistry.Never;

        // For struct types (slices, custom types), look up op_set_index function
        var prunedBtForSet = bt.Prune();
        if (prunedBtForSet is StructType structTypeForSetIndex)
        {
            var refBaseType = new ReferenceType(structTypeForSetIndex);

            // Check value type
            var val = CheckExpression(ae.Value);
            if (IsNever(val)) return TypeRegistry.Never;

            // Try with &T first: op_set_index(&T, index, value)
            var opSetIndexResult = TryResolveSetIndexFunction("op_set_index", refBaseType, it, val, ae.Span);

            // Also try with value T: op_set_index(T, index, value)
            if (opSetIndexResult == null)
                opSetIndexResult = TryResolveSetIndexFunction("op_set_index", prunedBtForSet, it, val, ae.Span);

            if (opSetIndexResult != null)
            {
                ix.ResolvedSetIndexFunction = opSetIndexResult.Value.Function;

                // Resolve comptime_int index and value to the parameter's concrete types
                var resolvedSetFunc = opSetIndexResult.Value.Function;
                if (resolvedSetFunc.Parameters.Count >= 2)
                {
                    var indexParamType = resolvedSetFunc.Parameters[1].ResolvedType;
                    if (indexParamType != null)
                        UnifyTypes(it, indexParamType, ix.Index.Span);
                }
                if (resolvedSetFunc.Parameters.Count >= 3)
                {
                    var valueParamType = resolvedSetFunc.Parameters[2].ResolvedType;
                    if (valueParamType != null)
                        UnifyTypes(val, valueParamType, ae.Value.Span);
                }

                return opSetIndexResult.Value.ReturnType;
            }

            // op_set_index not found — check WHY
            if (_functions.TryGetValue("op_set_index", out var setIndexCandidates))
            {
                var matchingBaseCandidates = setIndexCandidates
                    .Where(c => c.ParameterTypes.Count == 3 &&
                           (_unificationEngine.CanUnify(c.ParameterTypes[0], structTypeForSetIndex) ||
                            _unificationEngine.CanUnify(c.ParameterTypes[0], new ReferenceType(structTypeForSetIndex))))
                    .ToList();

                if (matchingBaseCandidates.Count > 0)
                {
                    // Type IS indexable for assignment, but not with this index type
                    var indexTypeName = FormatTypeNameForDisplay(it.Prune());
                    var baseTypeName = FormatTypeNameForDisplay(structTypeForSetIndex);

                    var acceptedTypes = matchingBaseCandidates
                        .Select(c => FormatTypeNameForDisplay(c.ParameterTypes[1]))
                        .Distinct().ToList();
                    var typeList = acceptedTypes.Count <= 3
                        ? string.Join(", ", acceptedTypes.Select(t => $"`{t}`"))
                        : string.Join(", ", acceptedTypes.Take(3).Select(t => $"`{t}`")) + ", ...";

                    ReportError(
                        $"type `{baseTypeName}` cannot be indexed by value of type `{indexTypeName}`",
                        ix.Index.Span,
                        $"expected {typeList}",
                        "E2028");
                    return TypeRegistry.Never;
                }
            }

            // No op_set_index for this type at all — fall through to array/slice check
        }

        // Built-in array indexing
        var prunedIt = it.Prune();
        if (!TypeRegistry.IsIntegerType(prunedIt))
        {
            ReportError(
                "array index must be an integer",
                ix.Index.Span,
                $"found `{prunedIt}`",
                "E2027");
        }
        else if (prunedIt is ComptimeInt)
        {
            UnifyTypes(it, TypeRegistry.USize, ix.Index.Span);
        }

        TypeBase elementType2;
        if (bt is ArrayType at)
        {
            elementType2 = at.ElementType;
        }
        else if (bt is StructType st && TypeRegistry.IsSlice(st))
        {
            elementType2 = st.TypeArguments[0];
        }
        else
        {
            ReportError(
                $"type `{bt}` does not support indexed assignment",
                ix.Base.Span,
                "define `op_set_index` to enable indexed assignment",
                "E2028");
            return TypeRegistry.Never;
        }

        // Check value against element type
        var valType = CheckExpression(ae.Value, elementType2);
        if (IsNever(valType)) return TypeRegistry.Never;

        UnifyTypes(valType, elementType2, ae.Value.Span);
        return elementType2;
    }

    private ArrayType CheckArrayLiteral(ArrayLiteralExpressionNode al, TypeBase? expectedType)
    {
        if (al.IsRepeatSyntax)
        {
            var rv = CheckExpression(al.RepeatValue!);
            return new ArrayType(rv, al.RepeatCount!.Value);
        }

        if (al.Elements!.Count == 0)
        {
            if (expectedType != null)
            {
                // Empty array with context: element type resolved via unification
                return new ArrayType(new TypeVar($"empty_arr_{al.Span.Index}"), 0);
            }

            ReportError(
                "cannot infer type of empty array literal",
                al.Span,
                "consider adding type annotation",
                "E2026");
            return new ArrayType(TypeRegistry.Never, 0);
        }

        var first = CheckExpression(al.Elements[0]);
        var unified = first;
        for (var i = 1; i < al.Elements.Count; i++)
        {
            var et = CheckExpression(al.Elements[i]);
            unified = UnifyTypes(unified, et, al.Elements[i].Span);
        }

        return new ArrayType(unified, al.Elements.Count);
    }

    private TypeBase CheckCallExpression(CallExpressionNode call, TypeBase? expectedType)
    {
        // First check if this is enum variant construction (short form)
        // Syntax: Variant(args) when type can be inferred
        var enumConstructionType =
            TryResolveEnumVariantConstruction(call.FunctionName, call.Arguments, expectedType, call.Span);
        if (enumConstructionType != null)
        {
            return enumConstructionType;
        }

        // UFCS calls (obj.method(args)) are semantically equivalent to method(&obj, args).
        // We don't mutate the AST - instead we build the effective argument list for resolution
        // and let lowering handle the actual transformation.
        TypeBase? ufcsReceiverType = null;
        if (call.UfcsReceiver != null && call.MethodName != null)
        {
            // Type-check the receiver expression first
            ufcsReceiverType = CheckExpression(call.UfcsReceiver);
            if (IsNever(ufcsReceiverType)) return TypeRegistry.Never;
            var prunedReceiverType = ufcsReceiverType.Prune();

            // Check if receiver is a struct with a function-typed field matching the method name.
            // This enables vtable-style patterns: ops.add(5, 3) calls the function in ops.add field.
            StructType? structType = prunedReceiverType switch
            {
                StructType st => st,
                ReferenceType { InnerType: StructType refSt } => refSt,
                _ => null
            };

            if (structType != null)
            {
                var fieldType = structType.GetFieldType(call.MethodName);
                if (fieldType?.Prune() is FunctionType funcType)
                {
                    // Field-call pattern: type-check arguments and mark as indirect call
                    return CheckFieldCall(call, funcType);
                }

                // Check if field exists but is not callable (for better error message)
                if (fieldType != null)
                {
                    var receiverTypeName = FormatTypeNameForDisplay(prunedReceiverType);
                    var fieldTypeName = FormatTypeNameForDisplay(fieldType.Prune());
                    ReportError(
                        $"`{call.MethodName}` is a field of `{receiverTypeName}`, not a method",
                        call.Span,
                        $"has type `{fieldTypeName}` which is not callable",
                        "E2011");
                    return TypeRegistry.Never;
                }
            }

            // UFCS: receiver.method(args) -> method(receiver, a, b) or method(&receiver, a, b)
            // The actual transformation depends on what the resolved function expects.
            // We keep the original receiver type here; overload resolution will try both forms.
        }

        // For UFCS calls, use MethodName (the actual function name) rather than FunctionName
        // (which is a synthetic name like "obj.method" for error messages)
        var functionName = call.MethodName ?? call.FunctionName;

        if (_functions.TryGetValue(functionName, out var candidates))
        {
            _logger.LogDebug("{Indent}Considering {CandidateCount} candidates for '{FunctionName}'", Indent(),
                candidates.Count, functionName);

            // Build effective argument types: for UFCS, prepend receiver type
            // Defer anonymous struct arguments - they need expected type from generic bindings
            var explicitArgTypes = new List<TypeBase>(call.Arguments.Count);
            var deferredAnonStructIndices = new List<int>();
            for (var i = 0; i < call.Arguments.Count; i++)
            {
                var arg = call.Arguments[i];
                if (arg is AnonymousStructExpressionNode)
                {
                    // Defer - use TypeVar placeholder until we have concrete expected type
                    explicitArgTypes.Add(new TypeVar($"__deferred_anon_{i}"));
                    deferredAnonStructIndices.Add(i);
                }
                else
                {
                    var argType = CheckExpression(arg);
                    if (IsNever(argType)) return TypeRegistry.Never;
                    explicitArgTypes.Add(argType);
                }
            }
            var argTypes = ufcsReceiverType != null
                ? new List<TypeBase> { ufcsReceiverType }.Concat(explicitArgTypes).ToList()
                : explicitArgTypes;

            FunctionEntry? bestNonGeneric = null;
            var bestNonGenericCost = int.MaxValue;

            // Track candidates that matched arg count but failed type check (for better error messages)
            FunctionEntry? closestTypeMismatch = null;
            int closestMismatchIndex = -1;
            TypeBase? closestExpectedType = null;
            TypeBase? closestActualType = null;

            foreach (var cand in candidates)
            {
                if (cand.IsGeneric) continue;
                if (cand.ParameterTypes.Count != argTypes.Count) continue;

                // For UFCS calls, adapt receiver type to match what the function expects
                var effectiveArgTypes = argTypes;
                if (ufcsReceiverType != null && argTypes.Count > 0 && cand.ParameterTypes.Count > 0)
                {
                    effectiveArgTypes = TryAdaptUfcsReceiverType(argTypes, cand.ParameterTypes[0]);
                }

                if (!TryComputeCoercionCost(effectiveArgTypes, cand.ParameterTypes, out var cost))
                {
                    // Track which argument failed for error reporting
                    if (closestTypeMismatch == null)
                    {
                        closestTypeMismatch = cand;
                        for (var i = 0; i < effectiveArgTypes.Count; i++)
                        {
                            var argPruned = effectiveArgTypes[i].Prune();
                            var paramPruned = cand.ParameterTypes[i].Prune();
                            if (!argPruned.Equals(paramPruned) && !_unificationEngine.CanUnify(effectiveArgTypes[i], cand.ParameterTypes[i]))
                            {
                                closestMismatchIndex = i;
                                closestExpectedType = paramPruned;
                                closestActualType = argPruned;
                                break;
                            }
                        }
                    }
                    continue;
                }

                if (cost < bestNonGenericCost)
                {
                    bestNonGeneric = cand;
                    bestNonGenericCost = cost;
                }
            }

            FunctionEntry? bestGeneric = null;
            Dictionary<string, TypeBase>? bestBindings = null;
            var bestGenericCost = int.MaxValue;
            string? conflictName = null;
            (TypeBase Existing, TypeBase Incoming)? conflictPair = null;

            foreach (var cand in candidates)
            {
                using var _ = new BindingDepthScope(this);
                _logger.LogDebug(
                    "{Indent}Candidate '{Name}': IsGeneric={IsGeneric}, ParamCount={ParamCount}, ArgCount={ArgCount}",
                    Indent(), cand.Name, cand.IsGeneric, cand.ParameterTypes.Count, argTypes.Count);
                if (!cand.IsGeneric) continue;
                if (cand.ParameterTypes.Count != argTypes.Count) continue;

                // For UFCS calls, adapt receiver type to match what the function expects
                var effectiveArgTypes = argTypes;
                if (ufcsReceiverType != null && argTypes.Count > 0 && cand.ParameterTypes.Count > 0)
                {
                    effectiveArgTypes = TryAdaptUfcsReceiverType(argTypes, cand.ParameterTypes[0]);
                }

                _logger.LogDebug("{Indent}Attempting generic binding for '{Name}'", Indent(), cand.Name);
                var bindings = new Dictionary<string, TypeBase>();
                var okGen = true;
                var failedBindingIndex = -1;
                for (var i = 0; i < effectiveArgTypes.Count; i++)
                {
                    var argType = effectiveArgTypes[i] ?? throw new NullReferenceException();
                    using var __ = new BindingDepthScope(this);
                    _logger.LogDebug("{Indent}Binding param[{Index}] '{ParamName}' with arg '{ArgType}'", Indent(), i,
                        cand.ParameterTypes[i].Name, argType.Name);
                    if (!TryBindGeneric(cand.ParameterTypes[i], argType, bindings, out var cn, out var ct))
                    {
                        okGen = false;
                        failedBindingIndex = i;
                        if (cn != null)
                        {
                            conflictName = cn;
                            conflictPair = ct;
                        }

                        break;
                    }
                }

                if (!okGen)
                {
                    // Track this as a type mismatch if we don't have one yet
                    // For generic candidates, we report the argument that failed binding
                    if (closestTypeMismatch == null && failedBindingIndex >= 0)
                    {
                        closestTypeMismatch = cand;
                        closestMismatchIndex = failedBindingIndex;
                        closestExpectedType = cand.ParameterTypes[failedBindingIndex].Prune();
                        closestActualType = effectiveArgTypes[failedBindingIndex].Prune();
                    }
                    continue;
                }

                var concreteParams = new List<TypeBase>();
                for (var i = 0; i < cand.ParameterTypes.Count; i++)
                    concreteParams.Add(SubstituteGenerics(cand.ParameterTypes[i], bindings));

                // Re-adapt for coercion cost check using concrete params (not generic params)
                var costCheckArgTypes = ufcsReceiverType != null && effectiveArgTypes.Count > 0 && concreteParams.Count > 0
                    ? TryAdaptUfcsReceiverType(argTypes, concreteParams[0])
                    : effectiveArgTypes;

                if (!TryComputeCoercionCost(costCheckArgTypes, concreteParams, out var genCost))
                {
                    _logger.LogDebug("{Indent}  Coercion cost failed: costCheckArgTypes[0]={Arg}, concreteParams[0]={Param}",
                        Indent(), costCheckArgTypes[0].Prune().Name, concreteParams[0].Prune().Name);
                    continue;
                }

                if (genCost < bestGenericCost)
                {
                    _logger.LogDebug("{Indent}  Setting bestGeneric to '{Name}' with cost {Cost}", Indent(), cand.Name, genCost);
                    bestGeneric = cand;
                    bestBindings = bindings;
                    bestGenericCost = genCost;
                }
            }

            FunctionEntry? chosen;
            Dictionary<string, TypeBase>? chosenBindings = null;

            if (bestNonGeneric != null && (bestGeneric == null || bestNonGenericCost <= bestGenericCost))
            {
                chosen = bestNonGeneric;
            }
            else
            {
                chosen = bestGeneric;
                chosenBindings = bestBindings;
            }

            if (chosen == null)
            {
                if (conflictName != null && conflictPair.HasValue)
                {
                    ReportError(
                        $"conflicting bindings for `{conflictName}`",
                        call.Span,
                        $"`{conflictName}` mapped to `{conflictPair.Value.Existing}` and `{conflictPair.Value.Incoming}`",
                        "E2102");
                }
                else
                {
                    // Build argument type list for error message
                    var argTypeNames = string.Join(", ", argTypes.Select(t => FormatTypeNameForDisplay(t.Prune())));

                    // Check if we have a candidate with matching arg count but type mismatch
                    if (closestTypeMismatch != null && closestMismatchIndex >= 0)
                    {
                        // For UFCS, index 0 is the receiver, explicit args start at 1
                        var argOffset = ufcsReceiverType != null ? 1 : 0;
                        SourceSpan errorSpan;
                        var isReceiverMismatch = ufcsReceiverType != null && closestMismatchIndex == 0;
                        if (isReceiverMismatch)
                        {
                            // Receiver type mismatch
                            errorSpan = call.UfcsReceiver!.Span;
                        }
                        else
                        {
                            // Explicit argument mismatch
                            errorSpan = call.Arguments[closestMismatchIndex - argOffset].Span;
                        }

                        var (expectedDisplay, actualDisplay) = FormatTypePairForDisplay(closestExpectedType!, closestActualType!);

                        if (isReceiverMismatch)
                        {
                            ReportError(
                                $"`{call.MethodName}` expects receiver of type `{expectedDisplay}`",
                                errorSpan,
                                $"expected `{expectedDisplay}`, found `{actualDisplay}`",
                                "E2011");
                        }
                        else
                        {
                            ReportError(
                                $"mismatched types",
                                errorSpan,
                                $"expected `{expectedDisplay}`, found `{actualDisplay}`",
                                "E2011");
                        }
                    }
                    else
                    {
                        // No candidate with matching arg count - report on the call with arg types
                        ReportError(
                            $"no function `{call.FunctionName}` found for arguments `({argTypeNames})`",
                            call.Span,
                            "no matching function signature",
                            "E2011");
                    }
                }

                return TypeRegistry.Never;
            }
            else if (!chosen.IsGeneric)
            {
                // Return actual function return type, not unified type,
                // so that coercion (e.g., T → Option<T>) can be applied by the caller
                var type = chosen.ReturnType;
                if (expectedType != null)
                    UnifyTypes(type, expectedType, call.Span);

                // For UFCS, receiver is at argTypes[0]/paramTypes[0], explicit args start at index 1
                var argOffset = ufcsReceiverType != null ? 1 : 0;

                // Unify receiver type if UFCS (using adapted type for proper value/ref matching)
                if (ufcsReceiverType != null)
                {
                    var adaptedArgTypes = TryAdaptUfcsReceiverType(argTypes, chosen.ParameterTypes[0]);
                    UnifyTypes(adaptedArgTypes[0], chosen.ParameterTypes[0], call.UfcsReceiver!.Span);
                }

                // Unify and wrap explicit arguments
                for (var i = 0; i < call.Arguments.Count; i++)
                {
                    var argIdx = i + argOffset;
                    var unified = UnifyTypes(argTypes[argIdx], chosen.ParameterTypes[argIdx], call.Arguments[i].Span);
                    call.Arguments[i] = WrapWithCoercionIfNeeded(call.Arguments[i], argTypes[argIdx].Prune(), chosen.ParameterTypes[argIdx].Prune());
                }

                call.ResolvedTarget = chosen.AstNode;
                return type;
            }
            else
            {
                var bindings = chosenBindings!;
                if (expectedType != null)
                    RefineBindingsWithExpectedReturn(chosen.ReturnType, expectedType, bindings, call.Span);
                var ret = SubstituteGenerics(chosen.ReturnType, bindings);
                // Unify to check compatibility, but return the actual function return type
                // so that coercion (e.g., T → Option<T>) can be applied by the caller
                if (expectedType != null) UnifyTypes(ret, expectedType, call.Span);
                var type = ret;

                var concreteParams = new List<TypeBase>();
                for (var i = 0; i < chosen.ParameterTypes.Count; i++)
                    concreteParams.Add(SubstituteGenerics(chosen.ParameterTypes[i], bindings));

                // For UFCS, receiver is at index 0, explicit args start at index 1
                var argOffset = ufcsReceiverType != null ? 1 : 0;

                // Re-check deferred anonymous struct arguments with concrete expected types
                foreach (var idx in deferredAnonStructIndices)
                {
                    var argIdx = idx + argOffset;
                    var concreteExpected = concreteParams[argIdx];
                    var argType = CheckExpression(call.Arguments[idx], concreteExpected);
                    if (IsNever(argType)) return TypeRegistry.Never;
                    argTypes[argIdx] = argType;
                    explicitArgTypes[idx] = argType;
                }

                // Unify receiver type if UFCS (using adapted type for proper value/ref matching)
                if (ufcsReceiverType != null)
                {
                    var adaptedArgTypes = TryAdaptUfcsReceiverType(argTypes, concreteParams[0]);
                    UnifyTypes(adaptedArgTypes[0], concreteParams[0], call.UfcsReceiver!.Span);
                }

                // Unify and wrap explicit arguments
                for (var i = 0; i < call.Arguments.Count; i++)
                {
                    var argIdx = i + argOffset;
                    var unified = UnifyTypes(concreteParams[argIdx], argTypes[argIdx], call.Arguments[i].Span);
                    call.Arguments[i] = WrapWithCoercionIfNeeded(call.Arguments[i], argTypes[argIdx].Prune(), concreteParams[argIdx].Prune());
                }

                var specializedNode = EnsureSpecialization(chosen, bindings, concreteParams, call.Span);
                call.ResolvedTarget = specializedNode;
                _logger.LogDebug("{Indent}  Set ResolvedTarget for '{FuncName}' to '{Target}'",
                    Indent(), call.FunctionName, specializedNode?.Name ?? "null");
                return type;
            }
        }
        else
        {
            // Temporary built-in fallback for C printf without explicit import
            if (functionName == "printf")
            {
                // Check arguments and resolve comptime_int to i32 for variadic args
                var argTypes = new List<TypeBase>();
                for (var i = 0; i < call.Arguments.Count; i++)
                {
                    var argType = CheckExpression(call.Arguments[i]);
                    if (argType.Prune() is ComptimeInt)
                    {
                        // Resolve comptime_int to i32 for variadic functions - unify handles TypeVar propagation
                        var unified = UnifyTypes(argType, TypeRegistry.I32, call.Arguments[i].Span);
                        argTypes.Add(unified);

                        // Wrap argument with coercion node
                        call.Arguments[i] = WrapWithCoercionIfNeeded(call.Arguments[i], argType.Prune(), TypeRegistry.I32);
                    }
                    else
                    {
                        argTypes.Add(argType);
                    }
                }

                call.ResolvedTarget = null;  // printf is a special builtin, no FunctionDeclarationNode
                return TypeRegistry.I32;
            }

            // Check if function name is a variable with function type (indirect call)
            if (TryLookupVariable(functionName, out var varType) && varType.Prune() is FunctionType funcType)
            {
                // Type-check the arguments
                var argTypes = call.Arguments.Select(arg => CheckExpression(arg)).ToList();

                // Check argument count
                if (argTypes.Count != funcType.ParameterTypes.Count)
                {
                    ReportError(
                        $"function expects {funcType.ParameterTypes.Count} argument(s), but {argTypes.Count} were provided",
                        call.Span,
                        $"expected {funcType.ParameterTypes.Count}, got {argTypes.Count}",
                        "E2011");
                    return TypeRegistry.Never;
                }

                // Check argument types - C semantics: exact match required except comptime_int
                // comptime_int can coerce to the expected integer type (handled by UnifyTypes)
                for (var i = 0; i < argTypes.Count; i++)
                {
                    var argTypePruned = argTypes[i].Prune();
                    var paramType = funcType.ParameterTypes[i].Prune();

                    // Allow comptime_int to coerce to the expected integer type
                    // and TypeVar unification for generic contexts
                    if (argTypePruned is ComptimeInt || argTypePruned is TypeVar ||
                        paramType is TypeVar || argTypePruned is GenericParameterType ||
                        paramType is GenericParameterType)
                    {
                        UnifyTypes(argTypes[i], funcType.ParameterTypes[i], call.Arguments[i].Span);
                        // Wrap argument with coercion node if needed
                        call.Arguments[i] = WrapWithCoercionIfNeeded(call.Arguments[i], argTypePruned, paramType);
                    }
                    else if (!argTypePruned.Equals(paramType))
                    {
                        // Exact match required for non-comptime types (C semantics - no integer widening)
                        ReportError(
                            $"mismatched types: expected `{paramType}`, got `{argTypePruned}`",
                            call.Arguments[i].Span,
                            $"expected `{paramType}`",
                            "E2002");
                        return TypeRegistry.Never;
                    }
                }

                // Mark this as an indirect call (ResolvedTarget remains null for indirect calls)
                call.ResolvedTarget = null;
                call.IsIndirectCall = true;
                return funcType.ReturnType;
            }

            ReportError(
                $"cannot find function `{call.MethodName ?? call.FunctionName}` in this scope",
                call.Span,
                "not found in this scope",
                "E2004");
            return TypeRegistry.Never;
        }
    }

    /// <summary>
    /// Handles field-call pattern: receiver.field(args) where field is a function type.
    /// Used for vtable-style patterns.
    /// </summary>
    private TypeBase CheckFieldCall(CallExpressionNode call, FunctionType funcType)
    {
        var fieldArgTypes = call.Arguments.Select(arg => CheckExpression(arg)).ToList();

        if (fieldArgTypes.Count != funcType.ParameterTypes.Count)
        {
            ReportError(
                $"function expects {funcType.ParameterTypes.Count} argument(s), but {fieldArgTypes.Count} were provided",
                call.Span,
                $"expected {funcType.ParameterTypes.Count}, got {fieldArgTypes.Count}",
                "E2011");
            return TypeRegistry.Never;
        }

        for (var i = 0; i < fieldArgTypes.Count; i++)
        {
            var argTypePruned = fieldArgTypes[i].Prune();
            var paramType = funcType.ParameterTypes[i].Prune();

            if (argTypePruned is ComptimeInt || argTypePruned is TypeVar ||
                paramType is TypeVar || argTypePruned is GenericParameterType ||
                paramType is GenericParameterType)
            {
                UnifyTypes(fieldArgTypes[i], funcType.ParameterTypes[i], call.Arguments[i].Span);
                call.Arguments[i] = WrapWithCoercionIfNeeded(call.Arguments[i], argTypePruned, paramType);
            }
            else if (!argTypePruned.Equals(paramType))
            {
                ReportError(
                    $"mismatched types",
                    call.Arguments[i].Span,
                    $"expected `{FormatTypeNameForDisplay(paramType)}`, found `{FormatTypeNameForDisplay(argTypePruned)}`",
                    "E2011");
                return TypeRegistry.Never;
            }
        }

        // Mark as indirect call (UfcsReceiver + MethodName indicate field-call in lowering)
        call.ResolvedTarget = null;
        call.IsIndirectCall = true;
        return funcType.ReturnType;
    }

    private TypeBase CheckExpression(ExpressionNode expression, TypeBase? expectedType = null)
    {
        TypeBase type;
        switch (expression)
        {
            case IntegerLiteralNode lit:
                if (lit.Suffix is not null)
                {
                    var suffixType = (PrimitiveType)TypeRegistry.GetTypeByName(lit.Suffix)!;
                    if (!FitsInType(lit.Value, suffixType))
                    {
                        var (min, max) = GetIntegerRange(suffixType);
                        ReportError(
                            $"literal value `{lit.Value}` out of range for `{lit.Suffix}`",
                            lit.Span,
                            $"valid range: {min}..{max}",
                            "E2029");
                    }
                    type = suffixType;
                }
                else
                {
                    var tvId = $"lit_{lit.Span.Index}_{_nextLiteralTypeVarId++}";
                    type = CreateLiteralTypeVar(tvId, lit.Span, TypeRegistry.ComptimeInt, lit.Value);
                }
                break;
            case BooleanLiteralNode:
                type = TypeRegistry.Bool;
                break;
            case StringLiteralNode strLit:
                type = CheckStringLiteral(strLit);
                break;
            case IdentifierExpressionNode id:
                type = CheckIdentifierExpression(id);
                break;
            case BinaryExpressionNode be:
                type = CheckBinaryExpression(be);
                break;
            case UnaryExpressionNode ue:
                type = CheckUnaryExpression(ue);
                break;
            case AssignmentExpressionNode ae:
                type = CheckAssignmentExpression(ae);
                break;
            case CallExpressionNode call:
                type = CheckCallExpression(call, expectedType);
                break;
            case IfExpressionNode ie:
                {
                    var ct = CheckExpression(ie.Condition);
                    if (IsNever(ct))
                    {
                        type = TypeRegistry.Never;
                        break;
                    }
                    var prunedCt = ct.Prune();
                    if (!prunedCt.Equals(TypeRegistry.Bool))
                        ReportError(
                            "mismatched types",
                            ie.Condition.Span,
                            $"expected `bool`, found `{prunedCt}`",
                            "E2002");
                    var tt = CheckExpression(ie.ThenBranch, expectedType);
                    if (ie.ElseBranch != null)
                    {
                        var et = CheckExpression(ie.ElseBranch, expectedType);
                        type = UnifyTypes(tt, et, ie.Span);
                    }
                    else
                    {
                        type = TypeRegistry.Never;
                    }

                    // Propagate expected type to resolve comptime literals in branches
                    if (expectedType != null && !IsNever(type))
                        type = UnifyTypes(type, expectedType, ie.Span);

                    break;
                }
            case BlockExpressionNode bex:
                {
                    PushScope();
                    TypeBase? last = null;
                    foreach (var s in bex.Statements)
                    {
                        if (s is ExpressionStatementNode es) last = CheckExpression(es.Expression);
                        else
                        {
                            CheckStatement(s);
                            last = null;
                        }
                    }

                    if (bex.TrailingExpression != null) last = CheckExpression(bex.TrailingExpression);
                    PopScope();
                    type = last ?? TypeRegistry.Never;
                    break;
                }
            case RangeExpressionNode re:
                {
                    TypeBase? st = null, en = null;

                    if (re.Start != null)
                    {
                        st = CheckExpression(re.Start);
                        if (IsNever(st))
                        {
                            type = TypeRegistry.Never;
                            break;
                        }
                    }

                    if (re.End != null)
                    {
                        en = CheckExpression(re.End);
                        if (IsNever(en))
                        {
                            type = TypeRegistry.Never;
                            break;
                        }
                    }

                    // For fully unbounded ranges (..), default to usize
                    // The actual bounds will be filled in during index lowering
                    if (st == null && en == null)
                    {
                        type = TypeRegistry.MakeRange(TypeRegistry.USize);
                        break;
                    }

                    var prunedSt = st?.Prune();
                    var prunedEn = en?.Prune();

                    // Validate present bounds are integers
                    if (prunedSt != null && !TypeRegistry.IsIntegerType(prunedSt))
                    {
                        ReportError("range bounds must be integers", re.Start!.Span, $"found `{prunedSt}`",
                            "E2002");
                        type = TypeRegistry.Never;
                        break;
                    }
                    if (prunedEn != null && !TypeRegistry.IsIntegerType(prunedEn))
                    {
                        ReportError("range bounds must be integers", re.End!.Span, $"found `{prunedEn}`",
                            "E2002");
                        type = TypeRegistry.Never;
                        break;
                    }

                    // If context expects Range(T), propagate T to present bounds
                    if (expectedType?.Prune() is StructType expectedRange
                        && TypeRegistry.IsRange(expectedRange)
                        && expectedRange.TypeArguments.Count == 1)
                    {
                        var expectedElem = expectedRange.TypeArguments[0];
                        if (st != null) UnifyTypes(st, expectedElem, re.Start!.Span);
                        if (en != null) UnifyTypes(en, expectedElem, re.End!.Span);
                    }

                    // Unify start and end types if both present
                    if (st != null && en != null)
                        UnifyTypes(st, en, re.Span);

                    // Determine the element type for Range(T) from whichever bound is present
                    var elementType = (st ?? en)!.Prune();

                    type = MakeRangeType(elementType, re.Span);
                    break;
                }
            case MatchExpressionNode match:
                type = CheckMatchExpression(match, expectedType);
                break;
            case AddressOfExpressionNode adr:
                {
                    // Propagate expected type through &: if context expects &T, pass T as expected type
                    TypeBase? innerExpected = expectedType is ReferenceType refExpected ? refExpected.InnerType : null;
                    var tt = CheckExpression(adr.Target, innerExpected);
                    if (IsNever(tt))
                    {
                        type = TypeRegistry.Never;
                        break;
                    }

                    // Check that the target is not a temporary (e.g. anonymous struct literal)
                    if (adr.Target is AnonymousStructExpressionNode)
                    {
                        ReportError(
                            "cannot take address of temporary value",
                            adr.Span,
                            "consider assigning to a variable first",
                            "E2040");
                        type = TypeRegistry.Never;
                        break;
                    }

                    type = new ReferenceType(tt);
                    break;
                }
            case DereferenceExpressionNode dr:
                {
                    var pt = CheckExpression(dr.Target);
                    if (IsNever(pt))
                    {
                        type = TypeRegistry.Never;
                        break;
                    }
                    var prunedPt = pt.Prune();
                    if (prunedPt is ReferenceType rft) type = rft.InnerType;
                    else if (prunedPt is StructType opt && TypeRegistry.IsOption(opt) && opt.TypeArguments.Count > 0 &&
                             opt.TypeArguments[0] is ReferenceType rf2) type = rf2.InnerType;
                    else
                    {
                        ReportError(
                            "cannot dereference non-reference type",
                            dr.Span,
                            $"expected `&T` or `&T?`, found `{prunedPt}`",
                            "E2012");
                        type = TypeRegistry.Never;
                    }

                    break;
                }
            case MemberAccessExpressionNode ma:
                type = CheckMemberAccessExpression(ma, expectedType);
                break;
            case StructConstructionExpressionNode sc:
                {
                    var resolvedType = ResolveTypeNode(sc.TypeName);
                    StructType? optionLiteral = null;
                    if (resolvedType is StructType optStruct && TypeRegistry.IsOption(optStruct))
                    {
                        optionLiteral = optStruct;
                        resolvedType = optStruct; // Already a StructType
                    }

                    if (resolvedType == null)
                    {
                        ReportError(
                            $"cannot find type `{(sc.TypeName as NamedTypeNode)?.Name ?? "unknown"}`",
                            sc.TypeName.Span,
                            "not found in this scope",
                            "E2003");
                        type = TypeRegistry.Never;
                        break;
                    }

                    if (resolvedType is GenericType genericType)
                        resolvedType = InstantiateStruct(genericType, sc.Span);

                    if (resolvedType is StructType optFromGeneric && TypeRegistry.IsOption(optFromGeneric))
                    {
                        optionLiteral = optFromGeneric;
                        resolvedType = optFromGeneric; // Already a StructType
                    }

                    if (resolvedType is not StructType st)
                    {
                        ReportError(
                            $"type `{resolvedType?.Name ?? "unknown"}` is not a struct",
                            sc.TypeName.Span,
                            "cannot construct non-struct type",
                            "E2018");
                        type = TypeRegistry.I32;
                        break;
                    }

                    ValidateStructLiteralFields(st, sc.Fields, sc.Span);
                    type = optionLiteral ?? st;
                    break;
                }
            case AnonymousStructExpressionNode anon:
                {
                    // Unwrap ReferenceType to find the underlying struct type
                    var unwrappedExpected = expectedType is ReferenceType reTypeBase ? reTypeBase.InnerType : expectedType;
                    StructType? structType = unwrappedExpected switch
                    {
                        StructType st => st,
                        GenericType gt => InstantiateStruct(gt, anon.Span),
                        _ => null
                    };

                    if (structType == null)
                    {
                        // No expected type - infer field types from values (tuple case)
                        // This enables tuples like (10, 20) without type annotation
                        var inferredFields = new List<(string Name, TypeBase Type)>();
                        bool inferenceSucceeded = true;

                        foreach (var (fieldName, fieldValue) in anon.Fields)
                        {
                            var fieldType = CheckExpression(fieldValue);

                            // Handle comptime types: default comptime_int to i32 for tuples
                            var prunedType = fieldType is TypeVar tv ? tv.Prune() : fieldType;
                            if (prunedType is ComptimeInt)
                            {
                                // Unify the TypeVar with i32 to resolve the comptime_int
                                fieldType = UnifyTypes(fieldType, TypeRegistry.I32, fieldValue.Span) ?? TypeRegistry.I32;
                            }
                            else if (fieldType == TypeRegistry.Never)
                            {
                                inferenceSucceeded = false;
                            }

                            inferredFields.Add((fieldName, fieldType));
                        }

                        if (!inferenceSucceeded)
                        {
                            ReportError(
                                "cannot infer type of anonymous struct/tuple literal",
                                anon.Span,
                                "add a type annotation",
                                "E2018");
                            type = TypeRegistry.Never;
                            break;
                        }

                        // Create an anonymous struct type from inferred fields
                        structType = new StructType("", typeArguments: null, fields: inferredFields);
                        _compilation.InstantiatedTypes.Add(structType);
                    }
                    else
                    {
                        ValidateStructLiteralFields(structType, anon.Fields, anon.Span);
                    }

                    anon.Type = structType;

                    if (expectedType != null && TypeRegistry.IsOption(expectedType))
                        type = expectedType;
                    else
                        type = structType;

                    break;
                }

            case NullLiteralNode nullLiteral:
                {
                    // Infer Option type from context
                    var innerType = expectedType switch
                    {
                        StructType st when TypeRegistry.IsOption(st) => st.TypeArguments[0],
                        _ => null
                    };

                    if (innerType == null)
                    {
                        ReportError(
                            "cannot infer type of null literal",
                            nullLiteral.Span,
                            "add an option type annotation or use an explicit constructor",
                            "E2001");
                        type = TypeRegistry.Never; // Fallback
                    }
                    else
                    {
                        type = TypeRegistry.MakeOption(innerType);
                    }

                    break;
                }
            case ArrayLiteralExpressionNode al:
                type = CheckArrayLiteral(al, expectedType);
                break;
            case IndexExpressionNode ix:
                {
                    var bt = CheckExpression(ix.Base);
                    if (IsNever(bt))
                    {
                        type = TypeRegistry.Never;
                        break;
                    }
                    var it = CheckExpression(ix.Index);
                    if (IsNever(it))
                    {
                        type = TypeRegistry.Never;
                        break;
                    }

                    // For struct types (slices, custom types), look up op_index function
                    // Arrays use built-in indexing (no op_index lookup)
                    // Special case: partial ranges on slices use built-in handling
                    var prunedBt = bt.Prune();
                    if (prunedBt is StructType structTypeForIndex)
                    {
                        // For slices with partial ranges, skip op_index lookup and use built-in handling
                        // This is because partial ranges need to fill in missing bounds from the slice's length
                        if (TypeRegistry.IsSlice(structTypeForIndex) &&
                            ix.Index is RangeExpressionNode partialRangeCheck &&
                            (partialRangeCheck.Start == null || partialRangeCheck.End == null))
                        {
                            // Fall through to built-in range indexing below
                            goto builtInRangeIndexing;
                        }

                        // Try with &T first (op_index(base: &T, index: I) R)
                        var refBaseType = new ReferenceType(structTypeForIndex);
                        var opIndexResult = TryResolveOperatorFunction("op_index", refBaseType, it, ix.Span);

                        // Also try with value T (op_index(base: T, index: I) R)
                        if (opIndexResult == null)
                            opIndexResult = TryResolveOperatorFunction("op_index", prunedBt, it, ix.Span);

                        if (opIndexResult != null)
                        {
                            // Use op_index function
                            ix.ResolvedIndexFunction = opIndexResult.Value.Function;
                            type = opIndexResult.Value.ReturnType;

                            // Resolve comptime_int index to the parameter's concrete type
                            var resolvedFunc = opIndexResult.Value.Function;
                            if (resolvedFunc.Parameters.Count >= 2)
                            {
                                var indexParamType = resolvedFunc.Parameters[1].ResolvedType;
                                if (indexParamType != null)
                                {
                                    UnifyTypes(it, indexParamType, ix.Index.Span);

                                    // For range literals, also unify the bound expressions
                                    // This ensures comptime_int bounds get resolved to the correct type
                                    if (ix.Index is RangeExpressionNode rangeExpr &&
                                        indexParamType is StructType rangeParamType &&
                                        TypeRegistry.IsRange(rangeParamType) &&
                                        rangeParamType.TypeArguments.Count > 0)
                                    {
                                        var elemType = rangeParamType.TypeArguments[0];
                                        if (rangeExpr.Start?.Type != null)
                                            UnifyTypes(rangeExpr.Start.Type, elemType, rangeExpr.Start.Span);
                                        if (rangeExpr.End?.Type != null)
                                            UnifyTypes(rangeExpr.End.Type, elemType, rangeExpr.End.Span);
                                    }
                                }
                            }

                            break;
                        }

                        // op_index not found — check WHY
                        if (_functions.TryGetValue("op_index", out var indexCandidates))
                        {
                            var matchingBaseCandidates = indexCandidates
                                .Where(c => c.ParameterTypes.Count == 2 &&
                                       (_unificationEngine.CanUnify(c.ParameterTypes[0], structTypeForIndex) ||
                                        _unificationEngine.CanUnify(c.ParameterTypes[0], new ReferenceType(structTypeForIndex))))
                                .ToList();

                            if (matchingBaseCandidates.Count > 0)
                            {
                                // Type IS indexable, but not with this index type
                                var indexTypeName = FormatTypeNameForDisplay(it.Prune());
                                var baseTypeName = FormatTypeNameForDisplay(structTypeForIndex);

                                var acceptedTypes = matchingBaseCandidates
                                    .Select(c => FormatTypeNameForDisplay(c.ParameterTypes[1]))
                                    .Distinct().ToList();
                                var typeList = acceptedTypes.Count <= 3
                                    ? string.Join(", ", acceptedTypes.Select(t => $"`{t}`"))
                                    : string.Join(", ", acceptedTypes.Take(3).Select(t => $"`{t}`")) + ", ...";

                                ReportError(
                                    $"type `{baseTypeName}` cannot be indexed by value of type `{indexTypeName}`",
                                    ix.Index.Span,
                                    $"expected {typeList}",
                                    "E2028");
                                type = TypeRegistry.Never;
                                break;
                            }
                        }

                        // No op_index for this type at all — fall through to array/slice check
                    }

                    // Check for range indexing on arrays/slices: arr[x..y] -> Slice(T)
                    // For partial ranges (x.., ..y, ..), use built-in handling for both arrays and slices
                    // Full ranges on slices use op_index from stdlib (handled above)
                builtInRangeIndexing:
                    var prunedIt = it.Prune();
                    if (prunedIt is StructType rangeStruct && TypeRegistry.IsRange(rangeStruct))
                    {
                        // Check if this is a partial range that needs built-in handling
                        var isPartialRange = ix.Index is RangeExpressionNode re && (re.Start == null || re.End == null);

                        TypeBase? elementType = null;
                        if (bt is ArrayType arrayForRange)
                            elementType = arrayForRange.ElementType;
                        else if (isPartialRange && bt is StructType sliceForRange && TypeRegistry.IsSlice(sliceForRange))
                            elementType = sliceForRange.TypeArguments[0];

                        if (elementType != null)
                        {
                            // Unify range bounds with usize via the Range type argument
                            if (rangeStruct.TypeArguments.Count > 0)
                                UnifyTypes(rangeStruct.TypeArguments[0], TypeRegistry.USize, ix.Index.Span);

                            // Also unify the actual bound expressions if it's a range literal
                            if (ix.Index is RangeExpressionNode rangeExpr)
                            {
                                if (rangeExpr.Start?.Type != null)
                                    UnifyTypes(rangeExpr.Start.Type, TypeRegistry.USize, rangeExpr.Start.Span);
                                if (rangeExpr.End?.Type != null)
                                    UnifyTypes(rangeExpr.End.Type, TypeRegistry.USize, rangeExpr.End.Span);
                            }

                            ix.IsRangeIndex = true;
                            type = TypeRegistry.MakeSlice(elementType);
                            break;
                        }
                    }

                    // Built-in array/slice indexing with usize
                    if (!TypeRegistry.IsIntegerType(prunedIt))
                    {
                        ReportError(
                            "array index must be an integer",
                            ix.Index.Span,
                            $"found `{prunedIt}`",
                            "E2027");
                    }
                    else if (prunedIt is ComptimeInt)
                    {
                        // Resolve comptime_int indices to usize for built-in indexing
                        UnifyTypes(it, TypeRegistry.USize, ix.Index.Span);
                    }

                    if (bt is ArrayType at) type = at.ElementType;
                    else if (bt is StructType st && TypeRegistry.IsSlice(st)) type = st.TypeArguments[0];
                    else
                    {
                        ReportError(
                            $"type `{bt}` does not support indexing",
                            ix.Base.Span,
                            "define `op_index` to enable indexing",
                            "E2028");
                        type = TypeRegistry.Never;
                    }

                    break;
                }
            case CastExpressionNode c:
                {
                    var src = CheckExpression(c.Expression);
                    var dst = ResolveTypeNode(c.TargetType) ?? TypeRegistry.Never;
                    if (!CanExplicitCast(src, dst))
                        ReportError(
                            "invalid cast",
                            c.Span,
                            $"cannot cast `{src}` to `{dst}`",
                            "E2020");

                    // When casting comptime_int to a concrete integer type, update the TypeVar
                    // so the literal gets properly resolved
                    if (src is TypeVar srcTv && srcTv.Prune() is ComptimeInt && TypeRegistry.IsIntegerType(dst))
                        srcTv.Instance = dst;

                    type = dst;
                    break;
                }
            case CoalesceExpressionNode coalesce:
                type = CheckCoalesceExpression(coalesce);
                break;
            case NullPropagationExpressionNode nullProp:
                type = CheckNullPropagationExpression(nullProp);
                break;
            default:
                throw new Exception($"Unknown expression type: {expression.GetType().Name}");
        }

        type = ApplyOptionExpectation(expression, type, expectedType);
        expression.Type = type;
        return type;
    }

    // ==================== Enum Variant Construction ====================

    /// <summary>
    /// Try to resolve a call as enum variant construction (short form).
    /// Returns the enum type if successful, null otherwise.
    /// </summary>
    private TypeBase? TryResolveEnumVariantConstruction(string variantName, IReadOnlyList<ExpressionNode> arguments,
        TypeBase? expectedType, SourceSpan span)
    {
        // Check if the function name contains a dot (qualified form: EnumName.Variant)
        if (variantName.Contains('.'))
        {
            var parts = variantName.Split('.');
            if (parts.Length == 2)
            {
                var enumName = parts[0];
                var actualVariantName = parts[1];

                // Try to find the enum
                if (_compilation.Enums.TryGetValue(enumName, out var enumTemplate))
                {
                    // If we have an expected type that's a specialized version of this enum, use that
                    EnumType enumToUse = enumTemplate;
                    if (expectedType is EnumType expectedEnumType &&
                        expectedEnumType.Name == enumTemplate.Name &&
                        expectedEnumType.TypeArguments.Count > 0)
                    {
                        enumToUse = expectedEnumType;
                    }
                    return CheckEnumVariantConstruction(enumToUse, actualVariantName, arguments, span);
                }
            }
        }

        // Short form - try variant lookup in current scope
        if (TryLookupVariable(variantName, out var varType) &&
            varType is EnumType enumFromScope &&
            enumFromScope.Variants.Any(v => v.VariantName == variantName))
        {
            return CheckEnumVariantConstruction(enumFromScope, variantName, arguments, span);
        }

        // Fallback: check expected type
        if (expectedType != null && expectedType is EnumType expectedEnum)
        {
            // Check if the expected enum has this variant
            var variant = expectedEnum.Variants.FirstOrDefault(v => v.VariantName == variantName);
            if (variant != default)
            {
                return CheckEnumVariantConstruction(expectedEnum, variantName, arguments, span);
            }
        }

        return null; // Not an enum variant
    }

    private TypeBase CheckEnumVariantConstruction(EnumType enumType, string variantName,
        IReadOnlyList<ExpressionNode> arguments, SourceSpan span)
    {
        // Find the variant
        var variant = enumType.Variants.FirstOrDefault(v => v.VariantName == variantName);
        if (variant == default)
        {
            ReportError(
                $"enum `{enumType.Name}` has no variant `{variantName}`",
                span,
                null,
                "E2037");
            return enumType;
        }

        // Check argument count
        var expectedArgCount = variant.PayloadType != null
            ? (variant.PayloadType is StructType stmp && stmp.Name.Contains("_payload") ? stmp.Fields.Count : 1)
            : 0;

        if (arguments.Count != expectedArgCount)
        {
            ReportError(
                $"variant `{variantName}` expects {expectedArgCount} argument(s), found {arguments.Count}",
                span,
                null,
                "E2032");
            return enumType;
        }

        // Type check arguments
        if (variant.PayloadType != null)
        {
            if (variant.PayloadType is StructType st && st.Name.Contains("_payload"))
            {
                // Multiple payloads - check each field
                for (int i = 0; i < arguments.Count && i < st.Fields.Count; i++)
                {
                    var expectedFieldType = st.Fields[i].Type;
                    var argType = CheckExpression(arguments[i], expectedFieldType);

                    // Unify argument with field type - TypeVar.Prune() handles propagation
                    var unified = UnifyTypes(argType, expectedFieldType, arguments[i].Span);
                }
            }
            else
            {
                // Single payload
                var argType = CheckExpression(arguments[0], variant.PayloadType);

                // Unify argument with payload type - TypeVar.Prune() handles propagation
                var unified = UnifyTypes(argType, variant.PayloadType, arguments[0].Span);
            }
        }

        return enumType;
    }

    // ==================== Match Expression Type Checking ====================

    private TypeBase CheckMatchExpression(MatchExpressionNode match, TypeBase? expectedType)
    {
        // Check scrutinee type
        var scrutineeType = CheckExpression(match.Scrutinee);
        var prunedScrutinee = scrutineeType.Prune();

        // Allow matching on &EnumType (auto-dereference)
        var needsDereference = false;
        if (prunedScrutinee is ReferenceType rt)
        {
            prunedScrutinee = rt.InnerType;
            needsDereference = true;
        }

        // Scrutinee must be an enum type
        if (prunedScrutinee is not EnumType enumType)
        {
            ReportError(
                "match expression requires enum type",
                match.Scrutinee.Span,
                $"found `{prunedScrutinee}`",
                "E2030");
            return TypeRegistry.Never; // Fallback
        }

        // Store metadata for lowering
        match.NeedsDereference = needsDereference;

        // Track which variants are covered
        var coveredVariants = new HashSet<string>();
        var hasElse = false;

        // Type check each arm and unify result types
        TypeBase? resultType = null;
        foreach (var arm in match.Arms)
        {
            // Check pattern and bind variables
            PushScope(); // Pattern variables are scoped to the arm

            var matchedVariants = CheckPattern(arm.Pattern, enumType, match.Scrutinee.Span);
            foreach (var v in matchedVariants)
            {
                if (v == "_else_")
                    hasElse = true;
                else
                    coveredVariants.Add(v);
            }

            // Check arm expression with expected type to help resolve comptime_int
            // Prefer expectedType (from context like return type) over inferred resultType
            var armType = CheckExpression(arm.ResultExpr, expectedType ?? resultType);

            PopScope();

            // Unify with expected type first if available, then with previous result type
            // TypeVar.Prune() handles propagation automatically - no need for UpdateTypeMapRecursive
            TypeBase unifiedArmType = armType;
            if (expectedType != null)
            {
                unifiedArmType = UnifyTypes(armType, expectedType, arm.Span);
            }
            else if (resultType != null)
            {
                unifiedArmType = UnifyTypes(resultType, armType, arm.Span);
            }

            // Unify with previous arm types
            if (resultType == null)
                resultType = unifiedArmType;
            else
                resultType = UnifyTypes(resultType, unifiedArmType, arm.Span);
        }

        // No second pass needed - TypeVar.Prune() handles type propagation automatically

        // Check exhaustiveness
        if (!hasElse)
        {
            var missingVariants = enumType.Variants
                .Select(v => v.VariantName)
                .Where(name => !coveredVariants.Contains(name))
                .ToList();

            if (missingVariants.Count > 0)
            {
                ReportError(
                    "non-exhaustive pattern match",
                    match.Span,
                    $"missing variants: {string.Join(", ", missingVariants)}",
                    "E2031");
            }
        }

        return resultType ?? TypeRegistry.Never;
    }

    /// <summary>
    /// Check a pattern against an enum type.
    /// Returns the set of variant names this pattern matches.
    /// </summary>
    private List<string> CheckPattern(PatternNode pattern, EnumType enumType, SourceSpan contextSpan)
    {
        switch (pattern)
        {
            case WildcardPatternNode:
                // Wildcard matches anything but doesn't bind
                return new List<string>(); // Doesn't count as covering any specific variant

            case ElsePatternNode:
                // Else matches everything
                return new List<string> { "_else_" };

            case EnumVariantPatternNode evp:
                {
                    // Find the variant
                    string variantName = evp.VariantName;
                    var variant = enumType.Variants.FirstOrDefault(v => v.VariantName == variantName);

                    if (variant == default)
                    {
                        ReportError(
                            $"enum `{enumType.Name}` has no variant `{variantName}`",
                            pattern.Span,
                            null,
                            "E2037");
                        return new List<string>();
                    }

                    // Check sub-pattern arity
                    var expectedSubPatterns = variant.PayloadType != null
                        ? (variant.PayloadType is StructType stArity && stArity.Name.Contains("_payload")
                            ? stArity.Fields.Count
                            : 1)
                        : 0;

                    if (evp.SubPatterns.Count != expectedSubPatterns)
                    {
                        ReportError(
                            $"variant `{variantName}` expects {expectedSubPatterns} field(s), pattern has {evp.SubPatterns.Count}",
                            pattern.Span,
                            null,
                            "E2032");
                    }
                    else if (variant.PayloadType != null)
                    {
                        // Bind sub-pattern variables
                        if (variant.PayloadType is StructType st && st.Name.Contains("_payload"))
                        {
                            // Multiple fields
                            for (int i = 0; i < evp.SubPatterns.Count && i < st.Fields.Count; i++)
                            {
                                BindPatternVariable(evp.SubPatterns[i], st.Fields[i].Type);
                            }
                        }
                        else
                        {
                            // Single field
                            BindPatternVariable(evp.SubPatterns[0], variant.PayloadType);
                        }
                    }

                    return new List<string> { variantName };
                }

            default:
                ReportError(
                    "invalid pattern",
                    pattern.Span,
                    "expected enum variant pattern, wildcard (_), or else",
                    "E1001");
                return new List<string>();
        }
    }

    private void BindPatternVariable(PatternNode pattern, TypeBase type)
    {
        switch (pattern)
        {
            case WildcardPatternNode:
                // Wildcard doesn't bind
                break;

            case VariablePatternNode vp:
                // Bind variable to the payload type (pattern bindings are mutable like let)
                _scopes.Peek()[vp.Name] = new VariableInfo(type, IsConst: false);
                break;

            case EnumVariantPatternNode:
                // Nested enum pattern - would need recursive handling
                // For now, not supported
                ReportError(
                    "nested enum patterns not yet supported",
                    pattern.Span,
                    null,
                    "E1001");
                break;
        }
    }
}
