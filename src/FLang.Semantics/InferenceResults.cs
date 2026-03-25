using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using Type = FLang.Core.Types.Type;

namespace FLang.Semantics;

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

    /// <summary>
    /// Get the previously inferred type for an AST node.
    /// Throws if the type was not recorded — a missing type indicates a bug in the type checker.
    /// </summary>
    public Type GetInferredType(AstNode node)
    {
        if (InferredTypes.TryGetValue(node, out var type))
            return type;
        throw new InternalCompilerError(
            $"No inferred type recorded for {node.GetType().Name}", node.Span);
    }

    /// <summary>
    /// Get the resolved operator function for an AST node, or null if none.
    /// </summary>
    public ResolvedOperator? GetResolvedOperator(AstNode node)
        => ResolvedOperators.TryGetValue(node, out var op) ? op : null;
}
