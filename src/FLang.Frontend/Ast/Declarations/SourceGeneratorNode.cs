using FLang.Core;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend.Ast.Declarations;

// ─── Generator parameter definitions ─────────────────────────────────────────

public enum GeneratorParamKind
{
    Ident, // bare identifier
    Type,  // type expression
}

public record GeneratorParameter(string Name, GeneratorParamKind Kind, SourceSpan Span, bool IsVariadic = false);

// ─── Template body AST ───────────────────────────────────────────────────────

/// <summary>Base class for template body nodes inside a #define body.</summary>
public abstract class TemplateNode(SourceSpan span) : AstNode(span);

/// <summary>A run of verbatim source text copied as-is into the output, including whitespace.</summary>
public class TemplateVerbatimNode(SourceSpan span, string text) : TemplateNode(span)
{
    public string Text { get; } = text;
}

/// <summary>#(expr) — evaluate expression, stringify, paste into output.</summary>
public class TemplateInterpolationNode(SourceSpan span, TemplateExpr expression) : TemplateNode(span)
{
    public TemplateExpr Expression { get; } = expression;
}

/// <summary>#for name in expr { body }</summary>
public class TemplateForNode(
    SourceSpan span,
    string variableName,
    TemplateExpr iterable,
    IReadOnlyList<TemplateNode> body) : TemplateNode(span)
{
    public string VariableName { get; } = variableName;
    public TemplateExpr Iterable { get; } = iterable;
    public IReadOnlyList<TemplateNode> Body { get; } = body;
}

/// <summary>#if expr { body } #else { body } or #else #if chaining</summary>
public class TemplateIfNode(
    SourceSpan span,
    TemplateExpr condition,
    IReadOnlyList<TemplateNode> body,
    IReadOnlyList<TemplateNode>? elseBranch = null) : TemplateNode(span)
{
    public TemplateExpr Condition { get; } = condition;
    public IReadOnlyList<TemplateNode> Body { get; } = body;
    public IReadOnlyList<TemplateNode>? ElseBranch { get; } = elseBranch;
}

// ─── Template expression AST ─────────────────────────────────────────────────

/// <summary>Base class for expressions inside #() interpolation and #for/#if.</summary>
public abstract class TemplateExpr(SourceSpan span) : AstNode(span);

/// <summary>String literal: "hello"</summary>
public class TemplateStringLiteral(SourceSpan span, string value) : TemplateExpr(span)
{
    public string Value { get; } = value;
}

/// <summary>Integer literal: 123</summary>
public class TemplateIntLiteral(SourceSpan span, long value) : TemplateExpr(span)
{
    public long Value { get; } = value;
}

/// <summary>Variable reference: field, Name, T</summary>
public class TemplateNameExpr(SourceSpan span, string name) : TemplateExpr(span)
{
    public string Name { get; } = name;
}

/// <summary>Member access: obj.member (chained via nesting)</summary>
public class TemplateMemberAccessExpr(SourceSpan span, TemplateExpr obj, string member) : TemplateExpr(span)
{
    public TemplateExpr Object { get; } = obj;
    public string Member { get; } = member;
}

/// <summary>Binary operator: a + b, a - b, etc.</summary>
public class TemplateBinaryExpr(SourceSpan span, TemplateExpr left, string op, TemplateExpr right) : TemplateExpr(span)
{
    public TemplateExpr Left { get; } = left;
    public string Operator { get; } = op;
    public TemplateExpr Right { get; } = right;
}

/// <summary>Single index: obj[expr]</summary>
public class TemplateIndexExpr(SourceSpan span, TemplateExpr obj, TemplateExpr index) : TemplateExpr(span)
{
    public TemplateExpr Object { get; } = obj;
    public TemplateExpr Index { get; } = index;
}

/// <summary>Slice: obj[start..end], obj[start..], obj[..end]</summary>
public class TemplateSliceExpr(SourceSpan span, TemplateExpr obj, TemplateExpr? start, TemplateExpr? end) : TemplateExpr(span)
{
    public TemplateExpr Object { get; } = obj;
    public TemplateExpr? Start { get; } = start;
    public TemplateExpr? End { get; } = end;
}

/// <summary>Built-in function call: type_of(expr), lower(expr)</summary>
public class TemplateCallExpr(SourceSpan span, string functionName, IReadOnlyList<TemplateExpr> arguments) : TemplateExpr(span)
{
    public string FunctionName { get; } = functionName;
    public IReadOnlyList<TemplateExpr> Arguments { get; } = arguments;
}

// ─── Top-level generator nodes ───────────────────────────────────────────────

/// <summary>
/// #define(name, Param1: Kind, ...) { body }
/// </summary>
public class SourceGeneratorDefinitionNode : AstNode
{
    public SourceGeneratorDefinitionNode(
        SourceSpan span,
        string name,
        IReadOnlyList<GeneratorParameter> parameters,
        IReadOnlyList<TemplateNode> body) : base(span)
    {
        Name = name;
        Parameters = parameters;
        Body = body;
    }

    public string Name { get; }
    public IReadOnlyList<GeneratorParameter> Parameters { get; }
    public IReadOnlyList<TemplateNode> Body { get; }
}

/// <summary>
/// #name(arg1, arg2, ...) — source generator invocation.
/// </summary>
public class SourceGeneratorInvocationNode : AstNode
{
    public SourceGeneratorInvocationNode(
        SourceSpan span,
        string name,
        IReadOnlyList<GeneratorArgument> arguments) : base(span)
    {
        Name = name;
        Arguments = arguments;
    }

    public string Name { get; }
    public IReadOnlyList<GeneratorArgument> Arguments { get; }
}

/// <summary>
/// An argument to a source generator invocation.
/// Can be either an identifier or a type expression.
/// </summary>
public class GeneratorArgument : AstNode
{
    public GeneratorArgument(SourceSpan span, string? identifier, TypeNode? typeExpr) : base(span)
    {
        Identifier = identifier;
        TypeExpr = typeExpr;
    }

    public string? Identifier { get; }
    public TypeNode? TypeExpr { get; }
}
