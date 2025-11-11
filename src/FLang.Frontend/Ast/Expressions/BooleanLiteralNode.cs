using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class BooleanLiteralNode : ExpressionNode
{
    public BooleanLiteralNode(SourceSpan span, bool value) : base(span)
    {
        Value = value;
    }

    public bool Value { get; }
}