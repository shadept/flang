using FLang.Core;

namespace FLang.Frontend.Ast.Declarations;

public class ImportDeclarationNode : AstNode
{
    public ImportDeclarationNode(SourceSpan span, IReadOnlyList<string> path) : base(span)
    {
        Path = path;
    }

    public IReadOnlyList<string> Path { get; }
}