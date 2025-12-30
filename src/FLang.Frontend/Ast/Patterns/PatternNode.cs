using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Base class for all pattern nodes used in match expressions.
/// </summary>
public abstract class PatternNode : AstNode
{
    protected PatternNode(SourceSpan span) : base(span)
    {
    }
}

