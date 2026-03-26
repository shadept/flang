# RFC-003: Promote BasicBlock to IR Builder with CFG Construction

**Type:** Refactor
**Status:** Proposed
**Depends on:** None (independent of RFC-001/RFC-002, though benefits from them)

## Summary

Transform `BasicBlock` from a passive data container (label + instruction list) into an LLVM-style IR builder that emits instructions through typed methods, enforces ABI rules for call sequences, and constructs the control flow graph automatically as blocks are linked by terminators.

## Motivation

`HmAstLowering` (4,746 lines) manually constructs every IR instruction via `new XxxInstruction(...)` + `_currentBlock.Instructions.Add(...)`. This creates three problems:

1. **ABI logic is copy-pasted across 5 call paths.** The implicit-reference-passing rules (materialize large args as pointers, insert return slots for large returns) are duplicated in `EmitFLangCall`, `LowerCall`, `LowerIndirectFieldCall`, `LowerIndirectVarCall`, and `LowerOperatorFunctionCall`. Each copy uses slightly different temp name prefixes (`byref_arg_`, `ifc_tmp_`, `ivc_tmp_`) but implements identical alloca+store+replace logic. A bug fix to the ABI must be applied in 4+ places.

2. **No control flow graph exists.** `BranchInstruction` and `JumpInstruction` reference target blocks, but blocks have no `Successors`/`Predecessors` lists. The CFG is implicit — recoverable by scanning instructions, but not available for optimization passes. Future work (dead block elimination, dominance analysis, SSA construction) would need to reconstruct the graph from scratch.

3. **Verbose emission obscures lowering logic.** A simple "allocate and store" is 3 lines of boilerplate:
   ```csharp
   var temp = new LocalValue($"byref_arg_{_tempCounter++}", new IrPointer(argIrType));
   _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, argIrType.Size, temp));
   _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, temp, argVal));
   ```
   With a builder: `var temp = _currentBlock.EmitAlloca(argIrType); _currentBlock.EmitStorePtr(temp, argVal);`

## Design

### Shared build context: `BlockBuildContext`

All blocks within a function share a single `BlockBuildContext`. This holds the temp counter (avoiding collisions when multiple blocks emit into the same function scope), the current source span, a reference to the owning `IrFunction` (for block registration), and `TypeLayoutService` (for ABI decisions).

```csharp
/// <summary>
/// Shared state for all BasicBlocks within an IrFunction.
/// Ensures unique temp names across blocks and provides
/// access to layout/ABI information.
/// </summary>
internal class BlockBuildContext
{
    public IrFunction Function { get; }
    public TypeLayoutService Layout { get; }

    private int _tempCounter;

    /// <summary>Current source span, set by HmAstLowering as it walks the AST.</summary>
    public SourceSpan Span { get; set; }

    /// <summary>Allocate a unique temp name like "retslot_7".</summary>
    public string FreshName(string hint) => $"{hint}_{_tempCounter++}";

    /// <summary>Create a new LocalValue with a unique name.</summary>
    public LocalValue FreshLocal(string hint, IrType type)
        => new(FreshName(hint), type);

    /// <summary>
    /// Create a new block, register it with the function, and return it.
    /// The new block shares this context.
    /// </summary>
    public BasicBlock CreateBlock(string label)
    {
        var block = new BasicBlock($"{label}_{_tempCounter++}", this);
        Function.BasicBlocks.Add(block);
        return block;
    }

    public BlockBuildContext(IrFunction function, TypeLayoutService layout)
    {
        Function = function;
        Layout = layout;
    }
}
```

### Promoted `BasicBlock`

`BasicBlock` gains three categories of methods:

#### 1. Low-level emit methods (one per instruction kind)

Each method constructs the instruction, appends it to the block, and returns the result value (if any). The caller never touches `Instructions` directly.

```csharp
public class BasicBlock
{
    public string Label { get; }
    public List<Instruction> Instructions { get; } = [];
    public BlockBuildContext Ctx { get; }

    // CFG edges
    public List<BasicBlock> Successors { get; } = [];
    public List<BasicBlock> Predecessors { get; } = [];

    // --- Low-level emit (one per instruction) ---

    public LocalValue EmitAlloca(IrType type)
    {
        var result = Ctx.FreshLocal("alloca", new IrPointer(type));
        Instructions.Add(new AllocaInstruction(Ctx.Span, type.Size, result));
        return result;
    }

    public void EmitStorePtr(Value dest, Value val)
        => Instructions.Add(new StorePointerInstruction(Ctx.Span, dest, val));

    public LocalValue EmitLoad(Value ptr, IrType resultType)
    {
        var result = Ctx.FreshLocal("load", resultType);
        Instructions.Add(new LoadInstruction(Ctx.Span, ptr, result));
        return result;
    }

    public void EmitStore(Value dest, int fieldOffset, Value val, int size)
        => Instructions.Add(new StoreInstruction(Ctx.Span, dest, fieldOffset, val, size));

    public LocalValue EmitBinary(BinaryOp op, Value left, Value right, IrType resultType)
    {
        var result = Ctx.FreshLocal("bin", resultType);
        Instructions.Add(new BinaryInstruction(Ctx.Span, op, left, right, result));
        return result;
    }

    public LocalValue EmitUnary(UnaryOp op, Value operand, IrType resultType)
    {
        var result = Ctx.FreshLocal("unary", resultType);
        Instructions.Add(new UnaryInstruction(Ctx.Span, op, operand, result));
        return result;
    }

    public LocalValue EmitCast(Value source, IrType targetType, CastKind kind)
    {
        var result = Ctx.FreshLocal("cast", targetType);
        Instructions.Add(new CastInstruction(Ctx.Span, source, targetType, result, kind));
        return result;
    }

    public LocalValue EmitGetElementPtr(Value basePtr, int byteOffset, IrType resultType)
    {
        var result = Ctx.FreshLocal("gep", new IrPointer(resultType));
        Instructions.Add(new GetElementPtrInstruction(Ctx.Span, basePtr, byteOffset, result));
        return result;
    }

    public LocalValue EmitAddressOf(Value operand)
    {
        var result = Ctx.FreshLocal("addr", new IrPointer(operand.IrType));
        Instructions.Add(new AddressOfInstruction(Ctx.Span, operand, result));
        return result;
    }

    public LocalValue EmitCopy(Value source, IrType type)
    {
        var result = Ctx.FreshLocal("copy", type);
        Instructions.Add(new CopyInstruction(Ctx.Span, source, result));
        return result;
    }

    public LocalValue EmitCopyFromOffset(Value basePtr, int byteOffset, IrType resultType)
    {
        var result = Ctx.FreshLocal("fld", resultType);
        Instructions.Add(new CopyFromOffsetInstruction(Ctx.Span, basePtr, byteOffset, result));
        return result;
    }

    public void EmitCopyToOffset(Value basePtr, int byteOffset, Value val)
        => Instructions.Add(new CopyToOffsetInstruction(Ctx.Span, basePtr, byteOffset, val));

    // --- Terminators (record CFG edges) ---

    public void EmitJump(BasicBlock target)
    {
        Instructions.Add(new JumpInstruction(Ctx.Span, target));
        AddEdge(this, target);
    }

    public void EmitBranch(Value cond, BasicBlock trueBlock, BasicBlock falseBlock)
    {
        Instructions.Add(new BranchInstruction(Ctx.Span, cond, trueBlock, falseBlock));
        AddEdge(this, trueBlock);
        AddEdge(this, falseBlock);
    }

    public void EmitReturn(Value val)
        => Instructions.Add(new ReturnInstruction(Ctx.Span, val));

    /// <summary>
    /// Emit a jump only if this block has no terminator yet.
    /// Used for implicit fall-through (e.g., loop back-edges).
    /// </summary>
    public void EmitJumpIfNotTerminated(BasicBlock target)
    {
        if (!IsTerminated)
            EmitJump(target);
    }

    public bool IsTerminated => Instructions.Count > 0
        && Instructions[^1] is ReturnInstruction or JumpInstruction or BranchInstruction;

    // --- Block creation (delegates to shared context) ---

    public BasicBlock CreateBlock(string label) => Ctx.CreateBlock(label);

    // --- CFG edge helper ---

    private static void AddEdge(BasicBlock from, BasicBlock to)
    {
        from.Successors.Add(to);
        to.Predecessors.Add(from);
    }
}
```

#### 2. ABI-aware high-level methods

These compose the low-level emit methods to implement FLang's calling convention. The ABI rule — values > 8 bytes are passed by implicit pointer — is applied automatically. Foreign functions are excluded.

```csharp
// On BasicBlock:

/// <summary>
/// Emit a complete FLang function call with ABI transformations.
/// Materializes large value args as pointers, inserts return slot for large
/// return types, emits the CallInstruction, and returns the result value.
/// </summary>
public LocalValue EmitCall(string fnName, List<Value> args, IrType retType,
                           List<IrType>? calleeParamTypes, bool isForeign = false)
{
    if (!isForeign)
        MaterializeArgs(args, calleeParamTypes);

    if (!isForeign && TypeLayoutService.IsLargeValue(retType))
    {
        var retSlot = EmitAlloca(retType);
        args.Insert(0, retSlot);

        var voidResult = Ctx.FreshLocal("call", TypeLayoutService.IrVoidPrim);
        var inst = new CallInstruction(Ctx.Span, fnName, args, voidResult);
        if (calleeParamTypes is { Count: > 0 })
            inst.CalleeIrParamTypes = calleeParamTypes;
        Instructions.Add(inst);

        return EmitLoad(retSlot, retType);
    }

    var result = Ctx.FreshLocal("call", retType);
    var call = new CallInstruction(Ctx.Span, fnName, args, result);
    call.IsForeignCall = isForeign;
    if (calleeParamTypes is { Count: > 0 })
        call.CalleeIrParamTypes = calleeParamTypes;
    Instructions.Add(call);
    return result;
}

/// <summary>
/// Emit an indirect call through a function pointer with ABI transformations.
/// </summary>
public LocalValue EmitIndirectCall(Value fnPtr, List<Value> args, IrType retType)
{
    MaterializeArgsByType(args);

    if (TypeLayoutService.IsLargeValue(retType))
    {
        var retSlot = EmitAlloca(retType);
        args.Insert(0, retSlot);

        var voidResult = Ctx.FreshLocal("call", TypeLayoutService.IrVoidPrim);
        Instructions.Add(new IndirectCallInstruction(Ctx.Span, fnPtr, args, voidResult));

        return EmitLoad(retSlot, retType);
    }

    var result = Ctx.FreshLocal("call", retType);
    Instructions.Add(new IndirectCallInstruction(Ctx.Span, fnPtr, args, result));
    return result;
}

/// <summary>
/// Emit a return, respecting the return-slot convention.
/// If the current function uses a return slot, stores to __ret and returns void.
/// </summary>
public void EmitFunctionReturn(Value val, IrFunction fn, Value? retSlotLocal)
{
    if (fn.UsesReturnSlot && retSlotLocal != null)
    {
        EmitStorePtr(retSlotLocal, val);
        EmitReturn(Ctx.FreshLocal("void", TypeLayoutService.IrVoidPrim));
    }
    else
    {
        EmitReturn(val);
    }
}

// --- Private ABI helpers ---

/// <summary>
/// Materialize large-value args using callee param types.
/// Used for direct calls where callee types are known.
/// </summary>
private void MaterializeArgs(List<Value> args, IReadOnlyList<IrType>? calleeParamTypes)
{
    if (calleeParamTypes == null) return;
    for (int i = 0; i < args.Count && i < calleeParamTypes.Count; i++)
    {
        if (TypeLayoutService.IsLargeValue(calleeParamTypes[i]) && args[i].IrType is not IrPointer)
        {
            var argType = args[i].IrType ?? calleeParamTypes[i];
            var temp = EmitAlloca(argType);
            EmitStorePtr(temp, args[i]);
            args[i] = temp;
        }
    }
}

/// <summary>
/// Materialize large-value args using the arg's own type.
/// Used for indirect calls where callee param types are not available.
/// </summary>
private void MaterializeArgsByType(List<Value> args)
{
    for (int i = 0; i < args.Count; i++)
    {
        if (TypeLayoutService.IsLargeValue(args[i].IrType) && args[i].IrType is not IrPointer)
        {
            var argType = args[i].IrType ?? TypeLayoutService.IrVoidPrim;
            var temp = EmitAlloca(argType);
            EmitStorePtr(temp, args[i]);
            args[i] = temp;
        }
    }
}
```

#### 3. Callee-side ABI setup

This is a static method — it transforms an `IrFunction`'s parameter list, not a block. It lives on `BasicBlock` as a factory-adjacent utility or on a separate static class.

```csharp
/// <summary>
/// Apply FLang ABI to a function's parameter list: mark large params IsByRef,
/// insert __ret pointer param for large return types.
/// </summary>
public static CalleeAbiResult SetupCalleeAbi(
    IReadOnlyList<(string Name, IrType Type)> declaredParams,
    IrType returnType,
    bool isEntryPoint)
{
    var irParams = new List<IrParam>();
    var byRefNames = new HashSet<string>();
    var locals = new Dictionary<string, Value>();

    foreach (var (name, paramType) in declaredParams)
    {
        var irParam = new IrParam(name, paramType);
        if (TypeLayoutService.IsLargeValue(paramType))
        {
            irParam = irParam with { IsByRef = true };
            locals[name] = new LocalValue(name, new IrPointer(paramType));
            byRefNames.Add(name);
        }
        else
        {
            locals[name] = new LocalValue(name, paramType);
        }
        irParams.Add(irParam);
    }

    bool usesReturnSlot = false;
    if (TypeLayoutService.IsLargeValue(returnType) && !isEntryPoint)
    {
        usesReturnSlot = true;
        var retPtrType = new IrPointer(returnType);
        irParams.Insert(0, new IrParam("__ret", retPtrType));
        locals["__ret"] = new LocalValue("__ret", retPtrType);
    }

    return new CalleeAbiResult
    {
        Params = irParams,
        UsesReturnSlot = usesReturnSlot,
        Locals = locals,
        ByRefParams = byRefNames,
    };
}

public sealed class CalleeAbiResult
{
    public IReadOnlyList<IrParam> Params { get; init; } = [];
    public bool UsesReturnSlot { get; init; }
    public IReadOnlyDictionary<string, Value> Locals { get; init; } = null!;
    public IReadOnlySet<string> ByRefParams { get; init; } = null!;
}
```

## What changes in HmAstLowering

### Before (EmitFLangCall — 43 lines, repeated 4 more times)

```csharp
private LocalValue EmitFLangCall(string fnName, List<Value> args,
    IrType retIrType, List<IrType>? calleeIrParamTypes)
{
    if (calleeIrParamTypes != null)
    {
        for (int i = 0; i < args.Count && i < calleeIrParamTypes.Count; i++)
        {
            if (IsLargeValue(calleeIrParamTypes[i]) && args[i].IrType is not IrPointer)
            {
                var argIrType = args[i].IrType ?? calleeIrParamTypes[i];
                var temp = new LocalValue($"byref_arg_{_tempCounter++}", new IrPointer(argIrType));
                _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, argIrType.Size, temp));
                _currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, temp, args[i]));
                args[i] = temp;
            }
        }
    }
    if (IsLargeValue(retIrType))
    {
        var retSlot = new LocalValue($"retslot_{_tempCounter++}", new IrPointer(retIrType));
        _currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, retIrType.Size, retSlot));
        args.Insert(0, retSlot);
        var voidResult = new LocalValue($"call_{_tempCounter++}", TypeLayoutService.IrVoidPrim);
        var callInst = new CallInstruction(_currentSpan, fnName, args, voidResult);
        if (calleeIrParamTypes != null && calleeIrParamTypes.Count > 0)
            callInst.CalleeIrParamTypes = calleeIrParamTypes;
        _currentBlock.Instructions.Add(callInst);
        var loaded = new LocalValue($"retload_{_tempCounter++}", retIrType);
        _currentBlock.Instructions.Add(new LoadInstruction(_currentSpan, retSlot, loaded));
        return loaded;
    }
    var result = new LocalValue($"call_{_tempCounter++}", retIrType);
    var normalCall = new CallInstruction(_currentSpan, fnName, args, result);
    if (calleeIrParamTypes != null && calleeIrParamTypes.Count > 0)
        normalCall.CalleeIrParamTypes = calleeIrParamTypes;
    _currentBlock.Instructions.Add(normalCall);
    return result;
}
```

### After (all 5 call paths collapse)

```csharp
// EmitFLangCall is deleted. All callers use _currentBlock.EmitCall directly.

// LowerIndirectFieldCall — was 40 lines, now:
var args = new List<Value>();
foreach (var arg in call.Arguments)
    args.Add(LowerExpression(arg));
return _currentBlock.EmitIndirectCall(funcPtrVal, args, retIrType);

// LowerIndirectVarCall — same collapse.

// LowerCall return-slot block — was 16 lines, now:
return _currentBlock.EmitCall(targetName, args, retIrType, calleeIrParamTypes, isForeign);

// LowerOperatorFunctionCall — delegates to EmitCall instead of deleted EmitFLangCall.
```

### Control flow (LowerLoop — before)

```csharp
private void LowerLoop(LoopNode loop)
{
    var bodyBlock = CreateBlock("loop_body");
    var exitBlock = CreateBlock("loop_exit");
    _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, bodyBlock));
    _currentFunction.BasicBlocks.Add(bodyBlock);
    _currentBlock = bodyBlock;
    _loopStack.Push((bodyBlock, exitBlock));
    LowerExpression(loop.Body);
    _loopStack.Pop();
    if (_currentBlock.Instructions.Count == 0 ||
        _currentBlock.Instructions[^1] is not (ReturnInstruction or JumpInstruction or BranchInstruction))
    {
        _currentBlock.Instructions.Add(new JumpInstruction(_currentSpan, bodyBlock));
    }
    _currentFunction.BasicBlocks.Add(exitBlock);
    _currentBlock = exitBlock;
}
```

### Control flow (LowerLoop — after)

```csharp
private void LowerLoop(LoopNode loop)
{
    var bodyBlock = _currentBlock.CreateBlock("loop_body");
    var exitBlock = _currentBlock.CreateBlock("loop_exit");
    _currentBlock.EmitJump(bodyBlock);         // links current → body in CFG
    _currentBlock = bodyBlock;
    _loopStack.Push((bodyBlock, exitBlock));
    LowerExpression(loop.Body);
    _loopStack.Pop();
    _currentBlock.EmitJumpIfNotTerminated(bodyBlock);  // back-edge, conditional
    _currentBlock = exitBlock;
}
```

Block registration with `_currentFunction.BasicBlocks.Add(block)` is handled by `CreateBlock`. The terminator check is handled by `EmitJumpIfNotTerminated`. CFG edges are recorded by every `EmitJump`/`EmitBranch`.

### Instruction emission throughout (example)

```csharp
// Before — scattered across 4,746 lines:
var temp = new LocalValue($"byref_arg_{_tempCounter++}", new IrPointer(argIrType));
_currentBlock.Instructions.Add(new AllocaInstruction(_currentSpan, argIrType.Size, temp));
_currentBlock.Instructions.Add(new StorePointerInstruction(_currentSpan, temp, argVal));

// After:
var temp = _currentBlock.EmitAlloca(argIrType);
_currentBlock.EmitStorePtr(temp, argVal);
```

## What does NOT change

- **Instruction classes are unchanged.** `CallInstruction`, `BranchInstruction`, etc. keep their constructors and properties. The builder methods are a layer on top, not a replacement.
- **`IrFunction`, `IrModule`, `IrParam` are unchanged.** The builder adds to `BasicBlock` only.
- **Optimization passes (`InliningPass`, `PeepholeOptimizer`) are unchanged.** They continue to iterate `Instructions` directly. They can optionally use `Successors`/`Predecessors` for future CFG-aware optimizations, but nothing breaks if they don't.
- **C codegen (`HmCCodeGenerator`) is unchanged.** It reads `Instructions`, not builder methods.
- **`_currentBlock` field remains on `HmAstLowering`.** The lowering class still tracks which block it's emitting into. What changes is that it calls builder methods instead of constructing instructions manually.

## Dependency Strategy

**In-process.** All changes are within `FLang.IR` (new `BlockBuildContext`, expanded `BasicBlock`) and `FLang.Semantics` (migration of `HmAstLowering`). No external dependencies, no I/O, no new assemblies.

`BasicBlock` gains a dependency on `TypeLayoutService` (via `BlockBuildContext`) for the `IsLargeValue` ABI predicate. This is acceptable — `TypeLayoutService` is already in `FLang.IR` and `BasicBlock` is in `FLang.IR`.

## Testing Strategy

- **New boundary tests to write:** None required for the refactor itself. The existing 225 `HmAstLoweringTests` + lit-style harness tests exercise every instruction emission and control flow pattern end-to-end. If the builder emits identical instructions, all tests pass.
- **Future tests enabled:** `BasicBlock` builder methods can be unit-tested by constructing a `BlockBuildContext` with a test `IrFunction` and `TypeLayoutService`, calling builder methods, and asserting on the `Instructions` list. This enables isolated ABI rule testing without a full lowering pass.
- **CFG tests enabled:** After the refactor, tests can assert on `Successors`/`Predecessors` to verify the graph structure — e.g., a loop body block has itself as a successor (back-edge).
- **Old tests to delete:** None. This is additive — the builder composes the same instructions that exist today.

## Implementation Sequence

### Phase 1: BlockBuildContext + BasicBlock scaffolding
- Create `BlockBuildContext` in `FLang.IR` with temp counter, span, function reference, layout service
- Add `Successors`/`Predecessors` lists to `BasicBlock`
- Add `BlockBuildContext` property to `BasicBlock`
- Add `CreateBlock` method on `BasicBlock` (delegates to context)
- Existing constructor remains for backward compatibility; add new constructor taking `BlockBuildContext`
- Build + test (no behavioral change yet)

### Phase 2: Low-level emit methods
- Add `EmitAlloca`, `EmitStorePtr`, `EmitLoad`, `EmitStore`, `EmitBinary`, `EmitUnary`, `EmitCast`, `EmitGetElementPtr`, `EmitAddressOf`, `EmitCopy`, `EmitCopyFromOffset`, `EmitCopyToOffset` to `BasicBlock`
- Add terminator methods: `EmitJump`, `EmitBranch`, `EmitReturn`, `EmitJumpIfNotTerminated` — these record CFG edges
- Add `IsTerminated` property
- Build + test (no behavioral change yet — methods exist but aren't called)

### Phase 3: Wire HmAstLowering to use BlockBuildContext
- Replace `_tempCounter`, `_blockCounter` on `HmAstLowering` with a `BlockBuildContext` created per-function
- Replace `CreateBlock` on `HmAstLowering` to delegate to `_currentBlock.CreateBlock` or context
- Update `_currentSpan` writes to also update `ctx.Span`
- Build + test

### Phase 4: Migrate instruction emission (incremental, per method)
- Replace `_currentBlock.Instructions.Add(new XxxInstruction(...))` with `_currentBlock.EmitXxx(...)` across `HmAstLowering`, one method at a time
- Replace terminator emission to use `EmitJump`/`EmitBranch`/`EmitReturn` (gains CFG edges)
- Build + test after each batch of method migrations

### Phase 5: ABI-aware call methods
- Add `EmitCall` and `EmitIndirectCall` to `BasicBlock`
- Add `EmitFunctionReturn` to `BasicBlock`
- Add static `SetupCalleeAbi` (on `BasicBlock` or separate utility)
- Replace `EmitFLangCall` and all 4 duplicated call paths with `_currentBlock.EmitCall`/`EmitIndirectCall`
- Delete `EmitFLangCall` from `HmAstLowering`
- Delete `IsLargeValue` forwarding alias from `HmAstLowering`
- Build + test

### Phase 6: Cleanup
- Verify `HmAstLowering` has zero direct `Instructions.Add` calls
- Verify all blocks created during lowering have `BlockBuildContext` set
- Update `docs/architecture.md` to document the builder pattern and CFG construction

## Trade-offs

**Gained:**
- ABI calling convention logic exists in exactly one place (`BasicBlock.EmitCall`)
- CFG is built automatically during lowering — `Successors`/`Predecessors` available for future optimization passes (dead block elimination, dominance, loop detection)
- Instruction emission is concise and uniform — impossible to forget `Instructions.Add` or use a stale span
- Temp naming is centralized in `BlockBuildContext` — no more divergent prefixes across call paths
- `HmAstLowering` shrinks significantly and reads as pure lowering logic, not IR construction boilerplate
- Builder methods are independently testable

**Cost:**
- `BasicBlock` grows from 9 lines to ~200 lines — it becomes a meaningful class instead of a data holder
- `FLang.IR.BasicBlock` gains a dependency on `TypeLayoutService` for ABI methods — acceptable since both are in the same assembly
- All instruction emission in `HmAstLowering` must be migrated — large mechanical diff, but each method can be migrated independently
- `InliningPass` and `PeepholeOptimizer` manipulate `Instructions` directly and would need updating if they ever need to maintain CFG edges during mutation (not required now)

**Deliberately not done:**
- No phi nodes or SSA form — future work that benefits from the CFG but is not part of this refactor
- No changes to optimization passes — they continue to work on the instruction list directly
- No builder interface/abstraction — `BasicBlock` is the builder, no indirection needed
- `_currentBlock` tracking remains on `HmAstLowering` — the builder pattern is about emission, not block selection

## Validation

- All existing tests must pass unchanged (`dotnet test.cs`)
- No semantic or behavioral changes — the builder emits identical instructions in identical order
- After migration, `HmAstLowering` should have zero `_currentBlock.Instructions.Add(` calls
- After migration, every `BranchInstruction` and `JumpInstruction` should have corresponding `Successors`/`Predecessors` entries on their source/target blocks
