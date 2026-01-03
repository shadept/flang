using FLang.Core;

namespace FLang.Frontend.Ast;

public abstract class AstNode(SourceSpan span)
{
    public SourceSpan Span { get; } = span;
}