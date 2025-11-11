using System.Collections.Concurrent;
using System.Collections.Generic;

namespace FLang.Core;

public class Compilation
{
    private readonly ConcurrentBag<Source> _sources = new();
    private readonly List<Source> _sourcesList = new();
    private readonly ConcurrentDictionary<string, int> _modulePathToFileId = new();
    private readonly object _lock = new object();
    private int _fileIdCounter = 0;

    public string StdlibPath { get; set; } = "";

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
            _sources.Add(source);
            _sourcesList.Add(source);
        }

        return fileId;
    }

    public string? TryResolveImportPath(IReadOnlyList<string> importPath)
    {
        // Convert import path to file path: ["std", "io"] -> "stdlib/std/io.f"
        var relativePath = string.Join(System.IO.Path.DirectorySeparatorChar, importPath) + ".f";
        var fullPath = System.IO.Path.Combine(StdlibPath, relativePath);

        if (System.IO.File.Exists(fullPath))
        {
            return fullPath;
        }

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
