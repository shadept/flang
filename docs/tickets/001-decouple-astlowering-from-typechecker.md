# RFC-001: Decouple HmAstLowering from HmTypeChecker

**Type:** Refactor
**Status:** Proposed
**Blocks:** RFC-002 (Consolidate HmTypeChecker state into typed registries)

## Summary

Extract a `TypeCheckResult` sealed data object that captures the immutable outputs of type checking. `HmAstLowering` and all LSP handlers receive this snapshot instead of the live `HmTypeChecker` + `InferenceEngine` pair.

## Motivation

`HmAstLowering` (4,750 lines) currently holds `HmTypeChecker _checker` and `InferenceEngine _engine` as fields, accessing them at 34 call sites. This coupling:

1. **Prevents reshaping the checker's internal state** — lowering can reach into any public member, so every field is effectively part of the checker's contract. This blocks RFC-002 (state consolidation).
2. **Keeps the InferenceEngine alive** for the entire compilation even though its mutable union-find is only needed during inference.
3. **Scatters `Engine.Resolve()` calls** across lowering and 4 LSP handlers as patches for types that should already be concrete after type checking. These calls mask incomplete resolution in the checker itself.

## Design

### New type: `TypeCheckResult`

A sealed class produced once by `HmTypeChecker.BuildResult()` after `ValidatePostInference()` completes. All types in the `NodeTypes` dictionary are **eagerly zonked** (resolved through the union-find) at construction time.

```csharp
public sealed class TypeCheckResult
{
    // Pre-zonked: no TypeVars appear as values after BuildResult()
    public IReadOnlyDictionary<AstNode, Type> NodeTypes { get; init; }

    public IReadOnlyDictionary<AstNode, ResolvedOperator> ResolvedOperators { get; init; }
    public IReadOnlyDictionary<string, NominalType> NominalTypes { get; init; }
    public IReadOnlyList<FunctionDeclarationNode> SpecializedFunctions { get; init; }
    public IReadOnlySet<Type> InstantiatedTypes { get; init; }
    public IReadOnlyDictionary<string, object> CompileTimeContext { get; init; }

    // --- Accessors ---

    /// Primary path: returns the fully-resolved type for a node.
    /// After BuildResult() zonks everything, this is a plain dictionary lookup.
    public Type GetResolvedType(AstNode node);

    /// Transitional: resolves a type through the captured engine delegate.
    /// Exists for call sites that hold raw types not yet in NodeTypes.
    /// Goal: once the checker resolves everything, these calls become
    /// identity functions and can be grepped + deleted.
    public Type Resolve(Type type);

    /// Operator lookup (nullable — null means primitive op, no overload).
    public ResolvedOperator? GetResolvedOperator(AstNode node);

    /// Nominal type lookup by FQN.
    public NominalType? LookupNominal(string fqn);
}
```

### Factory: `HmTypeChecker.BuildResult()`

```csharp
public TypeCheckResult BuildResult()
{
    // Zonk pass: resolve every inferred type once
    var zonked = new Dictionary<AstNode, Type>(_inferredTypes.Count);
    foreach (var (node, type) in _inferredTypes)
        zonked[node] = _engine.Resolve(type);

    var zonkedInstantiated = new HashSet<Type>(
        InstantiatedTypes.Select(t => _engine.Resolve(t)));

    // Capture Resolve as delegate for transitional use
    Func<Type, Type> resolve = _engine.Resolve;

    return new TypeCheckResult { ... };
}
```

### `Resolve()` as transitional crutch

Many `_checker.Engine.Resolve()` calls in lowering and LSP are patches for types that should already be fully resolved after type checking. The eager zonk in `BuildResult()` fixes this for everything in `NodeTypes`. However, some call sites hold raw `Type` values obtained through other paths (e.g., iterating `InstantiatedTypes`, casting function types). These still need `Resolve()` during the transition.

**The end state:** once the typechecker properly resolves all types before completion, `Resolve()` on `TypeCheckResult` becomes an identity function. At that point, grep for `.Resolve(` on `TypeCheckResult` usage sites and delete them. The captured engine delegate and the `Resolve` method itself can then be removed.

### Constructor changes

```csharp
// HmAstLowering — before:
public HmAstLowering(HmTypeChecker checker, TypeLayoutService layout, InferenceEngine engine)

// HmAstLowering — after:
public HmAstLowering(TypeCheckResult types, TypeLayoutService layout)
```

The `InferenceEngine` parameter is eliminated entirely. `TypeLayoutService` retains its own engine reference (constructed before `BuildResult()`).

### Call site migration (34 sites in HmAstLowering)

| Before | After | Count |
|---|---|---|
| `_engine.Resolve(_checker.GetInferredType(node))` | `_types.GetResolvedType(node)` | ~12 |
| `_checker.Engine.Resolve(_checker.GetInferredType(node))` | `_types.GetResolvedType(node)` | ~6 |
| `_checker.GetResolvedOperator(node)` | `_types.GetResolvedOperator(node)` | ~5 |
| `_checker.LookupNominalType(name)` | `_types.LookupNominal(name)` | ~4 |
| `_checker.CompileTimeContext` | `_types.CompileTimeContext` | 2 |
| `_checker.GetSpecializedFunctions()` | `_types.SpecializedFunctions` | 1 |
| `_checker.InstantiatedTypes.Select(t => _engine.Resolve(t))` | `_types.InstantiatedTypes` (pre-zonked) | 1 |
| `_engine.Resolve(someRawType)` (not from NodeTypes) | `_types.Resolve(someRawType)` (transitional) | ~3 |

### LSP handler migration

`FileAnalysisResult.TypeChecker` changes from `HmTypeChecker?` to `TypeCheckResult?`. All handlers:

| Before | After |
|---|---|
| `tc.Engine.Resolve(type)` | `tc.Resolve(type)` (transitional, then removable) |
| `tc.InferredTypes.TryGetValue(node, out var t)` | `tc.NodeTypes.TryGetValue(node, out var t)` |
| `tc.NominalTypes` | `tc.NominalTypes` (unchanged) |

Affected handlers: `HoverHandler`, `SignatureHelpHandler`, `InlayHintHandler`, `DefinitionHandler`.

### Optional: `ITypeResolver` implementation

`TypeCheckResult` can implement `ITypeResolver` (from `FLang.Core`) so that `TypeLayoutService` can accept it directly in future refactors:

```csharp
public sealed class TypeCheckResult : ITypeResolver
{
    Type ITypeResolver.Resolve(Type type) => Resolve(type);
}
```

This is not required for the initial refactor but keeps the door open.

## Implementation sequence

1. Create `TypeCheckResult.cs` in `FLang.Semantics`
2. Add `BuildResult()` to `HmTypeChecker`
3. Update `Compiler.cs` call site: call `BuildResult()`, pass result to lowering
4. Migrate `HmAstLowering`: replace `_checker`/`_engine` fields with `_types`, update all 34 call sites
5. Update `FLangWorkspace.FileAnalysisResult` record type
6. Migrate LSP handlers (4 files)
7. Build (`dotnet build.cs`) and test (`dotnet test.cs`)

## Trade-offs

**Gained:**
- Clean phase boundary: checker is done, snapshot is immutable
- InferenceEngine + DisjointSet can be GC'd after `BuildResult()`
- Unblocks RFC-002 (checker state consolidation)
- `Resolve()` calls are now visible as technical debt — easy to grep and track

**Cost:**
- One-time O(N) zonk pass over all inferred types at `BuildResult()` — negligible at FLang program sizes
- Transitional `Resolve()` delegate keeps engine alive until all callers are cleaned up (but the intent to remove is explicit)

**Deliberately not done:**
- No composable sub-interfaces (one consumer, no benefit to splitting)
- No interface — sealed class is sufficient (one implementation, no substitution need)
- No eager zonk of types inside `NominalType.FieldsOrVariants` — these are resolved by the checker during `ResolveNominalTypes` and should already be concrete

## Validation

- All existing tests must pass unchanged (`dotnet test.cs`)
- No semantic or behavioral changes — this is a pure structural refactor
- After migration, `HmAstLowering` should have zero imports from `HmTypeChecker` or `InferenceEngine`
