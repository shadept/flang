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
        RepeatCount = null;
    }

    /// <summary>
    /// Constructor for repeat syntax: [0; 10]
    /// </summary>
    public ArrayLiteralExpressionNode(SourceSpan span, ExpressionNode repeatValue, int repeatCount) : base(span)
    {
        RepeatValue = repeatValue;
        RepeatCount = repeatCount;
    }

    public IReadOnlyList<ExpressionNode>? Elements { get; }
    public ExpressionNode? RepeatValue { get; }
    public int? RepeatCount { get; }
    public bool IsRepeatSyntax => RepeatCount.HasValue;
}