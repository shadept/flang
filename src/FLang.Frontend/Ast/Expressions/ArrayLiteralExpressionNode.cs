using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Represents an array literal expression: [1, 2, 3] or [0; 10]
/// </summary>
public class ArrayLiteralExpressionNode : ExpressionNode
{
    /// <summary>
    /// Constructor for regular array literal: [1, 2, 3]
    /// </summary>
    public ArrayLiteralExpressionNode(SourceSpan span, IReadOnlyList<ExpressionNode> elements) : base(span)
    {
        Elements = elements;
        RepeatCountExpression = null;
    }

    /// <summary>
    /// Constructor for repeat syntax: [0; 10] or [0; SIZE]
    /// </summary>
    public ArrayLiteralExpressionNode(SourceSpan span, ExpressionNode repeatValue, ExpressionNode repeatCount) : base(span)
    {
        RepeatValue = repeatValue;
        RepeatCountExpression = repeatCount;
    }

    public IReadOnlyList<ExpressionNode>? Elements { get; }
    public ExpressionNode? RepeatValue { get; }
    public ExpressionNode? RepeatCountExpression { get; }
    public bool IsRepeatSyntax => RepeatCountExpression != null;
}