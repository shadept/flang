using FLang.Core;

namespace FLang.Frontend.Ast.Statements;

public class ReturnStatementNode : StatementNode
{
    public ExpressionNode Expression { get; }

    public ReturnStatementNode(SourceSpan span, ExpressionNode expression) : base(span)
    {
        Expression = expression;
    }
}
