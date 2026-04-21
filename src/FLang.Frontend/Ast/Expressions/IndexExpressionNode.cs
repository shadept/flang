using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Index expression: <c>arr[i]</c>.
/// Resolution (op_index value-form, op_index_ref ref-form, or built-in array/slice)
/// is recorded on the shared <c>InferenceResults.ResolvedOperators</c> dictionary,
/// keyed by this node. Lowering branches on the resolved form there.
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
