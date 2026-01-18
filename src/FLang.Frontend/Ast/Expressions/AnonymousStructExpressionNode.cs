using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

public class AnonymousStructExpressionNode : ExpressionNode
{
    public AnonymousStructExpressionNode(SourceSpan span, IReadOnlyList<(string FieldName, ExpressionNode Value)> fields) : base(span)
    {
        // Store as mutable list to allow TypeChecker to insert coercion nodes
        Fields = fields is List<(string FieldName, ExpressionNode Value)> list ? list : new List<(string FieldName, ExpressionNode Value)>(fields);
    }

    public List<(string FieldName, ExpressionNode Value)> Fields { get; }
}
