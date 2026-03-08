using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Represents a literal value pattern in a match expression.
/// Matches when the scrutinee equals the literal value.
/// Syntax: 42, b'x', true, false, "hello"
/// </summary>
public class LiteralPatternNode : PatternNode
{
    public LiteralPatternNode(SourceSpan span, ExpressionNode literal) : base(span)
    {
        Literal = literal;
    }

    public ExpressionNode Literal { get; }
}
