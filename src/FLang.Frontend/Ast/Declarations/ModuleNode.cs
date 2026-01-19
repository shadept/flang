using FLang.Core;

namespace FLang.Frontend.Ast.Declarations;

public class ModuleNode : AstNode
{
    public ModuleNode(
        SourceSpan span,
        IReadOnlyList<ImportDeclarationNode> imports,
        IReadOnlyList<StructDeclarationNode> structs,
        IReadOnlyList<EnumDeclarationNode> enums,
        IReadOnlyList<FunctionDeclarationNode> functions,
        IReadOnlyList<TestDeclarationNode> tests) : base(span)
    {
        Imports = imports;
        Structs = structs;
        Enums = enums;
        Functions = functions;
        Tests = tests;
    }

    public IReadOnlyList<ImportDeclarationNode> Imports { get; }
    public IReadOnlyList<StructDeclarationNode> Structs { get; }
    public IReadOnlyList<EnumDeclarationNode> Enums { get; }
    public IReadOnlyList<FunctionDeclarationNode> Functions { get; }
    public IReadOnlyList<TestDeclarationNode> Tests { get; }
}