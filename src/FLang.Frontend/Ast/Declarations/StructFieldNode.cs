using FLang.Core;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend.Ast.Declarations;

public class StructFieldNode : AstNode
{
    public StructFieldNode(SourceSpan span, string name, TypeNode type) : base(span)
    {
        Name = name;
        Type = type;
    }

    public string Name { get; }
    public TypeNode Type { get; }
}