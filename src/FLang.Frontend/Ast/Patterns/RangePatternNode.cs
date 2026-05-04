using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Range pattern (RFC-010). Forms:
/// <list type="bullet">
///   <item><c>a..b</c> — half-open: matches <c>a &lt;= x &lt; b</c></item>
///   <item><c>a..=b</c> — fully closed: matches <c>a &lt;= x &lt;= b</c></item>
///   <item><c>..b</c> — open-bottom half-open: matches <c>x &lt; b</c></item>
///   <item><c>..=b</c> — open-bottom closed: matches <c>x &lt;= b</c></item>
///   <item><c>a..</c> — open-top: matches <c>x &gt;= a</c></item>
/// </list>
/// Range expressions in non-pattern position (e.g. <c>for i in 0..N</c>) still
/// use <c>..</c> exclusively; <c>..=</c> is a pattern-only token.
/// </summary>
public class RangePatternNode : PatternNode
{
    public RangePatternNode(SourceSpan span, ExpressionNode? lo, ExpressionNode? hi, bool isInclusive) : base(span)
    {
        Lo = lo;
        Hi = hi;
        IsInclusive = isInclusive;
    }

    /// <summary>Lower bound (inclusive) or null for open-bottom.</summary>
    public ExpressionNode? Lo { get; }

    /// <summary>Upper bound or null for open-top. Inclusivity given by <see cref="IsInclusive"/>.</summary>
    public ExpressionNode? Hi { get; }

    /// <summary>True for <c>..=b</c> / <c>a..=b</c>; false for <c>..b</c> / <c>a..b</c>.</summary>
    public bool IsInclusive { get; }
}
