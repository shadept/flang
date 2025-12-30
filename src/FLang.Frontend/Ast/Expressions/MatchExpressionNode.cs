using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Represents a match expression for pattern matching on enum values.
/// Syntax: expr match { pattern => expr, ... }
/// </summary>
public class MatchExpressionNode : ExpressionNode
{
    public MatchExpressionNode(
        SourceSpan span,
        ExpressionNode scrutinee,
        List<MatchArmNode> arms)
        : base(span)
    {
        Scrutinee = scrutinee;
        Arms = arms;
    }

    public ExpressionNode Scrutinee { get; }
    public List<MatchArmNode> Arms { get; }
}

