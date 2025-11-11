using FLang.Core;

namespace FLang.Frontend.Ast;

public abstract class StatementNode : AstNode
{
    protected StatementNode(SourceSpan span) : base(span)
    {
    }
}