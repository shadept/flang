using FLang.Core;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend.Ast.Declarations;

public class FunctionParameterNode : AstNode
{
    public FunctionParameterNode(SourceSpan span, SourceSpan nameSpan, string name, TypeNode type) : base(span)
    {
        NameSpan = nameSpan;
        Name = name;
        Type = type;
    }

    public string Name { get; }
    public SourceSpan NameSpan { get; }
    public TypeNode Type { get; }

    /// <summary>
    /// Semantic: Resolved parameter type, set during type checking.
    /// Null before type checking completes.
    /// </summary>
    public TypeBase? ResolvedType { get; set; }
}