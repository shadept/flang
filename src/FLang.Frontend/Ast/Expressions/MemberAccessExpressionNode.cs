using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class MemberAccessExpressionNode : ExpressionNode
{
    public MemberAccessExpressionNode(SourceSpan span, ExpressionNode target, string fieldName) : base(span)
    {
        Target = target;
        FieldName = fieldName;
    }

    public ExpressionNode Target { get; }
    public string FieldName { get; }
}