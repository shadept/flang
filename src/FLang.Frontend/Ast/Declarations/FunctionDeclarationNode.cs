using System.Collections.Generic;
using FLang.Core;
using FLang.Frontend.Ast.Statements;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend.Ast.Declarations;

public class FunctionDeclarationNode : AstNode
{
    public string Name { get; }
    public IReadOnlyList<FunctionParameterNode> Parameters { get; }
    public TypeNode? ReturnType { get; }
    public IReadOnlyList<StatementNode> Body { get; }
    public bool IsForeign { get; }

    public FunctionDeclarationNode(SourceSpan span, string name, IReadOnlyList<FunctionParameterNode> parameters, TypeNode? returnType, IReadOnlyList<StatementNode> body, bool isForeign = false) : base(span)
    {
        Name = name;
        Parameters = parameters;
        ReturnType = returnType;
        Body = body;
        IsForeign = isForeign;
    }
}
