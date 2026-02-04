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

    /// <summary>
    /// If set, indexed assignment is resolved to a call to this op_set_index function.
    /// Lowering will emit: op_set_index(&amp;base, index, value)
    /// </summary>
    public FunctionDeclarationNode? ResolvedSetIndexFunction { get; set; }

    /// <summary>
    /// If true, this is a range index operation (e.g., arr[1..3], arr[..], arr[1..], arr[..3]).
    /// The result type is a slice of the base array/slice element type.
    /// </summary>
    public bool IsRangeIndex { get; set; }
}
