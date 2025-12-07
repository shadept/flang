using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class AnonymousStructExpressionNode : ExpressionNode
{
    public AnonymousStructExpressionNode(SourceSpan span, IReadOnlyList<(string FieldName, ExpressionNode Value)> fields) : base(span)
    {
        Fields = fields;
    }

    public IReadOnlyList<(string FieldName, ExpressionNode Value)> Fields { get; }
}
