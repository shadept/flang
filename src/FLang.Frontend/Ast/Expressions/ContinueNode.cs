using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Represents a continue expression (type: never).
/// Valid in statement position and match arm bodies, only inside loops.
/// </summary>
public class ContinueNode : ExpressionNode
{
    public ContinueNode(SourceSpan span) : base(span)
    {
    }
}
