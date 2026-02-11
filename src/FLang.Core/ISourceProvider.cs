namespace FLang.Core;

/// <summary>
/// Abstracts file I/O for module loading, allowing the LSP to overlay editor buffers.
/// </summary>
public interface ISourceProvider
{
    /// <summary>
    /// Returns file text, or null if not found.
    /// </summary>
    string? ReadSource(string filePath);

    /// <summary>
    /// Returns true if the file exists (on disk or in editor buffers).
    /// </summary>
    bool Exists(string filePath);
}
