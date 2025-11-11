using FLang.Core;

namespace FLang.Frontend.Ast.Statements;

public class ForLoopNode : StatementNode
{
    public string IteratorVariable { get; }
    public ExpressionNode IterableExpression { get; }
    public ExpressionNode Body { get; }

    public ForLoopNode(SourceSpan span, string iteratorVariable, ExpressionNode iterableExpression, ExpressionNode body) : base(span)
    {
        IteratorVariable = iteratorVariable;
        IterableExpression = iterableExpression;
        Body = body;
    }
}
