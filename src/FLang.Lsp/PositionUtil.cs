using FLang.Core;
using OmniSharp.Extensions.LanguageServer.Protocol.Models;
using Range = OmniSharp.Extensions.LanguageServer.Protocol.Models.Range;

namespace FLang.Lsp;

public static class PositionUtil
{
    /// <summary>
    /// Convert a FLang SourceSpan to an LSP Range.
    /// </summary>
    public static Range? ToLspRange(SourceSpan span, Compilation compilation)
    {
        if (span.FileId < 0 || span.FileId >= compilation.Sources.Count)
            return null;

        var source = compilation.Sources[span.FileId];
        var (startLine, startCol) = source.GetLineAndColumn(span.Index);
        var endIndex = Math.Min(span.Index + span.Length, source.Text.Length);
        var (endLine, endCol) = source.GetLineAndColumn(endIndex);

        return new Range(
            new Position(startLine, startCol),
            new Position(endLine, endCol));
    }

    /// <summary>
    /// Convert an LSP Position (line, character) to an absolute character offset in a Source.
    /// </summary>
    public static int ToSourcePosition(Position position, Source source)
    {
        var lineStart = source.GetLineStart(position.Line);
        return lineStart + position.Character;
    }

    /// <summary>
    /// Find the file ID in a Compilation for a given file path.
    /// </summary>
    public static int? FindFileId(string filePath, Compilation compilation)
    {
        var normalized = Path.GetFullPath(filePath);
        for (var i = 0; i < compilation.Sources.Count; i++)
        {
            if (Path.GetFullPath(compilation.Sources[i].FileName) == normalized)
                return i;
        }
        return null;
    }
}
