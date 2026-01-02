using System.Collections.Immutable;

namespace FLang.Core;

/// <summary>
/// Represents a source file with its text content and precomputed line ending positions.
/// </summary>
public sealed class Source
{
    /// <summary>
    /// Initializes a new instance of the <see cref="Source"/> class.
    /// </summary>
    /// <param name="text">The full-text content of the source file.</param>
    /// <param name="fileName">The name or path of the source file.</param>
    public Source(string text, string fileName)
    {
        Text = text;
        FileName = fileName;
        LineEndings = CalculateLineEndings(text);
    }

    /// <summary>
    /// Gets the full text content of the source file.
    /// </summary>
    public string Text { get; }

    /// <summary>
    /// Gets the name or path of the source file.
    /// </summary>
    public string FileName { get; }

    /// <summary>
    /// Gets the precomputed positions of all line endings (newline characters) in the text.
    /// </summary>
    public ImmutableArray<int> LineEndings { get; }

    /// <summary>
    /// Calculates the positions of all line endings in the given text.
    /// </summary>
    /// <param name="text">The source text to analyze.</param>
    /// <returns>An immutable array of positions where newline characters occur.</returns>
    private static ImmutableArray<int> CalculateLineEndings(string text)
    {
        var lineEndings = new List<int>();
        for (var i = 0; i < text.Length; i++)
            if (text[i] == '\n')
                lineEndings.Add(i);

        return [.. lineEndings];
    }

    /// <summary>
    /// Gets the zero-based line number for a given position in the source text.
    /// </summary>
    /// <param name="position">The zero-based character position in the source text.</param>
    /// <returns>The zero-based line number.</returns>
    public int GetLineNumber(int position)
    {
        var line = LineEndings.BinarySearch(position);
        return line >= 0 ? line : ~line;
    }

    /// <summary>
    /// Gets the zero-based column number for a given position in the source text.
    /// </summary>
    /// <param name="position">The zero-based character position in the source text.</param>
    /// <returns>The zero-based column number (offset from start of line).</returns>
    public int GetColumnNumber(int position)
    {
        var lineNumber = GetLineNumber(position);
        var lineStart = GetLineStart(lineNumber);
        return position - lineStart;
    }

    /// <summary>
    /// Gets the starting position of a line.
    /// </summary>
    /// <param name="lineNumber">The zero-based line number.</param>
    /// <returns>The zero-based position where the line starts.</returns>
    public int GetLineStart(int lineNumber)
    {
        if (lineNumber == 0)
            return 0;
        if (lineNumber - 1 < LineEndings.Length)
            return LineEndings[lineNumber - 1] + 1; // After the newline
        return Text.Length;
    }

    /// <summary>
    /// Gets the ending position of a line (position of the newline character).
    /// </summary>
    /// <param name="lineNumber">The zero-based line number.</param>
    /// <returns>The zero-based position where the line ends.</returns>
    public int GetLineEnd(int lineNumber)
    {
        if (lineNumber < LineEndings.Length)
            return LineEndings[lineNumber];
        return Text.Length;
    }

    /// <summary>
    /// Gets the text content of a specific line (without the newline character).
    /// </summary>
    /// <param name="lineNumber">The zero-based line number.</param>
    /// <returns>The text content of the line.</returns>
    public string GetLineText(int lineNumber)
    {
        var start = GetLineStart(lineNumber);
        var end = GetLineEnd(lineNumber);
        if (start >= Text.Length)
            return "";
        var length = end - start;
        return Text.Substring(start, length);
    }

    /// <summary>
    /// Gets both the line number and column number for a given position.
    /// </summary>
    /// <param name="position">The zero-based character position in the source text.</param>
    /// <returns>A tuple containing the zero-based line and column numbers.</returns>
    public (int Line, int Column) GetLineAndColumn(int position)
    {
        var line = GetLineNumber(position);
        var column = GetColumnNumber(position);
        return (line, column);
    }
}