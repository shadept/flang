using FLang.Core;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend.Ast.Declarations;

public class VariableDeclarationNode : StatementNode
{
    public VariableDeclarationNode(SourceSpan span, string name, TypeNode? type, ExpressionNode? initializer) :
        base(span)
    {
        Name = name;
        Type = type;
        Initializer = initializer;
    }

    public string Name { get; }
    public TypeNode? Type { get; }
    public ExpressionNode? Initializer { get; set; }

    /// <summary>
    /// Semantic: Resolved variable type (from annotation or initializer), set during type checking.
    /// Null before type checking completes.
    /// </summary>
    public TypeBase? ResolvedType { get; set; }
}