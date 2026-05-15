using FLang.Core;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend.Ast.Declarations;

/// <summary>
/// `[pub] [directives] type Name = TypeExpr` where the RHS is not a
/// struct or enum builder — i.e. a transparent alias. The name resolves
/// to the same type as the RHS; no nominal identity is introduced and
/// no runtime layout differs from the underlying type.
/// </summary>
public class TypeAliasDeclarationNode : AstNode
{
    public TypeAliasDeclarationNode(
        SourceSpan span,
        SourceSpan nameSpan,
        string name,
        TypeNode aliasedType,
        bool isPublic,
        IReadOnlyList<DirectiveNode>? directives = null) : base(span)
    {
        NameSpan = nameSpan;
        Name = name;
        AliasedType = aliasedType;
        IsPublic = isPublic;
        Directives = directives ?? [];
    }

    public string Name { get; }
    public SourceSpan NameSpan { get; }
    public TypeNode AliasedType { get; }
    public bool IsPublic { get; }
    public IReadOnlyList<DirectiveNode> Directives { get; }
}
