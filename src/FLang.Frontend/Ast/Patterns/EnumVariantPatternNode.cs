using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Represents an enum variant pattern for destructuring enum values.
/// Syntax: EnumName.Variant or Variant (short form)
///         EnumName.Variant(pattern1, pattern2) or Variant(pattern1, pattern2)
/// </summary>
public class EnumVariantPatternNode : PatternNode
{
    public EnumVariantPatternNode(
        SourceSpan span,
        string? enumName,
        string variantName,
        List<PatternNode> subPatterns) : base(span)
    {
        EnumName = enumName;
        VariantName = variantName;
        SubPatterns = subPatterns;
    }

    /// <summary>
    /// Fully qualified enum name (null for short form)
    /// </summary>
    public string? EnumName { get; }
    
    public string VariantName { get; }
    
    /// <summary>
    /// Sub-patterns for destructuring variant payload fields
    /// </summary>
    public List<PatternNode> SubPatterns { get; }
}

