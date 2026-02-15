using FLang.Core;

namespace FLang.Frontend.Ast.Declarations;

/// <summary>
/// Represents an enum (tagged union) declaration.
/// Syntax: enum Name(T, U) { Variant, Variant(Type), ... }
/// </summary>
public class EnumDeclarationNode : AstNode
{
    public EnumDeclarationNode(
        SourceSpan span,
        SourceSpan nameSpan,
        string name,
        List<string> typeParameters,
        List<EnumVariantNode> variants,
        IReadOnlyList<DirectiveNode>? directives = null)
        : base(span)
    {
        NameSpan = nameSpan;
        Name = name;
        TypeParameters = typeParameters;
        Variants = variants;
        Directives = directives ?? [];
    }

    public string Name { get; }
    public SourceSpan NameSpan { get; }
    public List<string> TypeParameters { get; }
    public List<EnumVariantNode> Variants { get; }
    public IReadOnlyList<DirectiveNode> Directives { get; }
}

