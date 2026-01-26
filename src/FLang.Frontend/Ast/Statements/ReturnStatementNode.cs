using FLang.Core;

namespace FLang.Frontend.Ast.Statements;

public class ReturnStatementNode : StatementNode
{
    public ReturnStatementNode(SourceSpan span, ExpressionNode? expression) : base(span)
    {
        Expression = expression;
    }

    /// <summary>
    /// The expression to return, or null for bare `return` in void functions.
    /// </summary>
    public ExpressionNode? Expression { get; set; }
}
