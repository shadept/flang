using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Represents a single arm in a match expression.
/// Syntax: pattern [if guard] => expr
/// </summary>
public class MatchArmNode : AstNode
{
    public MatchArmNode(
        SourceSpan span,
        PatternNode pattern,
        ExpressionNode resultExpr,
        ExpressionNode? guard = null)
        : base(span)
    {
        Pattern = pattern;
        ResultExpr = resultExpr;
        Guard = guard;
    }

    public PatternNode Pattern { get; }
    public ExpressionNode ResultExpr { get; }

    /// <summary>
    /// Optional guard expression: `pattern if cond => expr`. The arm matches
    /// only if the pattern matches AND the guard evaluates to true (RFC-010).
    /// </summary>
    public ExpressionNode? Guard { get; }
}

