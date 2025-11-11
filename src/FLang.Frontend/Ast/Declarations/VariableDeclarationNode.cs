using FLang.Core;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend.Ast.Declarations;

public class VariableDeclarationNode : StatementNode
{
    public string Name { get; }
    public TypeNode? Type { get; }
    public ExpressionNode? Initializer { get; }

    public VariableDeclarationNode(SourceSpan span, string name, TypeNode? type, ExpressionNode? initializer) : base(span)
    {
        Name = name;
        Type = type;
        Initializer = initializer;
    }
}
