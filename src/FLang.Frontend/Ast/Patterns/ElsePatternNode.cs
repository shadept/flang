using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Represents an 'else' pattern in match expressions (catch-all).
/// </summary>
public class ElsePatternNode : PatternNode
{
    public ElsePatternNode(SourceSpan span) : base(span)
    {
    }
}

