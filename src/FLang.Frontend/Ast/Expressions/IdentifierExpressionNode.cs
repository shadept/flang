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

    /// <summary>
    /// Semantic: When this identifier refers to a local variable,
    /// this holds the declaration node.
    /// </summary>
    public VariableDeclarationNode? ResolvedVariableDeclaration { get; set; }

    /// <summary>
    /// Semantic: When this identifier refers to a function parameter,
    /// this holds the parameter node.
    /// </summary>
    public FunctionParameterNode? ResolvedParameterDeclaration { get; set; }
}