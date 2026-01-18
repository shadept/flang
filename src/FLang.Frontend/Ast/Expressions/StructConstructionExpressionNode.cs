using FLang.Core;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend.Ast.Expressions;

public class StructConstructionExpressionNode : ExpressionNode
{
    public StructConstructionExpressionNode(SourceSpan span, TypeNode typeName,
        IReadOnlyList<(string, ExpressionNode)> fields) : base(span)
    {
        TypeName = typeName;
        // Store as mutable list to allow TypeChecker to insert coercion nodes
        Fields = fields is List<(string, ExpressionNode)> list ? list : new List<(string, ExpressionNode)>(fields);
    }

    public TypeNode TypeName { get; }
    public List<(string FieldName, ExpressionNode Value)> Fields { get; }
}