using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public enum BinaryOperatorKind
{
    Add,
    Subtract,
    Multiply,
    Divide,
    Modulo,

    // Comparisons
    Equal,
    NotEqual,
    LessThan,
    GreaterThan,
    LessThanOrEqual,
    GreaterThanOrEqual
}

public class BinaryExpressionNode : ExpressionNode
{
    public BinaryExpressionNode(SourceSpan span, ExpressionNode left, BinaryOperatorKind op, ExpressionNode right) :
        base(span)
    {
        Left = left;
        Operator = op;
        Right = right;
    }

    public ExpressionNode Left { get; }
    public BinaryOperatorKind Operator { get; }
    public ExpressionNode Right { get; }
}