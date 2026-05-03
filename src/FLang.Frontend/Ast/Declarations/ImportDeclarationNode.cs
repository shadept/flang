using FLang.Core;

namespace FLang.Frontend.Ast.Declarations;

public class ImportDeclarationNode : AstNode
{
    public ImportDeclarationNode(SourceSpan span, SourceSpan moduleSpan, IReadOnlyList<string> path, bool isPublic = false) : base(span)
    {
        ModuleSpan = moduleSpan;
        Path = path;
        IsPublic = isPublic;
    }

    /// <summary>
    /// The span covering just the module path (e.g., "std.io.file"), excluding the "import" keyword.
    /// </summary>
    public SourceSpan ModuleSpan { get; }

    public IReadOnlyList<string> Path { get; }

    /// <summary>
    /// True for `pub import path`. Pub imports re-export the imported module: anyone
    /// importing this module also sees the re-exported module's pub items.
    /// Private (`import path`) imports are visible only inside the importing module.
    /// </summary>
    public bool IsPublic { get; }
}
