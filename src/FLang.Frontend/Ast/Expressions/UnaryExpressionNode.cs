using FLang.Core;
using FLang.Frontend.Ast.Declarations;

namespace FLang.Frontend.Ast.Expressions;

public class UnaryExpressionNode : ExpressionNode
{
    public UnaryExpressionNode(SourceSpan span, UnaryOperatorKind op, ExpressionNode operand) : base(span)
    {
        Operator = op;
        Operand = operand;
    }

    public UnaryOperatorKind Operator { get; }
    public ExpressionNode Operand { get; }

    /// <summary>
    /// Semantic: The resolved operator function declaration.
    /// Null if the operator uses built-in handling (primitive types).
    /// </summary>
    public FunctionDeclarationNode? ResolvedOperatorFunction { get; set; }
}
