using FLang.Core;

namespace FLang.Frontend.Ast.Declarations;

/// <summary>
/// Represents a test block declaration: test "name" { ... }
/// Tests are module-scoped and not exported.
/// </summary>
public class TestDeclarationNode : AstNode
{
    public TestDeclarationNode(SourceSpan span, string name, IReadOnlyList<StatementNode> body) : base(span)
    {
        Name = name;
        Body = body;
    }

    /// <summary>
    /// The test name (from the string literal after 'test' keyword).
    /// </summary>
    public string Name { get; }

    /// <summary>
    /// The test body statements.
    /// </summary>
    public IReadOnlyList<StatementNode> Body { get; }
}
