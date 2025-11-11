using FLang.Core;

namespace FLang.Frontend.Ast;

public abstract class AstNode
{
    protected AstNode(SourceSpan span)
    {
        Span = span;
    }

    public SourceSpan Span { get; }
}