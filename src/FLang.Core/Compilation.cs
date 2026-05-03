using System.Collections.Concurrent;

namespace FLang.Core;

/// <summary>
/// Classifies a module by where it was loaded from. Used to scope project-level
/// features (project-global imports) so they apply only to project files.
/// </summary>
public enum ModuleOrigin
{
    /// <summary>Loaded from <see cref="Compilation.StdlibPath"/>.</summary>
    Stdlib,
    /// <summary>Loaded from the current project (entry point + <see cref="Compilation.ProjectSourceRoot"/>).</summary>
    Project,
    /// <summary>Reserved for future package system — third-party dependencies.</summary>
    External,
}

/// <summary>
/// Represents a compilation unit that manages source files, module resolution, and compilation-wide state.
/// Serves as the context object for passing state between compilation phases (Parser -> HmTypeChecker -> HmAstLowering).
/// </summary>
public class Compilation
{
    private readonly Lock _lock = new();
    private readonly ConcurrentDictionary<string, int> _modulePathToFileId = new();
    private readonly List<Source> _sourcesList = [];
    private int _fileIdCounter;
    private int _stringIdCounter;

    //=== Type System Registry (populated by HmTypeChecker, read by HmAstLowering) ===

    // Struct type registry
    public Dictionary<string, StructType> Structs { get; } = [];
    public Dictionary<string, StructType> StructSpecializations { get; } = [];
    public Dictionary<string, Dictionary<string, StructType>> StructsByModule { get; } = [];
    public Dictionary<string, StructType> StructsByFqn { get; } = [];

    // Enum type registry
    public Dictionary<string, EnumType> Enums { get; } = [];
    public Dictionary<string, EnumType> EnumSpecializations { get; } = [];
    public Dictionary<string, Dictionary<string, EnumType>> EnumsByModule { get; } = [];
    public Dictionary<string, EnumType> EnumsByFqn { get; } = [];

    // Module origin — classifies each module by where it was loaded from.
    // Used to scope project-level features (e.g. `[imports].global` from flang.toml)
    // so they apply only to project files, never to stdlib or third-party packages.
    public Dictionary<string, ModuleOrigin> ModuleOrigins { get; } = [];

    // Project-level imports injected into every Project-origin file's import list
    // before resolution. Sourced from flang.toml `[imports].global`.
    // Each entry is a dotted module path (e.g. "std.prelude").
    public IReadOnlyList<string> ProjectGlobalImports { get; set; } = [];

    // Module imports — module path -> set of imported module paths (private + public).
    // Populated by ModuleCompiler. A module always implicitly imports itself
    // (its own path is included).
    public Dictionary<string, HashSet<string>> ModuleImports { get; } = [];

    // Module re-exports — module path -> set of `pub import`ed module paths.
    // Subset of ModuleImports. Used to compute Visible[M].
    public Dictionary<string, HashSet<string>> ModuleReExports { get; } = [];

    // Cached visibility closure: module -> set of modules whose `pub` symbols are
    // visible to it. Computed lazily by GetVisibleModules. Includes the module
    // itself, its direct imports, and the transitive closure of pub-imports
    // through those imports.
    private readonly Dictionary<string, HashSet<string>> _visibleModulesCache = [];

    /// <summary>
    /// Returns the set of modules whose `pub` symbols are visible from
    /// <paramref name="modulePath"/>. Always includes the module itself.
    /// Result is cached. Returns an empty set if the module has no recorded imports.
    /// </summary>
    public HashSet<string> GetVisibleModules(string modulePath)
    {
        if (_visibleModulesCache.TryGetValue(modulePath, out var cached))
            return cached;

        var visible = new HashSet<string> { modulePath };
        if (!ModuleImports.TryGetValue(modulePath, out var direct))
        {
            _visibleModulesCache[modulePath] = visible;
            return visible;
        }

        foreach (var d in direct)
            visible.Add(d);

        // Transitive closure over `pub import` edges only.
        // Starting from each direct import, follow only pub-imports recursively.
        var stack = new Stack<string>(direct);
        var explored = new HashSet<string>(direct);
        while (stack.Count > 0)
        {
            var m = stack.Pop();
            if (!ModuleReExports.TryGetValue(m, out var reexports)) continue;
            foreach (var r in reexports)
            {
                if (visible.Add(r) && explored.Add(r))
                    stack.Push(r);
            }
        }

        _visibleModulesCache[modulePath] = visible;
        return visible;
    }

    /// <summary>
    /// Invalidates the visibility cache. Call after modifying ModuleImports / ModuleReExports.
    /// </summary>
    public void InvalidateVisibilityCache() => _visibleModulesCache.Clear();

    /// <summary>
    /// Records that <paramref name="modulePath"/> imports <paramref name="importedPath"/>.
    /// If <paramref name="isPublic"/> is true, this is a `pub import` re-export.
    /// Idempotent. Invalidates the visibility cache.
    /// </summary>
    public void RegisterImport(string modulePath, string importedPath, bool isPublic)
    {
        if (!ModuleImports.TryGetValue(modulePath, out var imports))
        {
            imports = [];
            ModuleImports[modulePath] = imports;
        }
        imports.Add(importedPath);

        if (isPublic)
        {
            if (!ModuleReExports.TryGetValue(modulePath, out var reexports))
            {
                reexports = [];
                ModuleReExports[modulePath] = reexports;
            }
            reexports.Add(importedPath);
        }

        InvalidateVisibilityCache();
    }

    // All instantiated types (for global type table generation)
    public HashSet<TypeBase> InstantiatedTypes { get; } = [];

    // Global constants registry (name -> type, populated during type checking)
    public Dictionary<string, TypeBase> GlobalConstants { get; } = [];

    // Lowered global constants (name -> GlobalValue, populated during AST lowering)
    public Dictionary<string, object> LoweredGlobalConstants { get; } = [];

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
    /// The project name from flang.toml (e.g., "calc"). When set, the first import
    /// segment matching this name resolves relative to <see cref="ProjectSourceRoot"/>.
    /// </summary>
    public string? ProjectName { get; set; }

    /// <summary>
    /// The resolved source root directory for the project (e.g., /path/to/calc/src).
    /// Used with <see cref="ProjectName"/> for project-name-based import resolution.
    /// </summary>
    public string? ProjectSourceRoot { get; set; }

    /// <summary>
    /// Structured compile-time context for #if directives.
    /// Evaluated as a tree: platform.os, runtime.testing, runtime.env["KEY"], etc.
    /// Values can be strings, bools, longs, or nested Dictionary&lt;string, object&gt;.
    /// </summary>
    public Dictionary<string, object> CompileTimeContext { get; set; } = [];

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
    /// <param name="sourceProvider">Optional source provider for file existence checks.</param>
    /// <returns>The resolved file path if found; otherwise, null.</returns>
    public string? TryResolveImportPath(IReadOnlyList<string> importPath, ISourceProvider? sourceProvider = null)
    {
        // Project-name-based resolution: if the first segment matches the project name,
        // resolve the rest relative to the project source root.
        // e.g., import calc.ast -> <ProjectSourceRoot>/ast.f
        if (ProjectName != null && ProjectSourceRoot != null
            && importPath.Count > 1 && importPath[0] == ProjectName)
        {
            var projectRelativePath = string.Join(Path.DirectorySeparatorChar, importPath.Skip(1)) + ".f";
            var fullPath = Path.Combine(ProjectSourceRoot, projectRelativePath);
            if (sourceProvider != null ? sourceProvider.Exists(fullPath) : File.Exists(fullPath))
                return fullPath;
        }

        // Filesystem-based resolution: search include paths in order (stdlib, working dir)
        var relativePath = string.Join(Path.DirectorySeparatorChar, importPath) + ".f";
        foreach (var basePath in IncludePaths)
        {
            var fullPath = Path.Combine(basePath, relativePath);
            if (sourceProvider != null ? sourceProvider.Exists(fullPath) : File.Exists(fullPath))
                return fullPath;
        }
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
