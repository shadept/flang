using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class FieldAccessExpressionNode : ExpressionNode
{
    public FieldAccessExpressionNode(SourceSpan span, ExpressionNode target, string fieldName) : base(span)
    {
        Target = target;
        FieldName = fieldName;
    }

    public ExpressionNode Target { get; }
    public string FieldName { get; }
}