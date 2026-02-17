using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class FloatingPointLiteralNode : ExpressionNode
{
    public FloatingPointLiteralNode(SourceSpan span, double value, string? suffix = null) : base(span)
    {
        Value = value;
        Suffix = suffix;
    }

    public double Value { get; }
    public string? Suffix { get; }
}
