namespace FLang.Core;

public readonly record struct SourceSpan(int FileId, int Index, int Length);