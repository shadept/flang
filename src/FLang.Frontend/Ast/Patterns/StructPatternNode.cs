using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// A single field within a <see cref="StructPatternNode"/>:
/// <list type="bullet">
///   <item><c>{ x }</c> — bare identifier; binds <c>x</c> to the value of field <c>x</c>.</item>
///   <item><c>{ x = pat }</c> — recurses <paramref name="Pattern"/> against field <c>x</c>.</item>
/// </list>
/// </summary>
public sealed record StructFieldPattern(string FieldName, PatternNode Pattern, SourceSpan Span);

/// <summary>
/// Struct destructuring pattern. Syntax: <c>TypeName { f1, f2 = pat, .. }</c>.
/// Per RFC-010 §"Struct destructuring", patterns must mention every field
/// unless <c>..</c> is present.
/// </summary>
public class StructPatternNode : PatternNode
{
    public StructPatternNode(
        SourceSpan span,
        string typeName,
        List<StructFieldPattern> fields,
        bool hasRest) : base(span)
    {
        TypeName = typeName;
        Fields = fields;
        HasRest = hasRest;
    }

    /// <summary>Top-level type name (qualifier syntax not yet supported).</summary>
    public string TypeName { get; }

    public List<StructFieldPattern> Fields { get; }

    /// <summary>True if the pattern includes a <c>..</c> rest marker.</summary>
    public bool HasRest { get; }
}
