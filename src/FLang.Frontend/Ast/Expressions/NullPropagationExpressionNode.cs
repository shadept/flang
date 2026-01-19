using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Represents a null-propagation member access expression (target?.field).
/// If target is null, the entire expression evaluates to null.
/// If target has a value, evaluates to Some(target.value.field).
/// </summary>
public class NullPropagationExpressionNode : ExpressionNode
{
    public NullPropagationExpressionNode(SourceSpan span, ExpressionNode target, string memberName) : base(span)
    {
        Target = target;
        MemberName = memberName;
    }

    /// <summary>
    /// The target expression (must be Option type).
    /// </summary>
    public ExpressionNode Target { get; }

    /// <summary>
    /// The member (field) name to access if target has a value.
    /// </summary>
    public string MemberName { get; }
}
