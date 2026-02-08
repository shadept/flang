using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// A block expression: <c>{ stmt1; stmt2; trailing_expr }</c>.
/// <para>
/// <see cref="Statements"/> contains only the statement nodes (variable declarations,
/// returns, expression-statements, etc.). The optional <see cref="TrailingExpression"/>
/// is stored separately and is NOT part of <see cref="Statements"/>. It determines the
/// block's value — when null the block evaluates to void.
/// </para>
/// </summary>
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