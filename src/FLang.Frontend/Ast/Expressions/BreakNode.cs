using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Represents a break expression (type: never).
/// Valid in statement position and match arm bodies, only inside loops.
/// </summary>
public class BreakNode : ExpressionNode
{
    public BreakNode(SourceSpan span) : base(span)
    {
    }
}
