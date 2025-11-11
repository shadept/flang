using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class IdentifierExpressionNode : ExpressionNode
{
    public IdentifierExpressionNode(SourceSpan span, string name) : base(span)
    {
        Name = name;
    }

    public string Name { get; }
}