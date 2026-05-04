using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Tuple destructuring pattern. Syntax: `(p1, p2, ..., pN)`.
/// Matches a tuple value of arity N where every sub-pattern matches its
/// corresponding tuple element. Tuples desugar to anonymous structs with
/// `__0`, `__1`, ... field names.
/// </summary>
public class TuplePatternNode : PatternNode
{
    public TuplePatternNode(SourceSpan span, List<PatternNode> elements) : base(span)
    {
        Elements = elements;
    }

    public List<PatternNode> Elements { get; }
}
