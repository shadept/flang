# Phase 2: New IR, AstLowering, and C Codegen

## Context

The current AstLowering (3,497 lines) uses the old `TypeBase` type system exclusively (`expr.Type`, `param.ResolvedType`, `StructType.Fields`, `EnumType.Variants`, etc.). It cannot use `HmTypeChecker` results. The IR carries no `SourceSpan`, preventing `#line` directive emission for source-level debugging. The C codegen is tightly coupled to `TypeBase` (pattern-matches on 11 subclasses, 37 `TypeRegistry` calls). Goal: new lowering using only new HM types, IR with spans, codegen that's type-system-agnostic.

## Design Decisions

**D1: IR gets its own type system (`IrType`).** Immutable records in `FLang.IR/`. Carries pre-computed layout (size, alignment, field offsets). Codegen imports only `FLang.IR`. Clean firewall from `FLang.Core.Types`.

```
IrType (abstract)
├── IrPrimitive { Name, Size, Alignment }        // i32, bool, void, etc.
├── IrPointer { Pointee: IrType }                 // &T → T*
├── IrArray { Element: IrType, Length }            // [T; N]
├── IrStruct { Name, CName, Fields[] }            // struct with layout
│   └── IrField { Name, Type: IrType, ByteOffset }
├── IrEnum { Name, CName, TagSize, Variants[] }   // enum with tag+payload
│   └── IrVariant { Name, TagValue, PayloadType?, PayloadOffset }
└── IrFunctionPtr { Params[], Return: IrType }     // fn pointer
```

**D2: `TypeLayoutService` computes layout during lowering.** Translates `FLang.Core.Types.Type` → `IrType`. Computes C-ABI-compatible field offsets, padding, alignment. Results baked into `IrStruct.Fields[i].ByteOffset`. Codegen never computes layout.

**D3: `NominalKind` tracking.** `HmTypeChecker` gets `Dictionary<string, NominalKind>` (Struct vs Enum) populated during `CollectStructNames`/`CollectEnumNames`. Lowering reads this to produce `IrStruct` vs `IrEnum`.

**D4: `SourceSpan` on `Instruction`.** Add `SourceSpan Span` to instruction base class. New lowering sets it from AST nodes. C codegen emits `#line` directives.

**D5: `IrModule` replaces per-function globals.** Module owns: type definitions, globals, functions, foreign declarations.

**D6: New `HmCCodeGenerator` alongside old.** Old codegen untouched. New one consumes `IrModule` with `IrType`. Flag `--use-hm` selects new pipeline.

**D7: Wire end-to-end early.** Get `hello world` through the new pipeline first, then grow coverage. Integration tests (`dotnet run test.cs`) verify incrementally.

**D8: Dynamic alloca.** `AllocaInstruction` gets optional `Value? Count` for runtime-sized stack arrays (VLAs). When set, C codegen emits `elemType name[count];` instead of static length. Existing static allocas unaffected (`Count = null`).

## Implementation Steps

### Step 1: `IrType` hierarchy
New file: `src/FLang.IR/IrType.cs`
- `IrPrimitive`, `IrPointer`, `IrArray`, `IrStruct` (with `IrField[]`), `IrEnum` (with `IrVariant[]`), `IrFunctionPtr`
- All carry `Size` and `Alignment`
- `IrStruct.Fields` carry `ByteOffset`
- `IrEnum.Variants` carry `TagValue`, `PayloadOffset`, `PayloadType`

### Step 2: `TypeLayoutService`
New file: `src/FLang.IR/TypeLayoutService.cs`
- Input: `FLang.Core.Types.Type` + `HmTypeChecker.NominalTypes` + `HmTypeChecker.NominalKinds`
- Output: `IrType`
- Caches by type identity/name
- Port layout algorithm from `StructType.ComputeLayout()` and `EnumType.GetTagOffset()/GetPayloadOffset()`

### Step 3: `NominalKind` on HmTypeChecker
Modify: `src/FLang.Semantics/HmTypeChecker.cs`, `HmTypeChecker.Declarations.cs`
- Add `enum NominalKind { Struct, Enum }`
- `Dictionary<string, NominalKind> _nominalKinds`
- Populated in `CollectStructNames` (Struct) and `CollectEnumNames` (Enum)
- Expose as `public IReadOnlyDictionary<string, NominalKind> NominalKinds`

### Step 4: `SourceSpan` on Instruction + Dynamic Alloca
Modify: `src/FLang.IR/Instructions/Instruction.cs`
- Add `public SourceSpan Span { get; init; } = SourceSpan.None;`
- Non-breaking — old lowering doesn't set it, defaults to None

Modify: `src/FLang.IR/Instructions/AllocaInstruction.cs`
- Add `Value? Count` property — when non-null, allocates `Count` elements of `AllocatedType`
- Keep `SizeInBytes` for static allocas (backward compat with old lowering)
- Add constructor overload: `AllocaInstruction(TypeBase allocatedType, int sizeInBytes, Value result, Value? count)`

Modify: `src/FLang.Codegen.C/CCodeGenerator.cs` (EmitAlloca)
- When `alloca.Count != null` and type is array: use `EmitValue(alloca.Count)` for array length instead of `arrayType.DeclaredLength`
- When `alloca.Count != null` and type is non-array: emit `elemType name[count];` (VLA)

Modify: `src/FLang.IR/FirPrinter.cs`
- When Count set: `%ptr = alloca i32, count %n`
- When Count null: `%ptr = alloca i32 ; 24 bytes` (unchanged)

### Step 5: `IrModule` + updated Value
New file: `src/FLang.IR/IrModule.cs`
```
IrModule { TypeDefs, Globals, Functions, ForeignDecls }
IrFunction { Name, ReturnType: IrType, Params, BasicBlocks, Locals }
```
Modify: `src/FLang.IR/Value.cs` — add `IrType? IrTy` alongside existing `TypeBase? Type` for dual-path coexistence. New lowering sets `IrTy`, old sets `Type`.

### Step 6: `HmAstLowering` scaffold
New file: `src/FLang.Semantics/HmAstLowering.cs`
- Constructor takes: `HmTypeChecker checker`, `TypeLayoutService layout`
- Reads types via `checker.GetInferredType(node)` and `checker.NominalTypes`
- Same memory model as old lowering (all vars on stack, alloca+pointer)
- Start with: function entry, parameters, return, integer literals, binary ops, calls — enough for hello world

### Step 7: `HmCCodeGenerator`
New file: `src/FLang.Codegen.C/HmCCodeGenerator.cs`
- Consumes `IrModule` with `IrType`
- `IrTypeToCType()` dispatches on `IrType` (not `TypeBase`)
- Emits `#line` directives from `Instruction.Span`
- Struct/enum defs from `IrModule.TypeDefs`
- Port from old `CCodeGenerator` but simpler — no `TypeRegistry` calls, no `Prune()`

### Step 8: Pipeline integration
Modify: `src/FLang.CLI/Compiler.cs`
- Add `--use-hm` flag
- When set: HmTypeChecker → HmAstLowering → HmCCodeGenerator
- Default: old pipeline unchanged

### Step 9: Grow coverage
- Port statement lowering (var decl, return, for, loop, break/continue, defer)
- Port expression lowering (if, block, match, struct construction, enum, arrays, strings, UFCS, operators, coalesce, null propagation, lambdas, casts, index, member access, address-of, deref)
- Port RTTI type table (or defer — not needed for most tests)
- Run `dotnet run test.cs` after each batch, track passing count

### Step 10: Switchover
- Once all 273+ integration tests pass with `--use-hm`, make it default
- Remove old `TypeChecker`, `AstLowering`, `CCodeGenerator` in a separate cleanup pass

## Files Summary

| Action | File |
|--------|------|
| **New** | `src/FLang.IR/IrType.cs` |
| **New** | `src/FLang.IR/TypeLayoutService.cs` |
| **New** | `src/FLang.IR/IrModule.cs` |
| **New** | `src/FLang.Semantics/HmAstLowering.cs` |
| **New** | `src/FLang.Codegen.C/HmCCodeGenerator.cs` |
| **Modify** | `src/FLang.IR/Instructions/Instruction.cs` — add SourceSpan |
| **Modify** | `src/FLang.IR/Instructions/AllocaInstruction.cs` — add Value? Count |
| **Modify** | `src/FLang.IR/Value.cs` — add IrType? alongside TypeBase? |
| **Modify** | `src/FLang.IR/FirPrinter.cs` — display dynamic count |
| **Modify** | `src/FLang.Codegen.C/CCodeGenerator.cs` — VLA emission in EmitAlloca |
| **Modify** | `src/FLang.Semantics/HmTypeChecker.cs` — NominalKind tracking |
| **Modify** | `src/FLang.Semantics/HmTypeChecker.Declarations.cs` — populate NominalKinds |
| **Modify** | `src/FLang.CLI/Compiler.cs` — --use-hm flag |

## Verification

- Step 1-2: Unit tests for `TypeLayoutService` (struct/enum layout matches old `StructType.ComputeLayout()`)
- Step 4: `dotnet run test.cs` — all 273 still pass (dynamic alloca is backward compat)
- Step 6-7: `hello world` through new pipeline produces working C + executable
- Step 9: `dotnet run test.cs` with `--use-hm`, track pass count toward 273+
- Step 10: All tests pass, old pipeline removable

## Open Questions

1. **RTTI type table** — should we port the full `EnsureTypeTableExists()` (~250 lines) or defer it? Most tests don't use RTTI.
2. **Generic monomorphization** — the old lowering assumes TypeChecker has already monomorphized. HmTypeChecker currently skips generic function bodies. Do we need a monomorphization pass, or do we check generic bodies at each call site?
