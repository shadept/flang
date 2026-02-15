using FLang.Core;

namespace FLang.Frontend.Ast;

public class DirectiveNode : AstNode
{
    public DirectiveNode(SourceSpan span, string name, IReadOnlyList<Token> arguments) : base(span)
    {
        Name = name;
        Arguments = arguments;
    }

    public string Name { get; }
    public IReadOnlyList<Token> Arguments { get; }
}
