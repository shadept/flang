using FLang.Core;

namespace FLang.Frontend.Ast.Declarations;

public class ImportDeclarationNode : AstNode
{
    public ImportDeclarationNode(SourceSpan span, SourceSpan moduleSpan, IReadOnlyList<string> path) : base(span)
    {
        ModuleSpan = moduleSpan;
        Path = path;
    }

    /// <summary>
    /// The span covering just the module path (e.g., "std.io.file"), excluding the "import" keyword.
    /// </summary>
    public SourceSpan ModuleSpan { get; }

    public IReadOnlyList<string> Path { get; }
}