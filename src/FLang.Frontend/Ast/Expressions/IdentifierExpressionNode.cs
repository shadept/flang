using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class IdentifierExpressionNode : ExpressionNode
{
    public string Name { get; }

    public IdentifierExpressionNode(SourceSpan span, string name) : base(span)
    {
        Name = name;
    }
}
