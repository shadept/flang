using FLang.Core;
using OmniSharp.Extensions.LanguageServer.Protocol;
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
    /// URI scheme under which template-expansion output is served as a virtual
    /// (read-only) document; the path is the origin's `.generated.f` path. The
    /// editor fetches the text via the `flang/generatedContent` request.
    /// </summary>
    public const string GeneratedScheme = "flang-generated";

    public static bool IsGeneratedPath(string path) =>
        path.EndsWith(".generated.f", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Convert a FLang SourceSpan to an LSP Location. Spans inside generated
    /// sources point at the <see cref="GeneratedScheme"/> virtual document.
    /// </summary>
    public static Location? SpanToLocation(SourceSpan span, Compilation compilation)
    {
        if (span.FileId < 0 || span.FileId >= compilation.Sources.Count)
            return null;

        var source = compilation.Sources[span.FileId];
        var range = ToLspRange(span, compilation);
        if (range == null) return null;

        var uri = IsGeneratedPath(source.FileName)
            ? DocumentUri.From($"{GeneratedScheme}://{source.FileName}")
            : DocumentUri.FromFileSystemPath(source.FileName);
        return new Location { Uri = uri, Range = range };
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
