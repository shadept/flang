using FLang.Core;

namespace FLang.Frontend.Ast.Statements;

public class ForLoopNode : StatementNode
{
    public ForLoopNode(SourceSpan span, string iteratorVariable, ExpressionNode iterableExpression,
        ExpressionNode body) : base(span)
    {
        IteratorVariable = iteratorVariable;
        IterableExpression = iterableExpression;
        Body = body;
    }

    public string IteratorVariable { get; }
    public ExpressionNode IterableExpression { get; }
    public ExpressionNode Body { get; }

    /// <summary>Semantic: The iterator type returned by iterator() method.</summary>
    public StructType? IteratorType { get; set; }

    /// <summary>Semantic: The element type returned by next() method.</summary>
    public TypeBase? ElementType { get; set; }

    /// <summary>Semantic: The Option[T] type wrapping next() result.</summary>
    public StructType? NextResultOptionType { get; set; }
}