using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class AssignmentExpressionNode : ExpressionNode
{
    public AssignmentExpressionNode(SourceSpan span, ExpressionNode target, ExpressionNode value) : base(span)
    {
        Target = target;
        Value = value;
    }

    public ExpressionNode Target { get; }
    public ExpressionNode Value { get; set; }
}