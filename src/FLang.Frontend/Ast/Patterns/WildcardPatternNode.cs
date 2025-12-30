using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Represents a wildcard pattern (_) that matches anything and discards the value.
/// </summary>
public class WildcardPatternNode : PatternNode
{
    public WildcardPatternNode(SourceSpan span) : base(span)
    {
    }
}

