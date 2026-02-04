using FLang.Core;

namespace FLang.Frontend.Ast.Statements;

/// <summary>
/// Represents an infinite loop statement: loop { body }
/// Exits via break or return.
/// </summary>
public class LoopNode : StatementNode
{
    public LoopNode(SourceSpan span, ExpressionNode body) : base(span)
    {
        Body = body;
    }

    public ExpressionNode Body { get; }
}
