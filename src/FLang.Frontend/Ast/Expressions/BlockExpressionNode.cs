using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class BlockExpressionNode : ExpressionNode
{
    public BlockExpressionNode(SourceSpan span, List<StatementNode> statements, ExpressionNode? trailingExpression) :
        base(span)
    {
        Statements = statements;
        TrailingExpression = trailingExpression;
    }

    public List<StatementNode> Statements { get; }
    public ExpressionNode? TrailingExpression { get; }
}