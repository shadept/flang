using FLang.Core;

namespace FLang.Frontend.Ast.Statements;

public class BreakStatementNode : StatementNode
{
    public BreakStatementNode(SourceSpan span) : base(span)
    {
    }
}