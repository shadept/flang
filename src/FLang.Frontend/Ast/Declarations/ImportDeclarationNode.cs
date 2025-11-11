using System.Collections.Generic;
using FLang.Core;

namespace FLang.Frontend.Ast.Declarations;

public class ImportDeclarationNode : AstNode
{
    public IReadOnlyList<string> Path { get; }

    public ImportDeclarationNode(SourceSpan span, IReadOnlyList<string> path) : base(span)
    {
        Path = path;
    }
}
