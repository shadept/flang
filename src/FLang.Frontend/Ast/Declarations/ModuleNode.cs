using FLang.Core;

namespace FLang.Frontend.Ast.Declarations;

public class ModuleNode(
    SourceSpan span,
    IReadOnlyList<ImportDeclarationNode> imports,
    IReadOnlyList<StructDeclarationNode> structs,
    IReadOnlyList<EnumDeclarationNode> enums,
    IReadOnlyList<TypeAliasDeclarationNode> typeAliases,
    IReadOnlyList<FunctionDeclarationNode> functions,
    IReadOnlyList<TestDeclarationNode> tests,
    IReadOnlyList<VariableDeclarationNode> globalConstants,
    IReadOnlyList<SourceGeneratorDefinitionNode> generatorDefinitions,
    IReadOnlyList<SourceGeneratorInvocationNode> generatorInvocations,
    IReadOnlyList<IfDirectiveDeclarationNode>? ifDirectives = null) : AstNode(span)
{
    public IReadOnlyList<ImportDeclarationNode> Imports { get; } = imports;
    public IReadOnlyList<VariableDeclarationNode> GlobalConstants { get; } = globalConstants;
    public IReadOnlyList<StructDeclarationNode> Structs { get; } = structs;
    public IReadOnlyList<EnumDeclarationNode> Enums { get; } = enums;
    public IReadOnlyList<TypeAliasDeclarationNode> TypeAliases { get; } = typeAliases;
    public IReadOnlyList<FunctionDeclarationNode> Functions { get; } = functions;
    public IReadOnlyList<TestDeclarationNode> Tests { get; } = tests;
    public IReadOnlyList<SourceGeneratorDefinitionNode> GeneratorDefinitions { get; } = generatorDefinitions;
    public IReadOnlyList<SourceGeneratorInvocationNode> GeneratorInvocations { get; } = generatorInvocations;

    /// <summary>
    /// Declaration-level #if directives, present only between parsing and the
    /// flatten pass (<c>IfDirectiveDeclarations.Flatten</c>). Empty afterwards:
    /// the active branches' declarations are merged into the lists above.
    /// </summary>
    public IReadOnlyList<IfDirectiveDeclarationNode> IfDirectives { get; } = ifDirectives ?? [];

    /// <summary>
    /// This module with <paramref name="other"/>'s declarations appended (imports,
    /// span and pending #if directives stay this module's). Used to fold template
    /// expansion output into its origin module.
    /// </summary>
    public ModuleNode Append(ModuleNode other) => new(Span, Imports,
        [.. Structs, .. other.Structs],
        [.. Enums, .. other.Enums],
        [.. TypeAliases, .. other.TypeAliases],
        [.. Functions, .. other.Functions],
        [.. Tests, .. other.Tests],
        [.. GlobalConstants, .. other.GlobalConstants],
        [.. GeneratorDefinitions, .. other.GeneratorDefinitions],
        GeneratorInvocations,
        IfDirectives);
}
