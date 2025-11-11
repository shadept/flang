using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class IntegerLiteralNode : ExpressionNode
{
    public IntegerLiteralNode(SourceSpan span, long value) : base(span)
    {
        Value = value;
    }

    public long Value { get; }
}