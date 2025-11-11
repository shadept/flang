using FLang.Core;

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
}