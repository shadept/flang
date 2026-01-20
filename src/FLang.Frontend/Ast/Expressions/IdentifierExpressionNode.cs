using FLang.Core;
using FLang.Frontend.Ast.Declarations;

namespace FLang.Frontend.Ast.Expressions;

public class IdentifierExpressionNode : ExpressionNode
{
    public IdentifierExpressionNode(SourceSpan span, string name) : base(span)
    {
        Name = name;
    }

    public string Name { get; }

    /// <summary>
    /// Semantic: When this identifier refers to a function (used as a value/function pointer),
    /// this holds the resolved function declaration.
    /// </summary>
    public FunctionDeclarationNode? ResolvedFunctionTarget { get; set; }
}