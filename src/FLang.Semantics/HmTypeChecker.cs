using FLang.Core;
using FLang.Core.Types;
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
public partial class HmTypeChecker : INominalTypeRegistry
{
    private readonly InferenceEngine _engine;
    private readonly TypeScopes _scopes;
    private readonly Compilation _compilation;
    private readonly List<Diagnostic> _diagnostics = [];

    /// <summary>
    /// FQN → NominalType template for all structs and enums.
    /// </summary>
    private readonly Dictionary<string, NominalType> _nominalTypes = [];

    /// <summary>
    /// FQN → SourceSpan of the first declaration, for duplicate-detection notes.
    /// </summary>
    private readonly Dictionary<string, SourceSpan> _nominalSpans = [];

    /// <summary>
    /// Function name → list of overloads.
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
    /// Lambda synthesis counter.
    /// </summary>
    private int _nextLambdaId;

    /// <summary>
    /// Scope barrier for non-capturing lambda enforcement.
    /// Variables from scopes at or below this index are inaccessible.
    /// </summary>
    private int _lambdaScopeBarrier;

    public HmTypeChecker(Compilation compilation)
    {
        _compilation = compilation;
        _engine = new InferenceEngine();
        _engine.AddCoercionRule(new IntegerWideningCoercionRule(true));
        _engine.AddCoercionRule(new OptionWrappingCoercionRule());
        _engine.AddCoercionRule(new StringToByteSliceCoercionRule());
        _engine.AddCoercionRule(new ArrayDecayCoercionRule());
        _engine.AddCoercionRule(new SliceToReferenceCoercionRule());
        _scopes = new TypeScopes();
    }

    public IReadOnlyList<Diagnostic> Diagnostics =>
        [.. _diagnostics, .. _engine.Diagnostics];
    public IReadOnlyDictionary<AstNode, Type> InferredTypes => _inferredTypes;
    public IReadOnlyDictionary<string, NominalType> NominalTypes => _nominalTypes;
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
    // Diagnostics
    // =========================================================================

    private void ReportError(string message, SourceSpan span, string code = "E2002")
    {
        _diagnostics.Add(Diagnostic.Error(message, span, null, code));
    }

    private void ReportWarning(string message, SourceSpan span, string code = "W0001")
    {
        _diagnostics.Add(Diagnostic.Warning(message, span, code));
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
        throw new InvalidOperationException(
            $"BUG: No inferred type recorded for {node.GetType().Name} at {node.Span}");
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
        overloads.Add(scheme);
    }

    private List<FunctionScheme>? LookupFunctions(string name)
    {
        return _functions.TryGetValue(name, out var overloads) ? overloads : null;
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
}
