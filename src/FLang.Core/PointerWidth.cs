namespace FLang.Core;

/// <summary>
/// Target architecture pointer width for isize/usize coercion rules.
/// </summary>
public enum PointerWidth
{
    Bits32,
    Bits64,
}


public static class PointerWidthExtensions
{
    extension(PointerWidth pw)
    {
        public int Size => pw switch
        {
            PointerWidth.Bits32 => 4,
            PointerWidth.Bits64 => 8,
            _ => throw new NotImplementedException(),
        };
    }
}