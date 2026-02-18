using FLang.Core;
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
    HmTypeChecker? TypeChecker);

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

    public void AnalyzeFile(string filePath)
    {
        var normalized = Path.GetFullPath(filePath);
        FLangLanguageServer.Log($"Analyzing: {normalized}");
        FLangLanguageServer.Log($"  stdlibPath={StdlibPath}, workDir={WorkingDirectory}");
        var sw = System.Diagnostics.Stopwatch.StartNew();

        try
        {
            var compilation = new Compilation();
            compilation.StdlibPath = StdlibPath ?? "";
            compilation.WorkingDirectory = WorkingDirectory
                ?? Path.GetDirectoryName(normalized)
                ?? Directory.GetCurrentDirectory();
            compilation.IncludePaths.Add(compilation.StdlibPath);
            compilation.IncludePaths.Add(compilation.WorkingDirectory);

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

            HmTypeChecker? hmChecker = null;

            if (!allDiagnostics.Any(d => d.Severity == DiagnosticSeverity.Error))
            {
                hmChecker = new HmTypeChecker(compilation);

                lap = sw.ElapsedMilliseconds;
                foreach (var kvp in parsedModules)
                {
                    var modulePath = HmTypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
                    hmChecker.CollectNominalTypes(kvp.Value, modulePath);
                }
                FLangLanguageServer.Log($"  [collectNominals] {sw.ElapsedMilliseconds - lap}ms");

                lap = sw.ElapsedMilliseconds;
                foreach (var kvp in parsedModules)
                {
                    var modulePath = HmTypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
                    hmChecker.ResolveNominalTypes(kvp.Value, modulePath);
                }
                FLangLanguageServer.Log($"  [resolveNominals] {sw.ElapsedMilliseconds - lap}ms");

                lap = sw.ElapsedMilliseconds;
                foreach (var kvp in parsedModules)
                {
                    var modulePath = HmTypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
                    hmChecker.CollectFunctionSignatures(kvp.Value, modulePath);
                }
                FLangLanguageServer.Log($"  [collectFnSigs] {sw.ElapsedMilliseconds - lap}ms");

                lap = sw.ElapsedMilliseconds;
                foreach (var kvp in parsedModules)
                {
                    var modulePath = HmTypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
                    hmChecker.CheckGlobalConstants(kvp.Value, modulePath);
                }
                FLangLanguageServer.Log($"  [checkGlobals] {sw.ElapsedMilliseconds - lap}ms");

                lap = sw.ElapsedMilliseconds;
                foreach (var kvp in parsedModules)
                {
                    var modulePath = HmTypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
                    hmChecker.CheckModuleBodies(kvp.Value, modulePath);
                }
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
                {
                    var modulePath = HmTypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
                    hmChecker.CheckGenericBodies(kvp.Value, modulePath);
                }
                // Collect diagnostics from generic body checking
                for (var i = diagCountBefore; i < hmChecker.Diagnostics.Count; i++)
                    allDiagnostics.Add(hmChecker.Diagnostics[i]);
                FLangLanguageServer.Log($"  [checkGenericBodies] {sw.ElapsedMilliseconds - lap}ms");
            }

            var result = new FileAnalysisResult(allDiagnostics, compilation, parsedModules, hmChecker);
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
