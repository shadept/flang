using FLang.Core;

namespace FLang.Frontend.Ast;

public abstract class StatementNode(SourceSpan span) : AstNode(span)
{
}
