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

    // Maps function names to their signatures
    private readonly Dictionary<string, FunctionSignature> _functions = new();

    // Maps variable names to their types (per scope)
    private readonly Stack<Dictionary<string, FType>> _scopes = new();

    // Maps struct names to their types
    private readonly Dictionary<string, StructType> _structs = new();

    // Maps AST nodes to their inferred/checked types
    private readonly Dictionary<AstNode, FType> _typeMap = new();

    public TypeSolver(Compilation compilation)
    {
        _compilation = compilation;
        PushScope(); // Global scope
    }

    public IReadOnlyList<Diagnostic> Diagnostics => _diagnostics;

    /// <summary>
    /// Gets the resolved type for an AST node.
    /// Returns null if the node hasn't been type-checked yet.
    /// </summary>
    public FType? GetType(AstNode node)
    {
        return _typeMap.GetValueOrDefault(node);
    }

    /// <summary>
    /// Resolves a type name to a Type object.
    /// Checks built-in types first, then struct types.
    /// Returns null if type not found.
    /// </summary>
    public FType? ResolveTypeName(string typeName)
    {
        // Check built-in types first
        var builtInType = TypeRegistry.GetTypeByName(typeName);
        if (builtInType != null)
            return builtInType;

        // Check struct types
        if (_structs.TryGetValue(typeName, out var structType))
            return structType;

        return null;
    }

    /// <summary>
    /// Collects function signatures from a module (first pass).
    /// </summary>
    public void CollectFunctionSignatures(ModuleNode module)
    {
        foreach (var function in module.Functions)
        {
            // Export only public or foreign functions in the global pass
            var mods = function.Modifiers;
            var isPublic = (mods & FunctionModifiers.Public) != 0;
            var isForeign = (mods & FunctionModifiers.Foreign) != 0;
            if (!(isPublic || isForeign))
                continue;

            var returnType = ResolveTypeNode(function.ReturnType) ?? TypeRegistry.I32;

            // Collect parameter types
            var parameterTypes = new List<FType>();
            foreach (var param in function.Parameters)
            {
                var paramType = ResolveTypeNode(param.Type);
                if (paramType == null)
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"cannot find type `{(param.Type as NamedTypeNode)?.Name ?? "unknown"}` in this scope",
                        param.Type.Span,
                        "not found in this scope",
                        "E2003"
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
            var fields = new List<(string, FType)>();

            foreach (var field in structDecl.Fields)
            {
                var fieldType = ResolveTypeNode(field.Type);
                if (fieldType == null)
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"cannot find type `{(field.Type as NamedTypeNode)?.Name ?? "unknown"}` in this scope",
                        field.Type.Span,
                        "not found in this scope",
                        "E2003"
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
        // Temporarily register this module's private functions for intra-module lookup
        var added = new List<string>();
        foreach (var function in module.Functions)
        {
            var mods = function.Modifiers;
            var isPublic = (mods & FunctionModifiers.Public) != 0;
            var isForeign = (mods & FunctionModifiers.Foreign) != 0;
            if (isPublic || isForeign)
                continue; // already registered in global pass

            var returnType = ResolveTypeNode(function.ReturnType) ?? TypeRegistry.I32;
            var parameterTypes = new List<FType>();
            foreach (var param in function.Parameters)
            {
                var pt = ResolveTypeNode(param.Type) ?? TypeRegistry.I32;
                parameterTypes.Add(pt);
            }
            _functions[function.Name] = new FunctionSignature(function.Name, parameterTypes, returnType);
            added.Add(function.Name);
        }

        foreach (var function in module.Functions)
            // Skip foreign functions - they have no body
            if ((function.Modifiers & FunctionModifiers.Foreign) == 0)
                CheckFunction(function);

        // Remove private registrations to avoid leaking across modules
        foreach (var name in added)
            _functions.Remove(name);
    }

    private void CheckFunction(FunctionDeclarationNode function)
    {
        PushScope(); // Function scope

        // Add parameters to scope
        foreach (var param in function.Parameters)
        {
            var paramType = ResolveTypeNode(param.Type);
            if (paramType != null) DeclareVariable(param.Name, paramType, param.Span);
        }

        var expectedReturnType = ResolveTypeNode(function.ReturnType) ?? TypeRegistry.I32;

        // Check function body
        foreach (var statement in function.Body) CheckStatement(statement, expectedReturnType);

        PopScope();
    }

    private void CheckStatement(StatementNode statement, FType? expectedReturnType)
    {
        switch (statement)
        {
            case ReturnStatementNode returnStmt:
                var exprType = CheckExpression(returnStmt.Expression);
                if (expectedReturnType != null)
                    if (!IsCompatible(exprType, expectedReturnType))
                        _diagnostics.Add(Diagnostic.Error(
                            "mismatched types",
                            returnStmt.Span,
                            $"expected `{expectedReturnType}`, found `{exprType}`",
                            "E2002"
                        ));

                break;

            case VariableDeclarationNode varDecl:
                var initType = CheckExpression(varDecl.Initializer);
                var declaredType = ResolveTypeNode(varDecl.Type);

                if (declaredType != null)
                {
                    // User provided explicit type - check compatibility
                    if (!IsCompatible(initType, declaredType))
                        _diagnostics.Add(Diagnostic.Error(
                            "mismatched types",
                            varDecl.Initializer.Span,
                            $"expected `{declaredType}`, found `{initType}`",
                            "E2002"
                        ));

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
                            "cannot infer type",
                            varDecl.Span,
                            $"type annotations needed: variable has comptime type `{initType}`",
                            "E2001"
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
                        _diagnostics.Add(Diagnostic.Error(
                            "range bounds must be integers",
                            forLoop.IterableExpression.Span,
                            $"found `{startType}..{endType}`",
                            "E2002"
                        ));

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

            case DeferStatementNode deferStmt:
                // Type-check the deferred expression
                CheckExpression(deferStmt.Expression);
                break;

            default:
                throw new Exception($"Unknown statement type: {statement.GetType().Name}");
        }
    }

    private FType CheckExpression(ExpressionNode expression)
    {
        FType type;

        switch (expression)
        {
            case IntegerLiteralNode:
                // Integer literals are comptime_int
                type = TypeRegistry.ComptimeInt;
                break;

            case BooleanLiteralNode:
                type = TypeRegistry.Bool;
                break;

            case StringLiteralNode:
                // String literals have type String
                if (_structs.TryGetValue("String", out var stringType))
                {
                    type = stringType;
                }
                else
                {
                    _diagnostics.Add(Diagnostic.Error(
                        "String type not found",
                        expression.Span,
                        "make sure to import core/string",
                        "E2013"
                    ));
                    type = TypeRegistry.I32; // Fallback
                }

                break;

            case IdentifierExpressionNode identifier:
                type = LookupVariable(identifier.Name, identifier.Span);
                break;

            case BinaryExpressionNode binary:
                var leftType = CheckExpression(binary.Left);
                var rightType = CheckExpression(binary.Right);

                // Check operator compatibility
                if (binary.Operator >= BinaryOperatorKind.Equal &&
                    binary.Operator <= BinaryOperatorKind.GreaterThanOrEqual)
                {
                    // Comparison operators: return bool
                    if (!IsCompatible(leftType, rightType))
                        _diagnostics.Add(Diagnostic.Error(
                            "mismatched types in comparison",
                            binary.Span,
                            $"cannot compare `{leftType}` with `{rightType}`",
                            "E2002"
                        ));
                    type = TypeRegistry.Bool;
                }
                else
                {
                    // Arithmetic operators: must have compatible types
                    if (!IsCompatible(leftType, rightType))
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            "mismatched types",
                            binary.Span,
                            $"cannot apply operator to `{leftType}` and `{rightType}`",
                            "E2002"
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
                    _diagnostics.Add(Diagnostic.Error(
                        "mismatched types",
                        assignment.Value.Span,
                        $"expected `{varType}`, found `{valueType}`",
                        "E2002"
                    ));

                type = varType;
                break;

            case CallExpressionNode call:
                // Handle compiler intrinsics (size_of, align_of)
                if (call.FunctionName == "size_of" || call.FunctionName == "align_of")
                {
                    // Intrinsics always return usize
                    type = TypeRegistry.USize;
                    // Don't type-check arguments - they'll be validated during FIR lowering
                    break;
                }

                if (_functions.TryGetValue(call.FunctionName, out var signature))
                {
                    // Check argument count
                    if (call.Arguments.Count != signature.ParameterTypes.Count)
                        _diagnostics.Add(Diagnostic.Error(
                            $"function `{call.FunctionName}` expects {signature.ParameterTypes.Count} argument(s) but {call.Arguments.Count} were provided",
                            call.Span,
                            $"expected {signature.ParameterTypes.Count} argument(s)",
                            "E2011"
                        ));
                    else
                        // Check argument types
                        for (var i = 0; i < call.Arguments.Count; i++)
                        {
                            var argType = CheckExpression(call.Arguments[i]);
                            var expectedType = signature.ParameterTypes[i];

                            if (!IsCompatible(argType, expectedType))
                                _diagnostics.Add(Diagnostic.Error(
                                    "mismatched types",
                                    call.Arguments[i].Span,
                                    $"expected `{expectedType}`, found `{argType}`",
                                    "E2002"
                                ));
                        }

                    type = signature.ReturnType;
                }
                else
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"cannot find function `{call.FunctionName}` in this scope",
                        call.Span,
                        "not found in this scope",
                        "E2004"
                    ));
                    type = TypeRegistry.I32; // Fallback
                }

                break;

            case IfExpressionNode ifExpr:
                var ifCondType = CheckExpression(ifExpr.Condition);
                if (!ifCondType.Equals(TypeRegistry.Bool))
                    _diagnostics.Add(Diagnostic.Error(
                        "mismatched types",
                        ifExpr.Condition.Span,
                        $"expected `bool`, found `{ifCondType}`",
                        "E2002"
                    ));

                var thenType = CheckExpression(ifExpr.ThenBranch);
                var elseType = ifExpr.ElseBranch != null ? CheckExpression(ifExpr.ElseBranch) : TypeRegistry.I32;

                if (!IsCompatible(thenType, elseType))
                    _diagnostics.Add(Diagnostic.Error(
                        "if and else branches have incompatible types",
                        ifExpr.Span,
                        $"`if` branch: `{thenType}`, `else` branch: `{elseType}`",
                        "E2002"
                    ));

                type = UnifyTypes(thenType, elseType);
                break;

            case BlockExpressionNode block:
                PushScope();
                FType? lastType = null;

                foreach (var stmt in block.Statements)
                    if (stmt is ExpressionStatementNode exprStmt)
                    {
                        lastType = CheckExpression(exprStmt.Expression);
                    }
                    else
                    {
                        CheckStatement(stmt, null);
                        lastType = null; // Non-expression statements don't contribute to block value
                    }

                if (block.TrailingExpression != null) lastType = CheckExpression(block.TrailingExpression);

                PopScope();
                type = lastType ?? TypeRegistry.I32; // Blocks without value default to i32(0)
                break;

            case RangeExpressionNode range:
                var rangeStartType = CheckExpression(range.Start);
                var rangeEndType = CheckExpression(range.End);

                if (!TypeRegistry.IsIntegerType(rangeStartType) || !TypeRegistry.IsIntegerType(rangeEndType))
                    _diagnostics.Add(Diagnostic.Error(
                        "range bounds must be integers",
                        range.Span,
                        $"found `{rangeStartType}..{rangeEndType}`",
                        "E2002"
                    ));

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
                        "cannot dereference non-reference type",
                        deref.Span,
                        $"expected `&T` or `&T?`, found `{ptrType}`",
                        "E2012"
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
                            $"struct `{structType.Name}` does not have a field named `{fieldAccess.FieldName}`",
                            "E2013"
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
                        "cannot access field on non-struct type",
                        fieldAccess.Span,
                        $"expected struct type, found `{targetObjType}`",
                        "E2013"
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
                        "not found in this scope",
                        "E2003"
                    ));
                    type = TypeRegistry.I32; // Fallback
                }
                else if (ctorType is not StructType structCtorType)
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"type `{ctorType.Name}` is not a struct",
                        structCtor.TypeName.Span,
                        "cannot construct non-struct type",
                        "E2014"
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
                                "unknown field",
                                "E2013"
                            ));
                        }
                        else
                        {
                            var fieldValueType = CheckExpression(fieldValue);
                            if (!IsCompatible(fieldValueType, fieldType))
                                _diagnostics.Add(Diagnostic.Error(
                                    $"mismatched types for field `{fieldName}`",
                                    fieldValue.Span,
                                    $"expected `{fieldType}`, found `{fieldValueType}`",
                                    "E2002"
                                ));
                        }
                    }

                    // Check that all required fields are provided
                    foreach (var (fieldName, _) in structCtorType.Fields)
                        if (!providedFields.Contains(fieldName))
                            _diagnostics.Add(Diagnostic.Error(
                                $"missing field `{fieldName}` in struct construction",
                                structCtor.Span,
                                $"struct `{structCtorType.Name}` requires field `{fieldName}`",
                                "E2015"
                            ));

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
                        "consider adding type annotation",
                        "E2016"
                    ));
                    type = new ArrayType(TypeRegistry.I32, 0); // Fallback
                }
                else
                {
                    // Regular array literal: [elem1, elem2, ...]
                    // Check all elements have compatible types
                    var firstElemType = CheckExpression(arrayLiteral.Elements[0]);
                    var unifiedType = firstElemType;

                    for (var i = 1; i < arrayLiteral.Elements.Count; i++)
                    {
                        var elemType = CheckExpression(arrayLiteral.Elements[i]);
                        if (!IsCompatible(elemType, unifiedType))
                            _diagnostics.Add(Diagnostic.Error(
                                "array elements have incompatible types",
                                arrayLiteral.Elements[i].Span,
                                $"expected `{unifiedType}`, found `{elemType}`",
                                "E2002"
                            ));
                        else
                            unifiedType = UnifyTypes(unifiedType, elemType);
                    }

                    type = new ArrayType(unifiedType, arrayLiteral.Elements.Count);
                }

                break;

            case IndexExpressionNode indexExpr:
                var baseType = CheckExpression(indexExpr.Base);
                var indexType = CheckExpression(indexExpr.Index);

                // Check that index is an integer type
                if (!TypeRegistry.IsIntegerType(indexType))
                    _diagnostics.Add(Diagnostic.Error(
                        "array index must be an integer",
                        indexExpr.Index.Span,
                        $"found `{indexType}`",
                        "E2017"
                    ));

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
                        "only arrays and slices can be indexed",
                        "E2018"
                    ));
                    type = TypeRegistry.I32; // Fallback
                }

                break;

            case CastExpressionNode cast:
                var srcType = CheckExpression(cast.Expression);
                var dstType = ResolveTypeNode(cast.TargetType) ?? TypeRegistry.I32;

                if (!CanExplicitCast(srcType, dstType))
                    _diagnostics.Add(Diagnostic.Error(
                        "invalid cast",
                        cast.Span,
                        $"cannot cast `{srcType}` to `{dstType}`",
                        "E2020"
                    ));

                type = dstType;
                break;

            default:
                throw new Exception($"Unknown expression type: {expression.GetType().Name}");
        }

        _typeMap[expression] = type;
        return type;
    }

    private bool CanExplicitCast(FType source, FType target)
    {
        if (source.Equals(target)) return true;

        // Integer ↔ integer (includes usize/isize)
        if (TypeRegistry.IsIntegerType(source) && TypeRegistry.IsIntegerType(target))
            return true;

        // Reference ↔ reference (allow for now; binary-compatibility checks deferred)
        if (source is ReferenceType && target is ReferenceType)
            return true;

        // Nullable reference to reference
        if (source is OptionType opt && opt.InnerType is ReferenceType && target is ReferenceType)
            return true;

        // Reference ↔ usize/isize
        if (source is ReferenceType && (target.Equals(TypeRegistry.USize) || target.Equals(TypeRegistry.ISize)))
            return true;
        if ((source.Equals(TypeRegistry.USize) || source.Equals(TypeRegistry.ISize)) && target is ReferenceType)
            return true;

        // String ↔ u8[] (blessed binary-compat)
        if (source is StructType s && s.Name == "String" && target is SliceType t && t.ElementType.Equals(TypeRegistry.U8))
            return true;
        if (target is StructType s2 && s2.Name == "String" && source is SliceType t2 && t2.ElementType.Equals(TypeRegistry.U8))
            return true;

        return false;
    }

    private FType? ResolveTypeNode(TypeNode? typeNode)
    {
        if (typeNode == null)
            return null;

        switch (typeNode)
        {
            case NamedTypeNode namedType:
            {
                // First check built-in types
                var type = TypeRegistry.GetTypeByName(namedType.Name);
                if (type != null) return type;

                // Then check struct types
                if (_structs.TryGetValue(namedType.Name, out var structType)) return structType;

                // Type not found
                _diagnostics.Add(Diagnostic.Error(
                    $"cannot find type `{namedType.Name}` in this scope",
                    namedType.Span,
                    "not found in this scope",
                    "E2003"
                ));
                return null;
            }

            case ReferenceTypeNode referenceType:
            {
                var innerType = ResolveTypeNode(referenceType.InnerType);
                if (innerType == null) return null; // Error already reported
                return new ReferenceType(innerType);
            }

            case NullableTypeNode nullableType:
            {
                var innerType = ResolveTypeNode(nullableType.InnerType);
                if (innerType == null) return null; // Error already reported
                return new OptionType(innerType);
            }

            case GenericTypeNode genericType:
            {
                // Resolve all type arguments
                var typeArgs = new List<FType>();
                foreach (var argNode in genericType.TypeArguments)
                {
                    var argType = ResolveTypeNode(argNode);
                    if (argType == null) return null; // Error already reported
                    typeArgs.Add(argType);
                }

                return new GenericType(genericType.Name, typeArgs);
            }

            case ArrayTypeNode arrayType:
            {
                var elementType = ResolveTypeNode(arrayType.ElementType);
                if (elementType == null) return null; // Error already reported
                return new ArrayType(elementType, arrayType.Length);
            }

            case SliceTypeNode sliceType:
            {
                var elementType = ResolveTypeNode(sliceType.ElementType);
                if (elementType == null) return null; // Error already reported
                return new SliceType(elementType);
            }

            default:
                return null;
        }
    }

    private bool IsCompatible(FType source, FType target)
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

        // Implicit integer-to-integer conversion
        if (TypeRegistry.IsIntegerType(source) && TypeRegistry.IsIntegerType(target))
            return true;

        // Array→slice coercion: [T; N] can be used where T[] is expected
        if (source is ArrayType arrayType && target is SliceType sliceType)
            return IsCompatible(arrayType.ElementType, sliceType.ElementType);

        // Array type compatibility: check element types and lengths
        if (source is ArrayType srcArray && target is ArrayType tgtArray)
            return srcArray.Length == tgtArray.Length && IsCompatible(srcArray.ElementType, tgtArray.ElementType);

        return false;
    }

    private FType UnifyTypes(FType a, FType b)
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
        _scopes.Push(new Dictionary<string, FType>());
    }

    private void PopScope()
    {
        _scopes.Pop();
    }

    private void DeclareVariable(string name, FType type, SourceSpan span)
    {
        var currentScope = _scopes.Peek();
        if (currentScope.ContainsKey(name))
            _diagnostics.Add(Diagnostic.Error(
                $"variable `{name}` is already declared",
                span,
                "variable redeclaration",
                "E2005"
            ));
        else
            currentScope[name] = type;
    }

    private FType LookupVariable(string name, SourceSpan span)
    {
        foreach (var scope in _scopes)
            if (scope.TryGetValue(name, out var type))
                return type;

        _diagnostics.Add(Diagnostic.Error(
            $"cannot find value `{name}` in this scope",
            span,
            "not found in this scope",
            "E2004"
        ));

        return TypeRegistry.I32; // Fallback to prevent cascading errors
    }
}

public class FunctionSignature
{
    public FunctionSignature(string name, IReadOnlyList<FType> parameterTypes, FType returnType)
    {
        Name = name;
        ParameterTypes = parameterTypes;
        ReturnType = returnType;
    }

    public string Name { get; }
    public IReadOnlyList<FType> ParameterTypes { get; }
    public FType ReturnType { get; }
}
