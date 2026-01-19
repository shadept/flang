using FLang.Core;
using FLang.Frontend.Ast.Declarations;

namespace FLang.Frontend.Ast.Expressions;

public class CallExpressionNode : ExpressionNode
{
    public CallExpressionNode(SourceSpan span, string functionName, IReadOnlyList<ExpressionNode> arguments,
        ExpressionNode? ufcsReceiver = null, string? methodName = null) :
        base(span)
    {
        FunctionName = functionName;
        // Store as mutable list to allow TypeChecker to insert coercion nodes
        Arguments = arguments is List<ExpressionNode> list ? list : new List<ExpressionNode>(arguments);
        UfcsReceiver = ufcsReceiver;
        MethodName = methodName;
    }

    public string FunctionName { get; }
    public List<ExpressionNode> Arguments { get; }

    /// <summary>
    /// For UFCS calls (obj.method(args)), this holds the receiver expression (obj).
    /// Null for regular function calls.
    /// </summary>
    public ExpressionNode? UfcsReceiver { get; }

    /// <summary>
    /// For UFCS calls, this holds the method name (just the method part, not "obj.method").
    /// Null for regular function calls.
    /// </summary>
    public string? MethodName { get; }

    /// <summary>
    /// Semantic: The resolved target function declaration.
    /// For generic functions, this points to the specialized FunctionDeclarationNode with concrete types.
    /// </summary>
    public FunctionDeclarationNode? ResolvedTarget { get; set; }
}