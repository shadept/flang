using System.Collections.Immutable;

namespace FLang.Core;

public sealed class Source
{
    public Source(string text, string fileName)
    {
        Text = text;
        FileName = fileName;
        LineEndings = CalculateLineEndings(text);
    }

    public string Text { get; }
    public string FileName { get; }
    public ImmutableArray<int> LineEndings { get; }

    private static ImmutableArray<int> CalculateLineEndings(string text)
    {
        var lineEndings = new List<int>();
        for (var i = 0; i < text.Length; i++)
            if (text[i] == '\n')
                lineEndings.Add(i);

        return [.. lineEndings];
    }

    public int GetLineNumber(int position)
    {
        var line = LineEndings.BinarySearch(position);
        return line >= 0 ? line : ~line;
    }

    public int GetColumnNumber(int position)
    {
        var lineNumber = GetLineNumber(position);
        var lineStart = GetLineStart(lineNumber);
        return position - lineStart;
    }

    public int GetLineStart(int lineNumber)
    {
        if (lineNumber == 0)
            return 0;
        if (lineNumber - 1 < LineEndings.Length)
            return LineEndings[lineNumber - 1] + 1; // After the newline
        return Text.Length;
    }

    public int GetLineEnd(int lineNumber)
    {
        if (lineNumber < LineEndings.Length)
            return LineEndings[lineNumber];
        return Text.Length;
    }

    public string GetLineText(int lineNumber)
    {
        var start = GetLineStart(lineNumber);
        var end = GetLineEnd(lineNumber);
        if (start >= Text.Length)
            return "";
        var length = end - start;
        return Text.Substring(start, length);
    }

    public (int Line, int Column) GetLineAndColumn(int position)
    {
        var line = GetLineNumber(position);
        var column = GetColumnNumber(position);
        return (line, column);
    }
}