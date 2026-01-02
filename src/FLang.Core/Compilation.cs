using System.Collections.Concurrent;

namespace FLang.Core;

/// <summary>
/// Represents a compilation unit that manages source files, module resolution, and compilation-wide state.
/// </summary>
public class Compilation
{
    private readonly Lock _lock = new();
    private readonly ConcurrentDictionary<string, int> _modulePathToFileId = new();
    private readonly List<Source> _sourcesList = [];
    private int _fileIdCounter;
    private int _stringIdCounter;

    /// <summary>
    /// Gets or sets the path to the standard library directory.
    /// </summary>
    public string StdlibPath { get; set; } = "";

    /// <summary>
    /// Gets or sets the working directory for resolving relative paths.
    /// </summary>
    public string WorkingDirectory { get; set; } = "";

    /// <summary>
    /// Gets or sets the list of additional include paths for module resolution.
    /// </summary>
    public List<string> IncludePaths { get; set; } = [];

    /// <summary>
    /// Allocates a unique string identifier for string literals.
    /// Thread-safe.
    /// </summary>
    /// <returns>A unique integer identifier for a string literal.</returns>
    public int AllocateStringId()
    {
        return Interlocked.Increment(ref _stringIdCounter) - 1;
    }

    /// <summary>
    /// Gets a read-only view of all source files in this compilation.
    /// </summary>
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

    /// <summary>
    /// Adds a source file to this compilation and returns its unique file ID.
    /// Thread-safe.
    /// </summary>
    /// <param name="source">The source file to add.</param>
    /// <returns>A unique file ID for the added source.</returns>
    public int AddSource(Source source)
    {
        var fileId = Interlocked.Increment(ref _fileIdCounter) - 1;

        lock (_lock)
        {
            _sourcesList.Add(source);
        }

        return fileId;
    }

    /// <summary>
    /// Attempts to resolve an import path to a file system path.
    /// </summary>
    /// <param name="importPath">The import path segments (e.g., ["std", "io"]).</param>
    /// <returns>The resolved file path if found; otherwise, null.</returns>
    public string? TryResolveImportPath(IReadOnlyList<string> importPath)
    {
        // Convert import path to filepath: ["std", "io"] -> "stdlib/std/io.f"
        var relativePath = string.Join(Path.DirectorySeparatorChar, importPath) + ".f";
        var fullPath = Path.Combine(StdlibPath, relativePath);
        if (File.Exists(fullPath)) return fullPath;
        return null;
    }

    /// <summary>
    /// Checks whether a module at the given path has already been loaded.
    /// </summary>
    /// <param name="modulePath">The file system path of the module.</param>
    /// <returns>True if the module is already loaded; otherwise, false.</returns>
    public bool IsModuleAlreadyLoaded(string modulePath)
    {
        return _modulePathToFileId.ContainsKey(modulePath);
    }

    /// <summary>
    /// Gets the file ID for a previously loaded module.
    /// </summary>
    /// <param name="modulePath">The file system path of the module.</param>
    /// <returns>The file ID if the module is loaded; otherwise, null.</returns>
    public int? GetFileIdForModule(string modulePath)
    {
        return _modulePathToFileId.TryGetValue(modulePath, out var fileId) ? fileId : null;
    }

    /// <summary>
    /// Registers a module path with its corresponding file ID.
    /// Thread-safe.
    /// </summary>
    /// <param name="modulePath">The file system path of the module.</param>
    /// <param name="fileId">The file ID assigned to this module.</param>
    public void RegisterModule(string modulePath, int fileId)
    {
        _modulePathToFileId.TryAdd(modulePath, fileId);
    }
}
