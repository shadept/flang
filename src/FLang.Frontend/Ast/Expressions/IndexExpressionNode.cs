using FLang.Core;
using FLang.Frontend.Ast.Declarations;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Represents an index expression: arr[i]<br/>
/// Desugars to op_index(&amp;base, index) when an op_index function is found.
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

    /// <summary>
    /// If set, indexing is resolved to a call to this op_index function.
    /// Lowering will emit: op_index(&amp;base, index)
    /// </summary>
    public FunctionDeclarationNode? ResolvedIndexFunction { get; set; }
}
