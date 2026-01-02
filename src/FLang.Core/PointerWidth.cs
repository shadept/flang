namespace FLang.Core;

/// <summary>
/// Target architecture pointer width for isize/usize coercion rules.
/// </summary>
public enum PointerWidth
{
    /// <summary>
    /// 32-bit pointer width (4 bytes).
    /// </summary>
    Bits32,

    /// <summary>
    /// 64-bit pointer width (8 bytes).
    /// </summary>
    Bits64,
}

/// <summary>
/// Extension methods for <see cref="PointerWidth"/> enumeration.
/// </summary>
public static class PointerWidthExtensions
{
    extension(PointerWidth pw)
    {
        /// <summary>
        /// Gets the size in bytes of this pointer width.
        /// </summary>
        public int Size => pw switch
        {
            PointerWidth.Bits32 => 4,
            PointerWidth.Bits64 => 8,
            _ => throw new NotImplementedException(),
        };
    }
}