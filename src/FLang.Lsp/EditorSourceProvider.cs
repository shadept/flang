using FLang.Core;

namespace FLang.Lsp;

/// <summary>
/// Source provider that overlays editor buffers on top of the file system.
/// Open documents are served from memory; everything else falls back to disk.
/// </summary>
public class EditorSourceProvider(Dictionary<string, string> openDocuments) : ISourceProvider
{
    public string? ReadSource(string filePath)
    {
        var normalized = Path.GetFullPath(filePath);
        return openDocuments.TryGetValue(normalized, out var content)
            ? content
            : (File.Exists(filePath) ? File.ReadAllText(filePath) : null);
    }

    public bool Exists(string filePath)
    {
        var normalized = Path.GetFullPath(filePath);
        return openDocuments.ContainsKey(normalized) || File.Exists(filePath);
    }
}
