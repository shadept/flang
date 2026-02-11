using FLang.Core;

namespace FLang.Frontend.Ast.Declarations;

public class StructDeclarationNode : AstNode
{
    public StructDeclarationNode(SourceSpan span, SourceSpan nameSpan, string name, IReadOnlyList<string> typeParameters,
        IReadOnlyList<StructFieldNode> fields) : base(span)
    {
        NameSpan = nameSpan;
        Name = name;
        TypeParameters = typeParameters;
        Fields = fields;
    }

    public string Name { get; }
    public SourceSpan NameSpan { get; }
    public IReadOnlyList<string> TypeParameters { get; }
    public IReadOnlyList<StructFieldNode> Fields { get; }
}