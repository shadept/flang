using FLang.Core;

namespace FLang.Frontend.Ast.Statements;

public class ExpressionStatementNode : StatementNode
{
    public ExpressionStatementNode(SourceSpan span, ExpressionNode expression) : base(span)
    {
        Expression = expression;
    }

    public ExpressionNode Expression { get; }
}