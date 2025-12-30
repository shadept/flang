using FLang.Core;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend.Ast.Declarations;

/// <summary>
/// Represents a variant within an enum declaration.
/// Syntax: Variant or Variant(Type1, Type2, ...)
/// </summary>
public class EnumVariantNode : AstNode
{
    public EnumVariantNode(
        SourceSpan span,
        string name,
        List<TypeNode> payloadTypes)
        : base(span)
    {
        Name = name;
        PayloadTypes = payloadTypes;
    }

    public string Name { get; }
    public List<TypeNode> PayloadTypes { get; }
}

