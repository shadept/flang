using System.Numerics;
using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class IntegerLiteralNode : ExpressionNode
{
    public IntegerLiteralNode(SourceSpan span, BigInteger value, string? suffix = null) : base(span)
    {
        Value = value;
        Suffix = suffix;
    }

    public BigInteger Value { get; }
    public string? Suffix { get; }
}
