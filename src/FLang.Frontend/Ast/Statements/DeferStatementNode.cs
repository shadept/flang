using FLang.Core;
using FLang.Frontend.Ast.Expressions;

namespace FLang.Frontend.Ast.Statements;

public class DeferStatementNode : StatementNode
{
    public DeferStatementNode(SourceSpan span, ExpressionNode expression) : base(span)
    {
        Expression = expression;
    }

    public ExpressionNode Expression { get; }
}
