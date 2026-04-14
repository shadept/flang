using FLang.Core;
using FLang.Frontend.Ast.Declarations;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Represents a dereference operation: ptr.*
/// Accesses the value pointed to by a reference.
/// </summary>
public class DereferenceExpressionNode : ExpressionNode
{
    public DereferenceExpressionNode(SourceSpan span, ExpressionNode target) : base(span)
    {
        Target = target;
    }

    public ExpressionNode Target { get; }

    /// <summary>
    /// When set, this dereference is resolved via op_deref instead of pointer dereference.
    /// The type checker sets this when the target is a nominal type with an op_deref function.
    /// </summary>
    public FunctionDeclarationNode? ResolvedOpDeref { get; set; }
}