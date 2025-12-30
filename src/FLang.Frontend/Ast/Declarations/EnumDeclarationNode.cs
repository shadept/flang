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
        string name,
        List<string> typeParameters,
        List<EnumVariantNode> variants)
        : base(span)
    {
        Name = name;
        TypeParameters = typeParameters;
        Variants = variants;
    }

    public string Name { get; }
    public List<string> TypeParameters { get; }
    public List<EnumVariantNode> Variants { get; }
}

