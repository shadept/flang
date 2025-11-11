using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class IfExpressionNode : ExpressionNode
{
    public ExpressionNode Condition { get; }
    public ExpressionNode ThenBranch { get; }
    public ExpressionNode? ElseBranch { get; }

    public IfExpressionNode(SourceSpan span, ExpressionNode condition, ExpressionNode thenBranch, ExpressionNode? elseBranch) : base(span)
    {
        Condition = condition;
        ThenBranch = thenBranch;
        ElseBranch = elseBranch;
    }
}
