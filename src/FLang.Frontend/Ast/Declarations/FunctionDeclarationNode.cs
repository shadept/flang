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
    public FunctionDeclarationNode(SourceSpan span, SourceSpan nameSpan, string name, IReadOnlyList<FunctionParameterNode> parameters,
        TypeNode? returnType, IReadOnlyList<StatementNode> body, FunctionModifiers modifiers = FunctionModifiers.None) : base(span)
    {
        NameSpan = nameSpan;
        Name = name;
        Parameters = parameters;
        ReturnType = returnType;
        Body = body;
        Modifiers = modifiers;
    }

    public string Name { get; }
    public SourceSpan NameSpan { get; }
    public IReadOnlyList<FunctionParameterNode> Parameters { get; }
    public TypeNode? ReturnType { get; }
    public IReadOnlyList<StatementNode> Body { get; }
    public FunctionModifiers Modifiers { get; }

    public bool IsGeneric => Parameters.Any(p => TypeNode.ContainsGenericParam(p.Type))
        || (ReturnType != null && TypeNode.ContainsGenericParam(ReturnType));

    public HashSet<string> GetGenericParamNames()
    {
        var names = new HashSet<string>();
        foreach (var param in Parameters)
            TypeNode.CollectGenericParamNames(param.Type, names);
        if (ReturnType != null)
            TypeNode.CollectGenericParamNames(ReturnType, names);
        return names;
    }

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