using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// A `$"..."` / `$(args)"..."` / `$ident"..."` interpolated string expression,
/// per RFC-004. Desugared by the type checker to a StringBuilder-based block.
/// </summary>
public class InterpolatedStringExpressionNode : ExpressionNode
{
    public InterpolatedStringExpressionNode(
        SourceSpan span,
        IdentifierExpressionNode? targetIdentifier,
        List<ExpressionNode>? builderArgs,
        List<InterpPart> parts) : base(span)
    {
        TargetIdentifier = targetIdentifier;
        BuilderArgs = builderArgs;
        Parts = parts;
    }

    /// <summary>Form 3 (`$sb"..."`): the target identifier appended into.</summary>
    public IdentifierExpressionNode? TargetIdentifier { get; }

    /// <summary>Form 2 (`$(args)"..."`): args passed to `string_builder(...)`.</summary>
    public List<ExpressionNode>? BuilderArgs { get; }

    /// <summary>
    /// Alternating segment and expression parts. Always starts and ends with a
    /// segment, so with N expression parts there are N+1 segment parts.
    /// </summary>
    public List<InterpPart> Parts { get; }

    /// <summary>
    /// Desugared BlockExpressionNode the type checker builds — a sequence of
    /// `__sb.append(...)` calls (plus a `to_string()` trailing expression for
    /// forms 1 and 2). Populated during type checking; consumed by lowering.
    /// </summary>
    public BlockExpressionNode? DesugaredBlock { get; set; }
}

public abstract class InterpPart
{
    public SourceSpan Span { get; protected set; }
}

public class InterpSegmentPart : InterpPart
{
    public InterpSegmentPart(SourceSpan span, string text)
    {
        Span = span;
        Text = text;
    }

    public string Text { get; }
}

public class InterpExpressionPart : InterpPart
{
    public InterpExpressionPart(SourceSpan span, ExpressionNode expression, string? formatSpec)
    {
        Span = span;
        Expression = expression;
        FormatSpec = formatSpec;
    }

    public ExpressionNode Expression { get; set; }
    public string? FormatSpec { get; }
}
