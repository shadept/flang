using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class AssignmentExpressionNode : ExpressionNode
{
    public string TargetName { get; }
    public ExpressionNode Value { get; }

    public AssignmentExpressionNode(SourceSpan span, string targetName, ExpressionNode value) : base(span)
    {
        TargetName = targetName;
        Value = value;
    }
}
