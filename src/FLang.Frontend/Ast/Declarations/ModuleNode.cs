using FLang.Core;

namespace FLang.Frontend.Ast.Declarations;

public class ModuleNode(
    SourceSpan span,
    IReadOnlyList<ImportDeclarationNode> imports,
    IReadOnlyList<StructDeclarationNode> structs,
    IReadOnlyList<EnumDeclarationNode> enums,
    IReadOnlyList<FunctionDeclarationNode> functions,
    IReadOnlyList<TestDeclarationNode> tests,
    IReadOnlyList<VariableDeclarationNode> globalConstants,
    IReadOnlyList<SourceGeneratorDefinitionNode> generatorDefinitions,
    IReadOnlyList<SourceGeneratorInvocationNode> generatorInvocations) : AstNode(span)
{
    public IReadOnlyList<ImportDeclarationNode> Imports { get; } = imports;
    public IReadOnlyList<VariableDeclarationNode> GlobalConstants { get; } = globalConstants;
    public IReadOnlyList<StructDeclarationNode> Structs { get; } = structs;
    public IReadOnlyList<EnumDeclarationNode> Enums { get; } = enums;
    public IReadOnlyList<FunctionDeclarationNode> Functions { get; } = functions;
    public IReadOnlyList<TestDeclarationNode> Tests { get; } = tests;
    public IReadOnlyList<SourceGeneratorDefinitionNode> GeneratorDefinitions { get; } = generatorDefinitions;
    public IReadOnlyList<SourceGeneratorInvocationNode> GeneratorInvocations { get; } = generatorInvocations;
}
