using FLang.Core;

namespace FLang.Frontend.Ast.Declarations;

public class StructDeclarationNode : AstNode
{
    public StructDeclarationNode(SourceSpan span, SourceSpan nameSpan, string name, IReadOnlyList<string> typeParameters,
        IReadOnlyList<StructFieldNode> fields, IReadOnlyList<DirectiveNode>? directives = null) : base(span)
    {
        NameSpan = nameSpan;
        Name = name;
        TypeParameters = typeParameters;
        Fields = fields;
        Directives = directives ?? [];
    }

    public string Name { get; }
    public SourceSpan NameSpan { get; }
    public IReadOnlyList<string> TypeParameters { get; }
    public IReadOnlyList<StructFieldNode> Fields { get; }
    public IReadOnlyList<DirectiveNode> Directives { get; }
}