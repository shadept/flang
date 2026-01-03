using FLang.Core;
using FLang.Frontend.Ast.Declarations;

namespace FLang.Frontend.Ast.Expressions;

public class CallExpressionNode : ExpressionNode
{
    public CallExpressionNode(SourceSpan span, string functionName, IReadOnlyList<ExpressionNode> arguments) :
        base(span)
    {
        FunctionName = functionName;
        Arguments = arguments;
    }

    public string FunctionName { get; }
    public IReadOnlyList<ExpressionNode> Arguments { get; }

    /// <summary>
    /// Semantic: The resolved target function declaration.
    /// For generic functions, this points to the specialized FunctionDeclarationNode with concrete types.
    /// </summary>
    public FunctionDeclarationNode? ResolvedTarget { get; set; }
}