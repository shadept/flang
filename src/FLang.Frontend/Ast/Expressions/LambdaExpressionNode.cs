using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Types;
using Type = FLang.Core.Types.Type;

namespace FLang.Frontend.Ast.Expressions;

public class LambdaExpressionNode : ExpressionNode
{
    public record LambdaParameter(SourceSpan Span, string Name, TypeNode? Type);

    /// <summary>
    /// A free variable referenced inside the lambda body that resolves to an
    /// outer scope. RFC-014 Phase 2: captures are by value, so each entry
    /// becomes a field on the synthesized closure struct.
    /// </summary>
    public record LambdaCapture(string Name, Type Type);

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
    /// Semantic: synthesized FunctionDeclarationNode (the lambda body, or
    /// `op_call(self: &Closure, ...)` for a capturing closure). Set by the
    /// type checker.
    /// </summary>
    public FunctionDeclarationNode? SynthesizedFunction { get; set; }

    /// <summary>
    /// Semantic: free variables captured from outer scope. Empty for non-capturing
    /// lambdas (those still lower to plain function pointers).
    /// </summary>
    public List<LambdaCapture> Captures { get; } = [];

    /// <summary>
    /// Semantic: synthesized closure struct type for capturing lambdas. Null
    /// when the lambda has no captures (lowers to a plain function pointer).
    /// </summary>
    public NominalType? SynthesizedClosureType { get; set; }
}
