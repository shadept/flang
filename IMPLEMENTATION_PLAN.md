# FLang Type System Reimplementation Plan

## Progress Tracking

**Current Status:** ✅ Phase 1-5 Near Complete - 51/55 Harness Tests Passing (93%)!

### Phase Status

| Phase | Status | Completion | Notes |
|-------|--------|------------|-------|
| Phase 1: TypeBase Hierarchy | ✅ Complete | 100% | Merged into FLang.Core namespace |
| Phase 2: Core Unification | ✅ Complete | 100% | TypeSolverCore.cs in FLang.Semantics namespace |
| Phase 3: Test Suite | ✅ Complete | 100% | **All 45 tests passing!** (Duration: 31ms) |
| Phase 4: Integration | ✅ Complete | 100% | TypeSolver replaced, TypeBase fully integrated |
| Phase 5: Fix Integration Tests | 🔄 In Progress | 93% | **51/55 harness tests passing!** |

### Key Milestones

- [x] **Milestone 1:** TypeBase hierarchy created (Phase 1)
- [x] **Milestone 2:** 45 TypeSolverCoreTests all pass ✅ (Phase 3) - **ACHIEVED!**
- [x] **Milestone 3:** Project compiles with TypeBase (Phase 4) - **ACHIEVED!**
- [ ] **Milestone 4:** All tests pass (Phase 5)

### Current Phase Details

**Phases 1-4 (Partial) Completed:**
- ✅ Merged TypeBase hierarchy into `src/FLang.Core/Types.cs` (FLang.Core namespace)
- ✅ Merged TypeBaseRegistry functionality into TypeRegistry
- ✅ Updated TypeSolverCore.cs to use FLang.Semantics namespace
- ✅ **All 45 TypeSolverCoreTests passing** (Duration: 31ms)
- ✅ Added FType compatibility alias (using FType = TypeBase) to all files
- ✅ Added ComptimeIntType alias for compatibility
- ✅ **Project builds successfully** (warnings only, no errors)
- ✅ Deleted separate TypeBase.cs and TypeBaseRegistry.cs files

**Phase 4 Completed:**
- ✅ TypeSolver completely rewritten with Algorithm W
- ✅ All coercion rules implemented (integer widening, option wrapping, array decay, etc.)
- ✅ Type($T) RTTI verified working
- ✅ Explicit casting support added for unsafe pointer operations

**Phase 5 Progress:**
- ✅ Fixed Slice<T> codegen (struct definitions now emitted correctly)
- ✅ Fixed field offset calculation (GetFieldOffset now triggers ComputeLayout)
- ✅ Fixed unsafe array→&u8 casts (explicit cast only, not coercion)
- ✅ Updated test expectations for usize→i32 narrowing (requires explicit cast)
- ⏸️ Generic inference tests (cascading errors in negative tests)
- ⏸️ Option codegen (pointer vs value issue)

**Test Results:**
- ✅ 58/58 TypeSolver unit tests passing
- ✅ 51/55 harness tests passing (93%)
- ❌ 2 generic tests (negative tests with cascading errors - low priority)
- ❌ 1 list test (list_get not implemented)
- ❌ 1 option test (codegen issue)

**Blockers:** None

**Last Updated:** 2025-12-28

---

## Goal
Reimplement FLang's type system using Algorithm W-style unification from the backup architecture, reducing TypeSolver complexity from 2192 lines to ~230 lines (core unification) + type checking logic.

**Primary Objective:** Get all 45 tests from `TYPE_SYSTEM_TypeSolverTests.cs.backup` passing, then integrate into the existing codebase.

## Strategy
Parallel implementation - create NEW type system alongside existing FType without breaking anything, then gradually migrate.

---

## Phase 1: Create TypeBase Hierarchy Foundation

### 1.1 Create `src/FLang.Core/TypeBase.cs` (NEW ~600 lines)

Implement the new type hierarchy that will replace FType:

**Core Abstract Base:**
```csharp
public abstract class TypeBase
{
    public abstract string Name { get; }
    public abstract int Size { get; }        // For RTTI (Type($T))
    public abstract int Alignment { get; }   // For RTTI (Type($T))

    // Algorithm W unification support
    public virtual TypeBase Prune() => this;
    public virtual bool IsConcrete => true;

    public abstract bool Equals(TypeBase other);
}
```

**Type Classes to Implement:**

1. **TypeVar** - Unification variable (mutable Instance property)
   - Has `Instance` property that gets bound during unification
   - `Prune()` follows Instance chain to find concrete type
   - `IsConcrete` returns false until bound
   - Size/Alignment throw if unbound

2. **PrimitiveType** - i8, i16, i32, i64, u8, u16, u32, u64, bool, isize, usize
   - Constructor: `PrimitiveType(string name, int size, int alignment)`
   - Add `CreateSkolem(string name)` static method for rigid generics
   - Size/Alignment passed in constructor

3. **ComptimeInt** - Compile-time integer literals
   - Singleton pattern
   - Size/Alignment throw (not a concrete type)
   - Used for integer literal inference (e.g., `42` has type comptime_int)

4. **StructType** - User-defined structs
   - Properties: `Name`, `TypeArguments: List<TypeBase>`, `Fields: List<(string, TypeBase)>`
   - Calculated Size/Alignment from field layout
   - Generic structs (e.g., `Option<T>`) have TypeArguments

5. **ArrayType** - Fixed-size arrays [T; N]
   - Properties: `ElementType`, `Length`
   - Size = ElementType.Size * Length
   - Alignment = ElementType.Alignment

6. **ReferenceType** - Reference types &T
   - Properties: `InnerType`
   - Size = 8 (pointer size on 64-bit), configurable for 32-bit
   - Alignment = Size

7. **EnumType** - Enum definitions (if needed for tests)
   - Properties: `Name`, `Variants`
   - Size/Alignment based on largest variant

**Key Methods:**
- `WithFields()` extension for StructType (builder pattern used in tests)
- `Equals()` - structural equality for all types
- `ToString()` - for diagnostics

### 1.2 Create `src/FLang.Core/TypeBaseRegistry.cs` (NEW ~150 lines)

Unified registry for both primitive types and well-known composite types (Option, Slice, String):

```csharp
public static class TypeBaseRegistry
{
    // Primitive types
    public static readonly PrimitiveType I8 = new("i8", 1, 1);
    public static readonly PrimitiveType I16 = new("i16", 2, 2);
    public static readonly PrimitiveType I32 = new("i32", 4, 4);
    public static readonly PrimitiveType I64 = new("i64", 8, 8);
    public static readonly PrimitiveType U8 = new("u8", 1, 1);
    public static readonly PrimitiveType U16 = new("u16", 2, 2);
    public static readonly PrimitiveType U32 = new("u32", 4, 4);
    public static readonly PrimitiveType U64 = new("u64", 8, 8);
    public static readonly PrimitiveType ISize = new("isize", 8, 8);
    public static readonly PrimitiveType USize = new("usize", 8, 8);
    public static readonly PrimitiveType Bool = new("bool", 1, 1);

    public static readonly ComptimeInt ComptimeInt = ComptimeInt.Instance;

    // Fully qualified names for well-known types
    private const string OptionFqn = "core.option.Option";
    private const string SliceFqn = "core.slice.Slice";
    private const string StringFqn = "core.string.String";

    // Factory methods for well-known composite types
    public static StructType MakeOption(TypeBase innerType)
    {
        // Create Option<T> with fully qualified name
        var optionStruct = new StructType(OptionFqn, [innerType]);
        // Set fields if needed for the tests
        return optionStruct;
    }

    public static StructType MakeSlice(TypeBase elementType)
    {
        // Create Slice<T> with fully qualified name
        var sliceStruct = new StructType(SliceFqn, [elementType]);
        return sliceStruct;
    }

    public static StructType MakeString()
    {
        // Create String as Slice<u8> equivalent
        var stringStruct = new StructType(StringFqn);
        return stringStruct;
    }

    // Recognition methods (for coercion rules)
    public static bool IsOption(StructType st)
    {
        // Check fully qualified name
        return st.Name == OptionFqn || st.Name == "Option";
    }

    public static bool IsSlice(StructType st)
    {
        // Check fully qualified name
        return st.Name == SliceFqn || st.Name == "Slice";
    }

    public static bool IsString(StructType st)
    {
        // Check fully qualified name
        return st.Name == StringFqn || st.Name == "String";
    }
}
```

**Implementation notes:**
- All recognition methods check **fully qualified names** (e.g., "core.option.Option")
- Also accept short names for backward compatibility during migration
- Factory methods create StructType instances with fully qualified names
- This consolidates WellKnownTypes and TypeRegistry into a single class

**Validation:** Write quick smoke tests to verify all primitives and factory methods work.

---

## Phase 2: Implement Core Unification Engine

### 2.1 Create `src/FLang.Semantics/TypeSolverCore.cs` (NEW ~230 lines)

**Copy from:** `TYPE_SYSTEM_TypeSolver.cs.backup` (lines 1-231) with these modifications:

**Required Changes:**
- Change all `WellKnownTypes.IsOption()` → `TypeBaseRegistry.IsOption()`
- Change all `WellKnownTypes.IsSlice()` → `TypeBaseRegistry.IsSlice()`
- Change all `WellKnownTypes.IsString()` → `TypeBaseRegistry.IsString()`

**Components:**

1. **PointerWidth enum** (lines 10-14)
   - Bits32, Bits64
   - Used for isize/usize platform equivalence

2. **ICoercionRule interface** (lines 16-20)
   ```csharp
   public interface ICoercionRule
   {
       bool TryApply(TypeBase from, TypeBase to, TypeSolverCore solver);
   }
   ```

3. **TypeSolverCore class** (lines 25-132)
   - `List<ICoercionRule> CoercionRules` - pluggable coercion system
   - `Unify(TypeBase t1, TypeBase t2, SourceSpan? span)` - main unification method
   - `List<Diagnostic> _diagnostics` - error collection
   - Constructor adds 4 default coercion rules

4. **IntegerWideningRule** (lines 136-190)
   - Same-signedness: i8→i16→i32→i64, u8→u16→u32→u64
   - Cross-signedness: u32→i64 (safe), u32→i32 rejected
   - Platform equivalence: isize===i32 (32-bit) or i64 (64-bit)
   - Rank-based algorithm with dictionaries

5. **OptionWrappingRule** (lines 192-202)
   - T → Option<T>
   - Checks target is Option using `TypeBaseRegistry.IsOption()`
   - Checks inner type matches source

6. **ArrayToSliceRule** (lines 204-218)
   - [T;N] → Slice<T>
   - &[T;N] → Slice<T>
   - Uses `TypeBaseRegistry.IsSlice()` to recognize Slice types

7. **StringToByteSliceRule** (lines 220-231)
   - String → Slice<u8>
   - Uses `TypeBaseRegistry.IsString()` and `IsSlice()` for recognition

**Critical Algorithm Order (UnifyInternal):**
1. Identity check (line 53)
2. Type variable binding (lines 56-67)
3. Comptime int hardening (lines 70-71)
4. **Coercion rules (lines 74-78)** ← BEFORE structural checks!
5. Structural recursion (structs/enums, lines 81-100)
6. Detailed failure reporting (lines 103-109)

**Name:** Use `TypeSolverCore` to avoid conflict with existing `TypeSolver`.

---

## Phase 3: Implement Test Suite

### 3.1 Create `tests/FLang.Tests/TypeSolverCoreTests.cs` (NEW ~800 lines)

**Copy from:** `TYPE_SYSTEM_TypeSolverTests.cs.backup` with these modifications:

**Global changes:**
- Class name: `TypeSolverTests` → `TypeSolverCoreTests`
- Solver type: `new TypeSolver()` → `new TypeSolverCore()`
- Registry: `TypeRegistry.I32` → `TypeBaseRegistry.I32`
- Well-known types: `WellKnownTypes.MakeOption()` → `TypeBaseRegistry.MakeOption()`
- Well-known types: `WellKnownTypes.MakeSlice()` → `TypeBaseRegistry.MakeSlice()`
- Well-known types: `WellKnownTypes.MakeString()` → `TypeBaseRegistry.MakeString()`
- Types: Change all type references to use TypeBase classes

**Test structure (45 tests organized in 9 regions):**

1. **Basic Unification Tests** (6 tests)
   - `Unify_IdenticalPrimitives_Succeeds`
   - `Unify_DifferentPrimitives_WithNoCoercion_Fails`
   - `Unify_TypeVarWithConcrete_BindsVariable`
   - `Unify_ConcreteWithTypeVar_BindsVariable`
   - `Unify_TwoTypeVars_BindsOneToOther`

2. **Struct Unification Tests** (4 tests)
   - `Unify_IdenticalStructs_Succeeds`
   - `Unify_DifferentStructNames_Fails`
   - `Unify_GenericStructs_WithMatchingTypeArgs_Succeeds`
   - `Unify_GenericStructs_WithDifferentTypeArgs_Fails`

3. **Comptime Int Hardening Tests** (3 tests)
   - `Unify_ComptimeIntWithI32_HardensToI32`
   - `Unify_I64WithComptimeInt_HardensToI64`
   - `Unify_ComptimeIntWithBool_Fails`

4. **IntegerWideningRule Tests** (11 tests)
   - Same-signedness: i8→i16, i8→i32, i32→i64, u8→u16, u8→u64
   - Narrowing fails: i16→i8
   - Cross-signedness: u32→i64, u8→i16 (succeeds), u32→i32, i32→u32 (fails)
   - Platform equivalence: isize32===i32, isize64===i64, usize32===u32, usize64===u64
   - Platform widening: i16→isize64

5. **OptionWrappingRule Tests** (4 tests)
   - i32→Option<i32>, bool→Option<bool> (succeeds)
   - i32→Option<i64> (fails)
   - struct→Option<struct> (succeeds)

6. **ArrayToSliceRule Tests** (4 tests)
   - [i32;10]→Slice<i32>, [bool;5]→Slice<bool> (succeeds)
   - [i32;10]→Slice<i64> (fails)
   - &[u8;20]→Slice<u8> (succeeds)

7. **StringToByteSliceRule Tests** (3 tests)
   - String→Slice<u8> (succeeds)
   - String→Slice<i8>, String→Slice<u16> (fails)

8. **Coercion Chain Tests** (2 tests)
   - Verify no transitive coercion (i8→Option<i64> fails)
   - Explicit chaining works (i8→i64→Option<i64>)

9. **Custom Coercion Rule Tests** (2 tests)
   - Test ICoercionRule extensibility
   - Includes helper `AlwaysTrueCoercionRule` class

10. **Error Message Tests** (2 tests)
    - Diagnostic includes expected and actual types
    - Skolem rigid generic error has code E3003

**Helper class in test file:**
```csharp
private class AlwaysTrueCoercionRule : ICoercionRule
{
    public bool TryApply(TypeBase from, TypeBase to, TypeSolverCore solver)
    {
        return true; // Always allow coercion (for testing)
    }
}
```

**Run tests:**
```bash
dotnet test --filter "FullyQualifiedName~TypeSolverCoreTests"
```

### 3.2 Fix any failing tests

**Common issues:**
- Missing StructType.WithFields() extension method
- TypeBaseRegistry not recognizing Option/Slice/String correctly
- TypeVar Prune() not following Instance chains
- Size/Alignment calculation errors in StructType

**Success Criteria:** All 45 tests pass ✅

---

## Phase 4: Integration into Existing Codebase

This phase begins ONLY after all 45 tests pass.

### 4.1 Replace FType with TypeBase (The Big Switch)

**Strategy:** Do a clean replacement to minimize confusion.

**Step 1: Backup**
```bash
git checkout -b type-system-rewrite
git commit -am "Checkpoint before type system replacement"
```

**Step 2: Delete old FType hierarchy**

Edit `src/FLang.Core/Types.cs`:
- Delete all FType classes (PrimitiveType, StructType, ArrayType, etc.)
- Keep any utility methods that are FType-independent

**Step 3: Merge TypeBase into Types.cs**

Move contents from:
- `TypeBase.cs` → `Types.cs`
- `TypeBaseRegistry.cs` → Merge into `TypeRegistry` class in `Types.cs`

Note: WellKnownTypes is already merged into TypeBaseRegistry, so no separate file to merge.

**Step 4: Rename for consistency**

Option A (Recommended): Keep TypeBase name
- Easier to track which code uses new vs old system
- Clear semantic meaning

Option B: Rename TypeBase → FType
- Minimal downstream changes
- But loses the distinction

**Step 5: Update TypeRegistry**

Merge `TypeBaseRegistry` into existing `TypeRegistry`:
```csharp
public static class TypeRegistry
{
    // Primitives (now TypeBase-based)
    public static readonly PrimitiveType I8 = new("i8", 1, 1);
    // ... etc

    // Keep existing methods but update to return TypeBase
    public static TypeBase? GetTypeByName(string name) { ... }
    public static bool IsIntegerType(TypeBase t) { ... }

    // Factory methods (updated for TypeBase)
    public static StructType GetSliceStruct(TypeBase elementType) { ... }
    public static StructType GetOptionStruct(TypeBase innerType) { ... }
    public static StructType GetTypeStruct(TypeBase innerType) { ... }
}
```

**Step 6: Global find-replace (if needed)**

If keeping TypeBase name:
```bash
# In all .cs files under src/
FType → TypeBase
```

**Compile and fix errors:**
```bash
dotnet build 2>&1 | tee build_errors.txt
```

Fix compilation errors one file at a time, starting with:
1. `Types.cs` (type definitions)
2. `TypeSolver.cs` (semantic analysis)
3. `AstLowering.cs` (IR generation)
4. `CCodeGenerator.cs` (codegen)

### 4.2 Integrate TypeSolverCore into TypeSolver

**File:** `src/FLang.Semantics/TypeSolver.cs`

**Strategy:** Keep existing TypeSolver class for type checking logic, use TypeSolverCore for unification.

**Step 1: Add TypeSolverCore as a field**

```csharp
public class TypeSolver
{
    private readonly TypeSolverCore _unificationEngine;

    public TypeSolver(Compilation compilation, ILogger<TypeSolver> logger)
    {
        _compilation = compilation;
        _logger = logger;
        _unificationEngine = new TypeSolverCore(PointerWidth.Bits64);
        PushScope(); // Global scope
    }
}
```

**Step 2: Replace UnifyTypes method**

Find the current `UnifyTypes(FType a, FType b)` method (around line 1536).

Replace with:
```csharp
private TypeBase UnifyTypes(TypeBase a, TypeBase b, SourceSpan? span = null)
{
    var result = _unificationEngine.Unify(a, b, span);

    // Copy diagnostics from unification engine
    foreach (var diag in _unificationEngine.Diagnostics)
        _diagnostics.Add(diag);

    return result;
}
```

**Step 3: Update type checking methods**

Methods that currently use type matching/coercion need updating:

1. **CheckReturnStatement** - Use UnifyTypes for return type checking
2. **CheckAssignment** - Use UnifyTypes for assignment compatibility
3. **CheckBinaryExpression** - Use UnifyTypes for operand type matching
4. **CheckIfExpression** - Use UnifyTypes for branch reconciliation
5. **CheckCallExpression** - Use UnifyTypes in argument matching

**Pattern to find:**
```bash
grep -n "IsCompatible\|CanCoerce\|IsAssignableFrom" src/FLang.Semantics/TypeSolver.cs
```

Replace calls to these methods with `UnifyTypes()`.

**Step 4: Handle coercion tracking**

The old system tracked Option lifts and coercions separately. With the new system:
- Coercion happens inside `Unify()`
- May need to track when OptionWrappingRule was applied
- Update `_optionLifts` dictionary when coercion happens

**Potential solution:**
```csharp
// After unification
if (result != a && TypeBaseRegistry.IsOption(result as StructType))
{
    // Option wrapping happened
    _optionLifts[expressionNode] = result as OptionType;
}
```

**Step 5: Remove old unification logic**

Delete methods that are now redundant:
- `IsCompatible()`
- `CanCoerce()`
- Old `UnifyTypes()` implementation

Keep methods still needed:
- `CheckExpression()` - type inference for expressions
- `CollectFunctionSignatures()` - signature collection
- `CheckModuleBodies()` - statement/expression checking
- Generic specialization logic

### 4.3 Update Size/Alignment Handling

**File:** `src/FLang.Semantics/AstLowering.cs`

Verify Type($T) RTTI still works:

1. **Global type table generation** (around line 136)
   - Should work unchanged if TypeBase has Size/Alignment properties
   - May need to update type name access: `type.Name` → `type.ToString()`

2. **Type literal lowering** (around line 176)
   - Verify Type(T) struct creation still works
   - Check field access (name, size, align)

**Test:**
```bash
dotnet build
dotnet run -- tests/FLang.Tests/Harness/intrinsics/sizeof_basic.f
```

Expected: Test passes, prints correct sizes.

---

## Phase 5: Fix Integration Tests

### 5.1 Run full test suite

```bash
dotnet build
dotnet test > test_results.txt 2>&1
pwsh build-all-tests.ps1 > harness_results.txt 2>&1
```

### 5.2 Fix failing tests by category

**Priority order:**

1. **Type system tests** (`Harness/types/`, `Harness/casts/`)
   - Should mostly work if Unify() is correct
   - May need to fix coercion tracking

2. **Generic tests** (`Harness/generics/`)
   - Verify generic specialization still works
   - May need to update generic parameter handling

3. **Option tests** (`Harness/option/`)
   - Verify OptionWrappingRule works in practice
   - Check _optionLifts tracking for codegen

4. **RTTI tests** (`Harness/intrinsics/sizeof_*.f`)
   - Verify Size/Alignment properties work
   - Check Type($T) global table generation

5. **All other tests**
   - Fix any remaining issues

### 5.3 Common failure patterns

**Pattern 1: Type name format changes**
- Error: String representation changed (e.g., "Slice[T]" vs "Slice<T>")
- Fix: Update ToString() methods or test expectations

**Pattern 2: Missing coercions**
- Error: "Type mismatch: i8 vs i32" where widening should work
- Fix: Verify IntegerWideningRule is registered and working

**Pattern 3: Diagnostic message changes**
- Error: Error messages differ from expected
- Fix: Update diagnostic generation or test expectations

**Pattern 4: Generic instantiation failures**
- Error: Generic types not specialized correctly
- Fix: Port generic handling logic, verify substitution works

---

## Success Criteria

**Phase 1-3 (Foundation + Tests):**
- ✅ All 45 TypeSolverCoreTests pass
- ✅ No compilation errors in new code

**Phase 4 (Integration):**
- ✅ Project compiles with TypeBase replacing FType
- ✅ TypeSolver uses TypeSolverCore.Unify() for type unification
- ✅ Type($T) RTTI tests pass (sizeof, align_of)

**Phase 5 (Full Integration):**
- ✅ All unit tests pass: `dotnet test`
- ✅ All harness tests pass: `pwsh build-all-tests.ps1`
- ✅ No known regressions

**Overall:**
- ✅ TypeSolver complexity reduced (~2192 → ~230 core + ~1500 checking ≈ 1730 total)
- ✅ Modular architecture with ICoercionRule interface
- ✅ Comprehensive test coverage (45 unit tests + integration tests)
- ✅ All existing functionality preserved

---

## Risk Mitigation

**Risk 1: Breaking existing tests during replacement**
- Mitigation: Create new branch, commit frequently, test after each phase
- Rollback: `git reset --hard` to last good commit

**Risk 2: Type($T) RTTI breaks**
- Mitigation: Test Size/Alignment properties in Phase 3, verify early in Phase 4
- Validation: Run sizeof tests continuously

**Risk 3: Generic specialization issues**
- Mitigation: Preserve generic logic from old TypeSolver, test generics early
- Test cases: `Harness/generics/` tests

**Risk 4: Performance regression**
- Mitigation: New system is simpler, should be faster; benchmark if needed
- Acceptance: ≤110% of baseline compilation time

---

## File Checklist

**Phase 1 - Create:**
- [ ] `src/FLang.Core/TypeBase.cs`
- [ ] `src/FLang.Core/TypeBaseRegistry.cs` (includes WellKnownTypes functionality)

**Phase 2 - Create:**
- [ ] `src/FLang.Semantics/TypeSolverCore.cs`

**Phase 3 - Create:**
- [ ] `tests/FLang.Tests/TypeSolverCoreTests.cs`

**Phase 4 - Modify:**
- [ ] `src/FLang.Core/Types.cs` (merge TypeBase, delete FType)
- [ ] `src/FLang.Semantics/TypeSolver.cs` (integrate TypeSolverCore)
- [ ] `src/FLang.Semantics/AstLowering.cs` (verify RTTI works)

**Phase 5 - Verify:**
- [ ] All test files in `tests/FLang.Tests/Harness/`

---

## Estimated Effort

- **Phase 1:** 1-2 days (TypeBase hierarchy)
- **Phase 2:** 0.5 day (copy TypeSolverCore)
- **Phase 3:** 1-2 days (port tests, fix issues)
- **Phase 4:** 2-3 days (integration, replacement)
- **Phase 5:** 2-3 days (fix failing tests)

**Total:** 7-11 days (1.5-2 weeks for single developer)

---

## Notes

- Keep backup files until Phase 5 is complete and all tests pass
- Document any deviations from this plan
- Add new tests for any bugs discovered during integration
- Consider updating `docs/architecture.md` after completion
- Update this progress tracking section as work progresses
