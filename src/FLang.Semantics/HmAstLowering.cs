using System.Numerics;
using System.Text;
using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;
using FLang.IR;
using FLang.IR.Instructions;
using FunctionType = FLang.Core.Types.FunctionType;
using Type = FLang.Core.Types.Type;

namespace FLang.Semantics;

/// <summary>
/// Lowers type-checked AST (via HmTypeChecker) to IrModule.
/// Uses IrType exclusively — no TypeBase.
/// </summary>
public class HmAstLowering
{
    private readonly HmTypeChecker _checker;
    private readonly TypeLayoutService _layout;
    private readonly InferenceEngine _engine;
    private readonly IrModule _module = new();
    private readonly List<Diagnostic> _diagnostics = [];

    // Per-function state
    private readonly Dictionary<string, Value> _locals = [];
    private readonly HashSet<string> _parameters = [];
    private readonly Dictionary<string, int> _shadowCounter = [];
    private BasicBlock _currentBlock = null!;
    private IrFunction _currentFunction = null!;
    private int _tempCounter;
    private int _blockCounter;
    private readonly Dictionary<string, int> _stringTableIndices = [];

    // Loop control flow
    private readonly Stack<(BasicBlock BodyBlock, BasicBlock ExitBlock)> _loopStack = new();

    // Defer stack — per-function, stores deferred expressions in LIFO order
    private readonly Stack<ExpressionNode> _deferStack = new();

    public IReadOnlyList<Diagnostic> Diagnostics => _diagnostics;

    public HmAstLowering(HmTypeChecker checker, TypeLayoutService layout, InferenceEngine engine)
    {
        _checker = checker;
        _layout = layout;
        _engine = engine;
    }

    // =========================================================================
    // Module lowering
    // =========================================================================

    public IrModule LowerModule(IEnumerable<(string ModulePath, ModuleNode Module)> modules)
    {
        // Collect foreign declarations (also collects types from signatures)
        foreach (var (modulePath, module) in modules)
        {
            foreach (var fn in module.Functions)
            {
                if ((fn.Modifiers & FunctionModifiers.Foreign) == 0) continue;
                var foreignDecl = LowerForeignDecl(fn);
                if (foreignDecl != null)
                    _module.ForeignDecls.Add(foreignDecl);
            }
        }

        // Lower non-generic, non-foreign functions
        foreach (var (modulePath, module) in modules)
        {
            foreach (var fn in module.Functions)
            {
                if ((fn.Modifiers & FunctionModifiers.Foreign) != 0) continue;
                if (fn.IsGeneric) continue;
                var irFn = LowerFunction(fn);
                _module.Functions.Add(irFn);
            }
        }

        // Collect struct/enum types referenced in function signatures
        CollectReferencedTypes();

        // Post-lowering validation: mark functions that call unlowered targets
        ValidateCallTargets();

        return _module;
    }

    // =========================================================================
    // Post-lowering validation
    // =========================================================================

    /// <summary>
    /// Mark functions as unsupported if they call targets that don't exist in the module.
    /// This catches calls to generic functions that weren't specialized/lowered.
    /// </summary>
    private void ValidateCallTargets()
    {
        var knownFunctions = new HashSet<string>();
        foreach (var fn in _module.Functions)
            knownFunctions.Add(MangleFunctionName(fn.Name, fn.Params.Select(p => p.Type).ToArray()));
        foreach (var decl in _module.ForeignDecls)
            knownFunctions.Add(decl.CName);
        // C stdlib functions are always available
        knownFunctions.UnionWith([
            "printf", "fprintf", "sprintf", "snprintf", "puts", "putchar",
            "malloc", "calloc", "realloc", "free",
            "memcpy", "memset", "memmove", "memcmp",
            "strlen", "strcmp", "strncmp", "strcpy", "strncpy",
            "abort", "exit", "atexit"
        ]);

        foreach (var fn in _module.Functions)
        {
            foreach (var block in fn.BasicBlocks)
            {
                foreach (var inst in block.Instructions)
                {
                    if (inst is CallInstruction call && !call.IsForeignCall)
                    {
                        var irParamTypes = call.CalleeIrParamTypes
                            ?? call.Arguments.Select(a => a.IrType ?? TypeLayoutService.IrI32).ToArray();
                        var calleeName = MangleFunctionName(call.FunctionName, (IReadOnlyList<IrType>)irParamTypes);
                        if (!knownFunctions.Contains(calleeName))
                        {
                            _diagnostics.Add(Diagnostic.Error(
                                $"Unknown call target `{calleeName}` in function `{fn.Name}`",
                                default, null, "E3002"));
                        }
                    }
                }
            }
        }
    }

    // =========================================================================
    // Type collection — gather struct/enum types from function signatures
    // =========================================================================

    private void CollectReferencedTypes()
    {
        var collected = new HashSet<string>();

        foreach (var fn in _module.Functions)
        {
            CollectIrType(fn.ReturnType, collected);
            foreach (var p in fn.Params)
                CollectIrType(p.Type, collected);
        }

        foreach (var decl in _module.ForeignDecls)
        {
            CollectIrType(decl.ReturnType, collected);
            foreach (var pt in decl.ParamTypes)
                CollectIrType(pt, collected);
        }
    }

    private void CollectIrType(IrType type, HashSet<string> collected)
    {
        switch (type)
        {
            case IrStruct s:
                if (collected.Add(s.Name))
                {
                    // Collect field types first (dependencies)
                    foreach (var f in s.Fields)
                        CollectIrType(f.Type, collected);
                    _module.TypeDefs.Add(s);
                }
                break;
            case IrEnum e:
                if (collected.Add(e.Name))
                {
                    foreach (var v in e.Variants)
                        if (v.PayloadType != null)
                            CollectIrType(v.PayloadType, collected);
                    _module.TypeDefs.Add(e);
                }
                break;
            case IrPointer p:
                CollectIrType(p.Pointee, collected);
                break;
            case IrArray a:
                CollectIrType(a.Element, collected);
                break;
            case IrFunctionPtr fp:
                CollectIrType(fp.Return, collected);
                foreach (var pt in fp.Params)
                    CollectIrType(pt, collected);
                break;
        }
    }

    // =========================================================================
    // Foreign declaration lowering
    // =========================================================================

    private IrForeignDecl LowerForeignDecl(FunctionDeclarationNode fn)
    {
        var fnType = GetFunctionHmType(fn);
        var retIr = _layout.Lower(fnType.ReturnType);
        var paramIrs = new IrType[fnType.ParameterTypes.Count];
        for (int i = 0; i < fnType.ParameterTypes.Count; i++)
            paramIrs[i] = _layout.Lower(fnType.ParameterTypes[i]);

        return new IrForeignDecl(fn.Name, fn.Name, retIr, paramIrs);
    }

    // =========================================================================
    // Function lowering
    // =========================================================================

    private IrFunction LowerFunction(FunctionDeclarationNode fn)
    {
        // Reset per-function state
        _locals.Clear();
        _parameters.Clear();
        _shadowCounter.Clear();
        _loopStack.Clear();
        _deferStack.Clear();
        _tempCounter = 0;
        _blockCounter = 0;

        var fnType = GetFunctionHmType(fn);
        var retIrType = _layout.Lower(fnType.ReturnType);

        var irFn = new IrFunction(fn.Name, retIrType);
        _currentFunction = irFn;

        if (fn.Name == "main")
            irFn.IsEntryPoint = true;

        // Create entry block
        _currentBlock = CreateBlock("entry");
        irFn.BasicBlocks.Add(_currentBlock);

        // Lower parameters
        if (fnType != null)
        {
            for (int i = 0; i < fn.Parameters.Count; i++)
            {
                var param = fn.Parameters[i];
                var paramIrType = _layout.Lower(fnType.ParameterTypes[i]);
                irFn.Params.Add(new IrParam(param.Name, paramIrType));

                var paramVal = new LocalValue(param.Name, paramIrType);
                _locals[param.Name] = paramVal;
                _parameters.Add(param.Name);
            }
        }

        // Lower body statements
        foreach (var stmt in fn.Body)
            LowerStatement(stmt);

        // Emit deferred expressions at function epilogue (before implicit return)
        EmitDeferredExpressions();

        // Add implicit void return if block has no terminator
        foreach (var block in irFn.BasicBlocks)
        {
            if (block.Instructions.Count == 0 ||
                block.Instructions[^1] is not (ReturnInstruction or JumpInstruction or BranchInstruction))
            {
                var voidVal = new ConstantValue(0, TypeLayoutService.IrVoidPrim);
                block.Instructions.Add(new ReturnInstruction(voidVal));
            }
        }

        return irFn;
    }

    // =========================================================================
    // Statement lowering
    // =========================================================================

    private void LowerStatement(StatementNode stmt)
    {
        switch (stmt)
        {
            case ReturnStatementNode ret:
                LowerReturn(ret);
                break;
            case ExpressionStatementNode exprStmt:
                LowerExpression(exprStmt.Expression);
                break;
            case VariableDeclarationNode varDecl:
                LowerVariableDeclaration(varDecl);
                break;
            case LoopNode loop:
                LowerLoop(loop);
                break;
            case BreakStatementNode brk:
                LowerBreak(brk);
                break;
            case ContinueStatementNode cont:
                LowerContinue(cont);
                break;
            case ForLoopNode forLoop:
                LowerForLoop(forLoop);
                break;
            case DeferStatementNode defer:
                LowerDefer(defer);
                break;
        }
    }

    private void LowerReturn(ReturnStatementNode ret)
    {
        // Emit deferred expressions before returning
        EmitDeferredExpressions();

        if (ret.Expression != null)
        {
            var val = LowerExpression(ret.Expression);
            _currentBlock.Instructions.Add(new ReturnInstruction(val));
        }
        else
        {
            var voidVal = new ConstantValue(0, TypeLayoutService.IrVoidPrim);
            _currentBlock.Instructions.Add(new ReturnInstruction(voidVal));
        }
    }

    private void LowerVariableDeclaration(VariableDeclarationNode varDecl)
    {
        var irType = GetIrType(varDecl);
        var uniqueName = GetUniqueVariableName(varDecl.Name);

        // Allocate stack space
        var allocaResult = new LocalValue(uniqueName, new IrPointer(irType));
        _currentBlock.Instructions.Add(new AllocaInstruction(null!, irType.Size, allocaResult)
        {
            // AllocaInstruction uses TypeBase for AllocatedType — leave null for new pipeline
            // The IrType is carried on the result value
        });

        // Store initializer if present
        if (varDecl.Initializer != null)
        {
            var initVal = LowerExpression(varDecl.Initializer);
            _currentBlock.Instructions.Add(new StorePointerInstruction(allocaResult, initVal));
        }

        _locals[varDecl.Name] = allocaResult;
    }

    private void LowerLoop(LoopNode loop)
    {
        var bodyBlock = CreateBlock("loop_body");
        var exitBlock = CreateBlock("loop_exit");

        // Jump from current block into the loop body
        _currentBlock.Instructions.Add(new JumpInstruction(bodyBlock));
        _currentFunction.BasicBlocks.Add(bodyBlock);
        _currentBlock = bodyBlock;

        // Push loop context for break/continue
        _loopStack.Push((bodyBlock, exitBlock));

        // Lower loop body — the body is an ExpressionNode (typically a BlockExpression)
        LowerExpression(loop.Body);

        // Pop loop context
        _loopStack.Pop();

        // Back-edge: jump back to loop body (if not already terminated)
        if (_currentBlock.Instructions.Count == 0 ||
            _currentBlock.Instructions[^1] is not (ReturnInstruction or JumpInstruction or BranchInstruction))
        {
            _currentBlock.Instructions.Add(new JumpInstruction(bodyBlock));
        }

        // Continue after the loop
        _currentFunction.BasicBlocks.Add(exitBlock);
        _currentBlock = exitBlock;
    }

    private void LowerBreak(BreakStatementNode _)
    {
        if (_loopStack.Count == 0)
        {
            _diagnostics.Add(Diagnostic.Error("break outside of loop", _.Span, null, "E3015"));
            return;
        }

        var (_, exitBlock) = _loopStack.Peek();
        _currentBlock.Instructions.Add(new JumpInstruction(exitBlock));

        // Start a dead block — subsequent code is unreachable but we need a valid block
        var deadBlock = CreateBlock("dead");
        _currentFunction.BasicBlocks.Add(deadBlock);
        _currentBlock = deadBlock;
    }

    private void LowerContinue(ContinueStatementNode _)
    {
        if (_loopStack.Count == 0)
        {
            _diagnostics.Add(Diagnostic.Error("continue outside of loop", _.Span, null, "E3016"));
            return;
        }

        var (bodyBlock, _2) = _loopStack.Peek();
        _currentBlock.Instructions.Add(new JumpInstruction(bodyBlock));

        // Start a dead block
        var deadBlock = CreateBlock("dead");
        _currentFunction.BasicBlocks.Add(deadBlock);
        _currentBlock = deadBlock;
    }

    private void LowerForLoop(ForLoopNode forLoop)
    {
        // If iter/next functions are not resolved, fall back to direct array iteration
        if (forLoop.ResolvedIterFunction == null || forLoop.ResolvedNextFunction == null)
        {
            LowerForLoopDirect(forLoop);
            return;
        }

        // Get element type (recorded by type checker)
        var elementIrType = GetIrType(forLoop);

        // Get iterator type from iter function return type
        var iterFnType = GetFunctionHmType(forLoop.ResolvedIterFunction);
        var iteratorIrType = _layout.Lower(iterFnType.ReturnType);

        // Get Option type from next function return type
        var nextFnType = GetFunctionHmType(forLoop.ResolvedNextFunction);
        var optionIrType = _layout.Lower(nextFnType.ReturnType);

        // Create loop blocks
        var condBlock = CreateBlock("for_cond");
        var bodyBlock = CreateBlock("for_body");
        var exitBlock = CreateBlock("for_exit");

        // 1. Lower iterable expression
        var iterableVal = LowerExpression(forLoop.IterableExpression);

        // Materialize iterable to alloca if not already a pointer (iter takes &T)
        if (iterableVal.IrType is not IrPointer)
        {
            var iterableIrType = iterableVal.IrType ?? TypeLayoutService.IrVoidPrim;
            var temp = new LocalValue($"iterable_tmp_{_tempCounter++}", new IrPointer(iterableIrType));
            _currentBlock.Instructions.Add(new AllocaInstruction(null!, iterableIrType.Size, temp));
            _currentBlock.Instructions.Add(new StorePointerInstruction(temp, iterableVal));
            iterableVal = temp;
        }

        // 2. Call iter(&iterable) → IteratorStruct
        var iterResult = new LocalValue($"iter_{_tempCounter++}", iteratorIrType);
        var iterCalleeParamTypes = new List<IrType>();
        foreach (var p in forLoop.ResolvedIterFunction.Parameters)
            iterCalleeParamTypes.Add(GetIrType(p));
        var iterCall = new CallInstruction("iter", [iterableVal], iterResult);
        if (iterCalleeParamTypes.Count > 0)
            iterCall.CalleeIrParamTypes = iterCalleeParamTypes;
        _currentBlock.Instructions.Add(iterCall);

        // 3. Allocate iterator state on stack
        var iteratorPtr = new LocalValue($"iter_ptr_{_tempCounter++}", new IrPointer(iteratorIrType));
        _currentBlock.Instructions.Add(new AllocaInstruction(null!, iteratorIrType.Size, iteratorPtr));
        _currentBlock.Instructions.Add(new StorePointerInstruction(iteratorPtr, iterResult));

        // 4. Allocate loop variable on stack
        var loopVarName = GetUniqueVariableName(forLoop.IteratorVariable);
        var loopVarPtr = new LocalValue(loopVarName, new IrPointer(elementIrType));
        _currentBlock.Instructions.Add(new AllocaInstruction(null!, elementIrType.Size, loopVarPtr));
        _locals[forLoop.IteratorVariable] = loopVarPtr;

        // Jump to condition block
        _currentBlock.Instructions.Add(new JumpInstruction(condBlock));

        // 5. Condition block: call next(&iterator), check has_value
        _currentFunction.BasicBlocks.Add(condBlock);
        _currentBlock = condBlock;

        var nextResult = new LocalValue($"next_{_tempCounter++}", optionIrType);
        var nextCalleeParamTypes = new List<IrType>();
        foreach (var p in forLoop.ResolvedNextFunction.Parameters)
            nextCalleeParamTypes.Add(GetIrType(p));
        var nextCall = new CallInstruction("next", [iteratorPtr], nextResult);
        if (nextCalleeParamTypes.Count > 0)
            nextCall.CalleeIrParamTypes = nextCalleeParamTypes;
        _currentBlock.Instructions.Add(nextCall);

        // Materialize next result to alloca so we can GEP into it
        var nextPtr = new LocalValue($"next_ptr_{_tempCounter++}", new IrPointer(optionIrType));
        _currentBlock.Instructions.Add(new AllocaInstruction(null!, optionIrType.Size, nextPtr));
        _currentBlock.Instructions.Add(new StorePointerInstruction(nextPtr, nextResult));

        // Load has_value field
        var optionStruct = (IrStruct)optionIrType;
        var hvField = FindField(optionStruct, "has_value")
;

        var hvPtr = new LocalValue($"for_hv_ptr_{_tempCounter++}", new IrPointer(hvField.Type));
        _currentBlock.Instructions.Add(
            new GetElementPtrInstruction(nextPtr, hvField.ByteOffset, hvPtr));
        var hvVal = new LocalValue($"for_hv_{_tempCounter++}", TypeLayoutService.IrBool);
        _currentBlock.Instructions.Add(new LoadInstruction(hvPtr, hvVal));

        // Branch: has_value → body, else → exit
        _currentBlock.Instructions.Add(new BranchInstruction(hvVal, bodyBlock, exitBlock));

        // 6. Body block: extract value, store to loop var, lower body, jump back to cond
        _currentFunction.BasicBlocks.Add(bodyBlock);
        _currentBlock = bodyBlock;

        _loopStack.Push((condBlock, exitBlock));

        // Extract value field from Option
        var valField = FindField(optionStruct, "value")
;
        var valPtr = new LocalValue($"for_val_ptr_{_tempCounter++}", new IrPointer(valField.Type));
        _currentBlock.Instructions.Add(
            new GetElementPtrInstruction(nextPtr, valField.ByteOffset, valPtr));
        var valLoaded = new LocalValue($"for_val_{_tempCounter++}", elementIrType);
        _currentBlock.Instructions.Add(new LoadInstruction(valPtr, valLoaded));
        _currentBlock.Instructions.Add(new StorePointerInstruction(loopVarPtr, valLoaded));

        // Lower loop body
        LowerExpression(forLoop.Body);

        _loopStack.Pop();

        // Back-edge to condition
        if (_currentBlock.Instructions.Count == 0 ||
            _currentBlock.Instructions[^1] is not (ReturnInstruction or JumpInstruction or BranchInstruction))
        {
            _currentBlock.Instructions.Add(new JumpInstruction(condBlock));
        }

        // 7. Exit block
        _currentFunction.BasicBlocks.Add(exitBlock);
        _currentBlock = exitBlock;
    }

    /// <summary>
    /// Direct index-based iteration for arrays/slices when no iter/next functions are resolved.
    /// Pattern: index = 0; while (index < length) { elem = arr[index]; body; index++; }
    /// </summary>
    private void LowerForLoopDirect(ForLoopNode forLoop)
    {
        var elementIrType = GetIrType(forLoop);

        // Lower iterable
        var iterableVal = LowerExpression(forLoop.IterableExpression);

        // Determine array length and get a pointer to the array data
        var usizeType = TypeLayoutService.IrUSize;
        Value arrayPtr;
        Value lengthVal;

        var baseIrType = iterableVal.IrType;
        // If it's a pointer to an array, load through it
        if (baseIrType is IrPointer ptrType && ptrType.Pointee is IrArray)
            baseIrType = ptrType.Pointee;

        if (baseIrType is IrArray irArray && irArray.Length.HasValue)
        {
            // Fixed-size array — length is compile-time known
            lengthVal = new ConstantValue(irArray.Length.Value, usizeType);

            // Get pointer to array start
            if (iterableVal.IrType is IrPointer)
                arrayPtr = iterableVal; // already a pointer
            else
            {
                // Materialize to stack
                var temp = new LocalValue($"arr_tmp_{_tempCounter++}", new IrPointer(baseIrType));
                _currentBlock.Instructions.Add(new AllocaInstruction(null!, baseIrType.Size, temp));
                _currentBlock.Instructions.Add(new StorePointerInstruction(temp, iterableVal));
                arrayPtr = temp;
            }
        }
        else
        {
            throw new InvalidOperationException(
                $"BUG: Unsupported direct iteration over {baseIrType} at {forLoop.Span}");
        }

        // Allocate index counter (usize, init to 0)
        var indexPtr = new LocalValue($"for_idx_{_tempCounter++}", new IrPointer(usizeType));
        _currentBlock.Instructions.Add(new AllocaInstruction(null!, usizeType.Size, indexPtr));
        _currentBlock.Instructions.Add(new StorePointerInstruction(indexPtr,
            new ConstantValue(0, usizeType)));

        // Allocate loop variable
        var loopVarName = GetUniqueVariableName(forLoop.IteratorVariable);
        var loopVarPtr = new LocalValue(loopVarName, new IrPointer(elementIrType));
        _currentBlock.Instructions.Add(new AllocaInstruction(null!, elementIrType.Size, loopVarPtr));
        _locals[forLoop.IteratorVariable] = loopVarPtr;

        // Create blocks
        var condBlock = CreateBlock("for_cond");
        var bodyBlock = CreateBlock("for_body");
        var exitBlock = CreateBlock("for_exit");

        _currentBlock.Instructions.Add(new JumpInstruction(condBlock));

        // Condition block: load index, compare < length
        _currentFunction.BasicBlocks.Add(condBlock);
        _currentBlock = condBlock;

        var indexVal = new LocalValue($"for_i_{_tempCounter++}", usizeType);
        _currentBlock.Instructions.Add(new LoadInstruction(indexPtr, indexVal));

        var cmpResult = new LocalValue($"for_cmp_{_tempCounter++}", TypeLayoutService.IrBool);
        _currentBlock.Instructions.Add(
            new BinaryInstruction(BinaryOp.LessThan, indexVal, lengthVal, cmpResult));

        _currentBlock.Instructions.Add(new BranchInstruction(cmpResult, bodyBlock, exitBlock));

        // Body block: GEP to array[index], load element, store to loop var
        _currentFunction.BasicBlocks.Add(bodyBlock);
        _currentBlock = bodyBlock;

        _loopStack.Push((condBlock, exitBlock));

        // Compute byte offset: index * element_size
        var elemSize = new ConstantValue(elementIrType.Size, usizeType);
        var byteOffset = new LocalValue($"for_off_{_tempCounter++}", usizeType);
        _currentBlock.Instructions.Add(
            new BinaryInstruction(BinaryOp.Multiply, indexVal, elemSize, byteOffset));

        // GEP to element
        var elemPtr = new LocalValue($"for_elem_ptr_{_tempCounter++}", new IrPointer(elementIrType));
        _currentBlock.Instructions.Add(new GetElementPtrInstruction(arrayPtr, byteOffset, elemPtr));

        // Load element and store to loop variable
        var elemVal = new LocalValue($"for_elem_{_tempCounter++}", elementIrType);
        _currentBlock.Instructions.Add(new LoadInstruction(elemPtr, elemVal));
        _currentBlock.Instructions.Add(new StorePointerInstruction(loopVarPtr, elemVal));

        // Lower loop body
        LowerExpression(forLoop.Body);

        _loopStack.Pop();

        // Increment index: index = index + 1
        var one = new ConstantValue(1, usizeType);
        var indexVal2 = new LocalValue($"for_i2_{_tempCounter++}", usizeType);
        _currentBlock.Instructions.Add(new LoadInstruction(indexPtr, indexVal2));
        var nextIndex = new LocalValue($"for_inc_{_tempCounter++}", usizeType);
        _currentBlock.Instructions.Add(
            new BinaryInstruction(BinaryOp.Add, indexVal2, one, nextIndex));
        _currentBlock.Instructions.Add(new StorePointerInstruction(indexPtr, nextIndex));

        // Back-edge to condition
        if (_currentBlock.Instructions.Count == 0 ||
            _currentBlock.Instructions[^1] is not (ReturnInstruction or JumpInstruction or BranchInstruction))
        {
            _currentBlock.Instructions.Add(new JumpInstruction(condBlock));
        }

        // Exit block
        _currentFunction.BasicBlocks.Add(exitBlock);
        _currentBlock = exitBlock;
    }

    private void LowerDefer(DeferStatementNode defer)
    {
        // Push the expression onto the defer stack; it will be emitted before returns
        _deferStack.Push(defer.Expression);
    }

    /// <summary>
    /// Emit all deferred expressions in LIFO order. Does not clear the stack
    /// (so multiple returns each emit all defers).
    /// </summary>
    private void EmitDeferredExpressions()
    {
        if (_deferStack.Count == 0) return;
        // Emit in LIFO order (stack iteration is LIFO)
        foreach (var expr in _deferStack)
        {
            LowerExpression(expr);
        }
    }

    // =========================================================================
    // Expression lowering
    // =========================================================================

    private Value LowerExpression(ExpressionNode expr)
    {
        return expr switch
        {
            IntegerLiteralNode intLit => LowerIntegerLiteral(intLit),
            BooleanLiteralNode boolLit => LowerBooleanLiteral(boolLit),
            StringLiteralNode strLit => LowerStringLiteral(strLit),
            NullLiteralNode nullLit => LowerNullLiteral(nullLit),
            IdentifierExpressionNode id => LowerIdentifier(id),
            CallExpressionNode call => LowerCall(call),
            BinaryExpressionNode binary => LowerBinary(binary),
            UnaryExpressionNode unary => LowerUnary(unary),
            MemberAccessExpressionNode member => LowerMemberAccess(member),
            CastExpressionNode cast => LowerCast(cast),
            BlockExpressionNode block => LowerBlock(block),
            IfExpressionNode ifExpr => LowerIf(ifExpr),
            AddressOfExpressionNode addrOf => LowerAddressOf(addrOf),
            DereferenceExpressionNode deref => LowerDereference(deref),
            AssignmentExpressionNode assign => LowerAssignment(assign),
            StructConstructionExpressionNode structCtor => LowerStructConstruction(structCtor),
            AnonymousStructExpressionNode anonStruct => LowerAnonymousStruct(anonStruct),
            ArrayLiteralExpressionNode arrLit => LowerArrayLiteral(arrLit),
            IndexExpressionNode index => LowerIndex(index),
            RangeExpressionNode range => LowerRange(range),
            ImplicitCoercionNode coercion => LowerImplicitCoercion(coercion),
            CoalesceExpressionNode coalesce => LowerCoalesce(coalesce),
            NullPropagationExpressionNode nullProp => LowerNullPropagation(nullProp),
            _ => throw new NotImplementedException($"Lowering of expression type {expr.GetType()} is not implemented.")
        };
    }

    private Value LowerIntegerLiteral(IntegerLiteralNode intLit)
    {
        var irType = GetIrType(intLit);
        return new ConstantValue(intLit.Value, irType);
    }

    private Value LowerBooleanLiteral(BooleanLiteralNode boolLit)
    {
        return new ConstantValue(boolLit.Value ? 1 : 0, TypeLayoutService.IrBool);
    }

    private Value LowerStringLiteral(StringLiteralNode strLit)
    {
        var stringNominal = _checker.LookupNominalType(WellKnown.String)
            ?? throw new InvalidOperationException($"Well-known type `{WellKnown.String}` not registered");
        var stringIrType = _layout.Lower(stringNominal);

        // Deduplicate: reuse existing entry for the same string value
        if (_stringTableIndices.TryGetValue(strLit.Value, out var existingIndex))
            return new StringTableValue(existingIndex, stringIrType);

        // Encode string to UTF-8 with null terminator
        var bytes = Encoding.UTF8.GetBytes(strLit.Value);
        var nullTerminated = new byte[bytes.Length + 1];
        Array.Copy(bytes, nullTerminated, bytes.Length);

        var index = _module.StringTable.Count;
        _module.StringTable.Add(new StringTableEntry(strLit.Value, nullTerminated));
        _stringTableIndices[strLit.Value] = index;

        return new StringTableValue(index, stringIrType);
    }

    private Value LowerNullLiteral(NullLiteralNode nullLit)
    {
        // Null is an Option with has_value = false
        var irType = GetIrType(nullLit);

        if (irType is IrStruct optionStruct && optionStruct.Fields.Length > 0)
        {
            // Alloca the option struct, store has_value = false (0)
            var allocaResult = new LocalValue($"null_{_tempCounter++}", new IrPointer(irType));
            _currentBlock.Instructions.Add(new AllocaInstruction(null!, irType.Size, allocaResult));

            // Find has_value field and store 0
            foreach (var f in optionStruct.Fields)
            {
                if (f.Name == "has_value")
                {
                    var fieldPtr = new LocalValue($"null_hv_ptr_{_tempCounter++}", new IrPointer(f.Type));
                    _currentBlock.Instructions.Add(new GetElementPtrInstruction(allocaResult, f.ByteOffset, fieldPtr));
                    _currentBlock.Instructions.Add(new StorePointerInstruction(fieldPtr,
                        new ConstantValue(0, TypeLayoutService.IrBool)));
                    break;
                }
            }

            // Load and return the struct
            var loaded = new LocalValue($"null_val_{_tempCounter++}", irType);
            _currentBlock.Instructions.Add(new LoadInstruction(allocaResult, loaded));
            return loaded;
        }

        return new ConstantValue(0, irType);
    }

    private Value LowerIdentifier(IdentifierExpressionNode id)
    {
        if (_locals.TryGetValue(id.Name, out var localVal))
        {
            if (_parameters.Contains(id.Name))
            {
                // Parameters are used directly
                return localVal;
            }

            // Local variables are stored via alloca — need to load
            var irType = GetIrType(id);
            var loaded = new LocalValue($"t{_tempCounter++}", irType);
            _currentBlock.Instructions.Add(new LoadInstruction(localVal, loaded));
            return loaded;
        }

        // Check for function reference
        if (_checker.GetInferredType(id) is FunctionType)
            return new FunctionReferenceValue(id.Name, null!) { IrType = GetIrType(id) };

        _diagnostics.Add(Diagnostic.Error(
            $"Unresolved identifier `{id.Name}`", id.Span, null, "E3002"));
        return new ConstantValue(0, TypeLayoutService.IrVoidPrim);
    }

    private Value LowerCall(CallExpressionNode call)
    {
        var retIrType = GetIrType(call);

        // Lower arguments
        var args = new List<Value>();

        // UFCS: prepend receiver as first arg
        if (call.UfcsReceiver != null)
        {
            var receiverVal = LowerExpression(call.UfcsReceiver);

            // UFCS temp materialization: if receiver is not already a pointer,
            // save to a temp alloca so the callee can receive a pointer
            if (receiverVal.IrType is not IrPointer)
            {
                var receiverIrType = receiverVal.IrType ?? TypeLayoutService.IrVoidPrim;
                var temp = new LocalValue($"ufcs_tmp_{_tempCounter++}", new IrPointer(receiverIrType));
                _currentBlock.Instructions.Add(new AllocaInstruction(null!, receiverIrType.Size, temp));
                _currentBlock.Instructions.Add(new StorePointerInstruction(temp, receiverVal));
                args.Add(temp);
            }
            else
            {
                args.Add(receiverVal);
            }
        }

        foreach (var arg in call.Arguments)
        {
            args.Add(LowerExpression(arg));
        }

        // Resolve target function name
        var targetName = call.ResolvedTarget?.Name ?? call.FunctionName;
        var isForeign = call.ResolvedTarget != null &&
                        (call.ResolvedTarget.Modifiers & FunctionModifiers.Foreign) != 0;

        // Generic functions must be monomorphized before lowering
        if (call.ResolvedTarget != null && !isForeign && call.ResolvedTarget.IsGeneric)
            throw new InvalidOperationException(
                $"BUG: Call to unspecialized generic function `{targetName}` at {call.Span}");

        // Build callee param IrTypes for name mangling
        var calleeIrParamTypes = new List<IrType>();
        if (call.ResolvedTarget != null && !isForeign)
        {
            foreach (var param in call.ResolvedTarget.Parameters)
            {
                calleeIrParamTypes.Add(GetIrType(param));
            }
        }

        var result = new LocalValue($"call_{_tempCounter++}", retIrType);
        var callInst = new CallInstruction(targetName, args, result);
        callInst.IsForeignCall = isForeign;
        if (calleeIrParamTypes.Count > 0)
            callInst.CalleeIrParamTypes = calleeIrParamTypes;

        _currentBlock.Instructions.Add(callInst);
        return result;
    }

    private Value LowerBinary(BinaryExpressionNode binary)
    {
        var left = LowerExpression(binary.Left);
        var right = LowerExpression(binary.Right);

        var irType = GetIrType(binary);

        var op = MapBinaryOp(binary.Operator);
        var result = new LocalValue($"t{_tempCounter++}", irType);
        _currentBlock.Instructions.Add(new BinaryInstruction(op, left, right, result));
        return result;
    }

    private Value LowerUnary(UnaryExpressionNode unary)
    {
        // If resolved to operator overload, emit as call
        if (unary.ResolvedOperatorFunction != null)
        {
            var operandVal = LowerExpression(unary.Operand);
            var retIrType = GetIrType(unary);

            var calleeIrParamTypes = new List<IrType>();
            foreach (var param in unary.ResolvedOperatorFunction.Parameters)
            {
                calleeIrParamTypes.Add(GetIrType(param));
            }

            var result = new LocalValue($"call_{_tempCounter++}", retIrType);
            var callInst = new CallInstruction(unary.ResolvedOperatorFunction.Name, [operandVal], result);
            if (calleeIrParamTypes.Count > 0)
                callInst.CalleeIrParamTypes = calleeIrParamTypes;
            _currentBlock.Instructions.Add(callInst);
            return result;
        }

        var operand = LowerExpression(unary.Operand);
        var irType = GetIrType(unary);

        var op = unary.Operator switch
        {
            UnaryOperatorKind.Negate => UnaryOp.Negate,
            UnaryOperatorKind.Not => UnaryOp.Not,
            _ => UnaryOp.Negate
        };

        var unaryResult = new LocalValue($"t{_tempCounter++}", irType);
        _currentBlock.Instructions.Add(new UnaryInstruction(op, operand, unaryResult));
        return unaryResult;
    }

    private Value LowerMemberAccess(MemberAccessExpressionNode member)
    {
        var targetVal = LowerExpression(member.Target);
        var fieldName = member.FieldName;

        // Get the result type from the type checker
        var fieldIrType = GetIrType(member);

        // Determine the struct IrType from the target
        var targetIrType = targetVal.IrType;

        // Auto-dereference: peel off pointer layers as needed
        var baseVal = targetVal;
        var baseIrType = targetIrType;
        for (int i = 0; i < member.AutoDerefCount; i++)
        {
            if (baseIrType is IrPointer ptrType)
            {
                var derefResult = new LocalValue($"autoderef_{_tempCounter++}", ptrType.Pointee);
                _currentBlock.Instructions.Add(new LoadInstruction(baseVal, derefResult));
                baseVal = derefResult;
                baseIrType = ptrType.Pointee;
            }
        }

        // Find the IrStruct to get field offset
        IrStruct? structType = baseIrType switch
        {
            IrStruct s => s,
            IrPointer { Pointee: IrStruct s } => s,
            _ => null
        };

        if (structType == null)
            throw new InvalidOperationException(
                $"BUG: Member access on non-struct type `{baseIrType}` at {member.Span}");

        var field = FindField(structType, fieldName);

        var gepResult = new LocalValue($"field_ptr_{_tempCounter++}", new IrPointer(field.Type));
        _currentBlock.Instructions.Add(
            new GetElementPtrInstruction(baseVal, field.ByteOffset, gepResult));

        // Load the field value
        var loadResult = new LocalValue($"field_{_tempCounter++}", fieldIrType);
        _currentBlock.Instructions.Add(new LoadInstruction(gepResult, loadResult));
        return loadResult;
    }

    private Value LowerCast(CastExpressionNode cast)
    {
        var srcVal = LowerExpression(cast.Expression);

        var targetIrType = GetIrType(cast);

        // No-op if types match
        if (srcVal.IrType != null && srcVal.IrType == targetIrType)
            return srcVal;

        // Constant folding for primitive casts
        if (srcVal is ConstantValue constSrc && targetIrType is IrPrimitive)
            return new ConstantValue(constSrc.IntValue, targetIrType);

        // Emit cast instruction — pass null! for TypeBase, codegen uses IrType
        var result = new LocalValue($"cast_{_tempCounter++}", targetIrType);
        _currentBlock.Instructions.Add(new CastInstruction(srcVal, null!, result));
        return result;
    }

    private Value LowerBlock(BlockExpressionNode block)
    {
        foreach (var stmt in block.Statements)
            LowerStatement(stmt);

        if (block.TrailingExpression != null)
            return LowerExpression(block.TrailingExpression);

        return new ConstantValue(0, TypeLayoutService.IrVoidPrim);
    }

    private Value LowerIf(IfExpressionNode ifExpr)
    {
        var condVal = LowerExpression(ifExpr.Condition);

        var resultIrType = GetIrType(ifExpr);
        var isVoid = resultIrType == TypeLayoutService.IrVoidPrim;

        var thenBlock = CreateBlock("if_then");
        var elseBlock = CreateBlock("if_else");
        var mergeBlock = CreateBlock("if_merge");

        // Phi-via-alloca: allocate result slot if non-void
        Value? resultPtr = null;
        if (!isVoid)
        {
            resultPtr = new LocalValue($"if_result_{_tempCounter++}", new IrPointer(resultIrType));
            _currentBlock.Instructions.Add(new AllocaInstruction(null!, resultIrType.Size, resultPtr));
        }

        _currentBlock.Instructions.Add(new BranchInstruction(condVal, thenBlock, elseBlock));

        // Then branch
        _currentFunction.BasicBlocks.Add(thenBlock);
        _currentBlock = thenBlock;
        var thenVal = LowerExpression(ifExpr.ThenBranch);
        if (!isVoid && resultPtr != null)
            _currentBlock.Instructions.Add(new StorePointerInstruction(resultPtr, thenVal));
        if (_currentBlock.Instructions.Count == 0 ||
            _currentBlock.Instructions[^1] is not (ReturnInstruction or JumpInstruction or BranchInstruction))
        {
            _currentBlock.Instructions.Add(new JumpInstruction(mergeBlock));
        }

        // Else branch
        _currentFunction.BasicBlocks.Add(elseBlock);
        _currentBlock = elseBlock;
        if (ifExpr.ElseBranch != null)
        {
            var elseVal = LowerExpression(ifExpr.ElseBranch);
            if (!isVoid && resultPtr != null)
                _currentBlock.Instructions.Add(new StorePointerInstruction(resultPtr, elseVal));
        }
        if (_currentBlock.Instructions.Count == 0 ||
            _currentBlock.Instructions[^1] is not (ReturnInstruction or JumpInstruction or BranchInstruction))
        {
            _currentBlock.Instructions.Add(new JumpInstruction(mergeBlock));
        }

        // Merge
        _currentFunction.BasicBlocks.Add(mergeBlock);
        _currentBlock = mergeBlock;

        if (!isVoid && resultPtr != null)
        {
            var loaded = new LocalValue($"if_val_{_tempCounter++}", resultIrType);
            _currentBlock.Instructions.Add(new LoadInstruction(resultPtr, loaded));
            return loaded;
        }

        return new ConstantValue(0, TypeLayoutService.IrVoidPrim);
    }

    private Value LowerAddressOf(AddressOfExpressionNode addrOf)
    {
        // If target is an identifier that maps to an alloca, return the alloca pointer directly
        if (addrOf.Target is IdentifierExpressionNode id && _locals.TryGetValue(id.Name, out var localVal))
        {
            // localVal is already a pointer (alloca result) for locals
            if (!_parameters.Contains(id.Name))
                return localVal;
        }

        // General case: emit AddressOfInstruction
        var targetVal = LowerExpression(addrOf.Target);
        var irType = GetIrType(addrOf);

        var result = new LocalValue($"addr_{_tempCounter++}", irType);
        _currentBlock.Instructions.Add(new AddressOfInstruction(targetVal.Name, result));
        return result;
    }

    private Value LowerDereference(DereferenceExpressionNode deref)
    {
        var targetVal = LowerExpression(deref.Target);

        var irType = GetIrType(deref);

        var result = new LocalValue($"deref_{_tempCounter++}", irType);
        _currentBlock.Instructions.Add(new LoadInstruction(targetVal, result));
        return result;
    }

    private Value LowerAssignment(AssignmentExpressionNode assign)
    {
        var ptr = LowerLValue(assign.Target);
        var val = LowerExpression(assign.Value);

        if (ptr != null)
            _currentBlock.Instructions.Add(new StorePointerInstruction(ptr, val));

        return new ConstantValue(0, TypeLayoutService.IrVoidPrim);
    }

    private Value LowerStructConstruction(StructConstructionExpressionNode structCtor)
    {
        var irType = GetIrType(structCtor);

        if (irType is not IrStruct structIrType)
            throw new InvalidOperationException(
                $"BUG: Struct construction target is not a struct type: `{irType}` at {structCtor.Span}");

        return EmitStructConstruction(structIrType, structCtor.Fields, structCtor.Span);
    }

    private Value LowerAnonymousStruct(AnonymousStructExpressionNode anonStruct)
    {
        var irType = GetIrType(anonStruct);

        if (irType is not IrStruct structIrType)
            throw new InvalidOperationException(
                $"BUG: Anonymous struct target is not a struct type: `{irType}` at {anonStruct.Span}");

        return EmitStructConstruction(structIrType, anonStruct.Fields, anonStruct.Span);
    }

    /// <summary>
    /// Shared helper for struct construction: alloca + GEP/store per field + load result.
    /// </summary>
    private Value EmitStructConstruction(IrStruct structIrType,
        IReadOnlyList<(string FieldName, ExpressionNode Value)> fields, SourceSpan span)
    {
        var resultPtr = new LocalValue($"struct_{_tempCounter++}", new IrPointer(structIrType));
        _currentBlock.Instructions.Add(new AllocaInstruction(null!, structIrType.Size, resultPtr));

        foreach (var (fieldName, fieldExpr) in fields)
        {
            var fieldVal = LowerExpression(fieldExpr);
            var irField = FindField(structIrType, fieldName);

            var fieldPtr = new LocalValue($"field_ptr_{_tempCounter++}", new IrPointer(irField.Type));
            _currentBlock.Instructions.Add(
                new GetElementPtrInstruction(resultPtr, irField.ByteOffset, fieldPtr));
            _currentBlock.Instructions.Add(new StorePointerInstruction(fieldPtr, fieldVal));
        }

        // Load the complete struct value
        var loaded = new LocalValue($"struct_val_{_tempCounter++}", structIrType);
        _currentBlock.Instructions.Add(new LoadInstruction(resultPtr, loaded));
        return loaded;
    }

    private Value LowerArrayLiteral(ArrayLiteralExpressionNode arrLit)
    {
        var irType = GetIrType(arrLit);

        if (irType is not IrArray arrayIrType)
            throw new InvalidOperationException(
                $"BUG: Array literal target is not an array type: `{irType}` at {arrLit.Span}");

        var elementIrType = arrayIrType.Element;
        var allocaResult = new LocalValue($"arr_{_tempCounter++}", new IrPointer(irType));
        _currentBlock.Instructions.Add(new AllocaInstruction(null!, irType.Size, allocaResult));

        if (arrLit.IsRepeatSyntax && arrLit.RepeatValue != null && arrLit.RepeatCount.HasValue)
        {
            // [val; count] — store same value at each index
            var repeatVal = LowerExpression(arrLit.RepeatValue);
            for (int i = 0; i < arrLit.RepeatCount.Value; i++)
            {
                var elemOffset = elementIrType.Size * i;
                var elemPtr = new LocalValue($"arr_elem_ptr_{_tempCounter++}", new IrPointer(elementIrType));
                _currentBlock.Instructions.Add(
                    new GetElementPtrInstruction(allocaResult, elemOffset, elemPtr));
                _currentBlock.Instructions.Add(new StorePointerInstruction(elemPtr, repeatVal));
            }
        }
        else if (arrLit.Elements != null)
        {
            // [a, b, c] — store each element
            for (int i = 0; i < arrLit.Elements.Count; i++)
            {
                var elemVal = LowerExpression(arrLit.Elements[i]);
                var elemOffset = elementIrType.Size * i;
                var elemPtr = new LocalValue($"arr_elem_ptr_{_tempCounter++}", new IrPointer(elementIrType));
                _currentBlock.Instructions.Add(
                    new GetElementPtrInstruction(allocaResult, elemOffset, elemPtr));
                _currentBlock.Instructions.Add(new StorePointerInstruction(elemPtr, elemVal));
            }
        }

        // Load the complete array value
        var loaded = new LocalValue($"arr_val_{_tempCounter++}", irType);
        _currentBlock.Instructions.Add(new LoadInstruction(allocaResult, loaded));
        return loaded;
    }

    private Value LowerIndex(IndexExpressionNode index)
    {
        // If resolved to an op_index function, emit as call
        if (index.ResolvedIndexFunction != null)
        {
            var baseVal = LowerExpression(index.Base);
            var indexVal = LowerExpression(index.Index);

            // Materialize base to a temp if not already a pointer
            if (baseVal.IrType is not IrPointer)
            {
                var baseIrType = baseVal.IrType ?? TypeLayoutService.IrVoidPrim;
                var temp = new LocalValue($"idx_tmp_{_tempCounter++}", new IrPointer(baseIrType));
                _currentBlock.Instructions.Add(new AllocaInstruction(null!, baseIrType.Size, temp));
                _currentBlock.Instructions.Add(new StorePointerInstruction(temp, baseVal));
                baseVal = temp;
            }

            var retIrType = GetIrType(index);

            var calleeIrParamTypes = new List<IrType>();
            foreach (var param in index.ResolvedIndexFunction.Parameters)
            {
                calleeIrParamTypes.Add(GetIrType(param));
            }

            var result = new LocalValue($"call_{_tempCounter++}", retIrType);
            var callInst = new CallInstruction(index.ResolvedIndexFunction.Name, [baseVal, indexVal], result);
            if (calleeIrParamTypes.Count > 0)
                callInst.CalleeIrParamTypes = calleeIrParamTypes;
            _currentBlock.Instructions.Add(callInst);
            return result;
        }

        // Built-in array indexing: compute element pointer via GEP
        var arrVal = LowerExpression(index.Base);
        var idxVal = LowerExpression(index.Index);

        var elementIrType = GetIrType(index);

        // Compute byte offset = index * element_size
        var elementSize = new ConstantValue(elementIrType.Size, TypeLayoutService.IrUSize);
        var byteOffset = new LocalValue($"idx_offset_{_tempCounter++}", TypeLayoutService.IrUSize);
        _currentBlock.Instructions.Add(new BinaryInstruction(BinaryOp.Multiply, idxVal, elementSize, byteOffset));

        var elemPtr = new LocalValue($"elem_ptr_{_tempCounter++}", new IrPointer(elementIrType));
        _currentBlock.Instructions.Add(new GetElementPtrInstruction(arrVal, byteOffset, elemPtr));

        var loaded = new LocalValue($"elem_{_tempCounter++}", elementIrType);
        _currentBlock.Instructions.Add(new LoadInstruction(elemPtr, loaded));
        return loaded;
    }

    private Value LowerRange(RangeExpressionNode range)
    {
        // Construct a Range struct from start and end values
        var rangeNominal = _checker.LookupNominalType(WellKnown.Range)
            ?? throw new InvalidOperationException(
                $"BUG: Range type not registered at {range.Span}");

        var rangeIrType = _layout.Lower(rangeNominal);
        if (rangeIrType is not IrStruct rangeStruct)
            throw new InvalidOperationException(
                $"BUG: Range type is not a struct: `{rangeIrType}` at {range.Span}");

        var resultPtr = new LocalValue($"range_{_tempCounter++}", new IrPointer(rangeStruct));
        _currentBlock.Instructions.Add(new AllocaInstruction(null!, rangeStruct.Size, resultPtr));

        // Store start
        if (range.Start != null)
        {
            var startVal = LowerExpression(range.Start);
            var startField = FindField(rangeStruct, "start");
            var startPtr = new LocalValue($"range_start_ptr_{_tempCounter++}", new IrPointer(startField.Type));
            _currentBlock.Instructions.Add(
                new GetElementPtrInstruction(resultPtr, startField.ByteOffset, startPtr));
            _currentBlock.Instructions.Add(new StorePointerInstruction(startPtr, startVal));
        }

        // Store end
        if (range.End != null)
        {
            var endVal = LowerExpression(range.End);
            var endField = FindField(rangeStruct, "end");
            var endPtr = new LocalValue($"range_end_ptr_{_tempCounter++}", new IrPointer(endField.Type));
            _currentBlock.Instructions.Add(
                new GetElementPtrInstruction(resultPtr, endField.ByteOffset, endPtr));
            _currentBlock.Instructions.Add(new StorePointerInstruction(endPtr, endVal));
        }

        var loaded = new LocalValue($"range_val_{_tempCounter++}", rangeStruct);
        _currentBlock.Instructions.Add(new LoadInstruction(resultPtr, loaded));
        return loaded;
    }

    private Value LowerImplicitCoercion(ImplicitCoercionNode coercion)
    {
        var innerVal = LowerExpression(coercion.Inner);

        var targetIrType = GetIrType(coercion);

        switch (coercion.Kind)
        {
            case CoercionKind.IntegerWidening:
                {
                    // Emit a cast instruction for widening
                    var result = new LocalValue($"widen_{_tempCounter++}", targetIrType);
                    _currentBlock.Instructions.Add(new CastInstruction(innerVal, null!, result));
                    return result;
                }

            case CoercionKind.ReinterpretCast:
                {
                    // No-op: same binary representation, just change the IrType
                    innerVal.IrType = targetIrType;
                    return innerVal;
                }

            case CoercionKind.Wrap:
                {
                    // Wrap T → Option(T): construct Option struct with has_value=true, value=inner
                    if (targetIrType is IrStruct optionStruct && optionStruct.Fields.Length >= 2)
                    {
                        var resultPtr = new LocalValue($"wrap_{_tempCounter++}", new IrPointer(optionStruct));
                        _currentBlock.Instructions.Add(new AllocaInstruction(null!, optionStruct.Size, resultPtr));

                        // Store has_value = true
                        var hvField = FindField(optionStruct, "has_value")
                ;
                        var hvPtr = new LocalValue($"wrap_hv_ptr_{_tempCounter++}", new IrPointer(hvField.Type));
                        _currentBlock.Instructions.Add(
                            new GetElementPtrInstruction(resultPtr, hvField.ByteOffset, hvPtr));
                        _currentBlock.Instructions.Add(new StorePointerInstruction(hvPtr,
                            new ConstantValue(1, TypeLayoutService.IrBool)));

                        // Store value = inner
                        var valField = FindField(optionStruct, "value")
                ;
                        var valPtr = new LocalValue($"wrap_val_ptr_{_tempCounter++}", new IrPointer(valField.Type));
                        _currentBlock.Instructions.Add(
                            new GetElementPtrInstruction(resultPtr, valField.ByteOffset, valPtr));
                        _currentBlock.Instructions.Add(new StorePointerInstruction(valPtr, innerVal));

                        var loaded = new LocalValue($"wrap_val_{_tempCounter++}", optionStruct);
                        _currentBlock.Instructions.Add(new LoadInstruction(resultPtr, loaded));
                        return loaded;
                    }

                    // Fallback: just return inner with target type
                    innerVal.IrType = targetIrType;
                    return innerVal;
                }

            default:
                return innerVal;
        }
    }

    private Value LowerCoalesce(CoalesceExpressionNode coalesce)
    {
        // Lower as call to op_coalesce if resolved
        if (coalesce.ResolvedCoalesceFunction != null)
        {
            var leftVal = LowerExpression(coalesce.Left);
            var rightVal = LowerExpression(coalesce.Right);

            var retIrType = GetIrType(coalesce);

            var calleeIrParamTypes = new List<IrType>();
            foreach (var param in coalesce.ResolvedCoalesceFunction.Parameters)
            {
                calleeIrParamTypes.Add(GetIrType(param));
            }

            var result = new LocalValue($"call_{_tempCounter++}", retIrType);
            var callInst = new CallInstruction(coalesce.ResolvedCoalesceFunction.Name,
                [leftVal, rightVal], result);
            if (calleeIrParamTypes.Count > 0)
                callInst.CalleeIrParamTypes = calleeIrParamTypes;
            _currentBlock.Instructions.Add(callInst);
            return result;
        }

        throw new InvalidOperationException(
            $"BUG: Coalesce expression without resolved function at {coalesce.Span}");
    }

    private Value LowerNullPropagation(NullPropagationExpressionNode nullProp)
    {
        // target?.field
        // if target.has_value: Some(target.value.field) else: null
        var targetVal = LowerExpression(nullProp.Target);

        var resultIrType = GetIrType(nullProp);

        // Get the target's Option type
        var targetIrType = targetVal.IrType;
        IrStruct? optionStruct = targetIrType as IrStruct;
        if (optionStruct == null && targetIrType is IrPointer { Pointee: IrStruct s })
            optionStruct = s;

        if (optionStruct == null)
            throw new InvalidOperationException(
                $"BUG: Null propagation target is not an Option type: `{targetIrType}` at {nullProp.Span}");

        // Materialize target to alloca if not already a pointer
        Value targetPtr;
        if (targetIrType is IrPointer)
        {
            targetPtr = targetVal;
        }
        else
        {
            targetPtr = new LocalValue($"np_tmp_{_tempCounter++}", new IrPointer(optionStruct));
            _currentBlock.Instructions.Add(new AllocaInstruction(null!, optionStruct.Size, targetPtr));
            _currentBlock.Instructions.Add(new StorePointerInstruction(targetPtr, targetVal));
        }

        // Load has_value field
        var hvField = FindField(optionStruct, "has_value");
        var hvPtr = new LocalValue($"np_hv_ptr_{_tempCounter++}", new IrPointer(hvField.Type));
        _currentBlock.Instructions.Add(
            new GetElementPtrInstruction(targetPtr, hvField.ByteOffset, hvPtr));
        var hvVal = new LocalValue($"np_hv_{_tempCounter++}", TypeLayoutService.IrBool);
        _currentBlock.Instructions.Add(new LoadInstruction(hvPtr, hvVal));

        // Branch on has_value
        var thenBlock = CreateBlock("np_then");
        var elseBlock = CreateBlock("np_else");
        var mergeBlock = CreateBlock("np_merge");

        // Alloca for result
        var resultPtr = new LocalValue($"np_result_{_tempCounter++}", new IrPointer(resultIrType));
        _currentBlock.Instructions.Add(new AllocaInstruction(null!, resultIrType.Size, resultPtr));
        _currentBlock.Instructions.Add(new BranchInstruction(hvVal, thenBlock, elseBlock));

        // Then: access target.value.field, wrap in new Option
        _currentFunction.BasicBlocks.Add(thenBlock);
        _currentBlock = thenBlock;

        // GEP to value field
        var valField = FindField(optionStruct, "value");
        var valPtr = new LocalValue($"np_val_ptr_{_tempCounter++}", new IrPointer(valField.Type));
        _currentBlock.Instructions.Add(new GetElementPtrInstruction(targetPtr, valField.ByteOffset, valPtr));

        // Access the member on value
        var innerStruct = (IrStruct)valField.Type;
        var memberField = FindField(innerStruct, nullProp.MemberName);
        var memberPtr = new LocalValue($"np_member_ptr_{_tempCounter++}", new IrPointer(memberField.Type));
        _currentBlock.Instructions.Add(new GetElementPtrInstruction(valPtr, memberField.ByteOffset, memberPtr));
        var memberVal = new LocalValue($"np_member_{_tempCounter++}", memberField.Type);
        _currentBlock.Instructions.Add(new LoadInstruction(memberPtr, memberVal));

        // Wrap in Option if result is Option type
        if (resultIrType is IrStruct resultOptionStruct && resultOptionStruct.Fields.Length >= 2)
        {
            var somePtr = new LocalValue($"np_some_{_tempCounter++}", new IrPointer(resultOptionStruct));
            _currentBlock.Instructions.Add(
                new AllocaInstruction(null!, resultOptionStruct.Size, somePtr));

            var someHvField = FindField(resultOptionStruct, "has_value");
            var someHvPtr = new LocalValue($"np_some_hv_{_tempCounter++}", new IrPointer(someHvField.Type));
            _currentBlock.Instructions.Add(
                new GetElementPtrInstruction(somePtr, someHvField.ByteOffset, someHvPtr));
            _currentBlock.Instructions.Add(new StorePointerInstruction(someHvPtr,
                new ConstantValue(1, TypeLayoutService.IrBool)));

            var someValField = FindField(resultOptionStruct, "value");
            var someValPtr = new LocalValue($"np_some_val_{_tempCounter++}", new IrPointer(someValField.Type));
            _currentBlock.Instructions.Add(
                new GetElementPtrInstruction(somePtr, someValField.ByteOffset, someValPtr));
            _currentBlock.Instructions.Add(new StorePointerInstruction(someValPtr, memberVal));

            var someLoaded = new LocalValue($"np_some_val_{_tempCounter++}", resultOptionStruct);
            _currentBlock.Instructions.Add(new LoadInstruction(somePtr, someLoaded));
            _currentBlock.Instructions.Add(new StorePointerInstruction(resultPtr, someLoaded));
        }
        else
        {
            _currentBlock.Instructions.Add(new StorePointerInstruction(resultPtr, memberVal));
        }
        _currentBlock.Instructions.Add(new JumpInstruction(mergeBlock));

        // Else: return null Option
        _currentFunction.BasicBlocks.Add(elseBlock);
        _currentBlock = elseBlock;
        if (resultIrType is IrStruct nullOptionStruct)
        {
            var nullPtr = new LocalValue($"np_null_{_tempCounter++}", new IrPointer(nullOptionStruct));
            _currentBlock.Instructions.Add(new AllocaInstruction(null!, nullOptionStruct.Size, nullPtr));

            var nullHvField = FindField(nullOptionStruct, "has_value");
            var nullHvPtr = new LocalValue($"np_null_hv_{_tempCounter++}", new IrPointer(nullHvField.Type));
            _currentBlock.Instructions.Add(
                new GetElementPtrInstruction(nullPtr, nullHvField.ByteOffset, nullHvPtr));
            _currentBlock.Instructions.Add(new StorePointerInstruction(nullHvPtr,
                new ConstantValue(0, TypeLayoutService.IrBool)));

            var nullLoaded = new LocalValue($"np_null_val_{_tempCounter++}", nullOptionStruct);
            _currentBlock.Instructions.Add(new LoadInstruction(nullPtr, nullLoaded));
            _currentBlock.Instructions.Add(new StorePointerInstruction(resultPtr, nullLoaded));
        }
        _currentBlock.Instructions.Add(new JumpInstruction(mergeBlock));

        // Merge
        _currentFunction.BasicBlocks.Add(mergeBlock);
        _currentBlock = mergeBlock;

        var finalResult = new LocalValue($"np_final_{_tempCounter++}", resultIrType);
        _currentBlock.Instructions.Add(new LoadInstruction(resultPtr, finalResult));
        return finalResult;
    }

    // =========================================================================
    // LValue lowering — returns a pointer to the assignable location
    // =========================================================================

    /// <summary>
    /// Returns a pointer Value for an assignable expression (lvalue).
    /// Returns null if the expression cannot be assigned to.
    /// </summary>
    private Value? LowerLValue(ExpressionNode expr)
    {
        switch (expr)
        {
            case IdentifierExpressionNode id:
                {
                    if (_locals.TryGetValue(id.Name, out var localVal))
                    {
                        // For parameters, we need to create an alloca to make them assignable
                        if (_parameters.Contains(id.Name))
                        {
                            var paramIrType = localVal.IrType ?? TypeLayoutService.IrVoidPrim;
                            var alloca = new LocalValue($"{id.Name}_mut", new IrPointer(paramIrType));
                            _currentBlock.Instructions.Add(new AllocaInstruction(null!, paramIrType.Size, alloca));
                            _currentBlock.Instructions.Add(new StorePointerInstruction(alloca, localVal));
                            _locals[id.Name] = alloca;
                            _parameters.Remove(id.Name);
                            return alloca;
                        }
                        return localVal; // Already an alloca pointer
                    }
                    _diagnostics.Add(Diagnostic.Error(
                        $"Cannot assign to unresolved identifier `{id.Name}`", id.Span, null, "E3003"));
                    return null;
                }

            case MemberAccessExpressionNode member:
                {
                    // Lower the target expression
                    var targetVal = LowerExpression(member.Target);
                    var targetIrType = targetVal.IrType;

                    // Auto-dereference
                    var baseVal = targetVal;
                    var baseIrType = targetIrType;
                    for (int i = 0; i < member.AutoDerefCount; i++)
                    {
                        if (baseIrType is IrPointer ptrType)
                        {
                            var derefResult = new LocalValue($"autoderef_{_tempCounter++}", ptrType.Pointee);
                            _currentBlock.Instructions.Add(new LoadInstruction(baseVal, derefResult));
                            baseVal = derefResult;
                            baseIrType = ptrType.Pointee;
                        }
                    }

                    IrStruct? structType = baseIrType switch
                    {
                        IrStruct s => s,
                        IrPointer { Pointee: IrStruct s } => s,
                        _ => null
                    };

                    if (structType == null)
                        throw new InvalidOperationException(
                            $"BUG: Cannot assign to member on non-struct type at {member.Span}");

                    var field = FindField(structType, member.FieldName);

                    // Return pointer to field (GEP without final load)
                    var gepResult = new LocalValue($"field_ptr_{_tempCounter++}", new IrPointer(field.Type));
                    _currentBlock.Instructions.Add(
                        new GetElementPtrInstruction(baseVal, field.ByteOffset, gepResult));
                    return gepResult;
                }

            case DereferenceExpressionNode deref:
                {
                    // Dereferencing gives us the pointer itself — it's already an lvalue
                    return LowerExpression(deref.Target);
                }

            case IndexExpressionNode index:
                {
                    var arrVal = LowerExpression(index.Base);
                    var idxVal = LowerExpression(index.Index);

                    var elementIrType = GetIrType(index);

                    // Compute byte offset = index * element_size
                    var elementSize = new ConstantValue(elementIrType.Size, TypeLayoutService.IrUSize);
                    var byteOffset = new LocalValue($"idx_offset_{_tempCounter++}", TypeLayoutService.IrUSize);
                    _currentBlock.Instructions.Add(
                        new BinaryInstruction(BinaryOp.Multiply, idxVal, elementSize, byteOffset));

                    var elemPtr = new LocalValue($"elem_ptr_{_tempCounter++}", new IrPointer(elementIrType));
                    _currentBlock.Instructions.Add(new GetElementPtrInstruction(arrVal, byteOffset, elemPtr));
                    return elemPtr;
                }

            default:
                _diagnostics.Add(Diagnostic.Error(
                    $"Expression is not assignable: {expr.GetType().Name}",
                    expr.Span, null, "E3005"));
                return null;
        }
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// <summary>
    /// Get the lowered IR type for an AST node: resolves the inferred HM type and lowers to IrType.
    /// </summary>
    private IrType GetIrType(AstNode node) => _layout.Lower(_checker.GetInferredType(node));

    private FunctionType GetFunctionHmType(FunctionDeclarationNode fn)
    {
        var scheme = _checker.GetInferredType(fn);
        return (FunctionType)_engine.Resolve(scheme);
    }

    private BasicBlock CreateBlock(string label)
    {
        return new BasicBlock($"{label}_{_blockCounter++}");
    }

    private string GetUniqueVariableName(string sourceName)
    {
        if (!_shadowCounter.TryGetValue(sourceName, out var count))
        {
            _shadowCounter[sourceName] = 0;
            return sourceName;
        }

        _shadowCounter[sourceName] = count + 1;
        return $"{sourceName}__shadow{count + 1}";
    }

    private static BinaryOp MapBinaryOp(BinaryOperatorKind kind)
    {
        return kind switch
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
            BinaryOperatorKind.BitwiseAnd => BinaryOp.BitwiseAnd,
            BinaryOperatorKind.BitwiseOr => BinaryOp.BitwiseOr,
            BinaryOperatorKind.BitwiseXor => BinaryOp.BitwiseXor,
            BinaryOperatorKind.ShiftLeft => BinaryOp.ShiftLeft,
            BinaryOperatorKind.ShiftRight => BinaryOp.ShiftRight,
            _ => throw new NotImplementedException($"Unsupported binary operator: {kind}"),
        };
    }

    private static IrField FindField(IrStruct structType, string fieldName)
    {
        foreach (var f in structType.Fields)
        {
            if (f.Name == fieldName)
                return f;
        }
        throw new InvalidOperationException(
            $"BUG: Field `{fieldName}` not found in struct `{structType.Name}`");
    }

    // =========================================================================
    // IrType-based name mangling (delegates to FLang.IR.IrNameMangling)
    // =========================================================================

    public static string MangleFunctionName(string baseName, IReadOnlyList<IrType> paramTypes)
        => IrNameMangling.MangleFunctionName(baseName, paramTypes);

    public static string MangleIrType(IrType type)
        => IrNameMangling.MangleIrType(type);
}
