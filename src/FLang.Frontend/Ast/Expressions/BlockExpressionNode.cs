using System.Collections.Generic;
using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class BlockExpressionNode : ExpressionNode
{
    public List<StatementNode> Statements { get; }
    public ExpressionNode? TrailingExpression { get; }

    public BlockExpressionNode(SourceSpan span, List<StatementNode> statements, ExpressionNode? trailingExpression) : base(span)
    {
        Statements = statements;
        TrailingExpression = trailingExpression;
    }
}
