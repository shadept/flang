using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class MemberAccessExpressionNode : ExpressionNode
{
    public MemberAccessExpressionNode(SourceSpan span, ExpressionNode target, string fieldName) : base(span)
    {
        Target = target;
        FieldName = fieldName;
    }

    public ExpressionNode Target { get; }
    public string FieldName { get; }

    /// <summary>
    /// Number of automatic dereferences needed to access the field.
    /// Set by TypeChecker when the target is &amp;T, &amp;&amp;T, etc.
    /// 0 = target is struct directly, 1 = target is &amp;Struct, 2 = target is &amp;&amp;Struct, etc.
    /// </summary>
    public int AutoDerefCount { get; set; }
}