using System.Collections.Concurrent;

namespace FLang.Core;

public class Compilation
{
    private readonly Lock _lock = new();
    private readonly ConcurrentDictionary<string, int> _modulePathToFileId = new();
    private readonly List<Source> _sourcesList = [];
    private int _fileIdCounter;
    private int _stringIdCounter;

    public string StdlibPath { get; set; } = "";

    public int AllocateStringId()
    {
        return Interlocked.Increment(ref _stringIdCounter) - 1;
    }

    public IReadOnlyList<Source> Sources
    {
        get
        {
            lock (_lock)
            {
                return _sourcesList.AsReadOnly();
            }
        }
    }

    public int AddSource(Source source)
    {
        var fileId = Interlocked.Increment(ref _fileIdCounter) - 1;

        lock (_lock)
        {
            _sourcesList.Add(source);
        }

        return fileId;
    }

    public string? TryResolveImportPath(IReadOnlyList<string> importPath)
    {
        // Convert import path to filepath: ["std", "io"] -> "stdlib/std/io.f"
        var relativePath = string.Join(Path.DirectorySeparatorChar, importPath) + ".f";
        var fullPath = Path.Combine(StdlibPath, relativePath);

        if (File.Exists(fullPath)) return fullPath;

        return null;
    }

    public bool IsModuleAlreadyLoaded(string modulePath)
    {
        return _modulePathToFileId.ContainsKey(modulePath);
    }

    public int? GetFileIdForModule(string modulePath)
    {
        return _modulePathToFileId.TryGetValue(modulePath, out var fileId) ? fileId : null;
    }

    public void RegisterModule(string modulePath, int fileId)
    {
        _modulePathToFileId.TryAdd(modulePath, fileId);
    }
}