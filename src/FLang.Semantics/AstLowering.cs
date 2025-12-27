using FLang.Core;
using FType = FLang.Core.TypeBase;
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
    private readonly TypeChecker _typeSolver;
    private int _blockCounter;
    private BasicBlock _currentBlock = null!;
    private Function _currentFunction = null!;
    private FunctionDeclarationNode _currentFunctionNode = null!;
    private int _tempCounter;

    // Track type literal indices for the global type table
    private readonly Dictionary<FType, int> _typeTableIndices = new();
    private GlobalValue? _typeTableGlobal = null;

    private AstLowering(Compilation compilation, TypeChecker typeSolver)
    {
        _compilation = compilation;
        _typeSolver = typeSolver;
    }

    public IReadOnlyList<Diagnostic> Diagnostics => _diagnostics;

    public static (Function Function, IReadOnlyList<Diagnostic> Diagnostics) Lower(FunctionDeclarationNode functionNode,
        Compilation compilation, TypeChecker typeSolver)
    {
        var lowering = new AstLowering(compilation, typeSolver);
        var function = lowering.LowerFunction(functionNode);
        return (function, lowering.Diagnostics);
    }

    private Function LowerFunction(FunctionDeclarationNode functionNode)
    {
        _currentFunctionNode = functionNode;
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
        return _typeSolver.ResolveTypeNode(typeNode) ?? TypeRegistry.I32;
    }

    private BasicBlock CreateBlock(string hint)
    {
        var block = new BasicBlock($"{hint}_{_blockCounter++}");
        _allBlocks.Add(block);
        return block;
    }

    private static string SanitizeTypeName(string name)
    {
        return name.Replace("&", "ref_")
                   .Replace("[", "_")
                   .Replace("]", "_")
                   .Replace("(", "_")
                   .Replace(")", "_")
                   .Replace(" ", "")
                   .Replace(";", "_");
    }

    private void EnsureTypeTableExists()
    {
        if (_typeTableGlobal != null) return;

        // Build the type table from all instantiated types collected by TypeSolver
        var types = _typeSolver.InstantiatedTypes.OrderBy(t => t.Name).ToList();
        var typeStructElements = new List<Value>();

        for (int i = 0; i < types.Count; i++)
        {
            var type = types[i];
            _typeTableIndices[type] = i;

            var typeName = type.Name;
            var nameBytes = System.Text.Encoding.UTF8.GetBytes(typeName + "\0");
            var nameArray = new ArrayConstantValue(nameBytes, TypeRegistry.U8)
            {
                StringRepresentation = typeName
            };
            var nameGlobal = new GlobalValue($"__flang__typename_{i}", nameArray);
            _currentFunction.Globals.Add(nameGlobal);

            var nameString = new StructConstantValue(TypeRegistry.StringStruct, new Dictionary<string, Value>
            {
                ["ptr"] = nameGlobal,
                ["len"] = new ConstantValue(typeName.Length) { Type = TypeRegistry.USize }
            });

            var typeStruct = new StructConstantValue(TypeRegistry.TypeStructTemplate, new Dictionary<string, Value>
            {
                ["name"] = nameString,
                ["size"] = new ConstantValue(type.Size) { Type = TypeRegistry.U8 },
                ["align"] = new ConstantValue(type.Alignment) { Type = TypeRegistry.U8 }
            });

            typeStructElements.Add(typeStruct);
        }

        // Create the global type table array
        var arrayType = new ArrayType(TypeRegistry.TypeStructTemplate, types.Count);
        var typeTableArray = new ArrayConstantValue(arrayType, typeStructElements.ToArray());
        _typeTableGlobal = new GlobalValue("__flang__type_table", typeTableArray);
        _currentFunction.Globals.Add(_typeTableGlobal);
    }

    private Value GetTypeLiteralValue(FType referencedType, StructType typeStructType)
    {
        EnsureTypeTableExists();

        // Get the index for this type in the table
        if (!_typeTableIndices.TryGetValue(referencedType, out var index))
        {
            throw new InvalidOperationException($"Type {referencedType.Name} was not collected during type checking");
        }

        // Calculate byte offset: index * sizeof(struct Type)
        var typeSize = TypeRegistry.TypeStructTemplate.Size;
        var byteOffset = new ConstantValue(index * typeSize) { Type = TypeRegistry.USize };

        // Get pointer to the element: &__flang__type_table[index]
        var elemPtr = new LocalValue($"type_ptr_{_tempCounter++}");
        elemPtr.Type = new ReferenceType(typeStructType);
        _currentBlock.Instructions.Add(new GetElementPtrInstruction(_typeTableGlobal, byteOffset, elemPtr));

        return elemPtr;
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
                            else if (TryWriteSliceFromArray(allocaResult, structType, initValue))
                            {
                                // Slice initialized from array pointer; fields were populated above
                            }
                            // Struct value (e.g., from cast): store it directly
                            else if (initValue.Type is StructType)
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
        var value = LowerExpressionCore(expression);
        var finalType = _typeSolver.GetType(expression);

        // If final type is Option<T> but value is T, wrap it
        if (finalType is StructType st && TypeRegistry.IsOption(st) &&
            st.TypeArguments.Count > 0 && value.Type != null && value.Type.Equals(st.TypeArguments[0]))
        {
            return LowerLiftToOption(value, st);
        }

        return value;
    }

    private Value LowerExpressionCore(ExpressionNode expression)
    {
        switch (expression)
        {
            case IntegerLiteralNode intLiteral:
                {
                    var literalType = _typeSolver.GetType(expression);
                    var valueType = (literalType is StructType st && TypeRegistry.IsOption(st) && st.TypeArguments.Count > 0)
                        ? st.TypeArguments[0]
                        : literalType ?? TypeRegistry.ComptimeInt;
                    return new ConstantValue(intLiteral.Value) { Type = valueType };
                }

            case BooleanLiteralNode boolLiteral:
                {
                    var literalType = _typeSolver.GetType(expression);
                    var valueType = (literalType is StructType st && TypeRegistry.IsOption(st) && st.TypeArguments.Count > 0)
                        ? st.TypeArguments[0]
                        : literalType ?? TypeRegistry.Bool;
                    return new ConstantValue(boolLiteral.Value ? 1 : 0) { Type = valueType };
                }


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
                    var exprType = _typeSolver.GetType(identifier);

                    // Check if this is a type literal
                    if (exprType is StructType st && TypeRegistry.IsType(st))
                    {
                        var referencedType = _typeSolver.ResolveTypeName(identifier.Name);
                        if (referencedType != null)
                        {
                            // Load type metadata from global
                            var typeGlobal = GetTypeLiteralValue(referencedType, st);

                            // Load the struct value
                            var loaded = new LocalValue($"type_load_{_tempCounter++}");
                            loaded.Type = st;
                            _currentBlock.Instructions.Add(new LoadInstruction(typeGlobal, loaded));
                            return loaded;
                        }
                    }

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

                if (targetPtr.Type is ReferenceType { InnerType: StructType targetStruct })
                {
                    if (assignValue.Type is ReferenceType { InnerType: StructType sourceStruct } && targetStruct.Equals(sourceStruct))
                    {
                        CopyStruct(targetPtr, assignValue, targetStruct);
                        return assignValue;
                    }

                    if (TryWriteSliceFromArray(targetPtr, targetStruct, assignValue))
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
                // size_of and align_of are now regular library functions defined in core.rtti
                // They accept Type($T) parameters and access struct fields directly

                // Regular function call
                var resolved = _typeSolver.GetResolvedCall(_currentFunctionNode, call);
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

                var callType = _typeSolver.GetType(call) ?? TypeRegistry.I32;
                var callResult = new LocalValue($"call_{_tempCounter++}") { Type = callType };
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
                {
                    var resolvedType = GetExpressionType(structCtor);
                    StructType? structType = resolvedType switch
                    {
                        StructType st => st,
                        GenericType gt => _typeSolver.InstantiateStruct(gt, structCtor.Span),
                        _ => null
                    };

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

                    return LowerStructLiteral(structCtor.Fields, structType, structCtor.Span);
                }

            case AnonymousStructExpressionNode anonStruct:
                {
                    var resolvedType = GetExpressionType(anonStruct);
                    StructType? structType = resolvedType switch
                    {
                        StructType st => st,
                        GenericType gt => _typeSolver.InstantiateStruct(gt, anonStruct.Span),
                        _ => null
                    };

                    if (structType == null)
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            "anonymous struct literal requires a concrete struct type",
                            anonStruct.Span,
                            "type checking failed",
                            "E3001"
                        ));
                        return new ConstantValue(0);
                    }

                    return LowerStructLiteral(anonStruct.Fields, structType, anonStruct.Span);
                }

            case NullLiteralNode nullLiteral:
                {
                    var exprType = _typeSolver.GetType(nullLiteral) as StructType;
                    if (exprType == null || !TypeRegistry.IsOption(exprType))
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            "null literal requires an option type",
                            nullLiteral.Span,
                            "add an explicit option annotation",
                            "E3001"));
                        return new ConstantValue(0);
                    }

                    return LowerNullLiteral(exprType);
                }

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
                {
                    // Get struct type from the target expression
                    var targetValue = LowerExpression(fieldAccess.Target);
                    var targetSemanticType = _typeSolver.GetType(fieldAccess.Target);
                    var accessStruct = targetSemanticType switch
                    {
                        StructType st => st,
                        _ => null
                    };
                    if (accessStruct == null)
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
                    var fieldByteOffset = accessStruct.GetFieldOffset(fieldAccess.FieldName);
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
                    var fieldType2 = accessStruct.GetFieldType(fieldAccess.FieldName) ?? TypeRegistry.I32;
                    var fieldPointer = new LocalValue($"field_ptr_{_tempCounter++}")
                    { Type = new ReferenceType(fieldType2) };
                    var fieldGepInst = new GetElementPtrInstruction(targetValue, fieldByteOffset, fieldPointer);
                    _currentBlock.Instructions.Add(fieldGepInst);

                    // Load value from field
                    var fieldLoadResult = new LocalValue($"field_load_{_tempCounter++}")
                    { Type = accessStruct.GetFieldType(fieldAccess.FieldName) };
                    var fieldLoadInst = new LoadInstruction(fieldPointer, fieldLoadResult);
                    _currentBlock.Instructions.Add(fieldLoadInst);

                    return fieldLoadResult;
                }

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

                if (baseArrayType is StructType sliceTypeForIndex && TypeRegistry.IsSlice(sliceTypeForIndex))
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
        // TODO skip next 3 lines if thenbranch is terminal (return, never, etc)
        var thenResult = new LocalValue($"if_result_then_{_tempCounter++}"); // TODO type
        _currentBlock.Instructions.Add(new StoreInstruction(thenResult.Name, thenValue, thenResult));
        _currentBlock.Instructions.Add(new JumpInstruction(mergeBlock));

        // Lower else branch if it exists
        Value? elseResult = null;
        if (ifExpr.ElseBranch != null && elseBlock != null)
        {
            _currentBlock = elseBlock;
            var elseValue = LowerExpression(ifExpr.ElseBranch);
            elseResult = new LocalValue($"if_result_else_{_tempCounter++}"); // TODO type
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

    private Value LowerStructLiteral(IReadOnlyList<(string FieldName, ExpressionNode Value)> fields, StructType structType,
        SourceSpan span)
    {
        var allocaResult = new LocalValue($"alloca_{_tempCounter++}") { Type = new ReferenceType(structType) };
        var allocaInst = new AllocaInstruction(structType, structType.Size, allocaResult);
        _currentBlock.Instructions.Add(allocaInst);

        foreach (var (fieldName, fieldExpr) in fields)
        {
            var fieldType = structType.GetFieldType(fieldName);
            var fieldOffset = structType.GetFieldOffset(fieldName);
            if (fieldType == null || fieldOffset < 0)
            {
                _diagnostics.Add(Diagnostic.Error(
                    $"struct `{structType.Name}` does not have a field named `{fieldName}`",
                    span,
                    null,
                    "E2013"));
                continue;
            }

            var fieldValue = LowerExpression(fieldExpr);
            var fieldPtrResult = new LocalValue($"field_ptr_{_tempCounter++}")
            { Type = new ReferenceType(fieldType) };
            var gepInst = new GetElementPtrInstruction(allocaResult, fieldOffset, fieldPtrResult);
            _currentBlock.Instructions.Add(gepInst);

            var storeInst = new StorePointerInstruction(fieldPtrResult, fieldValue);
            _currentBlock.Instructions.Add(storeInst);
        }

        var structValue = new LocalValue($"struct_val_{_tempCounter++}") { Type = structType };
        var loadInst = new LoadInstruction(allocaResult, structValue);
        _currentBlock.Instructions.Add(loadInst);
        return structValue;
    }

    private Value LowerNullLiteral(StructType optionType)
    {
        var allocaResult = new LocalValue($"alloca_{_tempCounter++}") { Type = new ReferenceType(optionType) };
        var allocaInst = new AllocaInstruction(optionType, optionType.Size, allocaResult);
        _currentBlock.Instructions.Add(allocaInst);

        ZeroInitialize(allocaResult, optionType.Size);
        var falseValue = new ConstantValue(0) { Type = TypeRegistry.Bool };
        StoreStructField(allocaResult, optionType, "has_value", falseValue);

        var structValue = new LocalValue($"struct_val_{_tempCounter++}") { Type = optionType };
        var loadInst = new LoadInstruction(allocaResult, structValue);
        _currentBlock.Instructions.Add(loadInst);
        return structValue;
    }

    private Value LowerLiftToOption(Value innerValue, StructType optionType)
    {
        var allocaResult = new LocalValue($"alloca_{_tempCounter++}") { Type = new ReferenceType(optionType) };
        var allocaInst = new AllocaInstruction(optionType, optionType.Size, allocaResult);
        _currentBlock.Instructions.Add(allocaInst);

        ZeroInitialize(allocaResult, optionType.Size);
        var trueValue = new ConstantValue(1) { Type = TypeRegistry.Bool };
        StoreStructField(allocaResult, optionType, "has_value", trueValue);
        StoreStructField(allocaResult, optionType, "value", innerValue);

        var structValue = new LocalValue($"struct_val_{_tempCounter++}") { Type = optionType };
        var loadInst = new LoadInstruction(allocaResult, structValue);
        _currentBlock.Instructions.Add(loadInst);
        return structValue;
    }

    private bool TryWriteSliceFromArray(Value destinationPtr, StructType structType, Value sourceValue)
    {
        if (!TypeRegistry.IsSlice(structType) && !TypeRegistry.IsString(structType))
            return false;

        if (sourceValue.Type is not ReferenceType { InnerType: ArrayType arrayType })
            return false;

        var elementPtrType = new ReferenceType(arrayType.ElementType);
        var elementPtrValue = new LocalValue($"slice_ptr_{_tempCounter++}") { Type = elementPtrType };
        var castInst = new CastInstruction(sourceValue, elementPtrType, elementPtrValue);
        _currentBlock.Instructions.Add(castInst);

        StoreStructField(destinationPtr, structType, "ptr", elementPtrValue);
        var lenValue = new ConstantValue(arrayType.Length) { Type = TypeRegistry.USize };
        StoreStructField(destinationPtr, structType, "len", lenValue);
        return true;
    }

    private void StoreStructField(Value destinationPtr, StructType structType, string fieldName, Value value)
    {
        if (destinationPtr.Type is not ReferenceType)
            return;

        var fieldType = structType.GetFieldType(fieldName) ?? TypeRegistry.I32;
        var fieldOffset = structType.GetFieldOffset(fieldName);
        if (fieldOffset < 0)
            return;

        var fieldPointer = new LocalValue($"struct_{fieldName}_ptr_{_tempCounter++}")
        { Type = new ReferenceType(fieldType) };
        var fieldGep = new GetElementPtrInstruction(destinationPtr, fieldOffset, fieldPointer);
        _currentBlock.Instructions.Add(fieldGep);
        var storeInst = new StorePointerInstruction(fieldPointer, value);
        _currentBlock.Instructions.Add(storeInst);
    }

    private FType? GetExpressionType(ExpressionNode node) => _typeSolver.GetType(node);

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
