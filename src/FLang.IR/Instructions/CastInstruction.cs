using FLang.Core;

namespace FLang.IR.Instructions;

/// <summary>
/// Converts a value from one type to another.
/// Supports various cast operations including:
/// - Integer casts (sign extension, truncation, zero extension)
/// - Pointer casts
/// - String to slice conversions
/// - Slice to pointer conversions
/// The specific cast behavior depends on the source and target types.
/// </summary>
public class CastInstruction : Instruction
{
    public CastInstruction(Value source, FType targetType, Value result)
    {
        Source = source;
        TargetType = targetType;
        Result = result;
    }

    /// <summary>
    /// The value to cast from.
    /// </summary>
    public Value Source { get; }

    /// <summary>
    /// The type to cast to.
    /// </summary>
    public FType TargetType { get; }

    /// <summary>
    /// The result value produced by this cast.
    /// </summary>
    public Value Result { get; }
}
