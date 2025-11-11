using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class RangeExpressionNode : ExpressionNode
{
    public ExpressionNode Start { get; }
    public ExpressionNode End { get; }

    public RangeExpressionNode(SourceSpan span, ExpressionNode start, ExpressionNode end) : base(span)
    {
        Start = start;
        End = end;
    }
}
