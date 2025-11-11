using System.Collections.Generic;
using FLang.Core;

namespace FLang.Frontend.Ast.Declarations;

public class StructDeclarationNode : AstNode
{
    public string Name { get; }
    public IReadOnlyList<string> TypeParameters { get; }
    public IReadOnlyList<StructFieldNode> Fields { get; }

    public StructDeclarationNode(SourceSpan span, string name, IReadOnlyList<string> typeParameters, IReadOnlyList<StructFieldNode> fields) : base(span)
    {
        Name = name;
        TypeParameters = typeParameters;
        Fields = fields;
    }
}
