using FLang.Core;

namespace FLang.Frontend.Ast.Statements;

public class ReturnStatementNode : StatementNode
{
    public ReturnStatementNode(SourceSpan span, ExpressionNode expression) : base(span)
    {
        Expression = expression;
    }

    public ExpressionNode Expression { get; set; }
}