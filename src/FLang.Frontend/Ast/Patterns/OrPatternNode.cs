using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Or-pattern: matches if any alternative matches. Syntax: A | B | C.
/// All alternatives must bind the same variable names with the same types.
/// </summary>
public class OrPatternNode : PatternNode
{
    public OrPatternNode(SourceSpan span, List<PatternNode> alternatives) : base(span)
    {
        Alternatives = alternatives;
    }

    public List<PatternNode> Alternatives { get; }
}
