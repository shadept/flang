using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class NullLiteralNode : ExpressionNode
{
    public NullLiteralNode(SourceSpan span) : base(span)
    {
    }
}
