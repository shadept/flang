using FLang.Core;

namespace FLang.Frontend;

/// <summary>
/// Default source provider that reads from the file system.
/// </summary>
public class FileSystemSourceProvider : ISourceProvider
{
    public string? ReadSource(string filePath) => File.Exists(filePath) ? File.ReadAllText(filePath) : null;
    public bool Exists(string filePath) => File.Exists(filePath);
}
