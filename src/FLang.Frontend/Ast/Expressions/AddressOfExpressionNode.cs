using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Represents an address-of operation: &variable
/// Takes the address of a variable to create a reference.
/// </summary>
public class AddressOfExpressionNode : ExpressionNode
{
    public ExpressionNode Target { get; }

    public AddressOfExpressionNode(SourceSpan span, ExpressionNode target) : base(span)
    {
        Target = target;
    }
}
