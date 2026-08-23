using FLang.Core;
using FLang.Frontend.Ast.Declarations;

namespace FLang.Frontend.Ast.Statements;

public class ForLoopNode : StatementNode
{
    public ForLoopNode(SourceSpan span, string iteratorVariable, ExpressionNode iterableExpression,
        ExpressionNode body, bool byRef = false) : base(span)
    {
        IteratorVariable = iteratorVariable;
        IterableExpression = iterableExpression;
        Body = body;
        ByRef = byRef;
    }

    public string IteratorVariable { get; }

    /// <summary>`for &amp;x in xs` - iterate through `iter_ref` (elements by reference) instead of `iter`.</summary>
    public bool ByRef { get; }
    public ExpressionNode IterableExpression { get; }
    public ExpressionNode Body { get; }

    /// <summary>Semantic: The iterator type returned by iterator() method.</summary>
    public StructType? IteratorType { get; set; }

    /// <summary>Semantic: The element type returned by next() method.</summary>
    public TypeBase? ElementType { get; set; }

    /// <summary>Semantic: The Option(T) type wrapping next() result.</summary>
    public StructType? NextResultOptionType { get; set; }

    /// <summary>Semantic (HM pipeline): Resolved iter() function declaration.</summary>
    public FunctionDeclarationNode? ResolvedIterFunction { get; set; }

    /// <summary>Semantic (HM pipeline): Resolved next() function declaration.</summary>
    public FunctionDeclarationNode? ResolvedNextFunction { get; set; }
}
