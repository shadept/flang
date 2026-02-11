using FLang.Core;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend.Ast.Declarations;

public class StructFieldNode : AstNode
{
    public StructFieldNode(SourceSpan span, SourceSpan nameSpan, string name, TypeNode type) : base(span)
    {
        NameSpan = nameSpan;
        Name = name;
        Type = type;
    }

    public string Name { get; }
    public SourceSpan NameSpan { get; }
    public TypeNode Type { get; }
}