using FLang.Core;
using FLang.Frontend.Ast.Declarations;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Represents a null-coalescing expression (a ?? b).
/// Evaluates to `a` if `a` has a value, otherwise evaluates to `b`.
/// </summary>
public class CoalesceExpressionNode : ExpressionNode
{
    public CoalesceExpressionNode(SourceSpan span, ExpressionNode left, ExpressionNode right) : base(span)
    {
        Left = left;
        Right = right;
    }

    public ExpressionNode Left { get; }
    public ExpressionNode Right { get; }

    /// <summary>
    /// Semantic: The resolved op_coalesce function declaration.
    /// For generic functions, this points to the specialized FunctionDeclarationNode with concrete types.
    /// </summary>
    public FunctionDeclarationNode? ResolvedCoalesceFunction { get; set; }
}
