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
/// Analysis result for a single file.
/// </summary>
public record FileAnalysisResult(
    IReadOnlyList<Diagnostic> Diagnostics,
    Compilation Compilation,
    Dictionary<string, ModuleNode> ParsedModules,
    TypeCheckResult? TypeChecker);

/// <summary>
/// Manages open documents, compilation cache, and analysis results for the LSP.
/// </summary>
public class FLangWorkspace
{
    private readonly Dictionary<string, string> _openDocuments = [];
    private readonly CompilationCache _cache = new();
    private readonly Dictionary<string, FileAnalysisResult> _analysisResults = [];
    private readonly Dictionary<string, Task> _pendingAnalyses = [];
    private readonly Lock _lock = new();
    private readonly ILogger _logger;
    private readonly ILanguageServerFacade _server;
    // Cache entries are invalidated when flang.toml's mtime changes — the LSP
    // does not see TOML saves through its flang-only document handler, so an
    // mtime check is required to pick up edits made outside or via clients
    // that don't forward non-flang saves.
    private readonly Dictionary<string, (FlangProject Project, DateTime LastWriteUtc)> _projectCache = [];

    public string? StdlibPath { get; set; }
    public string? WorkingDirectory { get; set; }

    public FLangWorkspace(ILanguageServerFacade server, LspConfig config, ILogger<FLangWorkspace> logger)
    {
        _logger = logger;
        _server = server;
        StdlibPath = config.StdlibPath;
    }

    public void UpdateDocument(string filePath, string content)
    {
        var normalized = Path.GetFullPath(filePath);
        lock (_lock)
        {
            _openDocuments[normalized] = content;
            _cache.InvalidateModule(normalized);
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

    public FileAnalysisResult? GetAnalysis(string filePath)
    {
        var normalized = Path.GetFullPath(filePath);
        lock (_lock)
        {
            return _analysisResults.GetValueOrDefault(normalized);
        }
    }

    /// <summary>
    /// Returns the analysis result, waiting for any pending analysis to complete first.
    /// Use this in handlers that need up-to-date results (InlayHint, Hover, etc.).
    /// </summary>
    public async Task<FileAnalysisResult?> GetAnalysisAsync(string filePath)
    {
        var normalized = Path.GetFullPath(filePath);
        Task? pending;
        lock (_lock)
        {
            _pendingAnalyses.TryGetValue(normalized, out pending);
        }
        if (pending != null)
        {
            try { await pending; }
            catch { /* analysis errors are handled internally */ }
        }
        lock (_lock)
        {
            return _analysisResults.GetValueOrDefault(normalized);
        }
    }

    public void SetPendingAnalysis(string filePath, Task task)
    {
        var normalized = Path.GetFullPath(filePath);
        lock (_lock)
        {
            _pendingAnalyses[normalized] = task;
        }
    }

    public void AnalyzeFile(string filePath) => AnalyzeFileInternal(filePath, cascade: true);

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

    private void AnalyzeFileInternal(string filePath, bool cascade)
    {
        var normalized = Path.GetFullPath(filePath);
        FLangLanguageServer.Log($"Analyzing: {normalized}");
        FLangLanguageServer.Log($"  stdlibPath={StdlibPath}, workDir={WorkingDirectory}");
        var sw = System.Diagnostics.Stopwatch.StartNew();

        try
        {
            var compilation = new Compilation();
            compilation.StdlibPath = StdlibPath ?? "";

            // Try to find project config for this file
            var projectInfo = FindProjectForFile(normalized);
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

                FLangLanguageServer.Log($"  project={pi.Project.Project.Name}, sourceRoot={sourceRoot}");
            }
            else
            {
                compilation.WorkingDirectory = WorkingDirectory
                    ?? Path.GetDirectoryName(normalized)
                    ?? Directory.GetCurrentDirectory();
                compilation.IncludePaths.Add(compilation.StdlibPath);
                compilation.IncludePaths.Add(compilation.WorkingDirectory);
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
            var parsedModules = moduleCompiler.CompileModules(normalized);
            FLangLanguageServer.Log($"  [parse] {sw.ElapsedMilliseconds - lap}ms — {parsedModules.Count} modules");

            var allDiagnostics = new List<Diagnostic>();
            allDiagnostics.AddRange(moduleCompiler.Diagnostics);

            TypeCheckResult? typeCheckResult = null;
            HmTypeChecker? hmChecker = null;

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
                var syntheticModulePaths = expansion.SyntheticModulePaths;
                FLangLanguageServer.Log($"  [templateExpand] {sw.ElapsedMilliseconds - lap}ms — {syntheticModulePaths.Count} synthetic modules");

                // Helper: resolve module path for real and synthetic modules
                string ResolveModulePath(string key) =>
                    syntheticModulePaths.TryGetValue(key, out var path)
                        ? path
                        : TemplateExpander.DeriveModulePath(key, compilation);

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
                foreach (var kvp in parsedModules)
                    hmChecker.CheckModuleBodies(kvp.Value, ResolveModulePath(kvp.Key));
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

            var result = new FileAnalysisResult(allDiagnostics, compilation, parsedModules, typeCheckResult);
            lock (_lock)
            {
                _analysisResults[normalized] = result;
                _pendingAnalyses.Remove(normalized);
            }

            sw.Stop();
            var errors = allDiagnostics.Count(d => d.Severity == DiagnosticSeverity.Error);
            var warnings = allDiagnostics.Count(d => d.Severity == DiagnosticSeverity.Warning);
            FLangLanguageServer.Log($"  [total] {sw.ElapsedMilliseconds}ms — {errors} errors, {warnings} warnings");

            lap = System.Diagnostics.Stopwatch.GetTimestamp();
            PublishDiagnostics(normalized, result);
            var publishMs = (System.Diagnostics.Stopwatch.GetTimestamp() - lap) * 1000.0 / System.Diagnostics.Stopwatch.Frequency;
            FLangLanguageServer.Log($"  [publishDiags] {publishMs:F1}ms — {allDiagnostics.Count} diagnostics");

            // Re-analyze open files that depend on the changed file
            if (cascade)
            {
                var dependents = GetDependentFiles(normalized);
                foreach (var dep in dependents)
                {
                    FLangLanguageServer.Log($"  cascade: re-analyzing {dep}");
                    AnalyzeFileInternal(dep, cascade: false);
                }
            }
        }
        catch (Exception ex)
        {
            FLangLanguageServer.Log($"  Analysis FAILED: {ex.Message}");
            FLangLanguageServer.Log($"  {ex.StackTrace}");
            lock (_lock)
            {
                _pendingAnalyses.Remove(normalized);
            }
        }
    }

    /// <summary>
    /// Returns open files whose last analysis included the given file as a dependency.
    /// </summary>
    private List<string> GetDependentFiles(string normalizedPath)
    {
        var dependents = new List<string>();
        lock (_lock)
        {
            foreach (var (file, result) in _analysisResults)
            {
                if (string.Equals(file, normalizedPath, StringComparison.OrdinalIgnoreCase))
                    continue;
                if (!_openDocuments.ContainsKey(file))
                    continue;
                if (result.ParsedModules.ContainsKey(normalizedPath))
                    dependents.Add(file);
            }
        }
        return dependents;
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
