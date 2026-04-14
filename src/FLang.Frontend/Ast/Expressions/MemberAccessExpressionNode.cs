using System.Collections.Generic;
using FLang.Core;
using FLang.Frontend.Ast.Declarations;

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

    /// <summary>
    /// Chain of op_deref functions to call before accessing the field.
    /// For example, rc.x on Rc(Wrapper(Point)) produces a chain of two:
    ///   [Rc(Wrapper(Point)).op_deref, Wrapper(Point).op_deref]
    /// Lowering replays this chain: call each op_deref in order, deref the result,
    /// then access the field on the final type.
    /// Null or empty = no op_deref involved.
    /// </summary>
    public List<FunctionDeclarationNode>? OpDerefChain { get; set; }
}