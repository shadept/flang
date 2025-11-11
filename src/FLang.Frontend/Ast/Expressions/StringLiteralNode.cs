using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class StringLiteralNode : ExpressionNode
{
    public StringLiteralNode(SourceSpan span, string value) : base(span)
    {
        Value = value;
    }

    public string Value { get; }
}