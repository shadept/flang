using FLang.Core;
using FLang.Frontend.Ast.Declarations;

namespace FLang.Frontend.Ast.Expressions;

public class BinaryExpressionNode : ExpressionNode
{
    public BinaryExpressionNode(SourceSpan span, ExpressionNode left, BinaryOperatorKind op, ExpressionNode right) :
        base(span)
    {
        Left = left;
        Operator = op;
        Right = right;
    }

    public ExpressionNode Left { get; }
    public BinaryOperatorKind Operator { get; }
    public ExpressionNode Right { get; }

    /// <summary>
    /// Semantic: The resolved operator function declaration.
    /// Null if the operator uses built-in handling (primitive types).
    /// For generic functions, this points to the specialized FunctionDeclarationNode with concrete types.
    /// </summary>
    public FunctionDeclarationNode? ResolvedOperatorFunction { get; set; }

    /// <summary>
    /// Semantic: When true, the result of the resolved operator function should be negated.
    /// Used when op_eq is auto-derived from op_ne or vice versa.
    /// </summary>
    public bool NegateOperatorResult { get; set; }
}