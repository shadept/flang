using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Represents a named argument in a function call: foo(name = value).
/// The type checker unwraps this; lowering should never see it.
/// </summary>
public class NamedArgumentExpressionNode : ExpressionNode
{
    public NamedArgumentExpressionNode(SourceSpan span, SourceSpan nameSpan, string name, ExpressionNode value) : base(span)
    {
        NameSpan = nameSpan;
        Name = name;
        Value = value;
    }

    public string Name { get; }
    public SourceSpan NameSpan { get; }
    public ExpressionNode Value { get; set; } // mutable for coercion insertion
}
