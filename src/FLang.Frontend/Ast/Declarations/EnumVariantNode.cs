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
        SourceSpan nameSpan,
        string name,
        List<TypeNode> payloadTypes,
        long? explicitTagValue = null)
        : base(span)
    {
        NameSpan = nameSpan;
        Name = name;
        PayloadTypes = payloadTypes;
        ExplicitTagValue = explicitTagValue;
    }

    public string Name { get; }
    public SourceSpan NameSpan { get; }
    public List<TypeNode> PayloadTypes { get; }
    public long? ExplicitTagValue { get; }
}
