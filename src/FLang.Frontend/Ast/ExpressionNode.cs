using FLang.Core;
namespace FLang.Frontend.Ast;

public abstract class ExpressionNode : AstNode
{
    protected ExpressionNode(SourceSpan span) : base(span)
    {
    }
}
