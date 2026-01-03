using FLang.Core;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend.Ast.Declarations;

public class FunctionParameterNode : AstNode
{
    public FunctionParameterNode(SourceSpan span, string name, TypeNode type) : base(span)
    {
        Name = name;
        Type = type;
    }

    public string Name { get; }
    public TypeNode Type { get; }

    /// <summary>
    /// Semantic: Resolved parameter type, set during type checking.
    /// Null before type checking completes.
    /// </summary>
    public TypeBase? ResolvedType { get; set; }
}