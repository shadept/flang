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
    private readonly InferenceEngine _engine;
    private readonly TypeScopes _scopes;
    private readonly Compilation _compilation;
    private readonly List<Diagnostic> _diagnostics = [];

    /// <summary>
    /// FQN -> NominalType template for all structs and enums.
    /// </summary>
    private readonly Dictionary<string, NominalType> _nominalTypes = [];

    /// <summary>
    /// FQN -> SourceSpan of the first declaration, for duplicate-detection notes.
    /// </summary>
    private readonly Dictionary<string, SourceSpan> _nominalSpans = [];

    /// <summary>
    /// FQN -> list of (field name, AST TypeNode) for struct fields.
    /// Used by source generator template expansion to access field type info.
    /// </summary>
    private readonly Dictionary<string, IReadOnlyList<(string Name, TypeNode TypeNode)>> _fieldTypeNodes = [];

    /// <summary>
    /// Function name -> list of overloads.
    /// </summary>
    private readonly Dictionary<string, List<FunctionScheme>> _functions = [];

    /// <summary>
    /// Monomorphized generic function bodies.
    /// </summary>
    private readonly List<FunctionDeclarationNode> _specializations = [];
    private readonly Dictionary<string, FunctionDeclarationNode> _emittedSpecs = [];

    /// <summary>
    /// Inferred type per AST node. Populated during inference, read during Zonk/stamping.
    /// </summary>
    private readonly Dictionary<AstNode, Type> _inferredTypes = [];

    /// <summary>
    /// Resolved operator functions per AST node (binary, unary, index, coalesce).
    /// Populated during type checking, read during lowering to emit CallInstructions.
    /// </summary>
    private readonly Dictionary<AstNode, ResolvedOperator> _resolvedOperators = [];


    /// <summary>
    /// Stack of functions currently being checked (for return type context).
    /// </summary>
    private readonly Stack<FunctionContext> _functionStack = new();

    /// <summary>
    /// Module currently being checked.
    /// </summary>
    private string? _currentModulePath;

    /// <summary>
    /// True during CheckGenericFunctionBody — enables fallback return type guessing
    /// when overload resolution fails (since placeholder types can't match).
    /// </summary>
    private bool _isCheckingGenericBody;

    /// <summary>
    /// Lambda synthesis counter.
    /// </summary>
    private int _nextLambdaId;

    /// <summary>
    /// Scope barrier for non-capturing lambda enforcement.
    /// Variables from scopes at or below this index are inaccessible.
    /// </summary>
    private int _lambdaScopeBarrier;

    /// <summary>
    /// Parallel scope stack for tracking const-ness of variable declarations.
    /// Each scope maps name -> isConst. Mirrors _scopes push/pop via PushScope/PopScope helpers.
    /// </summary>
    private readonly Stack<HashSet<string>> _constScopes = new(new[] { new HashSet<string>() });

    /// <summary>
    /// Active generic type parameter names (during specialization), for type-as-value wrapping.
    /// Uses ref-counting to handle nested specializations with the same param name.
    /// </summary>
    private readonly Dictionary<string, int> _activeTypeParams = [];

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

    /// <summary>
    /// Set by ResolveOverload/ResolveOverloadWithDefaults when specialization is deferred.
    /// Consumed by InferCall to register the pending specialization with the call node.
    /// </summary>
    private (FunctionScheme Scheme, Type[] Params, Type Return)? _deferredSpecInfo;

    /// <summary>
    /// Deprecated type FQNs → optional message. Populated during CollectNominalTypes.
    /// </summary>
    private readonly Dictionary<string, string?> _deprecatedTypes = [];

    /// <summary>
    /// Deprecated function names → optional message. Populated during CollectFunctionSignatures.
    /// </summary>
    private readonly Dictionary<string, string?> _deprecatedFunctions = [];

    /// <summary>
    /// Tracks variable declarations in the current function for unused variable warnings.
    /// Maps variable name to its declaration span. Null when not inside a function body.
    /// </summary>
    private Dictionary<string, SourceSpan>? _currentFnDeclaredVars;

    /// <summary>
    /// Tracks variable usages in the current function for unused variable warnings.
    /// </summary>
    private HashSet<string>? _currentFnUsedVars;

    /// <summary>
    /// Types used as Type(T) values (e.g., i32 in size_of(i32)).
    /// Populated during type checking, consumed by lowering to build type table.
    /// </summary>
    public HashSet<Type> InstantiatedTypes { get; } = new();

    public HmTypeChecker(Compilation compilation)
    {
        _compilation = compilation;
        _engine = new InferenceEngine();
        _engine.AddCoercionRule(new IntegerWideningCoercionRule(true));
        _engine.AddCoercionRule(new FloatWideningCoercionRule());
        _engine.AddCoercionRule(new OptionWrappingCoercionRule());
        _engine.AddCoercionRule(new StringToByteSliceCoercionRule());
        _engine.AddCoercionRule(new ArrayDecayCoercionRule());
        _engine.AddCoercionRule(new SliceToReferenceCoercionRule());
        _engine.AddCoercionRule(new AnonymousStructCoercionRule(LookupNominalType));
        _scopes = new TypeScopes();
    }

    public IReadOnlyList<Diagnostic> Diagnostics =>
        [.. _diagnostics, .. _engine.Diagnostics];
    public IReadOnlyDictionary<AstNode, Type> InferredTypes => _inferredTypes;
    public IReadOnlyDictionary<string, NominalType> NominalTypes => _nominalTypes;
    public IReadOnlyDictionary<string, SourceSpan> NominalSpans => _nominalSpans;
    public IReadOnlyDictionary<string, IReadOnlyList<(string Name, TypeNode TypeNode)>> FieldTypeNodes => _fieldTypeNodes;
    public IReadOnlyDictionary<string, List<FunctionScheme>> Functions => _functions;
    public IReadOnlyDictionary<AstNode, ResolvedOperator> ResolvedOperators => _resolvedOperators;
    public InferenceEngine Engine => _engine;

    public bool IsGenericFunction(FunctionDeclarationNode fn) => fn.IsGeneric;
    public IReadOnlyList<FunctionDeclarationNode> GetSpecializedFunctions() => _specializations;

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
    // Scope management (wraps _scopes with parallel const tracking)
    // =========================================================================

    private void PushScope()
    {
        _scopes.PushScope();
        _constScopes.Push(new HashSet<string>());
    }

    private void PopScope()
    {
        _scopes.PopScope();
        _constScopes.Pop();
    }

    private void MarkConst(string name)
    {
        _constScopes.Peek().Add(name);
    }

    private bool IsConst(string name)
    {
        foreach (var scope in _constScopes)
        {
            if (scope.Contains(name))
                return true;
        }
        return false;
    }

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
    // Type recording
    // =========================================================================

    /// <summary>
    /// Record the inferred type for an AST node.
    /// </summary>
    private Type Record(AstNode node, Type type)
    {
        _inferredTypes[node] = type;
        return type;
    }


    /// <summary>
    /// Get the previously inferred type for an AST node.
    /// Throws if the type was not recorded — a missing type indicates a bug in the type checker.
    /// </summary>
    public Type GetInferredType(AstNode node)
    {
        if (_inferredTypes.TryGetValue(node, out var type))
            return type;
        throw new InternalCompilerError(
            $"No inferred type recorded for {node.GetType().Name}", node.Span);
    }

    /// <summary>
    /// Get the resolved operator function for an AST node, or null if none.
    /// </summary>
    public ResolvedOperator? GetResolvedOperator(AstNode node)
        => _resolvedOperators.TryGetValue(node, out var op) ? op : null;

    // =========================================================================
    // Function registry
    // =========================================================================

    private void RegisterFunction(FunctionScheme scheme)
    {
        if (!_functions.TryGetValue(scheme.Name, out var overloads))
        {
            overloads = [];
            _functions[scheme.Name] = overloads;
        }

        // Check for duplicate overloads (same name + same parameter types)
        // Allow duplicate foreign declarations (extern decls across modules)
        foreach (var existing in overloads)
        {
            if (existing.IsForeign && scheme.IsForeign) continue;
            if (HasSameParameterSignature(existing.Node, scheme.Node))
            {
                ReportError(
                    $"duplicate definition of function `{scheme.Name}` with the same parameter types",
                    scheme.Node.NameSpan, "E2103");
                break;
            }
        }

        overloads.Add(scheme);
    }

    /// <summary>
    /// Checks whether two function declarations have the same parameter signature
    /// by comparing their AST type nodes structurally.
    /// </summary>
    private static bool HasSameParameterSignature(FunctionDeclarationNode a, FunctionDeclarationNode b)
    {
        if (a.Parameters.Count != b.Parameters.Count) return false;
        for (var i = 0; i < a.Parameters.Count; i++)
        {
            if (!TypeNodeEquals(a.Parameters[i].Type, b.Parameters[i].Type))
                return false;
        }
        return true;
    }

    /// <summary>
    /// Structural equality of two AST type nodes.
    /// </summary>
    private static bool TypeNodeEquals(TypeNode a, TypeNode b)
    {
        return (a, b) switch
        {
            (NamedTypeNode na, NamedTypeNode nb) => na.Name == nb.Name,
            (ReferenceTypeNode ra, ReferenceTypeNode rb) => TypeNodeEquals(ra.InnerType, rb.InnerType),
            (NullableTypeNode na, NullableTypeNode nb) => TypeNodeEquals(na.InnerType, nb.InnerType),
            (GenericTypeNode ga, GenericTypeNode gb) =>
                ga.Name == gb.Name
                && ga.TypeArguments.Count == gb.TypeArguments.Count
                && ga.TypeArguments.Zip(gb.TypeArguments).All(p => TypeNodeEquals(p.First, p.Second)),
            (ArrayTypeNode aa, ArrayTypeNode ab) =>
                aa.Length == ab.Length && TypeNodeEquals(aa.ElementType, ab.ElementType),
            (SliceTypeNode sa, SliceTypeNode sb) => TypeNodeEquals(sa.ElementType, sb.ElementType),
            (GenericParameterTypeNode ga, GenericParameterTypeNode gb) => ga.Name == gb.Name,
            (FunctionTypeNode fa, FunctionTypeNode fb) =>
                fa.ParameterTypes.Count == fb.ParameterTypes.Count
                && fa.ParameterTypes.Zip(fb.ParameterTypes).All(p => TypeNodeEquals(p.First, p.Second))
                && TypeNodeEquals(fa.ReturnType, fb.ReturnType),
            (AnonymousStructTypeNode sa, AnonymousStructTypeNode sb) =>
                sa.Fields.Count == sb.Fields.Count
                && sa.Fields.Zip(sb.Fields).All(p => p.First.FieldName == p.Second.FieldName && TypeNodeEquals(p.First.FieldType, p.Second.FieldType)),
            (AnonymousEnumTypeNode ea, AnonymousEnumTypeNode eb) =>
                ea.Variants.Count == eb.Variants.Count
                && ea.Variants.Zip(eb.Variants).All(p =>
                    p.First.Name == p.Second.Name
                    && p.First.PayloadTypes.Count == p.Second.PayloadTypes.Count
                    && p.First.PayloadTypes.Zip(p.Second.PayloadTypes).All(q => TypeNodeEquals(q.First, q.Second))),
            _ => false
        };
    }

    private List<FunctionScheme>? LookupFunctions(string name)
    {
        if (!_functions.TryGetValue(name, out var overloads)) return null;

        // Filter out non-public functions from other modules
        if (_currentModulePath != null)
        {
            var visible = overloads.Where(f => f.IsPublic || f.ModulePath == _currentModulePath).ToList();
            return visible.Count > 0 ? visible : null;
        }

        return overloads;
    }

    /// <summary>
    /// When overload resolution fails during generic body checking, guess the return type
    /// from the candidate functions. Heuristic:
    /// 1. If all candidates share the same return type structure, use that.
    /// 2. Otherwise use the first candidate's return type.
    /// The return type's generic params are specialized fresh so they don't pollute inference.
    /// </summary>
    private Type GuessReturnTypeFromCandidates(List<FunctionScheme> candidates)
    {
        if (candidates.Count == 0) return _engine.FreshVar();
        return _engine.Specialize(candidates[0].Signature) is Core.Types.FunctionType ft
            ? ft.ReturnType
            : _engine.FreshVar();
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
    {
        if (_nominalTypes.TryGetValue(name, out var type))
            return type;

        // Try with current module prefix
        if (_currentModulePath != null)
        {
            var fqn = $"{_currentModulePath}.{name}";
            if (_nominalTypes.TryGetValue(fqn, out type))
                return type;
        }

        // Try all registered types for short name match
        foreach (var (fqn, nominal) in _nominalTypes)
        {
            var shortName = fqn.Contains('.') ? fqn[(fqn.LastIndexOf('.') + 1)..] : fqn;
            if (shortName == name)
                return nominal;
        }

        return null;
    }

    // =========================================================================
    // Directive validation
    // =========================================================================

    private static readonly HashSet<string> _knownDirectives = ["foreign", "inline", "deprecated"];

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
            var resolved = _engine.Resolve(typeVar);

            if (resolved is FLang.Core.Types.TypeVar)
            {
                // Still unresolved after inference — no context to determine concrete type
                ReportError($"Cannot determine concrete type for integer literal `{node.Value}`", node.Span, "E2001");
                continue;
            }

            if (resolved is FLang.Core.Types.PrimitiveType prim)
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
            var resolved = _engine.Resolve(typeVar);

            if (resolved is FLang.Core.Types.TypeVar)
            {
                // Still unresolved after inference — no context to determine concrete type
                ReportError($"Cannot determine concrete type for float literal `{node.Value}`", node.Span, "E2001");
                continue;
            }

            if (resolved is FLang.Core.Types.PrimitiveType prim)
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
    /// Resolve specializations that were deferred because concreteParams contained TypeVars.
    /// Call after all module bodies are checked but before ValidatePostInference.
    /// </summary>
    public void ResolvePendingSpecializations()
    {
        foreach (var (scheme, paramTypes, returnType, callSpan, callNode) in _pendingSpecializations)
        {
            var resolvedParams = paramTypes.Select(p => _engine.Resolve(p)).ToArray();
            var resolvedReturn = _engine.Resolve(returnType);

            // If any param is still a TypeVar, skip — ValidatePostInference will report E2001
            if (resolvedParams.Any(p => p is FLang.Core.Types.TypeVar) || resolvedReturn is FLang.Core.Types.TypeVar)
                continue;

            var specialized = EnsureSpecialization(scheme, resolvedParams, resolvedReturn, callSpan);
            if (specialized != null)
                callNode.ResolvedTarget = specialized;
        }
        _pendingSpecializations.Clear();
    }
}
