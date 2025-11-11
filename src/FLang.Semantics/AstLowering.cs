using System.Collections.Generic;
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
    private readonly TypeSolver _typeSolver;
    private readonly List<Diagnostic> _diagnostics = new();
    private readonly Dictionary<string, Value> _locals = new();
    private int _tempCounter = 0;
    private int _blockCounter = 0;
    private BasicBlock _currentBlock = null!;
    private readonly List<BasicBlock> _allBlocks = new();
    private readonly Stack<LoopContext> _loopStack = new();

    public IReadOnlyList<Diagnostic> Diagnostics => _diagnostics;

    private class LoopContext
    {
        public BasicBlock ContinueTarget { get; }
        public BasicBlock BreakTarget { get; }

        public LoopContext(BasicBlock continueTarget, BasicBlock breakTarget)
        {
            ContinueTarget = continueTarget;
            BreakTarget = breakTarget;
        }
    }

    private AstLowering(Compilation compilation, TypeSolver typeSolver)
    {
        _compilation = compilation;
        _typeSolver = typeSolver;
    }

    public static (Function Function, IReadOnlyList<Diagnostic> Diagnostics) Lower(FunctionDeclarationNode functionNode, Compilation compilation, TypeSolver typeSolver)
    {
        var lowering = new AstLowering(compilation, typeSolver);
        var function = lowering.LowerFunction(functionNode);
        return (function, lowering.Diagnostics);
    }

    private Function LowerFunction(FunctionDeclarationNode functionNode)
    {
        var function = new Function(functionNode.Name);
        function.IsForeign = functionNode.IsForeign;

        // Add parameters to function
        foreach (var param in functionNode.Parameters)
        {
            var paramType = ResolveTypeFromNode(param.Type);
            var cType = TypeRegistry.ToCType(paramType);
            function.Parameters.Add(new IR.FunctionParameter(param.Name, cType));

            // Add parameter to locals so it can be referenced in the function body
            _locals[param.Name] = new LocalValue(param.Name);
        }

        // Foreign functions have no body
        if (functionNode.IsForeign)
        {
            return function;
        }

        _currentBlock = CreateBlock("entry");
        function.BasicBlocks.Add(_currentBlock);

        foreach (var statement in functionNode.Body)
        {
            LowerStatement(statement);
        }

        // Add all created blocks to function
        foreach (var block in _allBlocks)
        {
            if (!function.BasicBlocks.Contains(block))
            {
                function.BasicBlocks.Add(block);
            }
        }

        return function;
    }

    private Type ResolveTypeFromNode(TypeNode typeNode)
    {
        switch (typeNode)
        {
            case NamedTypeNode namedType:
            {
                var type = TypeRegistry.GetTypeByName(namedType.Name);
                if (type != null)
                {
                    return type;
                }
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
                var typeArgs = new List<Type>();
                foreach (var argNode in genericType.TypeArguments)
                {
                    typeArgs.Add(ResolveTypeFromNode(argNode));
                }
                return new GenericType(genericType.Name, typeArgs);
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
                if (varDecl.Initializer != null)
                {
                    var value = LowerExpression(varDecl.Initializer);
                    var local = new LocalValue(varDecl.Name);
                    _locals[varDecl.Name] = local;
                    _currentBlock.Instructions.Add(new StoreInstruction(varDecl.Name, value));
                }
                break;

            case ReturnStatementNode returnStmt:
                var returnValue = LowerExpression(returnStmt.Expression);
                _currentBlock.Instructions.Add(new ReturnInstruction(returnValue));
                break;

            case BreakStatementNode breakStmt:
                if (_loopStack.Count == 0)
                {
                    _diagnostics.Add(Diagnostic.Error(
                        "`break` statement outside of loop",
                        breakStmt.Span,
                        hint: "`break` can only be used inside a loop",
                        code: "E2006"
                    ));
                }
                else
                {
                    _currentBlock.Instructions.Add(new JumpInstruction(_loopStack.Peek().BreakTarget));
                }
                break;

            case ContinueStatementNode continueStmt:
                if (_loopStack.Count == 0)
                {
                    _diagnostics.Add(Diagnostic.Error(
                        "`continue` statement outside of loop",
                        continueStmt.Span,
                        hint: "`continue` can only be used inside a loop",
                        code: "E2007"
                    ));
                }
                else
                {
                    _currentBlock.Instructions.Add(new JumpInstruction(_loopStack.Peek().ContinueTarget));
                }
                break;

            case ForLoopNode forLoop:
                LowerForLoop(forLoop);
                break;

            case ExpressionStatementNode exprStmt:
                // Just evaluate the expression for its side effects (e.g., assignment)
                LowerExpression(exprStmt.Expression);
                break;
        }
    }

    private Value LowerExpression(ExpressionNode expression)
    {
        switch (expression)
        {
            case IntegerLiteralNode intLiteral:
                return new ConstantValue(intLiteral.Value);

            case BooleanLiteralNode boolLiteral:
                // In C, booleans are represented as integers (0 = false, 1 = true)
                return new ConstantValue(boolLiteral.Value ? 1 : 0);

            case IdentifierExpressionNode identifier:
                if (_locals.TryGetValue(identifier.Name, out var local))
                {
                    return local;
                }
                _diagnostics.Add(Diagnostic.Error(
                    $"cannot find value `{identifier.Name}` in this scope",
                    identifier.Span,
                    hint: "not found in this scope",
                    code: "E2004"
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
                    _ => throw new System.Exception($"Unknown binary operator: {binary.Operator}")
                };

                var temp = new LocalValue($"t{_tempCounter++}");
                var instruction = new BinaryInstruction(op, left, right)
                {
                    Result = temp
                };
                _currentBlock.Instructions.Add(instruction);
                return temp;

            case AssignmentExpressionNode assignment:
                var assignValue = LowerExpression(assignment.Value);
                if (!_locals.ContainsKey(assignment.TargetName))
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"cannot assign to `{assignment.TargetName}` because it is not declared",
                        assignment.Span,
                        hint: "declare the variable with `let` first",
                        code: "E2010"
                    ));
                    // Return the value to avoid cascading errors
                    return assignValue;
                }
                _currentBlock.Instructions.Add(new StoreInstruction(assignment.TargetName, assignValue));
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
                    hint: "use this expression inside a `for (x in range)` loop",
                    code: "E2008"
                ));
                // Return a dummy value to avoid cascading errors
                return new ConstantValue(0);

            case CallExpressionNode call:
                var args = new List<Value>();
                foreach (var arg in call.Arguments)
                {
                    args.Add(LowerExpression(arg));
                }
                var callResult = new LocalValue($"call_{_tempCounter++}");
                var callInst = new CallInstruction(call.FunctionName, args) { Result = callResult };
                _currentBlock.Instructions.Add(callInst);
                return callResult;

            case AddressOfExpressionNode addressOf:
                // Address-of: &variable
                // For now, we only support taking address of identifiers
                if (addressOf.Target is IdentifierExpressionNode addrIdentifier)
                {
                    var addrResult = new LocalValue($"addr_{_tempCounter++}");
                    var addrInst = new AddressOfInstruction(addrIdentifier.Name) { Result = addrResult };
                    _currentBlock.Instructions.Add(addrInst);
                    return addrResult;
                }
                else
                {
                    _diagnostics.Add(Diagnostic.Error(
                        "can only take address of variables",
                        addressOf.Span,
                        hint: "use `&variable_name`",
                        code: "E2012"
                    ));
                    return new ConstantValue(0); // Fallback
                }

            case DereferenceExpressionNode deref:
                // Dereference: ptr.*
                var ptrValue = LowerExpression(deref.Target);
                var loadResult = new LocalValue($"load_{_tempCounter++}");
                var loadInst = new LoadInstruction(ptrValue) { Result = loadResult };
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
                        hint: "type checking failed",
                        code: "E3001"
                    ));
                    return new ConstantValue(0);
                }

                // Allocate stack space for the struct
                var allocaResult = new LocalValue($"alloca_{_tempCounter++}");
                var allocaInst = new AllocaInstruction(structType, structType.GetSize()) { Result = allocaResult };
                _currentBlock.Instructions.Add(allocaInst);

                // Store each field value at the correct offset
                foreach (var (fieldName, fieldExpr) in structCtor.Fields)
                {
                    var fieldValue = LowerExpression(fieldExpr);
                    var fieldOffset = structType.GetFieldOffset(fieldName);

                    // Calculate field address: base + offset
                    var fieldPtrResult = new LocalValue($"field_ptr_{_tempCounter++}");
                    var gepInst = new GetElementPtrInstruction(allocaResult, fieldOffset) { Result = fieldPtrResult };
                    _currentBlock.Instructions.Add(gepInst);

                    // Store value to field
                    var storeInst = new StorePointerInstruction(fieldPtrResult, fieldValue);
                    _currentBlock.Instructions.Add(storeInst);
                }

                // Return pointer to the struct
                return allocaResult;

            case FieldAccessExpressionNode fieldAccess:
                // Get struct type from the target expression
                var targetValue = LowerExpression(fieldAccess.Target);
                var targetType = _typeSolver.GetType(fieldAccess.Target) as StructType;
                if (targetType == null)
                {
                    _diagnostics.Add(Diagnostic.Error(
                        "cannot access field on non-struct type",
                        fieldAccess.Span,
                        hint: "type checking failed",
                        code: "E3002"
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
                        hint: "type checking failed",
                        code: "E3003"
                    ));
                    return new ConstantValue(0);
                }

                // Get pointer to field: targetPtr + offset
                var fieldPointer = new LocalValue($"field_ptr_{_tempCounter++}");
                var fieldGepInst = new GetElementPtrInstruction(targetValue, fieldByteOffset) { Result = fieldPointer };
                _currentBlock.Instructions.Add(fieldGepInst);

                // Load value from field
                var fieldLoadResult = new LocalValue($"field_load_{_tempCounter++}");
                var fieldLoadInst = new LoadInstruction(fieldPointer) { Result = fieldLoadResult };
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
                        hint: "type checking failed",
                        code: "E3004"
                    ));
                    return new ConstantValue(0);
                }

                // Allocate stack space for the array
                var arrayAllocaResult = new LocalValue($"array_{_tempCounter++}");
                var arrayAllocaInst = new AllocaInstruction(arrayType, arrayType.GetSize()) { Result = arrayAllocaResult };
                _currentBlock.Instructions.Add(arrayAllocaInst);

                // Store each element value
                if (arrayLiteral.IsRepeatSyntax)
                {
                    // Repeat syntax: [value; count]
                    var repeatValue = LowerExpression(arrayLiteral.RepeatValue!);
                    var elementSize = GetTypeSize(arrayType.ElementType);

                    for (int i = 0; i < arrayLiteral.RepeatCount!.Value; i++)
                    {
                        // Calculate element address: base + (i * element_size)
                        var elemPtrResult = new LocalValue($"elem_ptr_{_tempCounter++}");
                        var elemGepInst = new GetElementPtrInstruction(arrayAllocaResult, i * elementSize) { Result = elemPtrResult };
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

                    for (int i = 0; i < arrayLiteral.Elements!.Count; i++)
                    {
                        var elemValue = LowerExpression(arrayLiteral.Elements[i]);

                        // Calculate element address: base + (i * element_size)
                        var elemPtrResult = new LocalValue($"elem_ptr_{_tempCounter++}");
                        var elemGepInst = new GetElementPtrInstruction(arrayAllocaResult, i * elementSize) { Result = elemPtrResult };
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
                    var offsetTemp = new LocalValue($"offset_{_tempCounter++}");
                    var offsetInst = new BinaryInstruction(BinaryOp.Multiply, indexValue, new ConstantValue(elemSize)) { Result = offsetTemp };
                    _currentBlock.Instructions.Add(offsetInst);

                    // Calculate element address: base + offset
                    var indexElemPtr = new LocalValue($"index_ptr_{_tempCounter++}");
                    var indexGepInst = new GetElementPtrInstruction(baseValue, offsetTemp) { Result = indexElemPtr };
                    _currentBlock.Instructions.Add(indexGepInst);

                    // Load value from element
                    var indexLoadResult = new LocalValue($"index_load_{_tempCounter++}");
                    var indexLoadInst = new LoadInstruction(indexElemPtr) { Result = indexLoadResult };
                    _currentBlock.Instructions.Add(indexLoadInst);

                    return indexLoadResult;
                }
                else if (baseArrayType is SliceType sliceTypeForIndex)
                {
                    // Slice indexing: slice[i]
                    // For now, simplified - full slice support deferred
                    _diagnostics.Add(Diagnostic.Error(
                        "slice indexing not yet implemented",
                        indexExpr.Span,
                        hint: "use array indexing for now",
                        code: "E3005"
                    ));
                    return new ConstantValue(0);
                }
                else
                {
                    _diagnostics.Add(Diagnostic.Error(
                        "cannot index non-array type",
                        indexExpr.Span,
                        hint: "type checking failed",
                        code: "E3006"
                    ));
                    return new ConstantValue(0);
                }

            default:
                throw new System.Exception($"Unknown expression type: {expression.GetType().Name}");
        }
    }

    private int GetTypeSize(FLang.Core.Type type)
    {
        return type switch
        {
            PrimitiveType pt => pt.SizeInBytes,
            ReferenceType => IntPtr.Size,
            StructType st => st.GetSize(),
            ArrayType at => at.GetSize(),
            _ => 4 // Default fallback
        };
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
        _currentBlock.Instructions.Add(new StoreInstruction(thenResult.Name, thenValue));
        _currentBlock.Instructions.Add(new JumpInstruction(mergeBlock));

        // Lower else branch if it exists
        Value? elseResult = null;
        if (ifExpr.ElseBranch != null && elseBlock != null)
        {
            _currentBlock = elseBlock;
            var elseValue = LowerExpression(ifExpr.ElseBranch);
            elseResult = new LocalValue($"if_result_else_{_tempCounter++}");
            _currentBlock.Instructions.Add(new StoreInstruction(elseResult.Name, elseValue));
            _currentBlock.Instructions.Add(new JumpInstruction(mergeBlock));
        }

        // Continue in merge block
        _currentBlock = mergeBlock;

        // For now, return the then result (proper SSA would use phi nodes or block arguments)
        return thenResult;
    }

    private Value LowerBlockExpression(BlockExpressionNode blockExpr)
    {
        foreach (var stmt in blockExpr.Statements)
        {
            LowerStatement(stmt);
        }

        if (blockExpr.TrailingExpression != null)
        {
            return LowerExpression(blockExpr.TrailingExpression);
        }

        // Block with no trailing expression returns unit/void (use 0 for now)
        return new ConstantValue(0);
    }

    private void LowerForLoop(ForLoopNode forLoop)
    {
        // Only handle Range expressions for now
        if (forLoop.IterableExpression is not RangeExpressionNode range)
        {
            _diagnostics.Add(Diagnostic.Error(
                "`for` loops currently only support range expressions",
                forLoop.IterableExpression.Span,
                hint: "use a range like `0..10` for iteration",
                code: "E2009"
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
        _currentBlock.Instructions.Add(new StoreInstruction(iteratorVar.Name, start));
        _currentBlock.Instructions.Add(new JumpInstruction(condBlock));

        // Condition: iterator < end
        _currentBlock = condBlock;
        var lessThan = new LocalValue($"loop_cond_{_tempCounter++}");
        var cmpInst = new BinaryInstruction(BinaryOp.Subtract, iteratorVar, end) { Result = lessThan };
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
        var incInst = new BinaryInstruction(BinaryOp.Add, iteratorVar, new ConstantValue(1)) { Result = incremented };
        _currentBlock.Instructions.Add(incInst);
        _currentBlock.Instructions.Add(new StoreInstruction(iteratorVar.Name, incremented));
        _currentBlock.Instructions.Add(new JumpInstruction(condBlock));

        // Exit
        _currentBlock = exitBlock;
    }
}
