using FLang.Core;

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
}