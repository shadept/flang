using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Postfix `expr?` (RFC-009). Desugars to:
///     op_try(expr) match { Continue(v) => v, Return(r) => return r }
/// where `Return(r)` short-circuits the enclosing function. The actual
/// match is synthesized by the type checker and stored on
/// <see cref="DesugaredMatch"/>; lowering walks that.
/// </summary>
public class TryExpressionNode : ExpressionNode
{
    public TryExpressionNode(SourceSpan span, ExpressionNode operand) : base(span)
    {
        Operand = operand;
    }

    public ExpressionNode Operand { get; }

    /// <summary>The desugared `op_try(...) match { ... }` produced during type inference.</summary>
    public ExpressionNode? DesugaredMatch { get; set; }
}
