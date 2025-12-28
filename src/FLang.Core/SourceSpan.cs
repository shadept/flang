namespace FLang.Core;

public readonly record struct SourceSpan(int FileId, int Index, int Length)
{
    public static SourceSpan None => new(-1, 0, 0);
}