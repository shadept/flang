using FLang.Core;

namespace FLang.Frontend.Ast;

public abstract class ExpressionNode(SourceSpan span) : AstNode(span)
{
    /// <summary>
    /// The semantic type of this expression, assigned during type checking.
    /// Null before type checking completes.
    /// </summary>
    public TypeBase? Type { get; set; }
}