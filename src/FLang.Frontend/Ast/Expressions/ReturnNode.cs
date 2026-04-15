using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Represents a return expression (type: never).
/// Valid in statement position and match arm bodies.
/// </summary>
public class ReturnNode : ExpressionNode
{
    public ReturnNode(SourceSpan span, ExpressionNode? expression) : base(span)
    {
        Expression = expression;
    }

    /// <summary>
    /// The expression to return, or null for bare <c>return</c> in void functions.
    /// </summary>
    public ExpressionNode? Expression { get; set; }
}
