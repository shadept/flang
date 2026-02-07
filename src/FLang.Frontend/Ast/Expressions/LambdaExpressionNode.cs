using FLang.Core;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend.Ast.Expressions;

public class LambdaExpressionNode : ExpressionNode
{
    public record LambdaParameter(SourceSpan Span, string Name, TypeNode? Type);

    public LambdaExpressionNode(SourceSpan span, IReadOnlyList<LambdaParameter> parameters,
        TypeNode? returnType, IReadOnlyList<StatementNode> body) : base(span)
    {
        Parameters = parameters;
        ReturnType = returnType;
        Body = body;
    }

    public IReadOnlyList<LambdaParameter> Parameters { get; }
    public TypeNode? ReturnType { get; }
    public IReadOnlyList<StatementNode> Body { get; }

    /// <summary>
    /// Semantic: synthesized FunctionDeclarationNode, set by the type checker.
    /// </summary>
    public FunctionDeclarationNode? SynthesizedFunction { get; set; }
}
