using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class IntegerLiteralNode : ExpressionNode
{
    public long Value { get; }

    public IntegerLiteralNode(SourceSpan span, long value) : base(span)
    {
        Value = value;
    }
}
