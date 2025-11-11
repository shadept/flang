using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class FieldAccessExpressionNode : ExpressionNode
{
    public ExpressionNode Target { get; }
    public string FieldName { get; }

    public FieldAccessExpressionNode(SourceSpan span, ExpressionNode target, string fieldName) : base(span)
    {
        Target = target;
        FieldName = fieldName;
    }
}
