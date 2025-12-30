using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Represents a variable binding pattern that matches anything and binds to a variable.
/// Syntax: identifier
/// </summary>
public class VariablePatternNode : PatternNode
{
    public VariablePatternNode(SourceSpan span, string name) : base(span)
    {
        Name = name;
    }

    public string Name { get; }
}

