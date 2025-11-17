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
    private readonly Compilation _compilation;
    private readonly List<BasicBlock> _allBlocks = [];
    private readonly List<Diagnostic> _diagnostics = [];
    private readonly Dictionary<string, Value> _locals = new();
    private readonly HashSet<string> _parameters = new();
    private readonly Stack<LoopContext> _loopStack = new();
    private readonly Stack<List<ExpressionNode>> _deferStack = new();
    private readonly TypeSolver _typeSolver;
    private int _blockCounter;
    private BasicBlock _currentBlock = null!;
    private Function _currentFunction = null!;
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
        _currentFunction = function;

        // Clear parameter set for new function
        _parameters.Clear();

        // Add parameters to function
        for (var i = 0; i < functionNode.Parameters.Count; i++)
        {
            var param = functionNode.Parameters[i];
            var paramType = resolvedParamTypes[i];
            function.Parameters.Add(new FunctionParameter(param.Name, paramType));

            // Add parameter to locals with type so it can be referenced in the function body
            var localParam = new LocalValue(param.Name) { Type = paramType };
            _locals[param.Name] = localParam;
            _parameters.Add(param.Name);
        }

        // Foreign functions have no body
        if (isForeign) return function;

        _currentBlock = CreateBlock("entry");
        function.BasicBlocks.Add(_currentBlock);

        // Push a new defer scope for this function
        _deferStack.Push([]);

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

                // Check if this is a struct or array type
                bool isStruct = varType is StructType;
                bool isArray = varType is ArrayType;

                if (isStruct)
                {
                    var structType = (StructType)varType;

                    // Allocate stack space for struct
                    var allocaResult = new LocalValue(varDecl.Name)
                        { Type = new ReferenceType(varType) };
                    var allocaInst = new AllocaInstruction(varType, varType.Size, allocaResult);
                    _currentBlock.Instructions.Add(allocaInst);

                    // Store the POINTER in locals map
                    _locals[varDecl.Name] = allocaResult;

                    // Handle initialization
                    if (varDecl.Initializer != null)
                    {
                        var initValue = LowerExpression(varDecl.Initializer);

                        // Pointer to struct: use memcpy
                        if (initValue.Type is ReferenceType { InnerType: StructType })
                        {
                            // Copy struct fields from initializer
                            CopyStruct(allocaResult, initValue, structType);
                        }
                        // Struct value (e.g., from cast): store it directly
                        else if (initValue.Type is StructType or SliceType)
                        {
                            var storeInst = new StorePointerInstruction(allocaResult, initValue);
                            _currentBlock.Instructions.Add(storeInst);
                        }
                    }
                    else
                    {
                        // Zero-initialize struct with memset
                        ZeroInitialize(allocaResult, structType.Size);
                    }
                }
                else if (isArray)
                {
                    var arrayType = (ArrayType)varType;

                    // Allocate stack space for array
                    var allocaResult = new LocalValue(varDecl.Name)
                        { Type = new ReferenceType(arrayType) };
                    var allocaInst = new AllocaInstruction(arrayType, arrayType.Size, allocaResult);
                    _currentBlock.Instructions.Add(allocaInst);

                    // Store the POINTER in locals map
                    _locals[varDecl.Name] = allocaResult;

                    // Handle initialization
                    if (varDecl.Initializer != null)
                    {
                        var initValue = LowerExpression(varDecl.Initializer);

                        // Array literals return GlobalValue with &[T; N] type
                        // We need to memcpy the array data
                        if (initValue is GlobalValue globalArray)
                        {
                            // Use memcpy to copy the array
                            var memcpyResult = new LocalValue($"memcpy_{_tempCounter++}") { Type = TypeRegistry.Void };
                            var sizeValue = new ConstantValue(arrayType.Size) { Type = TypeRegistry.USize };

                            var memcpyCall = new CallInstruction(
                                "memcpy",
                                new List<Value> { allocaResult, globalArray, sizeValue },
                                memcpyResult
                            )
                            {
                                IsForeignCall = true // memcpy is a C standard library function
                            };
                            _currentBlock.Instructions.Add(memcpyCall);
                        }
                    }
                    else
                    {
                        // Zero-initialize array with memset
                        ZeroInitialize(allocaResult, arrayType.Size);
                    }
                }
                else
                {
                    // Scalars: allocate on stack like arrays/structs (memory-based SSA)
                    var allocaResult = new LocalValue(varDecl.Name)
                        { Type = new ReferenceType(varType) };
                    var allocaInst = new AllocaInstruction(varType, varType.Size, allocaResult);
                    _currentBlock.Instructions.Add(allocaInst);

                    // Store the POINTER in locals map (not the value)
                    _locals[varDecl.Name] = allocaResult;

                    // Handle initialization
                    if (varDecl.Initializer != null)
                    {
                        var initValue = LowerExpression(varDecl.Initializer);
                        var initStoreInst = new StorePointerInstruction(allocaResult, initValue);
                        _currentBlock.Instructions.Add(initStoreInst);
                    }
                    else
                    {
                        // Zero-initialize scalar with store 0
                        var zeroValue = new ConstantValue(0) { Type = varType };
                        var zeroStoreInst = new StorePointerInstruction(allocaResult, zeroValue);
                        _currentBlock.Instructions.Add(zeroStoreInst);
                    }
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
                return new ConstantValue(intLiteral.Value)
                    { Type = _typeSolver.GetType(expression) ?? TypeRegistry.ComptimeInt };

            case BooleanLiteralNode boolLiteral:
                return new ConstantValue(boolLiteral.Value ? 1 : 0)
                    { Type = _typeSolver.GetType(expression) ?? TypeRegistry.Bool };

            case StringLiteralNode stringLiteral:
            {
                // String literals are represented as String struct constants
                var sid = _compilation.AllocateStringId();
                var globalName = $"LC{sid}"; // Use LC0, LC1, LC2... naming

                // Convert string to byte array (UTF-8 + null terminator for C FFI)
                var bytes = System.Text.Encoding.UTF8.GetBytes(stringLiteral.Value);
                var nullTerminated = new byte[bytes.Length + 1];
                Array.Copy(bytes, nullTerminated, bytes.Length);

                // Create array constant for the raw bytes
                var arrayConst = new ArrayConstantValue(nullTerminated, TypeRegistry.U8)
                {
                    StringRepresentation = stringLiteral.Value
                };

                // Get String struct type from type solver
                var stringType = _typeSolver.GetType(stringLiteral) as StructType;
                if (stringType == null)
                {
                    _diagnostics.Add(Diagnostic.Error(
                        "String type not found for string literal",
                        stringLiteral.Span,
                        "import core.string",
                        "E3010"
                    ));
                    return new ConstantValue(0);
                }

                // Create String struct constant: { ptr: <bytes>, len: <length> }
                var structConst = new StructConstantValue(stringType, new Dictionary<string, Value>
                {
                    ["ptr"] = arrayConst,
                    ["len"] = new ConstantValue(bytes.Length) { Type = TypeRegistry.USize }
                });

                // Create global (type will be &String)
                var global = new GlobalValue(globalName, structConst);

                // Register in function globals
                _currentFunction.Globals.Add(global);

                // Return the global - it's a pointer to String struct
                return global;
            }

            case IdentifierExpressionNode identifier:
            {
                if (_locals.TryGetValue(identifier.Name, out var localValue))
                {
                    // Parameters are passed by value (even if they're pointers), so use them directly
                    if (_parameters.Contains(identifier.Name))
                    {
                        return localValue;
                    }

                    // Local variables are now pointers (alloca'd)
                    if (localValue.Type is ReferenceType refType)
                    {
                        // Arrays and structs: return the pointer directly (don't load)
                        // They are manipulated via pointer in the IR
                        if (refType.InnerType is ArrayType or StructType)
                        {
                            return localValue;
                        }

                        // Scalars: load the value from memory
                        var loadedValue = new LocalValue($"{identifier.Name}_load_{_tempCounter++}")
                            { Type = refType.InnerType };
                        var loadInstruction = new LoadInstruction(localValue, loadedValue);
                        _currentBlock.Instructions.Add(loadInstruction);
                        return loadedValue;
                    }

                    // Shouldn't happen with new approach, but keep for safety
                    return localValue;
                }

                _diagnostics.Add(Diagnostic.Error(
                    $"cannot find value `{identifier.Name}` in this scope",
                    identifier.Span,
                    "not found in this scope",
                    "E2004"
                ));
                // Return a dummy value to avoid cascading errors
                return new ConstantValue(0);
            }

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
                if (!_locals.TryGetValue(assignment.TargetName, out var targetPtr))
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

                // Store to the memory location (no versioning needed)
                var assignStoreInst = new StorePointerInstruction(targetPtr, assignValue);
                _currentBlock.Instructions.Add(assignStoreInst);

                // Assignment expressions return the assigned value
                return assignValue;

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
                        // CastInstruction now infers cast kind from source and target types
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
                    // Check if this is a local variable (stored as pointer via alloca)
                    if (_locals.TryGetValue(addrIdentifier.Name, out var localValue))
                    {
                        // If it's already a pointer (alloca'd variable), return it directly
                        // This prevents double-pointer issues since all variables are now memory-based
                        if (localValue.Type is ReferenceType)
                        {
                            return localValue;
                        }
                    }

                    // For parameters or other non-alloca'd values, emit AddressOfInstruction
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
                        var offsetInst = new BinaryInstruction(BinaryOp.Multiply, addrIndexValue,
                            new ConstantValue(elemSize) { Type = TypeRegistry.I32 }, offsetTemp);
                        _currentBlock.Instructions.Add(offsetInst);

                        // element pointer = base + offset
                        var elemPtr = new LocalValue($"index_ptr_{_tempCounter++}")
                            { Type = new ReferenceType(atAddr.ElementType) };
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
                    var fieldPtrResult = new LocalValue($"field_ptr_{_tempCounter++}")
                        { Type = new ReferenceType(fieldType) };
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

                // Emit CastInstruction for all casts
                // The backend will determine the appropriate cast implementation by inspecting types
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
                var fieldPointer = new LocalValue($"field_ptr_{_tempCounter++}")
                    { Type = new ReferenceType(fieldType2) };
                var fieldGepInst = new GetElementPtrInstruction(targetValue, fieldByteOffset, fieldPointer);
                _currentBlock.Instructions.Add(fieldGepInst);

                // Load value from field
                var fieldLoadResult = new LocalValue($"field_load_{_tempCounter++}")
                    { Type = targetType.GetFieldType(fieldAccess.FieldName) };
                var fieldLoadInst = new LoadInstruction(fieldPointer, fieldLoadResult);
                _currentBlock.Instructions.Add(fieldLoadInst);

                return fieldLoadResult;

            case ArrayLiteralExpressionNode arrayLiteral:
                // Get array type from type solver
                var arrayLitType = _typeSolver.GetType(arrayLiteral) as ArrayType;
                if (arrayLitType == null)
                {
                    _diagnostics.Add(Diagnostic.Error(
                        "cannot determine array type",
                        arrayLiteral.Span,
                        "type checking failed",
                        "E3004"
                    ));
                    return new ConstantValue(0);
                }

                // Create global constant for array literal (like string literals)
                var arrayId = _compilation.AllocateStringId(); // Reuse the string ID counter for simplicity
                var arrayGlobalName = $"LA{arrayId}"; // LA = Literal Array

                // Collect element values
                Value[] elementValues;
                if (arrayLiteral.IsRepeatSyntax)
                {
                    // Repeat syntax: [value; count]
                    var repeatValue = LowerExpression(arrayLiteral.RepeatValue!);

                    // For constants, we can create the array directly
                    if (repeatValue is ConstantValue constVal)
                    {
                        elementValues = new Value[arrayLiteral.RepeatCount!.Value];
                        for (var i = 0; i < arrayLiteral.RepeatCount.Value; i++)
                        {
                            elementValues[i] = constVal;
                        }
                    }
                    else
                    {
                        // Non-constant repeat values not supported in array literals
                        _diagnostics.Add(Diagnostic.Error(
                            "array literal with repeat syntax must have constant value",
                            arrayLiteral.Span,
                            "use a constant expression",
                            "E3005"
                        ));
                        return new ConstantValue(0);
                    }
                }
                else
                {
                    // Regular array literal: [elem1, elem2, ...]
                    elementValues = new Value[arrayLiteral.Elements!.Count];
                    for (var i = 0; i < arrayLiteral.Elements.Count; i++)
                    {
                        var elemValue = LowerExpression(arrayLiteral.Elements[i]);

                        // Array literals must contain constant values
                        if (elemValue is not ConstantValue)
                        {
                            _diagnostics.Add(Diagnostic.Error(
                                "array literal elements must be constant values",
                                arrayLiteral.Elements[i].Span,
                                "use a constant expression",
                                "E3006"
                            ));
                            return new ConstantValue(0);
                        }

                        elementValues[i] = elemValue;
                    }
                }

                // Create array constant value
                var arrayLitConst = new ArrayConstantValue(arrayLitType, elementValues);

                // Create global (type will be &[T; N])
                var arrayGlobal = new GlobalValue(arrayGlobalName, arrayLitConst);

                // Register in function globals
                _currentFunction.Globals.Add(arrayGlobal);

                // Return the global - it's a pointer to the array
                return arrayGlobal;

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
                    var offsetInst = new BinaryInstruction(BinaryOp.Multiply, indexValue,
                        new ConstantValue(elemSize) { Type = TypeRegistry.I32 }, offsetTemp);
                    _currentBlock.Instructions.Add(offsetInst);

                    // Calculate element address: base + offset
                    var indexElemPtr = new LocalValue($"index_ptr_{_tempCounter++}")
                        { Type = new ReferenceType(arrayTypeForIndex.ElementType) };
                    var indexGepInst = new GetElementPtrInstruction(baseValue, offsetTemp, indexElemPtr);
                    _currentBlock.Instructions.Add(indexGepInst);

                    // Load value from element
                    var indexLoadResult = new LocalValue($"index_load_{_tempCounter++}")
                        { Type = arrayTypeForIndex.ElementType };
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
        _deferStack.Push([]);

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

        // Initialize iterator - allocate on stack (memory-based like all variables)
        var iteratorPtr = new LocalValue(forLoop.IteratorVariable)
            { Type = new ReferenceType(start.Type) };
        var iteratorAlloca = new AllocaInstruction(start.Type, start.Type.Size, iteratorPtr);
        _currentBlock.Instructions.Add(iteratorAlloca);
        _currentBlock.Instructions.Add(new StorePointerInstruction(iteratorPtr, start));
        _locals[forLoop.IteratorVariable] = iteratorPtr;
        _currentBlock.Instructions.Add(new JumpInstruction(condBlock));

        // Condition: load iterator, compare with end
        _currentBlock = condBlock;
        var iteratorValue = new LocalValue($"{forLoop.IteratorVariable}_load_{_tempCounter++}")
            { Type = start.Type };
        _currentBlock.Instructions.Add(new LoadInstruction(iteratorPtr, iteratorValue));
        var lessThan = new LocalValue($"loop_cond_{_tempCounter++}") { Type = start.Type };
        var cmpInst = new BinaryInstruction(BinaryOp.Subtract, iteratorValue, end, lessThan);
        _currentBlock.Instructions.Add(cmpInst);
        _currentBlock.Instructions.Add(new BranchInstruction(lessThan, bodyBlock, exitBlock));

        // Body
        _currentBlock = bodyBlock;
        _loopStack.Push(new LoopContext(continueBlock, exitBlock));
        LowerExpression(forLoop.Body);
        _loopStack.Pop();
        _currentBlock.Instructions.Add(new JumpInstruction(continueBlock));

        // Continue: load iterator, increment, store back
        _currentBlock = continueBlock;
        var currentIterator = new LocalValue($"{forLoop.IteratorVariable}_load_{_tempCounter++}")
            { Type = start.Type };
        _currentBlock.Instructions.Add(new LoadInstruction(iteratorPtr, currentIterator));
        var incremented = new LocalValue($"loop_inc_{_tempCounter++}") { Type = start.Type };
        var incInst = new BinaryInstruction(BinaryOp.Add, currentIterator, new ConstantValue(1) { Type = start.Type }, incremented);
        _currentBlock.Instructions.Add(incInst);
        _currentBlock.Instructions.Add(new StorePointerInstruction(iteratorPtr, incremented));
        _currentBlock.Instructions.Add(new JumpInstruction(condBlock));

        // Exit - no need to save/restore locals anymore! Memory persists naturally.
        _currentBlock = exitBlock;
    }

    /// <summary>
    /// Copy struct fields from one location to another using memcpy.
    /// </summary>
    private void CopyStruct(Value destPtr, Value srcPtr, StructType structType)
    {
        // Use memcpy to copy the entire struct
        var sizeVal = new ConstantValue(structType.Size) { Type = TypeRegistry.USize };
        var memcpyResult = new LocalValue($"_unused_{_tempCounter++}") { Type = TypeRegistry.Void };

        var memcpyCall = new CallInstruction("memcpy",
            new List<Value> { destPtr, srcPtr, sizeVal },
            memcpyResult);
        memcpyCall.IsForeignCall = true;

        _currentBlock.Instructions.Add(memcpyCall);
    }

    /// <summary>
    /// Zero-initialize memory using memset(ptr, 0, size).
    /// Used for uninitialized arrays and structs.
    /// </summary>
    private void ZeroInitialize(Value ptr, int sizeInBytes)
    {
        // memset(ptr, 0, size)
        var zeroValue = new ConstantValue(0) { Type = TypeRegistry.U8 };
        var sizeValue = new ConstantValue(sizeInBytes) { Type = TypeRegistry.USize };
        var memsetResult = new LocalValue($"_unused_{_tempCounter++}") { Type = TypeRegistry.Void };

        var memsetCall = new CallInstruction("memset",
            new List<Value> { ptr, zeroValue, sizeValue },
            memsetResult)
        {
            IsForeignCall = true // memset is a C standard library function
        };

        _currentBlock.Instructions.Add(memsetCall);
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
