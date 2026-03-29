using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;
using FLang.Frontend.Ast.Types;
using Type = FLang.Core.Types.Type;

namespace FLang.Semantics;

/// <summary>
/// A function's polymorphic signature for overload resolution.
/// </summary>
public record FunctionScheme(
    string Name,
    PolymorphicType Signature,
    FunctionDeclarationNode Node,
    bool IsForeign,
    bool IsPublic,
    string? ModulePath);

/// <summary>
/// Tracks the current function being checked (for return type context).
/// </summary>
public record FunctionContext(FunctionDeclarationNode Node, Type ReturnType);

/// <summary>
/// Records a resolved operator function for an AST node.
/// Used by the lowering pass to emit CallInstructions instead of primitive ops.
/// </summary>
public record ResolvedOperator(
    FunctionDeclarationNode Function,
    bool NegateResult = false,
    BinaryOperatorKind? CmpDerivedOperator = null);

/// <summary>
/// Hindley-Milner type checker. Drives InferenceEngine over the AST.
/// Works exclusively with FLang.Core.Types.Type — no TypeBase references.
/// </summary>
public partial class HmTypeChecker : INominalTypeRegistry, ITemplateTypeProvider
{
    private readonly TypeRegistry _types = new();
    private readonly FunctionRegistry _fns = new();
    private readonly InferenceResults _results = new();
    private readonly InferenceContext _ctx;
    private readonly Compilation _compilation;
    private readonly List<Diagnostic> _diagnostics = [];

    /// <summary>Compile-time context for #if directive evaluation.</summary>
    public Dictionary<string, object> CompileTimeContext => _compilation.CompileTimeContext;

    /// <summary>
    /// Unsuffixed integer literals and their TypeVars, for post-inference validation.
    /// After inference, these are checked for: unresolved TypeVars (E2001),
    /// non-numeric resolved types (E2102), and out-of-range values (E2029).
    /// </summary>
    private readonly List<(IntegerLiteralNode Node, Type TypeVar)> _unsuffixedLiterals = [];

    /// <summary>
    /// Unsuffixed float literals and their TypeVars, for post-inference validation.
    /// </summary>
    private readonly List<(FloatingPointLiteralNode Node, Type TypeVar)> _unsuffixedFloatLiterals = [];

    /// <summary>
    /// Specializations deferred because concreteParams contained unresolved TypeVars.
    /// Resolved after all module bodies are checked, when TypeVars should be concrete.
    /// </summary>
    private readonly List<(FunctionScheme Scheme, Type[] ParamTypes, Type ReturnType, SourceSpan CallSpan, CallExpressionNode CallNode)> _pendingSpecializations = [];

    public HashSet<Type> InstantiatedTypes => _results.InstantiatedTypes;

    public HmTypeChecker(Compilation compilation)
    {
        _compilation = compilation;
        var engine = new InferenceEngine();
        engine.AddCoercionRule(new IntegerWideningCoercionRule(true));
        engine.AddCoercionRule(new FloatWideningCoercionRule());
        engine.AddCoercionRule(new OptionWrappingCoercionRule());
        engine.AddCoercionRule(new StringToByteSliceCoercionRule());
        engine.AddCoercionRule(new ArrayDecayCoercionRule());
        engine.AddCoercionRule(new SliceToReferenceCoercionRule());
        engine.AddCoercionRule(new AnonymousStructCoercionRule(name => _types.LookupNominalType(name, _ctx.CurrentModulePath)));
        _ctx = new InferenceContext(engine);
    }

    public IReadOnlyList<Diagnostic> Diagnostics =>
        [.. _diagnostics, .. _ctx.Engine.Diagnostics];
    public IReadOnlyDictionary<AstNode, Type> InferredTypes => _results.InferredTypes;
    public IReadOnlyDictionary<string, NominalType> NominalTypes => _types.NominalTypes;
    public IReadOnlyDictionary<string, SourceSpan> NominalSpans => _types.NominalSpans;
    public IReadOnlyDictionary<string, IReadOnlyList<(string Name, TypeNode TypeNode)>> FieldTypeNodes => _types.FieldTypeNodes;
    public IReadOnlyDictionary<string, List<FunctionScheme>> Functions => _fns.Functions;
    public IReadOnlyDictionary<AstNode, ResolvedOperator> ResolvedOperators => _results.ResolvedOperators;
    public InferenceEngine Engine => _ctx.Engine;

    public bool IsGenericFunction(FunctionDeclarationNode fn) => fn.IsGeneric;
    public IReadOnlyList<FunctionDeclarationNode> GetSpecializedFunctions() => _results.Specializations;

    /// <summary>
    /// Run all type-checking phases on a module.
    /// </summary>
    public void CheckModule(ModuleNode module, string modulePath)
    {
        CollectNominalTypes(module, modulePath);
        ResolveNominalTypes(module, modulePath);
        CollectFunctionSignatures(module, modulePath);
        CheckModuleBodies(module, modulePath);
    }

    // =========================================================================
    // Scope management (delegates to _ctx)
    // =========================================================================

    private void PushScope() => _ctx.PushScope();
    private void PopScope() => _ctx.PopScope();
    private void MarkConst(string name) => _ctx.MarkConst(name);
    private bool IsConst(string name) => _ctx.IsConst(name);

    // =========================================================================
    // Diagnostics
    // =========================================================================

    private void ReportError(string message, SourceSpan span, string code = "E2002")
    {
        _diagnostics.Add(Diagnostic.Error(message, span, null, code));
    }

    private void ReportError(string message, SourceSpan span, string code, string? hint)
    {
        _diagnostics.Add(Diagnostic.Error(message, span, hint, code));
    }

    private void ReportWarning(string message, SourceSpan span, string code = "W0001")
    {
        _diagnostics.Add(Diagnostic.Warning(message, span, code: code));
    }

    private void ReportWarning(string message, SourceSpan span, string code, string? hint)
    {
        _diagnostics.Add(Diagnostic.Warning(message, span, hint, code));
    }

    // =========================================================================
    // Type recording (delegates to _results)
    // =========================================================================

    private Type Record(AstNode node, Type type) => _results.Record(node, type);

    public Type GetInferredType(AstNode node) => _results.GetInferredType(node);

    public ResolvedOperator? GetResolvedOperator(AstNode node) => _results.GetResolvedOperator(node);

    // =========================================================================
    // Function registry (delegates to _fns)
    // =========================================================================

    private void RegisterFunction(FunctionScheme scheme)
        => _fns.Register(scheme, ReportError);

    private List<FunctionScheme>? LookupFunctions(string name)
        => _fns.Lookup(name, _ctx.CurrentModulePath);

    /// <summary>
    /// When overload resolution fails during generic body checking, guess the return type
    /// from the candidate functions. Heuristic:
    /// 1. If all candidates share the same return type structure, use that.
    /// 2. Otherwise use the first candidate's return type.
    /// The return type's generic params are specialized fresh so they don't pollute inference.
    /// </summary>
    private Type GuessReturnTypeFromCandidates(List<FunctionScheme> candidates)
    {
        if (candidates.Count == 0) return _ctx.Engine.FreshVar();
        return _ctx.Engine.Specialize(candidates[0].Signature) is Core.Types.FunctionType ft
            ? ft.ReturnType
            : _ctx.Engine.FreshVar();
    }

    // =========================================================================
    // Module path
    // =========================================================================

    public static string DeriveModulePath(string filePath, IReadOnlyList<string> includePaths, string workingDirectory)
    {
        var normalizedFile = Path.GetFullPath(filePath);

        foreach (var includePath in includePaths)
        {
            var normalizedInclude = Path.GetFullPath(includePath);

            if (normalizedFile.StartsWith(normalizedInclude, StringComparison.OrdinalIgnoreCase))
            {
                var relativePath = Path.GetRelativePath(normalizedInclude, normalizedFile);
                var withoutExtension = Path.ChangeExtension(relativePath, null);
                return withoutExtension.Replace(Path.DirectorySeparatorChar, '.');
            }
        }

        var normalizedWorking = Path.GetFullPath(workingDirectory);
        var relativeToWorking = Path.GetRelativePath(normalizedWorking, normalizedFile);
        var modulePathFromWorking = Path.ChangeExtension(relativeToWorking, null);
        return modulePathFromWorking.Replace(Path.DirectorySeparatorChar, '.');
    }

    // =========================================================================
    // Nominal type registry
    // =========================================================================

    /// <summary>
    /// Look up a nominal type by FQN or short name.
    /// </summary>
    public NominalType? LookupNominalType(string name)
        => _types.LookupNominalType(name, _ctx.CurrentModulePath);

    // =========================================================================
    // Directive validation
    // =========================================================================

    private static readonly HashSet<string> _knownDirectives = ["foreign", "inline", "deprecated", "simd"];

    /// <summary>
    /// Validate directives on a declaration. Reports unknown directives (W2003)
    /// and validates argument counts for known directives.
    /// </summary>
    private void ValidateDirectives(IReadOnlyList<DirectiveNode> directives)
    {
        foreach (var d in directives)
        {
            if (!_knownDirectives.Contains(d.Name))
            {
                ReportWarning($"unknown directive `#{d.Name}`", d.Span, "W2003");
                continue;
            }

            switch (d.Name)
            {
                case "foreign" when d.Arguments.Count > 0:
                    ReportError("`#foreign` takes no arguments", d.Span, "E1002");
                    break;
                case "inline" when d.Arguments.Count > 0:
                    ReportError("`#inline` takes no arguments", d.Span, "E1002");
                    break;
                case "deprecated" when d.Arguments.Count > 1:
                    ReportError("`#deprecated` takes at most one string argument", d.Span, "E1002");
                    break;
                case "deprecated" when d.Arguments.Count == 1 && d.Arguments[0].Kind != Frontend.TokenKind.StringLiteral:
                    ReportError("`#deprecated` argument must be a string literal", d.Span, "E1002");
                    break;
                case "simd" when d.Arguments.Count > 0:
                    ReportError("`#simd` takes no arguments", d.Span, "E1002");
                    break;
            }
        }
    }

    /// <summary>
    /// Check if a directive list contains #deprecated and extract its optional message.
    /// Returns true if the directive is present.
    /// </summary>
    private static bool GetDeprecatedMessage(IReadOnlyList<DirectiveNode> directives, out string? message)
    {
        foreach (var d in directives)
        {
            if (d.Name == "deprecated")
            {
                message = d.Arguments.Count > 0 ? d.Arguments[0].Text : null;
                return true;
            }
        }
        message = null;
        return false;
    }

    private static bool HasSimdDirective(IReadOnlyList<DirectiveNode> directives)
        => directives.Any(d => d.Name == "simd");

    /// <summary>
    /// Emit a deprecation warning if the resolved function has a #deprecated directive.
    /// </summary>
    private void CheckDeprecatedCall(FunctionDeclarationNode node, SourceSpan callSpan)
    {
        if (GetDeprecatedMessage(node.Directives, out var msg))
        {
            var warning = msg != null
                ? $"function `{node.Name}` is deprecated: {msg}"
                : $"function `{node.Name}` is deprecated";
            ReportWarning(warning, callSpan, "W2002");
        }
    }

    // =========================================================================
    // Post-inference validation
    // =========================================================================

    private static readonly HashSet<string> _integerTypeNames =
        ["i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "isize", "usize", "char"];

    private static readonly HashSet<string> _floatTypeNames = ["f32", "f64"];

    /// <summary>
    /// Validate unsuffixed integer literals after all inference is complete.
    /// Detects: unresolved TypeVars (E2001), non-numeric resolved types (E2102),
    /// and out-of-range values (E2029).
    /// </summary>
    public void ValidatePostInference()
    {
        foreach (var (node, typeVar) in _unsuffixedLiterals)
        {
            var resolved = _ctx.Engine.Resolve(typeVar);

            if (resolved is Core.Types.TypeVar)
            {
                // Char literals default to char when unconstrained
                if (node.Suffix == "char")
                {
                    _ctx.Engine.Unify(typeVar, WellKnown.Char, node.Span);
                    continue;
                }
                // Still unresolved after inference — no context to determine concrete type
                ReportError($"Cannot determine concrete type for integer literal `{node.Value}`", node.Span, "E2001");
                continue;
            }

            if (resolved is Core.Types.PrimitiveType prim)
            {
                if (_floatTypeNames.Contains(prim.Name))
                {
                    // Integer literal used as float (e.g., 1 assigned to f32 field) — valid
                    continue;
                }

                if (!_integerTypeNames.Contains(prim.Name))
                {
                    // Resolved to a non-integer type (e.g., bool) — conflicting binding
                    ReportError(
                        $"Integer literal `{node.Value}` cannot be used as `{prim.Name}`",
                        node.Span, "E2102");
                    continue;
                }

                // Check range
                if (!HmTypeChecker.FitsInType(node.Value, prim.Name))
                {
                    ReportError(
                        $"Literal `{node.Value}` out of range for type `{prim.Name}`",
                        node.Span, "E2029");
                }
            }
            // Non-primitive resolved types (e.g., NominalType) are allowed —
            // they might be valid through coercion rules
        }

        // Validate unsuffixed float literals
        foreach (var (node, typeVar) in _unsuffixedFloatLiterals)
        {
            var resolved = _ctx.Engine.Resolve(typeVar);

            if (resolved is Core.Types.TypeVar)
            {
                // Still unresolved after inference — no context to determine concrete type
                ReportError($"Cannot determine concrete type for float literal `{node.Value}`", node.Span, "E2001");
                continue;
            }

            if (resolved is Core.Types.PrimitiveType prim)
            {
                if (!_floatTypeNames.Contains(prim.Name))
                {
                    ReportError(
                        $"Float literal `{node.Value}` cannot be used as `{prim.Name}`",
                        node.Span, "E2102");
                    continue;
                }

                // Check f32 range
                if (prim.Name == "f32" && double.IsInfinity((float)node.Value) && !double.IsInfinity(node.Value))
                {
                    ReportError(
                        $"Literal `{node.Value}` out of range for type `f32`",
                        node.Span, "E2029");
                }
            }
        }
    }

    /// <summary>
    /// Produces a read-only snapshot of all type-checking results.
    /// Call once after ValidatePostInference() has returned.
    /// All inferred types are eagerly zonked (resolved through the union-find)
    /// so consumers never need the InferenceEngine.
    /// </summary>
    public TypeCheckResult BuildResult()
    {
        var zonked = new Dictionary<AstNode, Type>(_results.InferredTypes.Count);
        foreach (var (node, type) in _results.InferredTypes)
            zonked[node] = _ctx.Engine.Resolve(type);

        var zonkedInstantiated = new HashSet<Type>(
            _results.InstantiatedTypes.Select(t => _ctx.Engine.Resolve(t)));

        return new TypeCheckResult(
            nodeTypes: zonked,
            resolvedOperators: _results.ResolvedOperators,
            nominalTypes: _types.NominalTypes,
            nominalSpans: _types.NominalSpans,
            functions: _fns.Functions,
            specializedFunctions: _results.Specializations,
            instantiatedTypes: zonkedInstantiated,
            compileTimeContext: _compilation.CompileTimeContext,
            resolver: _ctx.Engine);
    }

    /// <summary>
    /// Resolve specializations that were deferred because concreteParams contained TypeVars.
    /// Call after all module bodies are checked but before ValidatePostInference.
    /// </summary>
    public void ResolvePendingSpecializations()
    {
        foreach (var (scheme, paramTypes, returnType, callSpan, callNode) in _pendingSpecializations)
        {
            var resolvedParams = paramTypes.Select(p => _ctx.Engine.Resolve(p)).ToArray();
            var resolvedReturn = _ctx.Engine.Resolve(returnType);

            // If any param is still a TypeVar, skip — ValidatePostInference will report E2001
            if (resolvedParams.Any(p => p is Core.Types.TypeVar) || resolvedReturn is Core.Types.TypeVar)
                continue;

            var specialized = EnsureSpecialization(scheme, resolvedParams, resolvedReturn, callSpan);
            if (specialized != null)
                callNode.ResolvedTarget = specialized;
        }
        _pendingSpecializations.Clear();
    }
}
