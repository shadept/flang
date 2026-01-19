using FLang.Core;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend.Ast.Declarations;

public class VariableDeclarationNode : StatementNode
{
    public VariableDeclarationNode(SourceSpan span, string name, TypeNode? type, ExpressionNode? initializer, bool isConst = false) :
        base(span)
    {
        Name = name;
        Type = type;
        Initializer = initializer;
        IsConst = isConst;
    }

    public string Name { get; }
    public TypeNode? Type { get; }
    public ExpressionNode? Initializer { get; set; }

    /// <summary>
    /// Whether this is a const declaration (immutable binding).
    /// </summary>
    public bool IsConst { get; }

    /// <summary>
    /// Semantic: Resolved variable type (from annotation or initializer), set during type checking.
    /// Null before type checking completes.
    /// </summary>
    public TypeBase? ResolvedType { get; set; }
}