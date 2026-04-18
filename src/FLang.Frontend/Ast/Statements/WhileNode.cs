using FLang.Core;
using FLang.Frontend.Ast.Expressions;

namespace FLang.Frontend.Ast.Statements;

/// <summary>
/// Represents a while loop statement: while cond { body }
/// Exits when cond evaluates to false, or via break/return.
/// </summary>
public class WhileNode : StatementNode
{
    public WhileNode(SourceSpan span, ExpressionNode condition, ExpressionNode body) : base(span)
    {
        Condition = condition;
        Body = body;
    }

    public ExpressionNode Condition { get; }
    public ExpressionNode Body { get; }
}
