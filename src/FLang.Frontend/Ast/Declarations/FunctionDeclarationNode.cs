using FLang.Core;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend.Ast.Declarations;

[Flags]
public enum FunctionModifiers
{
    None = 0,
    Public = 1 << 0,
    Foreign = 1 << 1,
    Inline = 1 << 2,
}

public class FunctionDeclarationNode : AstNode
{
    public FunctionDeclarationNode(SourceSpan span, string name, IReadOnlyList<FunctionParameterNode> parameters,
        TypeNode? returnType, IReadOnlyList<StatementNode> body, FunctionModifiers modifiers = FunctionModifiers.None) : base(span)
    {
        Name = name;
        Parameters = parameters;
        ReturnType = returnType;
        Body = body;
        Modifiers = modifiers;
    }

    public string Name { get; }
    public IReadOnlyList<FunctionParameterNode> Parameters { get; }
    public TypeNode? ReturnType { get; }
    public IReadOnlyList<StatementNode> Body { get; }
    public FunctionModifiers Modifiers { get; }

    /// <summary>
    /// Semantic: Resolved return type, set during type checking.
    /// Null before type checking completes.
    /// </summary>
    public TypeBase? ResolvedReturnType { get; set; }

    /// <summary>
    /// Semantic: Resolved parameter types, set during type checking.
    /// Null before type checking completes.
    /// </summary>
    public List<TypeBase>? ResolvedParameterTypes { get; set; }
}