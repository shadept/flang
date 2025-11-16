using FLang.Core;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;
using FLang.Frontend.Ast.Types;
using FLang.IR;
using FLang.IR.Instructions;

namespace FLang.Semantics;

public class AstLowering
{
    private readonly List<BasicBlock> _allBlocks = new();
    private readonly Compilation _compilation;
    private readonly List<Diagnostic> _diagnostics = new();
    private readonly Dictionary<string, Value> _locals = new();
    private readonly Stack<LoopContext> _loopStack = new();
    private readonly Stack<List<ExpressionNode>> _deferStack = new();
    private readonly TypeSolver _typeSolver;
    private int _blockCounter;
    private BasicBlock _currentBlock = null!;
    private int _tempCounter;

    private AstLowering(Compilation compilation, TypeSolver typeSolver)
    {
        _compilation = compilation;
        _typeSolver = typeSolver;
    }

    public IReadOnlyList<Diagnostic> Diagnostics => _diagnostics;

    public static (Function Function, IReadOnlyList<Diagnostic> Diagnostics) Lower(FunctionDeclarationNode functionNode,
        Compilation compilation, TypeSolver typeSolver)
    {
        var lowering = new AstLowering(compilation, typeSolver);
        var function = lowering.LowerFunction(functionNode);
        return (function, lowering.Diagnostics);
    }

    private Function LowerFunction(FunctionDeclarationNode functionNode)
    {
        var isForeign = (functionNode.Modifiers & FunctionModifiers.Foreign) != 0;

        // Prepare return type (default to i32)
        var retTypeNode = functionNode.ReturnType;
        var retType = retTypeNode != null ? ResolveTypeFromNode(retTypeNode) : TypeRegistry.I32;

        // Resolve parameter types first
        var resolvedParamTypes = new List<FType>();
        foreach (var p in functionNode.Parameters)
            resolvedParamTypes.Add(ResolveTypeFromNode(p.Type));

        // Keep base name in IR; backend will mangle
        var function = new Function(functionNode.Name) { IsForeign = isForeign, ReturnType = retType };

        // Add parameters to function
        for (var i = 0; i < functionNode.Parameters.Count; i++)
        {
            var param = functionNode.Parameters[i];
            var paramType = resolvedParamTypes[i];
            function.Parameters.Add(new FunctionParameter(param.Name, paramType));

            // Add parameter to locals with type so it can be referenced in the function body
            var localParam = new LocalValue(param.Name) { Type = paramType };
            _locals[param.Name] = localParam;
        }

        // Foreign functions have no body
        if (isForeign) return function;

        _currentBlock = CreateBlock("entry");
        function.BasicBlocks.Add(_currentBlock);

        // Push a new defer scope for this function
        _deferStack.Push(new List<ExpressionNode>());

        foreach (var statement in functionNode.Body) LowerStatement(statement);

        // Emit deferred statements at function end (if no explicit return)
        EmitDeferredStatements();

        // Pop the defer scope
        _deferStack.Pop();

        // Add all created blocks to function
        foreach (var block in _allBlocks)
            if (!function.BasicBlocks.Contains(block))
                function.BasicBlocks.Add(block);

        return function;
    }

    private FType ResolveTypeFromNode(TypeNode typeNode)
    {
        switch (typeNode)
        {
            case NamedTypeNode namedType:
            {
                // Prefer built-ins, then resolver for user/stdlib types (e.g., String)
                var type = TypeRegistry.GetTypeByName(namedType.Name) ?? _typeSolver.ResolveTypeName(namedType.Name);
                if (type != null) return type;
                break;
            }

            case ReferenceTypeNode referenceType:
            {
                var innerType = ResolveTypeFromNode(referenceType.InnerType);
                return new ReferenceType(innerType);
            }

            case NullableTypeNode nullableType:
            {
                var innerType = ResolveTypeFromNode(nullableType.InnerType);
                return new OptionType(innerType);
            }

            case GenericTypeNode genericType:
            {
                var typeArgs = new List<FType>();
                foreach (var argNode in genericType.TypeArguments) typeArgs.Add(ResolveTypeFromNode(argNode));
                return new GenericType(genericType.Name, typeArgs);
            }

            case ArrayTypeNode arrayType:
            {
                var elementType = ResolveTypeFromNode(arrayType.ElementType);
                return new ArrayType(elementType, arrayType.Length);
            }

            case SliceTypeNode sliceType:
            {
                var elementType = ResolveTypeFromNode(sliceType.ElementType);
                return TypeRegistry.GetSliceStruct(elementType);
            }
        }

        // Fallback to i32
        return TypeRegistry.I32;
    }

    private BasicBlock CreateBlock(string hint)
    {
        var block = new BasicBlock($"{hint}_{_blockCounter++}");
        _allBlocks.Add(block);
        return block;
    }

    private void LowerStatement(StatementNode statement)
    {
        switch (statement)
        {
            case VariableDeclarationNode varDecl:
                {
                    // Establish variable type from annotation or initializer
                    FType varType = TypeRegistry.I32;
                    if (varDecl.Type != null)
                        varType = ResolveTypeFromNode(varDecl.Type);
                    else if (varDecl.Initializer != null)
                        varType = _typeSolver.GetType(varDecl.Initializer) ?? TypeRegistry.I32;

                    var local = new LocalValue(varDecl.Name) { Type = varType };
                    _locals[varDecl.Name] = local;

                    if (varDecl.Initializer != null)
                    {
                        var value = LowerExpression(varDecl.Initializer);
                        _currentBlock.Instructions.Add(new StoreInstruction(varDecl.Name, value, local));
                    }
                    break;
                }

            case ReturnStatementNode returnStmt:
                var returnValue = LowerExpression(returnStmt.Expression);
                // Execute deferred statements before returning (in LIFO order)
                EmitDeferredStatements();
                _currentBlock.Instructions.Add(new ReturnInstruction(returnValue));
                break;

            case BreakStatementNode breakStmt:
                if (_loopStack.Count == 0)
                    _diagnostics.Add(Diagnostic.Error(
                        "`break` statement outside of loop",
                        breakStmt.Span,
                        "`break` can only be used inside a loop",
                        "E2006"
                    ));
                else
                    _currentBlock.Instructions.Add(new JumpInstruction(_loopStack.Peek().BreakTarget));
                break;

            case ContinueStatementNode continueStmt:
                if (_loopStack.Count == 0)
                    _diagnostics.Add(Diagnostic.Error(
                        "`continue` statement outside of loop",
                        continueStmt.Span,
                        "`continue` can only be used inside a loop",
                        "E2007"
                    ));
                else
                    _currentBlock.Instructions.Add(new JumpInstruction(_loopStack.Peek().ContinueTarget));
                break;

            case ForLoopNode forLoop:
                LowerForLoop(forLoop);
                break;

            case DeferStatementNode deferStmt:
                // Add the deferred expression to the current scope's defer list
                if (_deferStack.Count > 0)
                    _deferStack.Peek().Add(deferStmt.Expression);
                break;

            case ExpressionStatementNode exprStmt:
                // Just evaluate the expression for its side effects (e.g., assignment)
                LowerExpression(exprStmt.Expression);
                break;
        }
    }

    /// <summary>
    /// Emits all deferred statements from the current scope in LIFO order.
    /// Called before returns and at the end of scopes.
    /// </summary>
    private void EmitDeferredStatements()
    {
        if (_deferStack.Count == 0) return;

        var deferredExpressions = _deferStack.Peek();
        // Execute in LIFO order (reverse)
        for (var i = deferredExpressions.Count - 1; i >= 0; i--)
        {
            LowerExpression(deferredExpressions[i]);
        }
    }

    private Value LowerExpression(ExpressionNode expression)
    {
        switch (expression)
        {
            case IntegerLiteralNode intLiteral:
                return new ConstantValue(intLiteral.Value) { Type = _typeSolver.GetType(expression) ?? TypeRegistry.ComptimeInt };

            case BooleanLiteralNode boolLiteral:
                // In C, booleans are represented as integers (0 = false, 1 = true)
                return new ConstantValue(boolLiteral.Value ? 1 : 0) { Type = _typeSolver.GetType(expression) ?? TypeRegistry.Bool };

            case StringLiteralNode stringLiteral:
                // String literals are represented as global constants; ensure unique name per compilation
                var sid = _compilation.AllocateStringId();
                var stringName = $"str_{sid}";
                return new StringConstantValue(stringLiteral.Value, stringName) { Type = _typeSolver.GetType(expression) };

            case IdentifierExpressionNode identifier:
                if (_locals.TryGetValue(identifier.Name, out var local)) return local;
                _diagnostics.Add(Diagnostic.Error(
                    $"cannot find value `{identifier.Name}` in this scope",
                    identifier.Span,
                    "not found in this scope",
                    "E2004"
                ));
                // Return a dummy value to avoid cascading errors
                return new ConstantValue(0);

            case BinaryExpressionNode binary:
                var left = LowerExpression(binary.Left);
                var right = LowerExpression(binary.Right);

                var op = binary.Operator switch
                {
                    BinaryOperatorKind.Add => BinaryOp.Add,
                    BinaryOperatorKind.Subtract => BinaryOp.Subtract,
                    BinaryOperatorKind.Multiply => BinaryOp.Multiply,
                    BinaryOperatorKind.Divide => BinaryOp.Divide,
                    BinaryOperatorKind.Modulo => BinaryOp.Modulo,
                    BinaryOperatorKind.Equal => BinaryOp.Equal,
                    BinaryOperatorKind.NotEqual => BinaryOp.NotEqual,
                    BinaryOperatorKind.LessThan => BinaryOp.LessThan,
                    BinaryOperatorKind.GreaterThan => BinaryOp.GreaterThan,
                    BinaryOperatorKind.LessThanOrEqual => BinaryOp.LessThanOrEqual,
                    BinaryOperatorKind.GreaterThanOrEqual => BinaryOp.GreaterThanOrEqual,
                    _ => throw new Exception($"Unknown binary operator: {binary.Operator}")
                };

                var temp = new LocalValue($"t{_tempCounter++}") { Type = _typeSolver.GetType(binary) };
                var instruction = new BinaryInstruction(op, left, right, temp);
                _currentBlock.Instructions.Add(instruction);
                return temp;

            case AssignmentExpressionNode assignment:
                var assignValue = LowerExpression(assignment.Value);
                if (!_locals.ContainsKey(assignment.TargetName))
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"cannot assign to `{assignment.TargetName}` because it is not declared",
                        assignment.Span,
                        "declare the variable with `let` first",
                        "E2010"
                    ));
                    // Return the value to avoid cascading errors
                    return assignValue;
                }

                // SSA: Create new version for this assignment
                var newVersion = new LocalValue($"{assignment.TargetName}_{_tempCounter++}") { Type = assignValue.Type };
                _locals[assignment.TargetName] = newVersion;
                _currentBlock.Instructions.Add(new StoreInstruction(assignment.TargetName, assignValue, newVersion));
                // Assignment expressions return the new version
                return newVersion;

            case IfExpressionNode ifExpr:
                return LowerIfExpression(ifExpr);

            case BlockExpressionNode blockExpr:
                return LowerBlockExpression(blockExpr);

            case RangeExpressionNode rangeExpr:
                // Range expressions are handled specially in for loop lowering
                _diagnostics.Add(Diagnostic.Error(
                    "range expressions can only be used in `for` loops",
                    rangeExpr.Span,
                    "use this expression inside a `for (x in range)` loop",
                    "E2008"
                ));
                // Return a dummy value to avoid cascading errors
                return new ConstantValue(0);

            case CallExpressionNode call:
                // Handle compiler intrinsics (size_of, align_of)
                if (call.FunctionName == "size_of" || call.FunctionName == "align_of")
                {
                    if (call.Arguments.Count != 1)
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            $"`{call.FunctionName}` requires exactly one type argument",
                            call.Span,
                            $"usage: {call.FunctionName}(TypeName)",
                            "E2014"
                        ));
                        return new ConstantValue(0);
                    }

                    // For now, we expect the argument to be an identifier (type name)
                    // TODO M11: Full Type[$T] support for generic type parameters
                    if (call.Arguments[0] is not IdentifierExpressionNode typeIdent)
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            $"`{call.FunctionName}` argument must be a type name",
                            call.Arguments[0].Span,
                            "pass a type name like `i32` or `Point`",
                            "E2015"
                        ));
                        return new ConstantValue(0);
                    }

                    // Resolve the type
                    var type = _typeSolver.ResolveTypeName(typeIdent.Name);
                    if (type == null)
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            $"unknown type `{typeIdent.Name}`",
                            typeIdent.Span,
                            "type must be defined before use",
                            "E2016"
                        ));
                        return new ConstantValue(0);
                    }

                    // Compute the constant value at compile time
                     var value = call.FunctionName == "size_of"
                         ? type.Size
                         : type.Alignment;


                    // Return constant value (no FIR instruction generated)
                    return new ConstantValue(value);
                }

                // Regular function call
                var resolved = _typeSolver.GetResolvedCall(call);
                var paramTypes = resolved?.ParameterTypes ?? new List<FType>();

                // Lower arguments, inserting implicit casts when needed
                var args = new List<Value>();
                for (var i = 0; i < call.Arguments.Count; i++)
                {
                    var argVal = LowerExpression(call.Arguments[i]);
                    var argType = _typeSolver.GetType(call.Arguments[i]);

                    // Insert cast if argument type doesn't match parameter type but can coerce
                    if (i < paramTypes.Count && argType != null && !argType.Equals(paramTypes[i]))
                    {
                        var argCastResult = new LocalValue($"cast_{_tempCounter++}") { Type = paramTypes[i] };
                        var argCastInst = new CastInstruction(argVal, paramTypes[i], argCastResult);
                        _currentBlock.Instructions.Add(argCastInst);
                        args.Add(argCastResult);
                    }
                    else
                    {
                        args.Add(argVal);
                    }
                }

                var callResult = new LocalValue($"call_{_tempCounter++}") { Type = _typeSolver.GetType(call) };
                var targetName = resolved?.Name ?? call.FunctionName;
                var callInst = new CallInstruction(targetName, args, callResult);
                if (resolved.HasValue)
                {
                    callInst.CalleeParamTypes = resolved.Value.ParameterTypes;
                    callInst.IsForeignCall = resolved.Value.IsForeign;
                }

                _currentBlock.Instructions.Add(callInst);
                return callResult;

            case AddressOfExpressionNode addressOf:
                // Address-of: &expr
                if (addressOf.Target is IdentifierExpressionNode addrIdentifier)
                {
                    var addrResult = new LocalValue($"addr_{_tempCounter++}") { Type = _typeSolver.GetType(addressOf) };
                    var addrInst = new AddressOfInstruction(addrIdentifier.Name, addrResult);
                    _currentBlock.Instructions.Add(addrInst);
                    return addrResult;
                }
                if (addressOf.Target is IndexExpressionNode ixAddr)
                {
                    // Compute pointer to array element: &base[index]
                    var baseType = _typeSolver.GetType(ixAddr.Base);
                    var addrBaseValue = LowerExpression(ixAddr.Base);
                    var addrIndexValue = LowerExpression(ixAddr.Index);

                    if (baseType is ArrayType atAddr)
                    {
                        var elemSize = GetTypeSize(atAddr.ElementType);
                        // offset = index * elem_size
                        var offsetTemp = new LocalValue($"offset_{_tempCounter++}") { Type = TypeRegistry.USize };
                        var offsetInst = new BinaryInstruction(BinaryOp.Multiply, addrIndexValue, new ConstantValue(elemSize) { Type = TypeRegistry.I32 }, offsetTemp);
                        _currentBlock.Instructions.Add(offsetInst);

                        // element pointer = base + offset
                        var elemPtr = new LocalValue($"index_ptr_{_tempCounter++}") { Type = new ReferenceType(atAddr.ElementType) };
                        var gepInst = new GetElementPtrInstruction(addrBaseValue, offsetTemp, elemPtr);
                        _currentBlock.Instructions.Add(gepInst);
                        return elemPtr;
                    }

                    _diagnostics.Add(Diagnostic.Error(
                        "cannot take address of indexed non-array value",
                        addressOf.Span,
                        null,
                        "E2012"));
                    return new ConstantValue(0);
                }

                _diagnostics.Add(Diagnostic.Error(
                    "can only take address of variables",
                    addressOf.Span,
                    "use `&variable_name`",
                    "E2012"
                ));
                return new ConstantValue(0); // Fallback

            case DereferenceExpressionNode deref:
                // Dereference: ptr.*
                var ptrValue = LowerExpression(deref.Target);
                var loadResult = new LocalValue($"load_{_tempCounter++}") { Type = _typeSolver.GetType(deref) };
                var loadInst = new LoadInstruction(ptrValue, loadResult);
                _currentBlock.Instructions.Add(loadInst);
                return loadResult;

            case StructConstructionExpressionNode structCtor:
                // Get struct type from type solver
                var structType = _typeSolver.GetType(structCtor) as StructType;
                if (structType == null)
                {
                    _diagnostics.Add(Diagnostic.Error(
                        "cannot determine struct type",
                        structCtor.Span,
                        "type checking failed",
                        "E3001"
                    ));
                    return new ConstantValue(0);
                }

                // Allocate stack space for the struct
                var allocaResult = new LocalValue($"alloca_{_tempCounter++}") { Type = new ReferenceType(structType) };
                var allocaInst = new AllocaInstruction(structType, structType.Size, allocaResult);
                _currentBlock.Instructions.Add(allocaInst);

                // Store each field value at the correct offset
                foreach (var (fieldName, fieldExpr) in structCtor.Fields)
                {
                    var fieldValue = LowerExpression(fieldExpr);
                    var fieldOffset = structType.GetFieldOffset(fieldName);
                    var fieldType = structType.GetFieldType(fieldName) ?? TypeRegistry.I32;

                    // Calculate field address: base + offset
                    var fieldPtrResult = new LocalValue($"field_ptr_{_tempCounter++}") { Type = new ReferenceType(fieldType) };
                    var gepInst = new GetElementPtrInstruction(allocaResult, fieldOffset, fieldPtrResult);
                    _currentBlock.Instructions.Add(gepInst);

                    // Store value to field
                    var storeInst = new StorePointerInstruction(fieldPtrResult, fieldValue);
                    _currentBlock.Instructions.Add(storeInst);
                }

                // Return pointer to the struct
                return allocaResult;

            case CastExpressionNode cast:
                var srcVal = LowerExpression(cast.Expression);
                var srcTypeForCast = _typeSolver.GetType(cast.Expression);
                var dstType = _typeSolver.GetType(cast) ?? TypeRegistry.I32;

                // No-op if types are already identical
                if (srcTypeForCast != null && srcTypeForCast.Equals(dstType))
                {
                    srcVal.Type = dstType;
                    return srcVal;
                }

                // Always emit CastInstruction for all other casts (including view casts)
                // The C codegen will handle zero-cost reinterpret casts appropriately
                var castResult = new LocalValue($"cast_{_tempCounter++}") { Type = dstType };
                var castInst = new CastInstruction(srcVal, dstType, castResult);
                _currentBlock.Instructions.Add(castInst);
                return castResult;


            case FieldAccessExpressionNode fieldAccess:
                // Get struct type from the target expression
                var targetValue = LowerExpression(fieldAccess.Target);
                var targetType = _typeSolver.GetType(fieldAccess.Target) as StructType;
                if (targetType == null)
                {
                    _diagnostics.Add(Diagnostic.Error(
                        "cannot access field on non-struct type",
                        fieldAccess.Span,
                        "type checking failed",
                        "E3002"
                    ));
                    return new ConstantValue(0);
                }

                // Calculate field offset
                var fieldByteOffset = targetType.GetFieldOffset(fieldAccess.FieldName);
                if (fieldByteOffset == -1)
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"field `{fieldAccess.FieldName}` not found",
                        fieldAccess.Span,
                        "type checking failed",
                        "E3003"
                    ));
                    return new ConstantValue(0);
                }

                // Get pointer to field: targetPtr + offset
                var fieldType2 = targetType.GetFieldType(fieldAccess.FieldName) ?? TypeRegistry.I32;
                var fieldPointer = new LocalValue($"field_ptr_{_tempCounter++}") { Type = new ReferenceType(fieldType2) };
                var fieldGepInst = new GetElementPtrInstruction(targetValue, fieldByteOffset, fieldPointer);
                _currentBlock.Instructions.Add(fieldGepInst);

                // Load value from field
                var fieldLoadResult = new LocalValue($"field_load_{_tempCounter++}") { Type = targetType.GetFieldType(fieldAccess.FieldName) };
                var fieldLoadInst = new LoadInstruction(fieldPointer, fieldLoadResult);
                _currentBlock.Instructions.Add(fieldLoadInst);

                return fieldLoadResult;

            case ArrayLiteralExpressionNode arrayLiteral:
                // Get array type from type solver
                var arrayType = _typeSolver.GetType(arrayLiteral) as ArrayType;
                if (arrayType == null)
                {
                    _diagnostics.Add(Diagnostic.Error(
                        "cannot determine array type",
                        arrayLiteral.Span,
                        "type checking failed",
                        "E3004"
                    ));
                    return new ConstantValue(0);
                }

                // Allocate stack space for the array
                var arrayAllocaResult = new LocalValue($"array_{_tempCounter++}") { Type = new ReferenceType(arrayType) };
                var arrayAllocaInst = new AllocaInstruction(arrayType, arrayType.Size, arrayAllocaResult);
                _currentBlock.Instructions.Add(arrayAllocaInst);

                // Store each element value
                if (arrayLiteral.IsRepeatSyntax)
                {
                    // Repeat syntax: [value; count]
                    var repeatValue = LowerExpression(arrayLiteral.RepeatValue!);
                    var elementSize = GetTypeSize(arrayType.ElementType);

                    for (var i = 0; i < arrayLiteral.RepeatCount!.Value; i++)
                    {
                        // Calculate element address: base + (i * element_size)
                        var elemPtrResult = new LocalValue($"elem_ptr_{_tempCounter++}") { Type = new ReferenceType(arrayType.ElementType) };
                        var elemGepInst = new GetElementPtrInstruction(arrayAllocaResult, i * elementSize, elemPtrResult);
                        _currentBlock.Instructions.Add(elemGepInst);

                        // Store value to element
                        var storeElemInst = new StorePointerInstruction(elemPtrResult, repeatValue);
                        _currentBlock.Instructions.Add(storeElemInst);
                    }
                }
                else
                {
                    // Regular array literal: [elem1, elem2, ...]
                    var elementSize = GetTypeSize(arrayType.ElementType);

                    for (var i = 0; i < arrayLiteral.Elements!.Count; i++)
                    {
                        var elemValue = LowerExpression(arrayLiteral.Elements[i]);

                        // Calculate element address: base + (i * element_size)
                        var elemPtrResult = new LocalValue($"elem_ptr_{_tempCounter++}") { Type = new ReferenceType(arrayType.ElementType) };
                        var elemGepInst = new GetElementPtrInstruction(arrayAllocaResult, i * elementSize, elemPtrResult);
                        _currentBlock.Instructions.Add(elemGepInst);

                        // Store value to element
                        var storeElemInst = new StorePointerInstruction(elemPtrResult, elemValue);
                        _currentBlock.Instructions.Add(storeElemInst);
                    }
                }

                // Return pointer to the array
                return arrayAllocaResult;

            case IndexExpressionNode indexExpr:
                // Get base array/slice
                var baseValue = LowerExpression(indexExpr.Base);
                var indexValue = LowerExpression(indexExpr.Index);
                var baseArrayType = _typeSolver.GetType(indexExpr.Base);

                if (baseArrayType is ArrayType arrayTypeForIndex)
                {
                    // Array indexing: arr[i]
                    var elemSize = GetTypeSize(arrayTypeForIndex.ElementType);

                    // Calculate offset: index * element_size
                    var offsetTemp = new LocalValue($"offset_{_tempCounter++}") { Type = TypeRegistry.USize };
                    var offsetInst = new BinaryInstruction(BinaryOp.Multiply, indexValue, new ConstantValue(elemSize) { Type = TypeRegistry.I32 }, offsetTemp);
                    _currentBlock.Instructions.Add(offsetInst);

                    // Calculate element address: base + offset
                    var indexElemPtr = new LocalValue($"index_ptr_{_tempCounter++}") { Type = new ReferenceType(arrayTypeForIndex.ElementType) };
                    var indexGepInst = new GetElementPtrInstruction(baseValue, offsetTemp, indexElemPtr);
                    _currentBlock.Instructions.Add(indexGepInst);

                    // Load value from element
                    var indexLoadResult = new LocalValue($"index_load_{_tempCounter++}") { Type = arrayTypeForIndex.ElementType };
                    var indexLoadInst = new LoadInstruction(indexElemPtr, indexLoadResult);
                    _currentBlock.Instructions.Add(indexLoadInst);

                    return indexLoadResult;
                }

                if (baseArrayType is SliceType sliceTypeForIndex)
                {
                    // Slice indexing: slice[i]
                    // For now, simplified - full slice support deferred
                    _diagnostics.Add(Diagnostic.Error(
                        "slice indexing not yet implemented",
                        indexExpr.Span,
                        "use array indexing for now",
                        "E3005"
                    ));
                    return new ConstantValue(0);
                }

                _diagnostics.Add(Diagnostic.Error(
                    "cannot index non-array type",
                    indexExpr.Span,
                    "type checking failed",
                    "E3006"
                ));
                return new ConstantValue(0);

            default:
                throw new Exception($"Unknown expression type: {expression.GetType().Name}");
        }
    }

    private int GetTypeSize(FType type)
    {
        return type.Size;
    }

    private Value LowerIfExpression(IfExpressionNode ifExpr)
    {
        var condition = LowerExpression(ifExpr.Condition);

        var thenBlock = CreateBlock("if_then");
        var elseBlock = ifExpr.ElseBranch != null ? CreateBlock("if_else") : null;
        var mergeBlock = CreateBlock("if_merge");

        // Branch to then or else
        _currentBlock.Instructions.Add(new BranchInstruction(condition, thenBlock, elseBlock ?? mergeBlock));

        // Lower then branch
        _currentBlock = thenBlock;
        var thenValue = LowerExpression(ifExpr.ThenBranch);
        var thenResult = new LocalValue($"if_result_then_{_tempCounter++}");
        _currentBlock.Instructions.Add(new StoreInstruction(thenResult.Name, thenValue, thenResult));
        _currentBlock.Instructions.Add(new JumpInstruction(mergeBlock));

        // Lower else branch if it exists
        Value? elseResult = null;
        if (ifExpr.ElseBranch != null && elseBlock != null)
        {
            _currentBlock = elseBlock;
            var elseValue = LowerExpression(ifExpr.ElseBranch);
            elseResult = new LocalValue($"if_result_else_{_tempCounter++}");
            _currentBlock.Instructions.Add(new StoreInstruction(elseResult.Name, elseValue, elseResult));
            _currentBlock.Instructions.Add(new JumpInstruction(mergeBlock));
        }

        // Continue in merge block
        _currentBlock = mergeBlock;

        // For now, return the then result (proper SSA would use phi nodes or block arguments)
        return thenResult;
    }

    private Value LowerBlockExpression(BlockExpressionNode blockExpr)
    {
        // Push a new defer scope for this block
        _deferStack.Push(new List<ExpressionNode>());

        foreach (var stmt in blockExpr.Statements) LowerStatement(stmt);

        Value result;
        if (blockExpr.TrailingExpression != null)
            result = LowerExpression(blockExpr.TrailingExpression);
        else
            // Block with no trailing expression returns unit/void (use 0 for now)
            result = new ConstantValue(0);

        // Emit deferred statements at block end (in LIFO order)
        EmitDeferredStatements();

        // Pop the defer scope
        _deferStack.Pop();

        return result;
    }

    private void LowerForLoop(ForLoopNode forLoop)
    {
        // Only handle Range expressions for now
        if (forLoop.IterableExpression is not RangeExpressionNode range)
        {
            _diagnostics.Add(Diagnostic.Error(
                "`for` loops currently only support range expressions",
                forLoop.IterableExpression.Span,
                "use a range like `0..10` for iteration",
                "E2009"
            ));
            return; // Skip lowering this loop
        }

        var start = LowerExpression(range.Start);
        var end = LowerExpression(range.End);

        // Create loop blocks
        var condBlock = CreateBlock("for_cond");
        var bodyBlock = CreateBlock("for_body");
        var continueBlock = CreateBlock("for_continue");
        var exitBlock = CreateBlock("for_exit");

        // Initialize iterator
        var iteratorVar = new LocalValue(forLoop.IteratorVariable);
        _locals[forLoop.IteratorVariable] = iteratorVar;
        _currentBlock.Instructions.Add(new StoreInstruction(iteratorVar.Name, start, iteratorVar));
        _currentBlock.Instructions.Add(new JumpInstruction(condBlock));

        // Condition: iterator < end
        _currentBlock = condBlock;
        var lessThan = new LocalValue($"loop_cond_{_tempCounter++}");
        var cmpInst = new BinaryInstruction(BinaryOp.Subtract, iteratorVar, end, lessThan);
        _currentBlock.Instructions.Add(cmpInst);
        _currentBlock.Instructions.Add(new BranchInstruction(lessThan, bodyBlock, exitBlock));

        // Body
        _currentBlock = bodyBlock;
        _loopStack.Push(new LoopContext(continueBlock, exitBlock));
        LowerExpression(forLoop.Body);
        _loopStack.Pop();
        _currentBlock.Instructions.Add(new JumpInstruction(continueBlock));

        // Continue: increment iterator
        _currentBlock = continueBlock;
        var incremented = new LocalValue($"loop_inc_{_tempCounter++}");
        var incInst = new BinaryInstruction(BinaryOp.Add, iteratorVar, new ConstantValue(1), incremented);
        _currentBlock.Instructions.Add(incInst);
        var newIteratorVersion = new LocalValue($"{forLoop.IteratorVariable}_{_tempCounter++}");
        _currentBlock.Instructions.Add(new StoreInstruction(iteratorVar.Name, incremented, newIteratorVersion));
        _currentBlock.Instructions.Add(new JumpInstruction(condBlock));

        // Exit
        _currentBlock = exitBlock;
    }

    private class LoopContext
    {
        public LoopContext(BasicBlock continueTarget, BasicBlock breakTarget)
        {
            ContinueTarget = continueTarget;
            BreakTarget = breakTarget;
        }

        public BasicBlock ContinueTarget { get; }
        public BasicBlock BreakTarget { get; }
    }
}