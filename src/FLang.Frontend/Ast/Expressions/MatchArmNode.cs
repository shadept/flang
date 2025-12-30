using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Represents a single arm in a match expression.
/// Syntax: pattern => expr
/// </summary>
public class MatchArmNode : AstNode
{
    public MatchArmNode(
        SourceSpan span,
        PatternNode pattern,
        ExpressionNode resultExpr)
        : base(span)
    {
        Pattern = pattern;
        ResultExpr = resultExpr;
    }

    public PatternNode Pattern { get; }
    public ExpressionNode ResultExpr { get; }
}

