using FLang.Core;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend.Ast.Expressions;

public class StructConstructionExpressionNode : ExpressionNode
{
    public StructConstructionExpressionNode(SourceSpan span, TypeNode typeName,
        IReadOnlyList<(string, ExpressionNode)> fields) : base(span)
    {
        TypeName = typeName;
        Fields = fields;
    }

    public TypeNode TypeName { get; }
    public IReadOnlyList<(string FieldName, ExpressionNode Value)> Fields { get; }
}