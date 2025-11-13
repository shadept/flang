using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class CastExpressionNode : ExpressionNode
{
    public CastExpressionNode(SourceSpan span, ExpressionNode expression, FLang.Frontend.Ast.Types.TypeNode targetType)
        : base(span)
    {
        Expression = expression;
        TargetType = targetType;
    }

    public ExpressionNode Expression { get; }
    public FLang.Frontend.Ast.Types.TypeNode TargetType { get; }
}