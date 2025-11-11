using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class RangeExpressionNode : ExpressionNode
{
    public RangeExpressionNode(SourceSpan span, ExpressionNode start, ExpressionNode end) : base(span)
    {
        Start = start;
        End = end;
    }

    public ExpressionNode Start { get; }
    public ExpressionNode End { get; }
}