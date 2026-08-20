using FLang.Core;

namespace FLang.Frontend.Ast.Declarations;

/// <summary>
/// A group of top-level declarations, as parsed inside one branch of a
/// declaration-level #if directive. Mirrors the per-kind lists of
/// <see cref="ModuleNode"/> (minus imports and generator definitions,
/// which may not appear inside #if branches).
/// </summary>
public class DeclarationGroup
{
    public List<StructDeclarationNode> Structs { get; } = [];
    public List<EnumDeclarationNode> Enums { get; } = [];
    public List<TypeAliasDeclarationNode> TypeAliases { get; } = [];
    public List<FunctionDeclarationNode> Functions { get; } = [];
    public List<TestDeclarationNode> Tests { get; } = [];
    public List<VariableDeclarationNode> GlobalConstants { get; } = [];
    public List<IfDirectiveDeclarationNode> IfDirectives { get; } = [];
}

/// <summary>
/// Declaration-level compile-time conditional: #if(expr) { decls... } else { decls... }
/// The condition is evaluated once, at collection time, against the compile-time
/// context. Only the active branch's declarations are collected; inactive
/// declarations parse but are invisible to name resolution.
/// </summary>
public class IfDirectiveDeclarationNode(
    SourceSpan span,
    TemplateExpr condition,
    DeclarationGroup thenGroup,
    DeclarationGroup? elseGroup) : AstNode(span)
{
    public TemplateExpr Condition { get; } = condition;
    public DeclarationGroup ThenGroup { get; } = thenGroup;
    public DeclarationGroup? ElseGroup { get; } = elseGroup;
}
