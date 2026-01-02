namespace FLang.Core;

/// <summary>
/// Represents a span of text in a source file, identified by file ID, starting index, and length.
/// </summary>
/// <param name="FileId">The unique identifier of the <see cref="Source"/> containing this span.</param>
/// <param name="Index">The zero-based starting position of this span in the source text.</param>
/// <param name="Length">The length of this span in characters.</param>
public readonly record struct SourceSpan(int FileId, int Index, int Length)
{
    /// <summary>
    /// Gets a special SourceSpan value representing no source location.
    /// Used when source information is unavailable (e.g., compiler-generated diagnostics).
    /// </summary>
    public static SourceSpan None => new(-1, 0, 0);

    /// <summary>
    /// Combines multiple spans into a single span that encompasses all of them.
    /// The resulting span starts at the first span's Index and ends at the last span's end position.
    /// All spans must be from the same file.
    /// </summary>
    /// <param name="first">The first span (leftmost in the source).</param>
    /// <param name="last">The last span (rightmost in the source).</param>
    /// <returns>A new <see cref="SourceSpan"/> that encompasses both input spans.</returns>
    /// <exception cref="ArgumentException">Thrown when spans are from different files.</exception>
    public static SourceSpan Combine(SourceSpan first, SourceSpan last)
    {
        if (first.FileId != last.FileId)
            throw new ArgumentException("Cannot combine spans from different files");

        var startIndex = first.Index;
        var endIndex = last.Index + last.Length;
        var length = endIndex - startIndex;

        return new SourceSpan(first.FileId, startIndex, length);
    }
}