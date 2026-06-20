# RFC-017: `flang_typer` — type system as a library

**Type:** Self-hosting / library extraction
**Status:** Phase 1 landed — every module from the layout is implemented and the lib compiles cleanly. The RTTI codegen blocker is fixed, so the lib is consumable: `flang_typer` is linked into [bootstrap](../../bootstrap/) and its `checker` pipeline now type-checks as part of the bootstrap build. Engine + coercion also exercised via [examples/typer-smoke](../../examples/typer-smoke/) (30 checks pass) and by colocated `test {}` blocks in `inference_engine.f`, run with `flang test` (the C# compiler is the test driver until bootstrap self-hosts). Remaining smoke checks (data layer, coercion) still to be ported into colocated blocks; the example is retired once that lands.
**Depends on:** `flang_parser`, `flang_core` (the lib, for `SourceSpan` / `Diagnostic`)
**Follows:** `flang_parser` (lex/parse + AST), `flang_codegen` (FIR + C backend) as the third self-hosted compiler library.

## Summary

A standalone library that owns the FLang type system: the `Ty` ADT, the unification engine, polymorphic schemes, coercion rules, nominal/function registries, and the AST-walking checker. It feeds an immutable `TypeCheckResult` to downstream consumers (lowering, LSP).

Goal: same capability as the C# `FLang.Semantics` (HM with let-generalisation, eager monomorphisation, coercion ladder, overload resolution, anon-struct / tuple support), with three explicit design corrections informed by the C# implementation:

1. **Model–engine decoupling.** The `Ty` ADT is pure data; the engine is just unification + var allocation. Coercion, scopes, registries, diagnostics, and AST mutation are each their own module.
2. **Outcome-based error handling.** The engine never produces a `Diagnostic`. It returns structured `UnifyOutcome` values; the caller decides the error code, message, and span. No more `OverrideErrors` / scoped templates / hidden diagnostic lists inside the engine.
3. **No AST mutation from the checker.** All inference output lives in side tables keyed by node identity. The AST stays the immutable view from the parser.

## Lessons from C# `FLang.Semantics`

What the new design is reacting to:

| Pain | Where it lives in C# | Fix in flang_typer |
|---|---|---|
| 13k-line partial `HmTypeChecker` with 28 fields | `HmTypeChecker.*.cs` | Phase-shaped free functions; state lives in 4 explicit containers. |
| Engine emits diagnostics + supports a scoped `OverrideErrors` API | `InferenceEngine.ReportError`, `OverrideErrors` | Engine returns `UnifyOutcome`. Diagnostics produced by `checker` only. |
| Coercion rules call back into `engine.Unify` mid-rule (reentrancy via `TryUnify` + commit) | `CoercionRules.cs` (`ArrayDecay`, `AnonymousStruct`) | Rules return a `Coercion { result_type, cost, pending: List(Constraint) }`. Engine commits or discards atomically. |
| Anonymous struct/tuple types share `NominalType` with `__anon_*` name munging and a `Kind` discriminator | `Core/Types/Type.cs` `NominalType` | First-class `Tuple(List(Type))` and `Record(List(Field))` variants. |
| `NominalType.FieldsOrVariants` doubles as struct fields and enum variants, payload-less variants use `void` as sentinel | same | Split into `StructDef { fields }` and `EnumDef { variants }` stored in `NominalRegistry`, referenced by `Nominal(NominalId)`. |
| `TypeVar.Id` is a global `Interlocked` counter; `PolymorphicType.QuantifiedVarIds` are ints | `Core/Types/Type.cs` `TypeVar` | Var ids are allocated by an engine-owned `VarFactory`; quantified sets are typed `Set(VarId)`. |
| Checker mutates AST nodes (`id.ResolvedFunctionTarget`, `member.OpDerefChain`, …) | `HmTypeChecker.Expressions.cs` | Side-table only: `InferenceResults.resolved_targets: Dict(NodeId, ResolvedTarget)`. AST is read-only. |
| `TypeCheckResult` still carries a live `_resolver` because some types aren't zonked | `TypeCheckResult.cs` | Zonk eagerly inside `result.f`. `TypeCheckResult` does not retain an engine. |
| `InferenceContext` holds 12 unrelated transient fields (lambda frames, defer depth, try counter, unused-var trackers …) | `InferenceContext.cs` | `InferenceContext` keeps only inference-relevant state (engine, env, function stack, level). Lambda capture, defer, `?`-desugaring counters live on their respective sub-checkers. |
| Throwing `InternalCompilerError` for missing node types | `InferenceResults.GetInferredType` | Return `Type?`. Callers explicitly handle the "checker never visited this node" case. |
| Visibility filtering threaded as `HashSet<string>?` through every lookup | `TypeRegistry.LookupNominalType`, `FunctionRegistry.Lookup` | `Visibility { current_module, visible }` is one value passed to lookups; same shape across nominal + function registries. |
| Lowering re-derives target types from slot context (e.g. `LowerEnumConstruction` had to pass `variant.PayloadType` to `LowerExpression` so anon-struct literals coerce instead of falling back to `__anon_*`) | `HmAstLowering.LowerExpression(expr, expectedType)` | **Inference is the only source of truth.** Every coercion materialises in `InferenceResults`: anon-struct literal in `Ty.Array(.{...})` position must end up with `node_types[anon] == Ty.Nominal(ArrayTy)` *after the checker runs*. Lowering reads the type; it never guesses from the surrounding slot. The expected-type plumbing in `LowerExpression` is the C# checker silently delegating its job to lowering. |

## Library layout

```
lib/flang_typer/
├── flang.toml                  # depends on flang_core (Diagnostic, SourceSpan), flang_parser (AST)
└── src/
    ├── type.f                  # Type ADT, Field, NominalRef, VarId — pure data
    ├── well_known.f            # primitives + well-known nominal FQNs as constants
    ├── scheme.f                # Scheme { quantified, body }, generalize, specialize
    ├── substitution.f          # Substitution helpers (no engine state)
    ├── union_find.f            # in-lib `UnionFind($K)` w/ checkpoint/rollback — not in stdlib
    ├── inference_engine.f      # Engine: vars, unify -> UnifyOutcome, level, occurs check
    ├── coercion.f              # CoercionRule, Coercion, built-in rules
    ├── env.f                   # TypeEnv: scoped name -> Scheme
    ├── nominal_registry.f      # StructDef / EnumDef, FQN lookup w/ visibility
    ├── function_registry.f     # overload sets, visibility filtering, signature-equality dedup
    ├── visibility.f            # Visibility { current_module, visible: Set(String) }
    ├── reporter.f              # checker-side diagnostic builder (translates UnifyOutcome -> Diagnostic)
    ├── inference_results.f     # mutable accumulator during checking
    ├── checker.f               # AST walker; phase entry points: collect_nominals / collect_signatures / check_bodies
    ├── checker_expr.f          # expression inference
    ├── checker_stmt.f          # statement inference
    ├── checker_decl.f          # declaration handling
    ├── checker_pattern.f       # pattern inference (match + struct patterns)
    ├── specialization.f       # eager monomorphisation: clone + substitute + re-check
    ├── result.f                # immutable TypeCheckResult (zonked, engine discarded)
    └── error_codes.f           # E20xx codes used by reporter
```

Same shape as `flang_parser` (one concern per file, no barrels) and `flang_codegen` (data file + builder file + driver file).

## The `Ty` ADT

```flang
// type.f

// Transparent aliases (FLang's `type Name = <type-expr>`): documentation
// at the API boundary, free at the type-checker level — the engine treats
// them as their underlying integer type.
pub type VarId = u32
pub type Level = u32
pub type NominalId = u32

// Renamed from `Type` to `Ty` (and `TypeVar` to `TyVar`) to avoid the
// `core.rtti.Type` collision: `#inline` functions like `box(...)` resolve
// type names at the call site, so an enum named `Type` shadows the rtti
// type and breaks `size_of(T) / new(Type(T))` inside stdlib generics.

pub type TyVar = struct {
    id: VarId
    level: Level
}

pub type Field = struct {
    name: String
    ty: Ty
}

pub type FunctionTy = struct {
    params: List(Ty)
    ret: &Ty
}

pub type ArrayTy = struct {
    elem: &Ty
    length: usize        // resolved at this point — no Expr in the type model
}

pub type Ty = enum {
    Var(TyVar)
    Prim(PrimitiveKind)        // u8/i32/bool/... — enum, not String
    Ref(&Ty)
    Array(ArrayTy)
    Func(FunctionTy)
    Tuple(List(Ty))            // first-class, distinct from records
    Record(List(Field))        // anonymous struct — structural
    Nominal(NominalRef)        // user-defined; NominalRef = (id, args)
    Never
    Void
    Error                      // poison; unifies with anything silently
}

pub type NominalRef = struct {
    id: NominalId
    args: List(Ty)
}

pub type PrimitiveKind = enum {
    Bool
    I8 I16 I32 I64 ISize
    U8 U16 U32 U64 USize
    F32 F64
    Char
}
```

Key differences from the C# `Type`:

- **`Var.id`** is a `VarId` (transparent alias for `u32`) allocated by the engine, not a global counter — schemes can be serialised, two compilations don't collide, tests can reset. The alias is naming-only; the type-checker resolves it to `u32` so there's no wrapping overhead.
- **`PrimitiveKind`** is an enum, not a string. Comparison is integer-cheap, no `"i32"` literal floats around the codebase.
- **`Tuple` and `Record`** are separate constructors. No `Name.StartsWith("__anon_")` checks anywhere.
- **`Nominal(NominalRef)`** is an indirection through `NominalRegistry` — the definition (fields/variants) lives in the registry, the type carries only `id + args`. Eliminates the C# version's "anonymous types carry structure in `FieldsOrVariants`, named ones don't" duality.
- **`Error`** variant lets the checker propagate poison without crashing downstream code; any unification involving `Error` succeeds without producing a diagnostic.
- **No `PolymorphicType` in `Ty`.** Polymorphism is a property of *bindings*, not types. `Scheme { quantified, body }` is a separate struct, only used in `TypeEnv` and `FunctionRegistry`. Every `Ty` value is a monotype.

## The engine

```flang
// inference_engine.f

pub type Engine = struct {
    uf: UnionFind(VarId)
    next_var_id: u32
    level: Level
    prim_constraints: Dict(VarId, Set(PrimitiveKind))   // narrow `char` literals etc.
    coercion_rules: List(CoercionRule)
    allocator: &Allocator
}

pub fn engine(allocator: &Allocator? = null) Engine { ... }

pub fn fresh_var(self: &Engine) Type { ... }
pub fn fresh_constrained_var(self: &Engine, kinds: Set(PrimitiveKind)) Type { ... }

pub fn enter_level(self: &Engine) { ... }
pub fn exit_level(self: &Engine) { ... }

pub fn resolve(self: &Engine, t: Type) Type { ... }                  // walks union-find
pub fn zonk(self: &Engine, t: Type) Type { ... }                     // resolve recursively
pub fn occurs_in(self: &Engine, v: VarId, t: Type) bool { ... }

pub fn unify(self: &Engine, actual: Type, expected: Type) UnifyOutcome { ... }
pub fn try_unify(self: &Engine, a: Type, b: Type) UnifyOutcome { ... } // speculative + rolled back

pub fn generalize(self: &Engine, t: Type) Scheme { ... }
pub fn specialize(self: &Engine, s: &Scheme) Type { ... }
pub fn specialize_with_map(self: &Engine, s: &Scheme) (Type, Dict(VarId, VarId)) { ... }
```

```flang
// inference_engine.f — outcomes

pub type UnifyOutcome = enum {
    Ok(UnifyOk)
    Mismatch(Mismatch)
    OccursCheck(Occurs)
    ArityMismatch(Arity)
    PrimConstraintViolation(PrimViolation)
    FunctionParamCount(FnArity)
    FunctionReturnMismatch(FnRet)
    ArrayLengthMismatch(ArrLen)
}

pub type UnifyOk = struct {
    ty: Type
    cost: u32          // number of coercions applied
}

pub type Mismatch = struct {
    actual: Type
    expected: Type
}
// ... other detail records ...
```

`unify` is the one entry point. No `span`, no diagnostic. Callers translate outcomes via `reporter.f` and attach their own context (call site, return statement, assignment, etc.).

`try_unify` always rolls back; used by overload resolution and coercion rule scoring.

`UnifyJoin` from the C# version becomes `unify_join(a, b)` — symmetric coercion direction. Same single-outcome return shape.

## Coercion model

The C# version's `IInferenceCoercionRule.TryApply` calls back into `engine.Unify` mid-rule, mixing speculative side-effects with the rule's own logic. New shape:

```flang
// coercion.f

pub type CoercionRule = struct {
    name: String       // diagnostic label
    apply: fn(from: Type, to: Type, &CoercionCtx) Coercion?
}

pub type CoercionCtx = struct {
    resolve: fn(Type) Type
    try_unify: fn(Type, Type) UnifyOutcome     // speculative; never commits
    lookup_nominal: fn(NominalId) &NominalDef?
}

pub type Coercion = struct {
    result_ty: Type
    cost: u32
    side_unifications: List(Constraint)   // engine commits these atomically
}

pub type Constraint = struct {
    a: Type
    b: Type
}
```

A rule's `apply` is *read-only* against the engine — it speculates via `try_unify` and reports any required follow-up unifications as `side_unifications`. The engine commits them atomically after the rule succeeds. No more `engine.TryUnify(...) != null; engine.Unify(...)` pattern from `ArrayDecayCoercionRule`.

**Coercions materialise in `InferenceResults`.** When a rule fires, the engine commits the side-unifications *and* the originating expression's entry in `node_types` is rewritten to the coerced type. Concretely: `Ty.Array(.{ elem, length })` records `node_types[anon] = Nominal(ArrayTy)`, not the synthesized `Record(...)` shape. Lowering reads the type from the side-table; it never inspects the surrounding slot to guess. This is the property the C# version fails — the `expectedType` parameter on `LowerExpression` exists only because the C# checker recorded the un-coerced type and left the conversion to lowering. The FLang checker is responsible for resolving every node to its final concrete type before the engine is discarded.

Built-in rules ship with the lib:
`integer_widening`, `float_widening`, `option_wrapping`, `string_to_byte_slice`, `array_decay`, `slice_to_reference`, `anonymous_struct`, `nominal_to_type`. Each in `coercion.f` as a free function returning a `CoercionRule`.

## Registries

```flang
// nominal_registry.f

pub type NominalDef = enum {
    Struct(StructDef)
    Enum(EnumDef)
}

pub type StructDef = struct {
    fqn: String
    module: String
    is_pub: bool
    type_params: List(VarId)        // generic type-var ids
    fields: List(Field)
    decl_span: SourceSpan
    deprecation: String?
}

pub type EnumDef = struct {
    fqn: String
    module: String
    is_pub: bool
    type_params: List(VarId)
    variants: List(VariantDef)
    tag_values: Dict(String, i64)?   // naked enums
    decl_span: SourceSpan
    deprecation: String?
}

pub type VariantDef = struct {
    name: String
    payloads: List(Type)            // empty for nullary variants — no `void` sentinel
}

pub type NominalRegistry = struct {
    defs: List(NominalDef)          // indexed by NominalId.idx
    by_fqn: Dict(String, NominalId)
}

pub fn lookup(self: &NominalRegistry, name: String, vis: &Visibility) LookupResult(NominalId) { ... }

pub type LookupResult(T) = enum {
    Found(T)
    NotVisible(T, String)   // found but module not imported — for better diagnostics
    NotFound
}
```

Visibility is explicit:

```flang
// visibility.f
pub type Visibility = struct {
    current_module: String?
    visible: Set(String)        // modules in scope, incl. transitive pub-imports
}
```

`FunctionRegistry` mirrors this shape: separate file, same `LookupResult`-style return, same `Visibility` parameter.

## Env & inference context

```flang
// env.f
pub type TypeEnv = struct {
    scopes: List(Scope)          // stack — back is innermost
}

pub type Scope = struct {
    bindings: Dict(String, Binding)
}

pub type Binding = struct {
    scheme: Scheme
    decl: NodeId                 // span via AST, not stored here
    is_const: bool
    captured_at_depth: u32?      // set when crossing lambda frame
}
```

`InferenceContext` holds only inference-relevant state. Lambda capture, defer depth, try-counter, unused-var tracking become *separate* sub-checkers composed with the main checker (each file owns its own state):

```flang
// checker.f
pub type Checker = struct {
    engine: Engine
    env: TypeEnv
    nominals: &NominalRegistry
    functions: &FunctionRegistry
    results: InferenceResults
    diagnostics: &List(Diagnostic)

    fn_stack: List(FnFrame)          // current function's return type
    current_module: String?
    spec_callers: List(String)       // visibility union for generic body checking
    level: Level
}
```

No `LambdaFrames`, `DeferDepth`, `NextTryId` on the main checker. Each is contained in the file that needs it:

```flang
// checker_expr.f
fn check_lambda(self: &Checker, lam: &LambdaExpr) Type {
    let frame = lambda_frame(self.env.depth())
    // ... walks body, recording captures into `frame.captures` ...
}
```

## Inference output

```flang
// inference_results.f

pub type InferenceResults = struct {
    node_types: Dict(NodeId, Type)
    resolved_ops: Dict(NodeId, ResolvedOperator)
    resolved_targets: Dict(NodeId, ResolvedTarget)   // call → function decl, identifier → variant ctor, etc.
    instantiated_types: Set(Type)
    specializations: List(SpecializedFn)
}

pub type ResolvedTarget = enum {
    Function(FnId)
    LocalVar(NodeId)
    StructField(NominalId, u32)        // struct + field index
    EnumVariant(NominalId, u32)
    SpecializedFn(SpecId)
}
```

`NodeId` comes from `flang_parser` — every AST node already has a `span` we can fingerprint by `(file_id, start, length)`. No reliance on object identity, no mutation of AST nodes, and consumers (LSP find-references) get the same identity model that already works in the C# version.

## The pipeline

```flang
// checker.f

pub fn collect_nominals(modules: &List(ParsedModule)) NominalRegistry { ... }

pub fn collect_signatures(
    modules: &List(ParsedModule),
    nominals: &NominalRegistry,
    diagnostics: &List(Diagnostic),
) FunctionRegistry { ... }

pub fn check_module_bodies(
    module: &ParsedModule,
    nominals: &NominalRegistry,
    functions: &FunctionRegistry,
    diagnostics: &List(Diagnostic),
) InferenceResults { ... }

pub fn check_all(
    modules: &List(ParsedModule),
    diagnostics: &List(Diagnostic),
) TypeCheckResult { ... }
```

`check_all` orchestrates: `collect_nominals` → source-generator hook → `collect_signatures` → for each module `check_module_bodies` → `resolve_pending_specializations` → `validate_post_inference` → `zonk` → return.

Each phase is a free function. No object juggling phase ordering; the caller can reach into individual phases if needed (LSP wants to re-check one module on save).

## The final result

```flang
// result.f

pub type TypeCheckResult = struct {
    node_types: Dict(NodeId, Type)       // zonked
    resolved_ops: Dict(NodeId, ResolvedOperator)
    resolved_targets: Dict(NodeId, ResolvedTarget)
    nominals: NominalRegistry               // ownership transferred
    functions: FunctionRegistry             // ownership transferred
    specializations: List(SpecializedFn)
    instantiated_types: Set(Type)
}
```

All types are zonked at construction. **No engine retained.** No back-channel `Resolve()`. If a consumer needs the type of a node, it's a hash-map lookup, period.

## Diagnostics path

```
unify outcome
  → reporter.from_outcome(outcome, ctx)
  → Diagnostic { code, message, hint, span }
  → push to &List(Diagnostic)
```

`reporter.from_outcome` takes a `ReportCtx { code: String, span: SourceSpan, hint_builder: fn(...) String? }`. Equivalent to C#'s `OverrideErrors` but explicit and locally-scoped per call site, not a stack of dynamically-bound state on the engine.

Error codes registered in `error_codes.f` — one consolidated list, easier audit than scattered string literals.

## Migration

The C# `FLang.Semantics` stays the production type checker until `flang_typer` is feature-complete and parity-tested. The lib is developed in tandem with the existing parser/codegen libs, gated behind an opt-in self-host driver.

Suggested build order:

1. **`type.f` + `well_known.f` + `scheme.f` + `substitution.f` + `union_find.f`** — pure data + helpers. Unit-testable in isolation.
2. **`inference_engine.f`** — unify / try_unify / generalize / specialize, no coercion. Tests against hand-written `Ty` values.
3. **`coercion.f`** — built-in rules, registered into the engine.
4. **`nominal_registry.f` + `function_registry.f` + `visibility.f`** — registries with lookup tests.
5. **`env.f` + `inference_results.f` + `reporter.f`** — small support modules.
6. **`checker_*.f`** — AST walker, one expression-family file at a time, gated by FLang feature coverage. Parity goal: every C# harness test that exercises typing passes against the new checker too.
7. **`specialization.f`** — eager monomorphisation, last because it requires the full checker working monomorphically first.
8. **`result.f`** — final assembly + zonk.

## Open questions

- **NodeId identity.** The C# version uses object identity for some maps and `(file_id, start, length)` fingerprints for others. The new design unifies on the fingerprint; need to confirm the parser's AST nodes expose a stable `span` for every node (they do, looking at `lib/flang_parser/src/ast.f`).
- **Iterator protocol checks.** The C# checker bakes the `iter()` / `next()` / `Option(E)` shape into expression inference for `for`-loops. Should this live in `checker_stmt.f` (`for` is a Stmt in the AST) or in a small `protocols.f` file? Lean towards `checker_stmt.f` — it's one site.
- **Source generators.** `TemplateExpander` runs between `collect_nominals` and `collect_signatures` in the C# version. For self-host parity, who owns that hook? Probably a separate library (`flang_macros`) — out of scope here, but the checker pipeline should accept "modules after source-gen expansion" as input, not raw parsed modules.
- **`op_deref` fallback chains.** In C#, member access stores an `OpDerefChain` on the AST node (mutating). The new design stores it in `resolved_targets` as `ResolvedTarget.Field` with an optional list of deref hops. Same information, side-table only. Need to spec the variant shape before writing `checker_expr.f`.
- **Cross-compilation interop.** Does the C# CLI / LSP need to consume `flang_typer`'s `TypeCheckResult`, or is `flang_typer` only invoked by a fully self-hosted compiler? If interop is needed, the result types must be serialisable; if not, in-memory ADTs are enough.
