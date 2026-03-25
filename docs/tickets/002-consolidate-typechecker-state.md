# RFC-002: Consolidate HmTypeChecker State into Typed Registries

**Type:** Refactor
**Status:** Proposed
**Depends on:** RFC-001 (Decouple HmAstLowering from HmTypeChecker)

## Summary

Group `HmTypeChecker`'s 28 private fields into 4 cohesive state objects that mirror the checker's natural phases. Each object owns a well-defined slice of the checker's responsibility, making it explicit which state each method actually needs.

## Motivation

`HmTypeChecker` is a 4,500-line partial class across 6 files with 28 private fields serving 6 different concerns. Any method in any partial file can read or write any field. This makes it hard to:

1. **Understand a method's dependencies** — to know what `InferCall` needs, you must read all 228 lines and track which fields it touches.
2. **Reason about phase ordering** — nothing prevents phase 4 code from accidentally writing to phase 1 state.
3. **Test a single concern** — you can't instantiate "just the expression inference" without constructing the entire checker.
4. **Onboard to the codebase** — a new reader sees 28 fields and doesn't know which ones matter for what they're looking at.

After RFC-001 extracts the output side (`TypeCheckResult`), the remaining fields are purely internal. This is the right time to organize them.

## Field Inventory

Here are all fields on `HmTypeChecker`, grouped by the concern they serve:

### Group A: Type Registry (phases 1-2, then frozen)
| Field | Type | Purpose |
|---|---|---|
| `_nominalTypes` | `Dict<string, NominalType>` | FQN → struct/enum type |
| `_nominalSpans` | `Dict<string, SourceSpan>` | FQN → declaration span (error notes) |
| `_fieldTypeNodes` | `Dict<string, IReadOnlyList<...>>` | FQN → field AST type nodes (template expansion) |
| `_deprecatedTypes` | `Dict<string, string?>` | FQN → deprecation message |

### Group B: Function Registry (phase 3, then frozen)
| Field | Type | Purpose |
|---|---|---|
| `_functions` | `Dict<string, List<FunctionScheme>>` | Name → overload set |
| `_deprecatedFunctions` | `Dict<string, string?>` | Name → deprecation message |

### Group C: Inference Working State (transient during phase 4)
| Field | Type | Purpose |
|---|---|---|
| `_engine` | `InferenceEngine` | Unification, type variables |
| `_scopes` | `TypeScopes` | Variable → type bindings |
| `_constScopes` | `Stack<HashSet<string>>` | Parallel const tracking |
| `_functionStack` | `Stack<FunctionContext>` | Current function context |
| `_currentModulePath` | `string?` | Module being checked |
| `_isCheckingGenericBody` | `bool` | Generic body mode flag |
| `_lambdaScopeBarrier` | `int` | Lambda non-capture barrier |
| `_nextLambdaId` | `int` | Lambda name counter |
| `_activeTypeParams` | `Dict<string, int>` | Generic type param ref counting |
| `_deferredSpecInfo` | nullable tuple | Overload→call communication |
| `_currentFnDeclaredVars` | `Dict<string, SourceSpan>?` | Unused var tracking (declared) |
| `_currentFnUsedVars` | `HashSet<string>?` | Unused var tracking (used) |

### Group D: Inference Results (populated during phase 4, consumed by RFC-001's BuildResult)
| Field | Type | Purpose |
|---|---|---|
| `_inferredTypes` | `Dict<AstNode, Type>` | Node → inferred type |
| `_resolvedOperators` | `Dict<AstNode, ResolvedOperator>` | Node → resolved operator |
| `InstantiatedTypes` | `HashSet<Type>` | RTTI type set |
| `_specializations` | `List<FunctionDeclarationNode>` | Monomorphized functions |
| `_emittedSpecs` | `Dict<string, FunctionDeclarationNode>` | Spec dedup cache |

### Group E: Deferred Validation (accumulated phase 4, consumed post-inference)
| Field | Type | Purpose |
|---|---|---|
| `_unsuffixedLiterals` | `List<(IntegerLiteralNode, Type)>` | Int literals needing validation |
| `_unsuffixedFloatLiterals` | `List<(FloatingPointLiteralNode, Type)>` | Float literals needing validation |
| `_pendingSpecializations` | `List<(FunctionScheme, ...)>` | Deferred generic specs |

### Always present
| Field | Type | Purpose |
|---|---|---|
| `_compilation` | `Compilation` | Build context |
| `_diagnostics` | `List<Diagnostic>` | Error accumulator |

## Design

### Introduce 4 state containers

Each container is a plain class that owns its fields and exposes them to the checker. They are **not** independent modules with their own logic — the checker still orchestrates everything. The containers are organizational, not architectural. They make the field groupings explicit and enforceable.

```
HmTypeChecker
├── _types: TypeRegistry        (Group A — frozen after phase 2)
├── _functions: FunctionRegistry (Group B — frozen after phase 3)
├── _results: InferenceResults   (Group D — accumulated during phase 4, feeds BuildResult)
├── _ctx: InferenceContext       (Group C — transient working state during phase 4)
│
├── _compilation: Compilation    (unchanged — build context)
├── _diagnostics: List<Diag>     (unchanged — cross-cutting)
│
└── Group E fields stay on the checker (small, consumed in ValidatePostInference only)
```

### Container: `TypeRegistry`

```csharp
/// <summary>
/// Nominal type declarations collected during phases 1-2.
/// Frozen after ResolveNominalTypes completes.
/// </summary>
internal sealed class TypeRegistry
{
    public Dictionary<string, NominalType> NominalTypes { get; } = [];
    public Dictionary<string, SourceSpan> NominalSpans { get; } = [];
    public Dictionary<string, IReadOnlyList<(string Name, TypeNode TypeNode)>> FieldTypeNodes { get; } = [];
    public Dictionary<string, string?> DeprecatedTypes { get; } = [];

    public NominalType? Lookup(string name) { ... }
    public NominalType? LookupWithModule(string name, string? currentModule) { ... }
    public bool Contains(string fqn) => NominalTypes.ContainsKey(fqn);
}
```

This absorbs the current `LookupNominalType` logic (exact FQN, module-prefixed, short-name scan) and `_nominalSpans` for duplicate-detection notes. The `INominalTypeRegistry` interface can be implemented by `TypeRegistry` instead of `HmTypeChecker`.

### Container: `FunctionRegistry`

```csharp
/// <summary>
/// Function overload sets collected during phase 3.
/// Frozen after CollectFunctionSignatures completes.
/// </summary>
internal sealed class FunctionRegistry
{
    public Dictionary<string, List<FunctionScheme>> Functions { get; } = [];
    public Dictionary<string, string?> DeprecatedFunctions { get; } = [];

    public void Register(FunctionScheme scheme, Action<string, SourceSpan, string> reportError) { ... }
    public List<FunctionScheme>? Lookup(string name, string? currentModule) { ... }
}
```

This absorbs `RegisterFunction`, `LookupFunctions`, `HasSameParameterSignature`, and `TypeNodeEquals` — all of which are self-contained function-registry logic currently mixed into the checker's main file.

### Container: `InferenceResults`

```csharp
/// <summary>
/// Accumulated type-checking outputs. Fed into TypeCheckResult.BuildResult().
/// </summary>
internal sealed class InferenceResults
{
    public Dictionary<AstNode, Type> InferredTypes { get; } = [];
    public Dictionary<AstNode, ResolvedOperator> ResolvedOperators { get; } = [];
    public HashSet<Type> InstantiatedTypes { get; } = [];
    public List<FunctionDeclarationNode> Specializations { get; } = [];
    public Dictionary<string, FunctionDeclarationNode> EmittedSpecs { get; } = [];

    /// <summary>Record the inferred type for an AST node.</summary>
    public Type Record(AstNode node, Type type)
    {
        InferredTypes[node] = type;
        return type;
    }

    /// <summary>Get previously inferred type or throw.</summary>
    public Type GetInferredType(AstNode node) { ... }

    /// <summary>Get resolved operator or null.</summary>
    public ResolvedOperator? GetResolvedOperator(AstNode node) { ... }
}
```

This is the container that RFC-001's `BuildResult()` reads from. The `Record`, `GetInferredType`, and `GetResolvedOperator` methods move here from the checker, keeping the same signatures.

### Container: `InferenceContext`

```csharp
/// <summary>
/// Transient working state during phase 4 (body checking).
/// Reset or irrelevant between functions.
/// </summary>
internal sealed class InferenceContext
{
    public InferenceEngine Engine { get; }
    public TypeScopes Scopes { get; }

    // Parallel const scope tracking
    public Stack<HashSet<string>> ConstScopes { get; } = new(new[] { new HashSet<string>() });

    // Function context
    public Stack<FunctionContext> FunctionStack { get; } = new();
    public string? CurrentModulePath { get; set; }
    public bool IsCheckingGenericBody { get; set; }

    // Lambda state
    public int LambdaScopeBarrier { get; set; }
    public int NextLambdaId { get; set; }

    // Generic specialization state
    public Dictionary<string, int> ActiveTypeParams { get; } = [];
    public (FunctionScheme Scheme, Type[] Params, Type Return)? DeferredSpecInfo { get; set; }

    // Unused variable tracking (per-function)
    public Dictionary<string, SourceSpan>? CurrentFnDeclaredVars { get; set; }
    public HashSet<string>? CurrentFnUsedVars { get; set; }

    // Scope management helpers
    public void PushScope() { ... }
    public void PopScope() { ... }
    public void MarkConst(string name) { ... }
    public bool IsConst(string name) { ... }

    public InferenceContext(InferenceEngine engine)
    {
        Engine = engine;
        Scopes = new TypeScopes();
    }
}
```

This absorbs `PushScope`/`PopScope`/`MarkConst`/`IsConst` — currently on `HmTypeChecker` but purely about scope state.

## What changes in the checker

### Before

```csharp
public partial class HmTypeChecker
{
    private readonly InferenceEngine _engine;
    private readonly TypeScopes _scopes;
    private readonly Dictionary<string, NominalType> _nominalTypes = [];
    private readonly Dictionary<string, SourceSpan> _nominalSpans = [];
    // ... 24 more fields ...

    private Type InferBinary(BinaryExpressionNode bin)
    {
        var left = InferExpression(bin.Left);
        var right = InferExpression(bin.Right);
        _engine.Unify(left, right, bin.Span);      // which _engine?
        _resolvedOperators[bin] = resolved;         // which dict?
        return Record(bin, resultType);             // touches _inferredTypes
    }
}
```

### After

```csharp
public partial class HmTypeChecker
{
    private readonly TypeRegistry _types;
    private readonly FunctionRegistry _fns;
    private readonly InferenceResults _results;
    private readonly InferenceContext _ctx;
    private readonly Compilation _compilation;
    private readonly List<Diagnostic> _diagnostics = [];

    private Type InferBinary(BinaryExpressionNode bin)
    {
        var left = InferExpression(bin.Left);
        var right = InferExpression(bin.Right);
        _ctx.Engine.Unify(left, right, bin.Span);   // clearly inference state
        _results.ResolvedOperators[bin] = resolved;  // clearly output
        return _results.Record(bin, resultType);     // clearly output
    }
}
```

Every field access now self-documents which concern it belongs to. A reader seeing `_ctx.` knows it's transient inference state. Seeing `_results.` knows it's output that feeds `BuildResult()`. Seeing `_types.` knows it's the frozen type registry.

## What does NOT change

- **No new files for the partial class split.** The 6 existing partial files (`HmTypeChecker.cs`, `.Declarations.cs`, `.Expressions.cs`, `.Statements.cs`, `.Types.cs`, `.Specialization.cs`) stay as-is. The containers are field groupings, not architectural boundaries.
- **No method signature changes on public API.** `CheckModule`, `CollectNominalTypes`, `BuildResult`, etc. keep their signatures.
- **No behavioral changes.** Same phases, same order, same errors.
- **Group E fields stay on the checker.** `_unsuffixedLiterals`, `_unsuffixedFloatLiterals`, and `_pendingSpecializations` are small, only touched by `ValidatePostInference` and `ResolvePendingSpecializations`. Not worth a container.

## Migration strategy

This is a mechanical refactor — rename field accesses from `_fieldName` to `_container.FieldName`. It can be done one container at a time:

1. **TypeRegistry first** — extract `_nominalTypes`, `_nominalSpans`, `_fieldTypeNodes`, `_deprecatedTypes` + move `LookupNominalType` logic. Touches `HmTypeChecker.cs` and `HmTypeChecker.Declarations.cs` primarily.
2. **FunctionRegistry second** — extract `_functions`, `_deprecatedFunctions` + move `RegisterFunction`, `LookupFunctions`, `HasSameParameterSignature`, `TypeNodeEquals`. Touches `HmTypeChecker.cs` and `HmTypeChecker.Declarations.cs`.
3. **InferenceResults third** — extract `_inferredTypes`, `_resolvedOperators`, `InstantiatedTypes`, `_specializations`, `_emittedSpecs` + move `Record`, `GetInferredType`, `GetResolvedOperator`. Touches all partial files. Update RFC-001's `BuildResult()` to read from `_results`.
4. **InferenceContext last** — extract remaining transient fields + move `PushScope`/`PopScope`/`MarkConst`/`IsConst`. Touches all partial files (most mechanical, highest line count).

Each step compiles and tests independently.

## Implementation sequence

- [ ] Create `TypeRegistry.cs` in `FLang.Semantics`, move 4 fields + lookup logic
- [ ] Add `_types: TypeRegistry` to `HmTypeChecker`, update all `_nominalTypes`/`_nominalSpans`/`_fieldTypeNodes`/`_deprecatedTypes` references
- [ ] Move `INominalTypeRegistry` implementation to `TypeRegistry`, delegate from checker
- [ ] Build + test
- [ ] Create `FunctionRegistry.cs`, move 2 fields + register/lookup/dedup logic
- [ ] Add `_fns: FunctionRegistry`, update all `_functions`/`_deprecatedFunctions` references
- [ ] Build + test
- [ ] Create `InferenceResults.cs`, move 5 fields + Record/Get methods
- [ ] Add `_results: InferenceResults`, update all `_inferredTypes`/`_resolvedOperators`/etc. references
- [ ] Update `BuildResult()` (RFC-001) to read from `_results`
- [ ] Build + test
- [ ] Create `InferenceContext.cs`, move 12 fields + scope helpers
- [ ] Add `_ctx: InferenceContext`, update all transient state references
- [ ] Build + test

## Trade-offs

**Gained:**
- Every field access self-documents its concern (`_ctx.` vs `_results.` vs `_types.`)
- Phase boundaries become enforceable — a method that only takes `TypeRegistry` can't accidentally touch inference state
- Individual containers are testable in isolation (e.g., test `FunctionRegistry.Lookup` visibility logic without a full checker)
- Future extraction of concerns (e.g., making specialization its own pass) has a clear starting point

**Cost:**
- Longer field access paths (`_ctx.Engine.Unify(...)` instead of `_engine.Unify(...)`)
- 4 new small files in FLang.Semantics
- Large mechanical diff (touching all 6 partial files)

**Mitigated by:**
- Each container is `internal sealed` — no public API surface change
- Migration is 4 independent steps, each compilable and testable
- The longer paths are a feature: they force you to think about which concern you're touching

## Validation

- All existing tests must pass unchanged (`dotnet test.cs`)
- No semantic or behavioral changes
- After migration, `HmTypeChecker` constructor should have exactly 6 fields: `_types`, `_fns`, `_results`, `_ctx`, `_compilation`, `_diagnostics`
