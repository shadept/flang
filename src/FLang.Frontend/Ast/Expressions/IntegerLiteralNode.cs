using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class IntegerLiteralNode : ExpressionNode
{
    public IntegerLiteralNode(SourceSpan span, long value, string? suffix = null) : base(span)
    {
        Value = value;
        Suffix = suffix;
    }

    public long Value { get; }
    public string? Suffix { get; }
}
