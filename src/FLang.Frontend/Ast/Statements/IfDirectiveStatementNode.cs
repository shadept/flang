using FLang.Core;
using FLang.Frontend.Ast.Declarations;

namespace FLang.Frontend.Ast.Statements;

/// <summary>
/// Represents a compile-time conditional: #if(expr) { ... } else { ... }
/// The condition is a TemplateExpr evaluated against the compile-time context
/// (e.g., platform.os == "macos", runtime.testing, runtime.env["KEY"] == "val").
/// Only the active branch is type-checked and lowered.
/// </summary>
public class IfDirectiveStatementNode : StatementNode
{
    public IfDirectiveStatementNode(
        SourceSpan span,
        TemplateExpr condition,
        IReadOnlyList<StatementNode> thenBody,
        IReadOnlyList<StatementNode>? elseBody) : base(span)
    {
        Condition = condition;
        ThenBody = thenBody;
        ElseBody = elseBody;
    }

    /// <summary>
    /// The compile-time condition expression (e.g., platform.os == "windows", runtime.testing).
    /// </summary>
    public TemplateExpr Condition { get; }

    /// <summary>
    /// Statements to execute when the condition is true.
    /// </summary>
    public IReadOnlyList<StatementNode> ThenBody { get; }

    /// <summary>
    /// Statements to execute when the condition is false (optional).
    /// </summary>
    public IReadOnlyList<StatementNode>? ElseBody { get; }
}
