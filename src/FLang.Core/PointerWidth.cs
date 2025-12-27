namespace FLang.Core;

/// <summary>
/// Target architecture pointer width for isize/usize coercion rules.
/// </summary>
public enum PointerWidth
{
    Bits32, // isize=i32, usize=u32
    Bits64,  // isize=i64, usize=u64
}
