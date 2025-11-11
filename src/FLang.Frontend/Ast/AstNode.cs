using FLang.Core;

namespace FLang.Frontend.Ast;

public abstract class AstNode
{
    public SourceSpan Span { get; }

    protected AstNode(SourceSpan span)
    {
        Span = span;
    }
}
