using FLang.Core;

namespace FLang.Frontend.Ast.Declarations;

public class ModuleNode : AstNode
{
    public ModuleNode(
        SourceSpan span,
        IReadOnlyList<ImportDeclarationNode> imports,
        IReadOnlyList<StructDeclarationNode> structs,
        IReadOnlyList<FunctionDeclarationNode> functions) : base(span)
    {
        Imports = imports;
        Structs = structs;
        Functions = functions;
    }

    public IReadOnlyList<ImportDeclarationNode> Imports { get; }
    public IReadOnlyList<StructDeclarationNode> Structs { get; }
    public IReadOnlyList<FunctionDeclarationNode> Functions { get; }
}