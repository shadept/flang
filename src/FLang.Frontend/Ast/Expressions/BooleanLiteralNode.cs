using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class BooleanLiteralNode : ExpressionNode
{
    public bool Value { get; }

    public BooleanLiteralNode(SourceSpan span, bool value) : base(span)
    {
        Value = value;
    }
}
