using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Represents an index expression: arr[i]
/// </summary>
public class IndexExpressionNode : ExpressionNode
{
    public IndexExpressionNode(SourceSpan span, ExpressionNode @base, ExpressionNode index) : base(span)
    {
        Base = @base;
        Index = index;
    }

    public ExpressionNode Base { get; }
    public ExpressionNode Index { get; }
}