using FLang.Core;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend.Ast.Declarations;

public class FunctionParameterNode : AstNode
{
    public string Name { get; }
    public TypeNode Type { get; }

    public FunctionParameterNode(SourceSpan span, string name, TypeNode type) : base(span)
    {
        Name = name;
        Type = type;
    }
}
