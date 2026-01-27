using FLang.Core;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend.Ast.Declarations;

public class VariableDeclarationNode : StatementNode
{
    public VariableDeclarationNode(SourceSpan span, string name, TypeNode? type, ExpressionNode? initializer, bool isConst = false, bool isPublic = false) :
        base(span)
    {
        Name = name;
        Type = type;
        Initializer = initializer;
        IsConst = isConst;
        IsPublic = isPublic;
    }

    public string Name { get; }
    public TypeNode? Type { get; }
    public ExpressionNode? Initializer { get; set; }

    /// <summary>
    /// Whether this is a const declaration (immutable binding).
    /// </summary>
    public bool IsConst { get; }

    /// <summary>
    /// Whether this is a public declaration (visible outside the module).
    /// Only valid for top-level const declarations.
    /// </summary>
    public bool IsPublic { get; }

    /// <summary>
    /// Semantic: Resolved variable type (from annotation or initializer), set during type checking.
    /// Null before type checking completes.
    /// </summary>
    public TypeBase? ResolvedType { get; set; }
}
