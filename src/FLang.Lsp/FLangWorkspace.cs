using System.Runtime.InteropServices;
using FLang.Core;
using FLang.Core.Project;
using FLang.Frontend;
using FLang.Frontend.Ast.Declarations;
using FLang.Semantics;
using Microsoft.Extensions.Logging;
using OmniSharp.Extensions.LanguageServer.Protocol;
using OmniSharp.Extensions.LanguageServer.Protocol.Document;
using OmniSharp.Extensions.LanguageServer.Protocol.Models;
using OmniSharp.Extensions.LanguageServer.Protocol.Server;
using Diagnostic = FLang.Core.Diagnostic;
using DiagnosticSeverity = FLang.Core.DiagnosticSeverity;

namespace FLang.Lsp;

/// <summary>
/// One shared whole-program analysis. Despite the historical name, this is
/// per analysis root (a project, or the workspace directory for project-less
/// files), never per file: every file of the root maps to the same instance.
/// </summary>
public record FileAnalysisResult(
    IReadOnlyList<Diagnostic> Diagnostics,
    Compilation Compilation,
    Dictionary<string, ModuleNode> ParsedModules,
    TypeCheckResult? TypeChecker,
    IReadOnlyDictionary<string, string> GeneratedFiles);

/// <summary>
/// Manages open documents and analysis results for the LSP.
///
/// Memory model: exactly one <see cref="FileAnalysisResult"/> is retained per
/// analysis root, replaced wholesale on re-analysis. The previous design kept
/// one whole-program analysis per FILE (compilation + full module forest +
/// inference tables each, nothing shared), which grew to gigabytes on any
/// non-trivial workspace and made indexing O(files × whole-program checks).
/// </summary>
public class FLangWorkspace
{
    private readonly Dictionary<string, string> _openDocuments = [];
    // Keyed by analysis root (project root, workspace dir, or a loose file's
    // own path — see AnalysisKeyFor).
    private readonly Dictionary<string, FileAnalysisResult> _projectAnalyses = [];
    private readonly Dictionary<string, Task> _pendingAnalyses = [];
    // Debounce state for external (watched-file) changes, keyed by analysis
    // root: agents and git checkouts touch many files in one burst, which must
    // coalesce into a single re-analysis per root.
    private readonly Dictionary<string, CancellationTokenSource> _watchDebounce = [];
    private readonly Lock _lock = new();
    private readonly ILanguageServerFacade _server;
    // Cache entries are invalidated when flang.toml's mtime changes — the LSP
    // does not see TOML saves through its flang-only document handler, so an
    // mtime check is required to pick up edits made outside or via clients
    // that don't forward non-flang saves.
    private readonly Dictionary<string, (FlangProject Project, DateTime LastWriteUtc)> _projectCache = [];

    public string? StdlibPath { get; set; }
    public string? WorkingDirectory { get; set; }

    public FLangWorkspace(ILanguageServerFacade server, LspConfig config)
    {
        _server = server;
        StdlibPath = config.StdlibPath;
    }

    public void UpdateDocument(string filePath, string content)
    {
        var normalized = Path.GetFullPath(filePath);
        lock (_lock)
        {
            _openDocuments[normalized] = content;
        }
    }

    public void CloseDocument(string filePath)
    {
        var normalized = Path.GetFullPath(filePath);
        lock (_lock)
        {
            _openDocuments.Remove(normalized);
        }
    }

    /// <summary>
    /// The analysis root a file belongs to: its project's root when one
    /// exists, else the workspace directory when the file lives under it,
    /// else the file itself (a truly loose file). One shared analysis is
    /// kept per root.
    /// </summary>
    private string AnalysisKeyFor(string normalizedPath, out (FlangProject Project, string ProjectRoot)? projectInfo)
    {
        projectInfo = FindProjectForFile(normalizedPath);
        if (projectInfo is { } pi)
            return Path.GetFullPath(pi.ProjectRoot);

        if (!string.IsNullOrEmpty(WorkingDirectory))
        {
            var workDir = Path.GetFullPath(WorkingDirectory);
            if (normalizedPath.StartsWith(workDir + Path.DirectorySeparatorChar,
                    OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))
                return workDir;
        }

        return normalizedPath;
    }

    public FileAnalysisResult? GetAnalysis(string filePath)
    {
        var normalized = Path.GetFullPath(filePath);
        var key = AnalysisKeyFor(normalized, out _);
        lock (_lock)
        {
            return _projectAnalyses.GetValueOrDefault(key);
        }
    }

    /// <summary>
    /// Snapshot of every retained analysis — one per analysis root. Used by
    /// find-references / workspace symbols; each entry already spans its
    /// root's whole module graph (project files, deps, reached stdlib).
    /// </summary>
    /// <summary>Text of a generated virtual document, from whichever analysis produced it.</summary>
    public string? GetGeneratedContent(string generatedPath)
    {
        var normalized = Path.GetFullPath(generatedPath);
        foreach (var analysis in GetAllAnalyses())
            foreach (var (path, text) in analysis.GeneratedFiles)
                if (string.Equals(Path.GetFullPath(path), normalized, StringComparison.OrdinalIgnoreCase))
                    return text;
        return null;
    }

    public IReadOnlyList<FileAnalysisResult> GetAllAnalyses()
    {
        lock (_lock)
        {
            return [.. _projectAnalyses.Values];
        }
    }

    /// <summary>
    /// Returns the analysis result, waiting for any pending analysis to complete first.
    /// Use this in handlers that need up-to-date results (InlayHint, Hover, etc.).
    /// </summary>
    public async Task<FileAnalysisResult?> GetAnalysisAsync(string filePath)
    {
        var normalized = Path.GetFullPath(filePath);
        var key = AnalysisKeyFor(normalized, out _);
        Task? pending;
        lock (_lock)
        {
            _pendingAnalyses.TryGetValue(key, out pending);
        }
        if (pending != null)
        {
            try { await pending; }
            catch { /* analysis errors are handled internally */ }
        }
        lock (_lock)
        {
            return _projectAnalyses.GetValueOrDefault(key);
        }
    }

    public void SetPendingAnalysis(string filePath, Task task)
    {
        var normalized = Path.GetFullPath(filePath);
        var key = AnalysisKeyFor(normalized, out _);
        lock (_lock)
        {
            _pendingAnalyses[key] = task;
        }
    }

    public void AnalyzeFile(string filePath)
    {
        var normalized = Path.GetFullPath(filePath);
        var key = AnalysisKeyFor(normalized, out var projectInfo);
        AnalyzeRootInternal(key, normalized, projectInfo);
    }

    /// <summary>
    /// Called for filesystem changes reported by the client's watcher
    /// (workspace/didChangeWatchedFiles) — edits made outside the editor:
    /// external tools, agents, git operations. Open-document buffers still
    /// win over disk during analysis, so events for open files are harmless.
    /// Each affected root is re-analyzed once, after a short quiet period.
    /// </summary>
    public void NotifyWatchedFilesChanged(IReadOnlyList<string> changedPaths)
    {
        var tomlChanged = changedPaths.Any(p =>
            Path.GetFileName(p).Equals("flang.toml", StringComparison.OrdinalIgnoreCase));
        if (tomlChanged)
            InvalidateProjectCache();

        var roots = new Dictionary<string, (string Rep, (FlangProject Project, string ProjectRoot)? Project)>();
        foreach (var path in changedPaths)
        {
            if (!path.EndsWith(".f", StringComparison.OrdinalIgnoreCase)) continue;
            string normalized;
            try { normalized = Path.GetFullPath(path); }
            catch { continue; }
            var key = AnalysisKeyFor(normalized, out var pi);
            roots.TryAdd(key, (normalized, pi));
        }

        // A toml-only change with no .f edits: the config cache is already
        // invalidated above and FindProjectForFile's mtime check picks the
        // new config up on the next analysis of each root.
        foreach (var (key, info) in roots)
            ScheduleRootReanalysis(key, info.Rep, info.Project);
    }

    private void ScheduleRootReanalysis(string key, string representative, (FlangProject Project, string ProjectRoot)? projectInfo)
    {
        var cts = new CancellationTokenSource();
        lock (_lock)
        {
            if (_watchDebounce.TryGetValue(key, out var previous))
                previous.Cancel();
            _watchDebounce[key] = cts;
        }

        var task = Task.Run(async () =>
        {
            try { await Task.Delay(400, cts.Token); }
            catch (TaskCanceledException) { return; }
            lock (_lock) { _watchDebounce.Remove(key); }
            FLangLanguageServer.Log($"watched-file change: re-analyzing root {key}");
            AnalyzeRootInternal(key, representative, projectInfo);
        });
        lock (_lock) { _pendingAnalyses[key] = task; }
    }

    /// <summary>
    /// Eagerly analyze every <c>.f</c> file the project(s) under the workspace
    /// can see, populating the workspace-wide picture needed by
    /// <c>workspace/symbol</c> and find-references. Without this, only files
    /// transitively reachable from already-opened editor documents are visible.
    /// <para>
    /// Strategy: find every <c>flang.toml</c> at or under <c>WorkingDirectory</c>
    /// (plus any ancestor toml that contains the workspace), and index each
    /// project's source root. Stdlib is deliberately <i>not</i> scanned directly
    /// — modules from <c>StdlibPath</c> are only pulled in when a project
    /// transitively imports them (e.g. via the auto-imported prelude), so a
    /// project that doesn't use stdlib doesn't pay for it.
    /// </para>
    /// <para>
    /// Falls back to scanning <c>WorkingDirectory</c> directly when no project
    /// file is discoverable, so non-project workspaces still get indexed.
    /// Runs synchronously; callers should dispatch onto a background task if
    /// they don't want to block.
    /// </para>
    /// </summary>
    public void IndexWorkspace()
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        if (string.IsNullOrEmpty(WorkingDirectory))
        {
            FLangLanguageServer.Log("IndexWorkspace: no WorkingDirectory set, skipping");
            return;
        }

        var roots = new List<string>();
        var projects = DiscoverProjectSourceRoots(WorkingDirectory);
        if (projects.Count > 0)
        {
            roots.AddRange(projects);
            FLangLanguageServer.Log($"IndexWorkspace: {projects.Count} project source root(s) -> {string.Join(", ", projects)}");
        }
        else
        {
            roots.Add(WorkingDirectory);
            FLangLanguageServer.Log($"IndexWorkspace: no flang.toml found, falling back to scan of {WorkingDirectory}");
        }

        // One shared whole-program analysis per root: the first file under a
        // root determines its analysis key (project root or workspace dir),
        // and the analysis itself pulls in every file of that root.
        var analyzed = 0;
        var skipped = 0;
        foreach (var root in roots)
        {
            if (!Directory.Exists(root)) continue;

            string? representative = null;
            try
            {
                representative = EnumerateFlangFiles(root)
                    .FirstOrDefault(f => !PositionUtil.IsGeneratedPath(f));
            }
            catch (Exception ex)
            {
                FLangLanguageServer.Log($"  enumerate failed for {root}: {ex.Message}");
                continue;
            }
            if (representative == null) continue;

            var normalized = Path.GetFullPath(representative);
            var key = AnalysisKeyFor(normalized, out var projectInfo);
            lock (_lock)
            {
                if (_projectAnalyses.ContainsKey(key)) { skipped++; continue; }
            }

            try
            {
                AnalyzeRootInternal(key, normalized, projectInfo);
                analyzed++;
            }
            catch (Exception ex)
            {
                FLangLanguageServer.Log($"  index analyze failed for {root}: {ex.Message}");
            }
        }

        FLangLanguageServer.Log($"IndexWorkspace: {analyzed} root(s) analyzed, {skipped} already-cached in {sw.ElapsedMilliseconds}ms");
    }

    /// <summary>
    /// Returns every project source root (absolute) reachable from <paramref
    /// name="workspaceDir"/>: any <c>flang.toml</c> at or under it (monorepo
    /// case), and any ancestor toml that already contains it (user opened a
    /// subdirectory of a project). When a project's source glob can't be
    /// resolved to a static prefix (e.g. <c>**/*.f</c> with no leading
    /// directory), the project root itself is used.
    /// </summary>
    private static List<string> DiscoverProjectSourceRoots(string workspaceDir)
    {
        var found = new List<string>();
        var addedProjectRoots = new HashSet<string>(OperatingSystem.IsWindows()
            ? StringComparer.OrdinalIgnoreCase
            : StringComparer.Ordinal);

        void TryAddProject(string tomlPath)
        {
            var projectRoot = Path.GetFullPath(Path.GetDirectoryName(tomlPath)!);
            if (!addedProjectRoots.Add(projectRoot)) return;
            try
            {
                var project = ProjectLoader.Load(tomlPath);
                var sourceRoot = ProjectLoader.ResolveSourceRoot(project.Project.Source, projectRoot);
                found.Add(sourceRoot ?? projectRoot);
            }
            catch (Exception ex)
            {
                FLangLanguageServer.Log($"  failed to load {tomlPath}: {ex.Message}");
            }
        }

        // Walk-up: workspaceDir may be inside a project.
        var ancestorToml = ProjectLoader.FindProjectFile(workspaceDir);
        if (ancestorToml != null) TryAddProject(ancestorToml);

        // Walk-down: monorepo or "workspace folder with multiple projects".
        foreach (var toml in EnumerateProjectFiles(workspaceDir))
            TryAddProject(toml);

        return found;
    }

    private static IEnumerable<string> EnumerateProjectFiles(string root)
    {
        var stack = new Stack<string>();
        stack.Push(root);
        while (stack.Count > 0)
        {
            var dir = stack.Pop();
            string candidate;
            try { candidate = Path.Combine(dir, ProjectLoader.ProjectFileName); }
            catch { continue; }
            if (File.Exists(candidate)) yield return candidate;

            string[] subdirs;
            try { subdirs = Directory.GetDirectories(dir); }
            catch { subdirs = []; }
            foreach (var sub in subdirs)
            {
                var name = Path.GetFileName(sub);
                if (IsIgnoredDirectory(name)) continue;
                stack.Push(sub);
            }
        }
    }

    /// <summary>
    /// Yield every <c>.f</c> file under <paramref name="root"/>, skipping build
    /// artifact and version control directories. Done as a recursive walk
    /// (rather than <c>SearchOption.AllDirectories</c>) so we can prune
    /// uninteresting subtrees up-front instead of paying the IO to enumerate them.
    /// </summary>
    private static IEnumerable<string> EnumerateFlangFiles(string root)
    {
        var stack = new Stack<string>();
        stack.Push(root);
        while (stack.Count > 0)
        {
            var dir = stack.Pop();
            string[] entries;
            try { entries = Directory.GetFiles(dir, "*.f"); }
            catch { entries = []; }
            foreach (var f in entries) yield return f;

            string[] subdirs;
            try { subdirs = Directory.GetDirectories(dir); }
            catch { subdirs = []; }
            foreach (var sub in subdirs)
            {
                var name = Path.GetFileName(sub);
                if (IsIgnoredDirectory(name)) continue;
                stack.Push(sub);
            }
        }
    }

    private static bool IsIgnoredDirectory(string name) => name switch
    {
        "bin" or "obj" or "dist" or "node_modules"
            or ".git" or ".vs" or ".vscode" or ".idea"
            or ".test-artifacts" or ".scratch" or ".claude"
            or "packages" => true,
        _ => name.StartsWith('.'),
    };

    public void InvalidateProjectCache()
    {
        lock (_lock) { _projectCache.Clear(); }
    }

    private (FlangProject Project, string ProjectRoot)? FindProjectForFile(string filePath)
    {
        var dir = Path.GetDirectoryName(filePath);
        if (dir == null) return null;

        var tomlPath = ProjectLoader.FindProjectFile(dir);
        if (tomlPath == null) return null;

        DateTime currentMtime;
        try { currentMtime = File.GetLastWriteTimeUtc(tomlPath); }
        catch { currentMtime = DateTime.MinValue; }

        lock (_lock)
        {
            if (!_projectCache.TryGetValue(tomlPath, out var entry) || entry.LastWriteUtc != currentMtime)
            {
                try
                {
                    var loaded = ProjectLoader.Load(tomlPath);
                    entry = (loaded, currentMtime);
                    _projectCache[tomlPath] = entry;
                }
                catch (Exception ex)
                {
                    FLangLanguageServer.Log($"  Failed to load {tomlPath}: {ex.Message}");
                    return null;
                }
            }

            return (entry.Project, Path.GetDirectoryName(tomlPath)!);
        }
    }

    /// <summary>
    /// Runs the shared whole-program analysis for one root. Entry points are
    /// every .f file under the root (so unimported files still get symbols and
    /// diagnostics); the result replaces the root's previous analysis.
    /// </summary>
    private void AnalyzeRootInternal(string key, string normalized, (FlangProject Project, string ProjectRoot)? projectInfo)
    {
        FLangLanguageServer.Log($"Analyzing root: {key} (via {normalized})");
        FLangLanguageServer.Log($"  stdlibPath={StdlibPath}, workDir={WorkingDirectory}");
        var sw = System.Diagnostics.Stopwatch.StartNew();

        try
        {
            var compilation = new Compilation();
            compilation.StdlibPath = StdlibPath ?? "";

            string? entryRoot = null;
            if (projectInfo is { } pi)
            {
                compilation.WorkingDirectory = pi.ProjectRoot;
                compilation.ProjectName = pi.Project.Project.Name;
                var sourceRoot = ProjectLoader.ResolveSourceRoot(pi.Project.Project.Source, pi.ProjectRoot);
                compilation.ProjectSourceRoot = sourceRoot;
                compilation.ProjectGlobalImports = pi.Project.Imports?.Global ?? [];

                compilation.IncludePaths.Add(compilation.StdlibPath);
                if (sourceRoot != null)
                    compilation.IncludePaths.Add(sourceRoot);
                compilation.IncludePaths.Add(pi.ProjectRoot);

                // Resolve [dependencies] so imports like `flang_parser.lexer` reach the
                // dep's source root the same way they do under `flang build`. Failures
                // are logged but non-fatal — the file may still parse usefully, and
                // surfacing the toml error here would clobber diagnostics on every
                // analysis pass.
                if (sourceRoot != null)
                    compilation.ProjectMetadata[pi.Project.Project.Name] = new ProjectMetadata(
                        pi.Project.Project.Name, pi.Project.Project.Version, sourceRoot);
                try
                {
                    foreach (var dep in DependencyResolver.ResolveDirect(pi.Project, pi.ProjectRoot))
                    {
                        compilation.DependencySourceRoots[dep.Name] = dep.SourceRoot;
                        compilation.ProjectMetadata[dep.Name] = new ProjectMetadata(
                            dep.Name, dep.Project.Project.Version, dep.SourceRoot);
                    }
                }
                catch (Exception ex)
                {
                    FLangLanguageServer.Log($"  dependency resolution failed: {ex.Message}");
                }

                FLangLanguageServer.Log($"  project={pi.Project.Project.Name}, sourceRoot={sourceRoot}, deps={compilation.DependencySourceRoots.Count}");
                entryRoot = sourceRoot ?? pi.ProjectRoot;
            }
            else
            {
                compilation.WorkingDirectory = WorkingDirectory
                    ?? Path.GetDirectoryName(normalized)
                    ?? Directory.GetCurrentDirectory();
                compilation.IncludePaths.Add(compilation.StdlibPath);
                compilation.IncludePaths.Add(compilation.WorkingDirectory);
                // Workspace-dir root: analyze the whole directory as one unit.
                // A truly loose file (key == its own path) stays single-entry.
                if (key != normalized)
                    entryRoot = key;
            }

            // Entry points: every .f file under the root, plus the requested
            // file itself (it may live outside the source root).
            var entries = new List<string> { normalized };
            if (entryRoot != null && Directory.Exists(entryRoot))
            {
                var seen = new HashSet<string>(OperatingSystem.IsWindows()
                    ? StringComparer.OrdinalIgnoreCase
                    : StringComparer.Ordinal) { normalized };
                try
                {
                    foreach (var f in EnumerateFlangFiles(entryRoot))
                    {
                        // Template-expansion sidecars are not standalone
                        // modules — analyzed as entries they only produce
                        // noise; they're pulled in through their origin.
                        if (PositionUtil.IsGeneratedPath(f)) continue;
                        var full = Path.GetFullPath(f);
                        if (seen.Add(full)) entries.Add(full);
                    }
                }
                catch (Exception ex)
                {
                    FLangLanguageServer.Log($"  entry enumeration failed for {entryRoot}: {ex.Message}");
                }
            }

            // Build compile-time context for #if directives (same as CLI)
            var ctx = compilation.CompileTimeContext;
            string os;
            if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX)) os = "macos";
            else if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux)) os = "linux";
            else if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) os = "windows";
            else os = "unknown";
            var arch = RuntimeInformation.OSArchitecture switch
            {
                Architecture.Arm64 => "arm64",
                Architecture.X64 => "x86_64",
                Architecture.X86 => "x86",
                _ => RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant()
            };
            ctx["platform"] = new Dictionary<string, object>
            {
                ["os"] = os,
                ["arch"] = arch
            };
            ctx["runtime"] = new Dictionary<string, object>
            {
                ["testing"] = false,
                ["release"] = false,
                ["env"] = new Dictionary<string, object>()
            };

            Dictionary<string, string> openDocs;
            lock (_lock)
            {
                openDocs = new Dictionary<string, string>(_openDocuments);
            }

            var sourceProvider = new EditorSourceProvider(openDocs);
            var moduleLogger = new NullLogger();
            var moduleCompiler = new ModuleCompiler(compilation, moduleLogger, sourceProvider);

            var lap = sw.ElapsedMilliseconds;
            var parsedModules = moduleCompiler.CompileModules(entries);
            FLangLanguageServer.Log($"  [parse] {sw.ElapsedMilliseconds - lap}ms — {parsedModules.Count} modules from {entries.Count} entries");

            var allDiagnostics = new List<Diagnostic>();
            allDiagnostics.AddRange(moduleCompiler.Diagnostics);

            TypeCheckResult? typeCheckResult = null;
            HmTypeChecker? hmChecker = null;

            IReadOnlyDictionary<string, string> generatedFiles = new Dictionary<string, string>();
            // Best-effort type checking: proceed even with parse errors so the LSP
            // can provide hover/definition for the parts of the file that parsed correctly.
            // The type checker handles dummy AST nodes from error recovery gracefully.
            try
            {
                hmChecker = new HmTypeChecker(compilation);

                // Register imports into Compilation.ModuleImports/ModuleReExports.
                const string preludeModulePath = "core.prelude";
                foreach (var kvp in parsedModules)
                {
                    var modulePath = TemplateExpander.DeriveModulePath(kvp.Key, compilation);

                    // Auto-import core.prelude into every module (except the prelude itself).
                    if (modulePath != preludeModulePath)
                        compilation.RegisterImport(modulePath, preludeModulePath, isPublic: false);

                    foreach (var import in kvp.Value.Imports)
                    {
                        var importedPath = string.Join(".", import.Path);
                        compilation.RegisterImport(modulePath, importedPath, import.IsPublic);
                    }

                    // Project-level globals — Project-origin modules only.
                    if (compilation.ProjectGlobalImports.Count > 0
                        && compilation.ModuleOrigins.TryGetValue(Path.GetFullPath(kvp.Key), out var origin)
                        && origin == ModuleOrigin.Project)
                    {
                        foreach (var g in compilation.ProjectGlobalImports)
                            compilation.RegisterImport(modulePath, g, isPublic: false);
                    }
                }

                lap = sw.ElapsedMilliseconds;
                foreach (var kvp in parsedModules)
                {
                    var modulePath = TemplateExpander.DeriveModulePath(kvp.Key, compilation);
                    hmChecker.CollectNominalTypes(kvp.Value, modulePath);
                }
                FLangLanguageServer.Log($"  [collectNominals] {sw.ElapsedMilliseconds - lap}ms");

                // ── Source generator template expansion ──────────────────
                // Runs after CollectNominalTypes but before ResolveNominalTypes
                // so generated types are available as struct fields.
                lap = sw.ElapsedMilliseconds;
                var expansion = TemplateExpander.ExpandAll(parsedModules, compilation, hmChecker, allDiagnostics);
                generatedFiles = expansion.GeneratedFiles;
                FLangLanguageServer.Log($"  [templateExpand] {sw.ElapsedMilliseconds - lap}ms — {expansion.GeneratedFiles.Count} origins expanded");

                string ResolveModulePath(string key) => TemplateExpander.DeriveModulePath(key, compilation);

                lap = sw.ElapsedMilliseconds;
                foreach (var kvp in parsedModules)
                    hmChecker.ResolveNominalTypes(kvp.Value, ResolveModulePath(kvp.Key));
                FLangLanguageServer.Log($"  [resolveNominals] {sw.ElapsedMilliseconds - lap}ms");

                lap = sw.ElapsedMilliseconds;
                foreach (var kvp in parsedModules)
                    hmChecker.CollectFunctionSignatures(kvp.Value, ResolveModulePath(kvp.Key));
                FLangLanguageServer.Log($"  [collectFnSigs] {sw.ElapsedMilliseconds - lap}ms");

                lap = sw.ElapsedMilliseconds;
                foreach (var kvp in parsedModules)
                    hmChecker.CheckGlobalConstants(kvp.Value, ResolveModulePath(kvp.Key));
                FLangLanguageServer.Log($"  [checkGlobals] {sw.ElapsedMilliseconds - lap}ms");

                lap = sw.ElapsedMilliseconds;
                // LSP always type-checks test bodies for hover / go-to-definition
                // / diagnostics inside `test "..." { ... }` blocks.
                foreach (var kvp in parsedModules)
                    hmChecker.CheckModuleBodies(kvp.Value, ResolveModulePath(kvp.Key), checkTests: true);
                FLangLanguageServer.Log($"  [checkBodies] {sw.ElapsedMilliseconds - lap}ms");

                hmChecker.ResolvePendingSpecializations();

                lap = sw.ElapsedMilliseconds;
                hmChecker.ValidatePostInference();
                FLangLanguageServer.Log($"  [validatePost] {sw.ElapsedMilliseconds - lap}ms");

                allDiagnostics.AddRange(hmChecker.Diagnostics);

                // LSP-only: type-check generic function bodies with placeholder types
                // for hover/go-to-definition support. Run after all normal phases complete.
                lap = sw.ElapsedMilliseconds;
                var diagCountBefore = hmChecker.Diagnostics.Count;
                foreach (var kvp in parsedModules)
                    hmChecker.CheckGenericBodies(kvp.Value, ResolveModulePath(kvp.Key));
                // Collect diagnostics from generic body checking
                for (var i = diagCountBefore; i < hmChecker.Diagnostics.Count; i++)
                    allDiagnostics.Add(hmChecker.Diagnostics[i]);
                FLangLanguageServer.Log($"  [checkGenericBodies] {sw.ElapsedMilliseconds - lap}ms");

                typeCheckResult = hmChecker.BuildResult();
            }
            catch (Exception ex)
            {
                FLangLanguageServer.Log($"  Type checking failed (best-effort): {ex.Message}");
                // Still build a partial result if we got far enough
                if (hmChecker != null)
                {
                    try { typeCheckResult = hmChecker.BuildResult(); }
                    catch { /* truly broken — proceed without type info */ }
                }
            }

            var result = new FileAnalysisResult(allDiagnostics, compilation, parsedModules, typeCheckResult, generatedFiles);
            lock (_lock)
            {
                _projectAnalyses[key] = result;
                _pendingAnalyses.Remove(key);
            }

            sw.Stop();
            var errors = allDiagnostics.Count(d => d.Severity == DiagnosticSeverity.Error);
            var warnings = allDiagnostics.Count(d => d.Severity == DiagnosticSeverity.Warning);
            FLangLanguageServer.Log($"  [total] {sw.ElapsedMilliseconds}ms — {errors} errors, {warnings} warnings");

            // Publish per-file diagnostics for every project-origin module (so
            // the Problems panel covers the whole root, and files whose errors
            // were just fixed get their stale diagnostics cleared), plus any
            // open document in the graph. Stdlib/dep modules stay unpublished,
            // as before. No cascade needed: one analysis IS all dependents.
            lap = System.Diagnostics.Stopwatch.GetTimestamp();
            var comparer = OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;
            var openOrEntry = new HashSet<string>(entries, comparer);
            lock (_lock) { openOrEntry.UnionWith(_openDocuments.Keys); }
            var publishTargets = new HashSet<string>(comparer);
            foreach (var path in parsedModules.Keys)
            {
                var full = Path.GetFullPath(path);
                var isProjectFile = compilation.ModuleOrigins.TryGetValue(full, out var origin)
                    && origin == ModuleOrigin.Project;
                if (isProjectFile || openOrEntry.Contains(full))
                    publishTargets.Add(full);
            }
            foreach (var target in publishTargets)
                PublishDiagnostics(target, result);
            var publishMs = (System.Diagnostics.Stopwatch.GetTimestamp() - lap) * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
            FLangLanguageServer.Log($"  [publishDiags] {publishMs:F1}ms — {allDiagnostics.Count} diagnostics over {publishTargets.Count} files");
        }
        catch (Exception ex)
        {
            FLangLanguageServer.Log($"  Analysis FAILED: {ex.Message}");
            FLangLanguageServer.Log($"  {ex.StackTrace}");
            lock (_lock)
            {
                _pendingAnalyses.Remove(key);
            }
        }
    }

    private void PublishDiagnostics(string filePath, FileAnalysisResult result)
    {
        var fileId = PositionUtil.FindFileId(filePath, result.Compilation);

        var lspDiags = new List<OmniSharp.Extensions.LanguageServer.Protocol.Models.Diagnostic>();
        foreach (var diag in result.Diagnostics)
        {
            // Only publish diagnostics for this file
            if (diag.Span.FileId < 0) continue;
            if (fileId.HasValue && diag.Span.FileId != fileId.Value) continue;

            var range = PositionUtil.ToLspRange(diag.Span, result.Compilation);
            if (range == null) continue;

            lspDiags.Add(new OmniSharp.Extensions.LanguageServer.Protocol.Models.Diagnostic
            {
                Range = range,
                Severity = MapSeverity(diag.Severity),
                Message = diag.Message,
                Code = diag.Code,
                Source = "flang"
            });
        }

        _server.TextDocument.PublishDiagnostics(new PublishDiagnosticsParams
        {
            Uri = DocumentUri.FromFileSystemPath(filePath),
            Diagnostics = new Container<OmniSharp.Extensions.LanguageServer.Protocol.Models.Diagnostic>(lspDiags)
        });
    }

    private static OmniSharp.Extensions.LanguageServer.Protocol.Models.DiagnosticSeverity MapSeverity(DiagnosticSeverity severity) => severity switch
    {
        DiagnosticSeverity.Error => OmniSharp.Extensions.LanguageServer.Protocol.Models.DiagnosticSeverity.Error,
        DiagnosticSeverity.Warning => OmniSharp.Extensions.LanguageServer.Protocol.Models.DiagnosticSeverity.Warning,
        DiagnosticSeverity.Info => OmniSharp.Extensions.LanguageServer.Protocol.Models.DiagnosticSeverity.Information,
        DiagnosticSeverity.Hint => OmniSharp.Extensions.LanguageServer.Protocol.Models.DiagnosticSeverity.Hint,
        _ => OmniSharp.Extensions.LanguageServer.Protocol.Models.DiagnosticSeverity.Information,
    };

    /// <summary>
    /// Minimal no-op logger for the module compiler in LSP context.
    /// </summary>
    private class NullLogger : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => false;
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter) { }
    }
}
