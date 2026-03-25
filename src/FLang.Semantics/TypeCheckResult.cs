using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using Type = FLang.Core.Types.Type;

namespace FLang.Semantics;

/// <summary>
/// Immutable snapshot of type-checker outputs, consumed by HmAstLowering and LSP handlers.
/// All types in NodeTypes are eagerly zonked (resolved through the union-find) at construction
/// time by HmTypeChecker.BuildResult(). The InferenceEngine is not retained.
/// Implements ITypeResolver so it can be passed to TypeLayoutService directly.
/// </summary>
public sealed class TypeCheckResult : ITypeResolver
{
    private readonly ITypeResolver _resolver;

    /// <summary>
    /// Pre-zonked inferred type for every AST node. TypeVars should not appear as values.
    /// </summary>
    public IReadOnlyDictionary<AstNode, Type> NodeTypes { get; }

    /// <summary>
    /// Resolved operator/function binding per operator AST node.
    /// Null entry means the operation is a primitive (no overload).
    /// </summary>
    public IReadOnlyDictionary<AstNode, ResolvedOperator> ResolvedOperators { get; }

    /// <summary>
    /// FQN -> NominalType for all structs and enums.
    /// </summary>
    public IReadOnlyDictionary<string, NominalType> NominalTypes { get; }

    /// <summary>
    /// FQN -> SourceSpan of each nominal type declaration.
    /// </summary>
    public IReadOnlyDictionary<string, SourceSpan> NominalSpans { get; }

    /// <summary>
    /// Function name -> overload set. Used by LSP signature help.
    /// </summary>
    public IReadOnlyDictionary<string, List<FunctionScheme>> Functions { get; }

    /// <summary>
    /// Monomorphized generic function bodies ready for lowering.
    /// </summary>
    public IReadOnlyList<FunctionDeclarationNode> SpecializedFunctions { get; }

    /// <summary>
    /// Types used as Type(T) values (RTTI). Pre-zonked.
    /// </summary>
    public IReadOnlySet<Type> InstantiatedTypes { get; }

    /// <summary>
    /// Compile-time context for #if directive evaluation.
    /// </summary>
    public Dictionary<string, object> CompileTimeContext { get; }

    internal TypeCheckResult(
        IReadOnlyDictionary<AstNode, Type> nodeTypes,
        IReadOnlyDictionary<AstNode, ResolvedOperator> resolvedOperators,
        IReadOnlyDictionary<string, NominalType> nominalTypes,
        IReadOnlyDictionary<string, SourceSpan> nominalSpans,
        IReadOnlyDictionary<string, List<FunctionScheme>> functions,
        IReadOnlyList<FunctionDeclarationNode> specializedFunctions,
        IReadOnlySet<Type> instantiatedTypes,
        Dictionary<string, object> compileTimeContext,
        ITypeResolver resolver)
    {
        NodeTypes = nodeTypes;
        ResolvedOperators = resolvedOperators;
        NominalTypes = nominalTypes;
        NominalSpans = nominalSpans;
        Functions = functions;
        SpecializedFunctions = specializedFunctions;
        InstantiatedTypes = instantiatedTypes;
        CompileTimeContext = compileTimeContext;
        _resolver = resolver;
    }

    /// <summary>
    /// Returns the fully-resolved type for an AST node.
    /// Since NodeTypes is pre-zonked, this is a plain dictionary lookup.
    /// </summary>
    public Type GetResolvedType(AstNode node)
    {
        if (NodeTypes.TryGetValue(node, out var type))
            return type;
        throw new InternalCompilerError(
            $"No inferred type recorded for {node.GetType().Name}", node.Span);
    }

    /// <summary>
    /// Transitional: resolves a type through the captured engine reference.
    /// Exists for call sites that hold raw types not yet in NodeTypes.
    /// Goal: once the checker resolves everything properly, these calls become
    /// identity functions and can be grepped + deleted.
    /// </summary>
    public Type Resolve(Type type) => _resolver.Resolve(type);

    /// <inheritdoc />
    public Type Zonk(Type type) => _resolver.Zonk(type);

    /// <summary>
    /// Returns the resolved operator binding for an AST node, or null
    /// when the operation maps to a primitive IR instruction.
    /// </summary>
    public ResolvedOperator? GetResolvedOperator(AstNode node)
        => ResolvedOperators.TryGetValue(node, out var op) ? op : null;

    /// <summary>
    /// Look up a nominal type by FQN. Returns null when not found.
    /// </summary>
    public NominalType? LookupNominal(string fqn)
        => NominalTypes.TryGetValue(fqn, out var n) ? n : null;
}
