using System.Collections.Generic;
using System.Linq;
using FLang.Core;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;
using FLang.Frontend.Ast.Types;

namespace FLang.Semantics;

/// <summary>
/// Performs type checking and inference on the AST.
/// </summary>
public class TypeSolver
{
    private readonly Compilation _compilation;
    private readonly List<Diagnostic> _diagnostics = new();

    // Maps AST nodes to their inferred/checked types
    private readonly Dictionary<AstNode, Type> _typeMap = new();

    // Maps variable names to their types (per scope)
    private readonly Stack<Dictionary<string, Type>> _scopes = new();

    // Maps function names to their signatures
    private readonly Dictionary<string, FunctionSignature> _functions = new();

    // Maps struct names to their types
    private readonly Dictionary<string, StructType> _structs = new();

    public IReadOnlyList<Diagnostic> Diagnostics => _diagnostics;

    public TypeSolver(Compilation compilation)
    {
        _compilation = compilation;
        PushScope(); // Global scope
    }

    /// <summary>
    /// Gets the resolved type for an AST node.
    /// Returns null if the node hasn't been type-checked yet.
    /// </summary>
    public Type? GetType(AstNode node)
    {
        return _typeMap.GetValueOrDefault(node);
    }

    /// <summary>
    /// Collects function signatures from a module (first pass).
    /// </summary>
    public void CollectFunctionSignatures(ModuleNode module)
    {
        foreach (var function in module.Functions)
        {
            var returnType = ResolveTypeNode(function.ReturnType);
            if (returnType == null)
            {
                // If no return type specified, default to i32 for now
                returnType = TypeRegistry.I32;
            }

            // Collect parameter types
            var parameterTypes = new List<Type>();
            foreach (var param in function.Parameters)
            {
                var paramType = ResolveTypeNode(param.Type);
                if (paramType == null)
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"cannot find type `{(param.Type as NamedTypeNode)?.Name ?? "unknown"}` in this scope",
                        param.Type.Span,
                        hint: "not found in this scope",
                        code: "E2003"
                    ));
                    paramType = TypeRegistry.I32; // Fallback
                }
                parameterTypes.Add(paramType);
            }

            _functions[function.Name] = new FunctionSignature(function.Name, parameterTypes, returnType);
        }
    }

    /// <summary>
    /// Collects struct definitions from a module (first pass).
    /// </summary>
    public void CollectStructDefinitions(ModuleNode module)
    {
        foreach (var structDecl in module.Structs)
        {
            var fields = new List<(string, Type)>();

            foreach (var field in structDecl.Fields)
            {
                var fieldType = ResolveTypeNode(field.Type);
                if (fieldType == null)
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"cannot find type `{(field.Type as NamedTypeNode)?.Name ?? "unknown"}` in this scope",
                        field.Type.Span,
                        hint: "not found in this scope",
                        code: "E2003"
                    ));
                    fieldType = TypeRegistry.I32; // Fallback
                }
                fields.Add((field.Name, fieldType));
            }

            var structType = new StructType(structDecl.Name, structDecl.TypeParameters, fields);
            _structs[structDecl.Name] = structType;
        }
    }

    /// <summary>
    /// Type checks function bodies in a module (second pass).
    /// </summary>
    public void CheckModuleBodies(ModuleNode module)
    {
        foreach (var function in module.Functions)
        {
            // Skip foreign functions - they have no body
            if (!function.IsForeign)
            {
                CheckFunction(function);
            }
        }
    }

    private void CheckFunction(FunctionDeclarationNode function)
    {
        PushScope(); // Function scope

        // Add parameters to scope
        foreach (var param in function.Parameters)
        {
            var paramType = ResolveTypeNode(param.Type);
            if (paramType != null)
            {
                DeclareVariable(param.Name, paramType, param.Span);
            }
        }

        var expectedReturnType = ResolveTypeNode(function.ReturnType) ?? TypeRegistry.I32;

        // Check function body
        foreach (var statement in function.Body)
        {
            CheckStatement(statement, expectedReturnType);
        }

        PopScope();
    }

    private void CheckStatement(StatementNode statement, Type? expectedReturnType)
    {
        switch (statement)
        {
            case ReturnStatementNode returnStmt:
                var exprType = CheckExpression(returnStmt.Expression);
                if (expectedReturnType != null)
                {
                    if (!IsCompatible(exprType, expectedReturnType))
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            $"mismatched types",
                            returnStmt.Span,
                            hint: $"expected `{expectedReturnType}`, found `{exprType}`",
                            code: "E2002"
                        ));
                    }
                }
                break;

            case VariableDeclarationNode varDecl:
                var initType = CheckExpression(varDecl.Initializer);
                var declaredType = ResolveTypeNode(varDecl.Type);

                if (declaredType != null)
                {
                    // User provided explicit type - check compatibility
                    if (!IsCompatible(initType, declaredType))
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            $"mismatched types",
                            varDecl.Initializer.Span,
                            hint: $"expected `{declaredType}`, found `{initType}`",
                            code: "E2002"
                        ));
                    }

                    // Store the declared type for the variable
                    DeclareVariable(varDecl.Name, declaredType, varDecl.Span);
                }
                else
                {
                    // No explicit type - infer from initializer
                    // But if it's comptime_int, we need more context
                    if (TypeRegistry.IsComptimeType(initType))
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            $"cannot infer type",
                            varDecl.Span,
                            hint: $"type annotations needed: variable has comptime type `{initType}`",
                            code: "E2001"
                        ));
                        // Use i32 as fallback to continue checking
                        DeclareVariable(varDecl.Name, TypeRegistry.I32, varDecl.Span);
                    }
                    else
                    {
                        DeclareVariable(varDecl.Name, initType, varDecl.Span);
                    }
                }
                break;

            case ExpressionStatementNode exprStmt:
                CheckExpression(exprStmt.Expression);
                break;

            case ForLoopNode forLoop:
                PushScope(); // For loop scope

                // Check the iterable expression
                if (forLoop.IterableExpression is RangeExpressionNode rangeExpr)
                {
                    var startType = CheckExpression(rangeExpr.Start);
                    var endType = CheckExpression(rangeExpr.End);

                    if (!TypeRegistry.IsIntegerType(startType) || !TypeRegistry.IsIntegerType(endType))
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            $"range bounds must be integers",
                            forLoop.IterableExpression.Span,
                            hint: $"found `{startType}..{endType}`",
                            code: "E2002"
                        ));
                    }

                    // The loop variable is i32 for now
                    DeclareVariable(forLoop.IteratorVariable, TypeRegistry.I32, forLoop.Span);
                }
                else
                {
                    CheckExpression(forLoop.IterableExpression);
                    // Assume the loop variable is i32 for now
                    DeclareVariable(forLoop.IteratorVariable, TypeRegistry.I32, forLoop.Span);
                }

                // Check the body (which is an expression, not a list of statements)
                CheckExpression(forLoop.Body);

                PopScope();
                break;

            case BreakStatementNode:
            case ContinueStatementNode:
                // Nothing to check
                break;

            default:
                throw new System.Exception($"Unknown statement type: {statement.GetType().Name}");
        }
    }

    private Type CheckExpression(ExpressionNode expression)
    {
        Type type;

        switch (expression)
        {
            case IntegerLiteralNode:
                // Integer literals are comptime_int
                type = TypeRegistry.ComptimeInt;
                break;

            case BooleanLiteralNode:
                type = TypeRegistry.Bool;
                break;

            case IdentifierExpressionNode identifier:
                type = LookupVariable(identifier.Name, identifier.Span);
                break;

            case BinaryExpressionNode binary:
                var leftType = CheckExpression(binary.Left);
                var rightType = CheckExpression(binary.Right);

                // Check operator compatibility
                if (binary.Operator >= BinaryOperatorKind.Equal && binary.Operator <= BinaryOperatorKind.GreaterThanOrEqual)
                {
                    // Comparison operators: return bool
                    if (!IsCompatible(leftType, rightType))
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            $"mismatched types in comparison",
                            binary.Span,
                            hint: $"cannot compare `{leftType}` with `{rightType}`",
                            code: "E2002"
                        ));
                    }
                    type = TypeRegistry.Bool;
                }
                else
                {
                    // Arithmetic operators: must have compatible types
                    if (!IsCompatible(leftType, rightType))
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            $"mismatched types",
                            binary.Span,
                            hint: $"cannot apply operator to `{leftType}` and `{rightType}`",
                            code: "E2002"
                        ));
                        type = leftType; // Use left type as fallback
                    }
                    else
                    {
                        // Result type is the more specific of the two
                        type = UnifyTypes(leftType, rightType);
                    }
                }
                break;

            case AssignmentExpressionNode assignment:
                var varType = LookupVariable(assignment.TargetName, assignment.Span);
                var valueType = CheckExpression(assignment.Value);

                if (!IsCompatible(valueType, varType))
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"mismatched types",
                        assignment.Value.Span,
                        hint: $"expected `{varType}`, found `{valueType}`",
                        code: "E2002"
                    ));
                }

                type = varType;
                break;

            case CallExpressionNode call:
                if (_functions.TryGetValue(call.FunctionName, out var signature))
                {
                    // Check argument count
                    if (call.Arguments.Count != signature.ParameterTypes.Count)
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            $"function `{call.FunctionName}` expects {signature.ParameterTypes.Count} argument(s) but {call.Arguments.Count} were provided",
                            call.Span,
                            hint: $"expected {signature.ParameterTypes.Count} argument(s)",
                            code: "E2011"
                        ));
                    }
                    else
                    {
                        // Check argument types
                        for (int i = 0; i < call.Arguments.Count; i++)
                        {
                            var argType = CheckExpression(call.Arguments[i]);
                            var expectedType = signature.ParameterTypes[i];

                            if (!IsCompatible(argType, expectedType))
                            {
                                _diagnostics.Add(Diagnostic.Error(
                                    $"mismatched types",
                                    call.Arguments[i].Span,
                                    hint: $"expected `{expectedType}`, found `{argType}`",
                                    code: "E2002"
                                ));
                            }
                        }
                    }

                    type = signature.ReturnType;
                }
                else
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"cannot find function `{call.FunctionName}` in this scope",
                        call.Span,
                        hint: "not found in this scope",
                        code: "E2004"
                    ));
                    type = TypeRegistry.I32; // Fallback
                }
                break;

            case IfExpressionNode ifExpr:
                var ifCondType = CheckExpression(ifExpr.Condition);
                if (!ifCondType.Equals(TypeRegistry.Bool))
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"mismatched types",
                        ifExpr.Condition.Span,
                        hint: $"expected `bool`, found `{ifCondType}`",
                        code: "E2002"
                    ));
                }

                var thenType = CheckExpression(ifExpr.ThenBranch);
                var elseType = ifExpr.ElseBranch != null ? CheckExpression(ifExpr.ElseBranch) : TypeRegistry.I32;

                if (!IsCompatible(thenType, elseType))
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"if and else branches have incompatible types",
                        ifExpr.Span,
                        hint: $"`if` branch: `{thenType}`, `else` branch: `{elseType}`",
                        code: "E2002"
                    ));
                }

                type = UnifyTypes(thenType, elseType);
                break;

            case BlockExpressionNode block:
                PushScope();
                Type? lastType = null;

                foreach (var stmt in block.Statements)
                {
                    if (stmt is ExpressionStatementNode exprStmt)
                    {
                        lastType = CheckExpression(exprStmt.Expression);
                    }
                    else
                    {
                        CheckStatement(stmt, null);
                        lastType = null; // Non-expression statements don't contribute to block value
                    }
                }

                if (block.TrailingExpression != null)
                {
                    lastType = CheckExpression(block.TrailingExpression);
                }

                PopScope();
                type = lastType ?? TypeRegistry.I32; // Blocks without value default to i32(0)
                break;

            case RangeExpressionNode range:
                var rangeStartType = CheckExpression(range.Start);
                var rangeEndType = CheckExpression(range.End);

                if (!TypeRegistry.IsIntegerType(rangeStartType) || !TypeRegistry.IsIntegerType(rangeEndType))
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"range bounds must be integers",
                        range.Span,
                        hint: $"found `{rangeStartType}..{rangeEndType}`",
                        code: "E2002"
                    ));
                }

                // Range expressions don't have a concrete type yet (will be iterator type later)
                type = TypeRegistry.I32;
                break;

            case AddressOfExpressionNode addressOf:
                var targetType = CheckExpression(addressOf.Target);

                // Taking address of a value creates a reference type
                type = new ReferenceType(targetType);
                break;

            case DereferenceExpressionNode deref:
                var ptrType = CheckExpression(deref.Target);

                // Dereferencing a reference gives you the inner type
                if (ptrType is ReferenceType refType)
                {
                    type = refType.InnerType;
                }
                else if (ptrType is OptionType optRefType && optRefType.InnerType is ReferenceType innerRef)
                {
                    // Dereferencing &T? requires null check (for now, just return the inner type)
                    type = innerRef.InnerType;

                    // TODO: Add null checking semantics in future milestone
                }
                else
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"cannot dereference non-reference type",
                        deref.Span,
                        hint: $"expected `&T` or `&T?`, found `{ptrType}`",
                        code: "E2012"
                    ));
                    type = TypeRegistry.I32; // Fallback
                }
                break;

            case FieldAccessExpressionNode fieldAccess:
                var targetObjType = CheckExpression(fieldAccess.Target);

                // Check if the target is a struct type
                if (targetObjType is StructType structType)
                {
                    var fieldType = structType.GetFieldType(fieldAccess.FieldName);
                    if (fieldType == null)
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            $"no field `{fieldAccess.FieldName}` on type `{structType.Name}`",
                            fieldAccess.Span,
                            hint: $"struct `{structType.Name}` does not have a field named `{fieldAccess.FieldName}`",
                            code: "E2013"
                        ));
                        type = TypeRegistry.I32; // Fallback
                    }
                    else
                    {
                        type = fieldType;
                    }
                }
                else
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"cannot access field on non-struct type",
                        fieldAccess.Span,
                        hint: $"expected struct type, found `{targetObjType}`",
                        code: "E2013"
                    ));
                    type = TypeRegistry.I32; // Fallback
                }
                break;

            case StructConstructionExpressionNode structCtor:
                var ctorType = ResolveTypeNode(structCtor.TypeName);
                if (ctorType == null)
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"cannot find type `{(structCtor.TypeName as NamedTypeNode)?.Name ?? "unknown"}`",
                        structCtor.TypeName.Span,
                        hint: "not found in this scope",
                        code: "E2003"
                    ));
                    type = TypeRegistry.I32; // Fallback
                }
                else if (ctorType is not StructType structCtorType)
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"type `{ctorType.Name}` is not a struct",
                        structCtor.TypeName.Span,
                        hint: "cannot construct non-struct type",
                        code: "E2014"
                    ));
                    type = TypeRegistry.I32; // Fallback
                }
                else
                {
                    // Check that all fields are provided and have correct types
                    var providedFields = new HashSet<string>();
                    foreach (var (fieldName, fieldValue) in structCtor.Fields)
                    {
                        providedFields.Add(fieldName);
                        var fieldType = structCtorType.GetFieldType(fieldName);
                        if (fieldType == null)
                        {
                            _diagnostics.Add(Diagnostic.Error(
                                $"struct `{structCtorType.Name}` does not have a field named `{fieldName}`",
                                fieldValue.Span,
                                hint: $"unknown field",
                                code: "E2013"
                            ));
                        }
                        else
                        {
                            var fieldValueType = CheckExpression(fieldValue);
                            if (!IsCompatible(fieldValueType, fieldType))
                            {
                                _diagnostics.Add(Diagnostic.Error(
                                    $"mismatched types for field `{fieldName}`",
                                    fieldValue.Span,
                                    hint: $"expected `{fieldType}`, found `{fieldValueType}`",
                                    code: "E2002"
                                ));
                            }
                        }
                    }

                    // Check that all required fields are provided
                    foreach (var (fieldName, _) in structCtorType.Fields)
                    {
                        if (!providedFields.Contains(fieldName))
                        {
                            _diagnostics.Add(Diagnostic.Error(
                                $"missing field `{fieldName}` in struct construction",
                                structCtor.Span,
                                hint: $"struct `{structCtorType.Name}` requires field `{fieldName}`",
                                code: "E2015"
                            ));
                        }
                    }

                    type = structCtorType;
                }
                break;

            case ArrayLiteralExpressionNode arrayLiteral:
                if (arrayLiteral.IsRepeatSyntax)
                {
                    // Repeat syntax: [value; count]
                    var repeatValueType = CheckExpression(arrayLiteral.RepeatValue!);
                    type = new ArrayType(repeatValueType, arrayLiteral.RepeatCount!.Value);
                }
                else if (arrayLiteral.Elements!.Count == 0)
                {
                    // Empty array [] - error: cannot infer type
                    _diagnostics.Add(Diagnostic.Error(
                        "cannot infer type of empty array literal",
                        arrayLiteral.Span,
                        hint: "consider adding type annotation",
                        code: "E2016"
                    ));
                    type = new ArrayType(TypeRegistry.I32, 0); // Fallback
                }
                else
                {
                    // Regular array literal: [elem1, elem2, ...]
                    // Check all elements have compatible types
                    var firstElemType = CheckExpression(arrayLiteral.Elements[0]);
                    var unifiedType = firstElemType;

                    for (int i = 1; i < arrayLiteral.Elements.Count; i++)
                    {
                        var elemType = CheckExpression(arrayLiteral.Elements[i]);
                        if (!IsCompatible(elemType, unifiedType))
                        {
                            _diagnostics.Add(Diagnostic.Error(
                                "array elements have incompatible types",
                                arrayLiteral.Elements[i].Span,
                                hint: $"expected `{unifiedType}`, found `{elemType}`",
                                code: "E2002"
                            ));
                        }
                        else
                        {
                            unifiedType = UnifyTypes(unifiedType, elemType);
                        }
                    }

                    type = new ArrayType(unifiedType, arrayLiteral.Elements.Count);
                }
                break;

            case IndexExpressionNode indexExpr:
                var baseType = CheckExpression(indexExpr.Base);
                var indexType = CheckExpression(indexExpr.Index);

                // Check that index is an integer type
                if (!TypeRegistry.IsIntegerType(indexType))
                {
                    _diagnostics.Add(Diagnostic.Error(
                        "array index must be an integer",
                        indexExpr.Index.Span,
                        hint: $"found `{indexType}`",
                        code: "E2017"
                    ));
                }

                // Check that base is an array or slice
                if (baseType is ArrayType arrayType)
                {
                    type = arrayType.ElementType;
                }
                else if (baseType is SliceType sliceType)
                {
                    type = sliceType.ElementType;
                }
                else
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"cannot index into value of type `{baseType}`",
                        indexExpr.Base.Span,
                        hint: "only arrays and slices can be indexed",
                        code: "E2018"
                    ));
                    type = TypeRegistry.I32; // Fallback
                }
                break;

            default:
                throw new System.Exception($"Unknown expression type: {expression.GetType().Name}");
        }

        _typeMap[expression] = type;
        return type;
    }

    private Type? ResolveTypeNode(TypeNode? typeNode)
    {
        if (typeNode == null)
            return null;

        switch (typeNode)
        {
            case NamedTypeNode namedType:
            {
                // First check built-in types
                var type = TypeRegistry.GetTypeByName(namedType.Name);
                if (type != null)
                {
                    return type;
                }

                // Then check struct types
                if (_structs.TryGetValue(namedType.Name, out var structType))
                {
                    return structType;
                }

                // Type not found
                _diagnostics.Add(Diagnostic.Error(
                    $"cannot find type `{namedType.Name}` in this scope",
                    namedType.Span,
                    hint: "not found in this scope",
                    code: "E2003"
                ));
                return null;
            }

            case ReferenceTypeNode referenceType:
            {
                var innerType = ResolveTypeNode(referenceType.InnerType);
                if (innerType == null)
                {
                    return null; // Error already reported
                }
                return new ReferenceType(innerType);
            }

            case NullableTypeNode nullableType:
            {
                var innerType = ResolveTypeNode(nullableType.InnerType);
                if (innerType == null)
                {
                    return null; // Error already reported
                }
                return new OptionType(innerType);
            }

            case GenericTypeNode genericType:
            {
                // Resolve all type arguments
                var typeArgs = new List<Type>();
                foreach (var argNode in genericType.TypeArguments)
                {
                    var argType = ResolveTypeNode(argNode);
                    if (argType == null)
                    {
                        return null; // Error already reported
                    }
                    typeArgs.Add(argType);
                }

                return new GenericType(genericType.Name, typeArgs);
            }

            case ArrayTypeNode arrayType:
            {
                var elementType = ResolveTypeNode(arrayType.ElementType);
                if (elementType == null)
                {
                    return null; // Error already reported
                }
                return new ArrayType(elementType, arrayType.Length);
            }

            case SliceTypeNode sliceType:
            {
                var elementType = ResolveTypeNode(sliceType.ElementType);
                if (elementType == null)
                {
                    return null; // Error already reported
                }
                return new SliceType(elementType);
            }

            default:
                return null;
        }
    }

    private bool IsCompatible(Type source, Type target)
    {
        // Same type is always compatible
        if (source.Equals(target))
            return true;

        // comptime_int is compatible with any integer type (bidirectional)
        if (source is ComptimeIntType && TypeRegistry.IsIntegerType(target))
            return true;
        if (target is ComptimeIntType && TypeRegistry.IsIntegerType(source))
            return true;

        // Two comptime_ints are compatible
        if (source is ComptimeIntType && target is ComptimeIntType)
            return true;

        // comptime_float is compatible with any float type (when we add them)
        if (source is ComptimeFloatType || target is ComptimeFloatType)
            return true; // For now, always allow

        // Array→slice coercion: [T; N] can be used where T[] is expected
        if (source is ArrayType arrayType && target is SliceType sliceType)
        {
            return IsCompatible(arrayType.ElementType, sliceType.ElementType);
        }

        // Array type compatibility: check element types and lengths
        if (source is ArrayType srcArray && target is ArrayType tgtArray)
        {
            return srcArray.Length == tgtArray.Length && IsCompatible(srcArray.ElementType, tgtArray.ElementType);
        }

        return false;
    }

    private Type UnifyTypes(Type a, Type b)
    {
        if (a.Equals(b))
            return a;

        // If one is comptime and the other is concrete, use the concrete type
        if (a is ComptimeIntType && TypeRegistry.IsIntegerType(b))
            return b;
        if (b is ComptimeIntType && TypeRegistry.IsIntegerType(a))
            return a;

        // Default to the first type
        return a;
    }

    private void PushScope()
    {
        _scopes.Push(new Dictionary<string, Type>());
    }

    private void PopScope()
    {
        _scopes.Pop();
    }

    private void DeclareVariable(string name, Type type, SourceSpan span)
    {
        var currentScope = _scopes.Peek();
        if (currentScope.ContainsKey(name))
        {
            _diagnostics.Add(Diagnostic.Error(
                $"variable `{name}` is already declared",
                span,
                hint: "variable redeclaration",
                code: "E2005"
            ));
        }
        else
        {
            currentScope[name] = type;
        }
    }

    private Type LookupVariable(string name, SourceSpan span)
    {
        foreach (var scope in _scopes)
        {
            if (scope.TryGetValue(name, out var type))
            {
                return type;
            }
        }

        _diagnostics.Add(Diagnostic.Error(
            $"cannot find value `{name}` in this scope",
            span,
            hint: "not found in this scope",
            code: "E2004"
        ));

        return TypeRegistry.I32; // Fallback to prevent cascading errors
    }
}

public class FunctionSignature
{
    public string Name { get; }
    public IReadOnlyList<Type> ParameterTypes { get; }
    public Type ReturnType { get; }

    public FunctionSignature(string name, IReadOnlyList<Type> parameterTypes, Type returnType)
    {
        Name = name;
        ParameterTypes = parameterTypes;
        ReturnType = returnType;
    }
}
