using System.Diagnostics;
using FLang.Core;
using FLang.Frontend;
using FLang.Frontend.Ast.Declarations;
using Microsoft.Extensions.Logging;

namespace FLang.CLI;

public class ModuleCompiler
{
    private readonly Compilation _compilation;
    private readonly ILogger<ModuleCompiler> _logger;
    private readonly Dictionary<string, ModuleNode> _parsedModules = [];
    private readonly Queue<string> _workQueue = new();
    private readonly HashSet<string> _queuedModules = [];
    private readonly List<Diagnostic> _diagnostics = [];

    private void EnqueueModule(string modulePath, SourceSpan? importSpan = null, string? importerPath = null)
    {
        var normalizedPath = Path.GetFullPath(modulePath);

        if (importerPath != null && Path.GetFullPath(importerPath) == normalizedPath)
        {
            Debug.Assert(importSpan != null);
            _diagnostics.Add(Diagnostic.Error(
                "circular import detected",
                importSpan.Value,
                "module imports itself",
                "E0002"));
            return;
        }

        if (_parsedModules.ContainsKey(normalizedPath)) return;
        if (_queuedModules.Contains(normalizedPath)) return;

        _queuedModules.Add(normalizedPath);
        _workQueue.Enqueue(normalizedPath);
        _compilation.RegisterModule(normalizedPath, -1);
    }

    public ModuleCompiler(Compilation compilation, ILogger<ModuleCompiler> logger)
    {
        _compilation = compilation;
        _logger = logger;
    }

    public IReadOnlyList<Diagnostic> Diagnostics => _diagnostics;

    public Dictionary<string, ModuleNode> CompileModules(string entryPointPath)
    {
        _logger.LogDebug("Starting module compilation...");

        // Always include core prelude (imports all core modules)
        var preludePath = Path.Combine(_compilation.StdlibPath, "core", "predule.f");
        if (File.Exists(preludePath))
        {
            _logger.LogDebug("Queueing prelude: {PreludePath}", preludePath);
            EnqueueModule(Path.GetFullPath(preludePath));
        }
        else
        {
            _logger.LogDebug("Prelude not found: {PreludePath}", preludePath);
        }

        // Normalize the entry point path
        var normalizedPath = Path.GetFullPath(entryPointPath);
        _logger.LogDebug("Queueing entry point: {EntryPoint}", normalizedPath);

        // Queue the entry point for parsing
        EnqueueModule(normalizedPath);

        _logger.LogDebug("Starting work queue processing. Initial queue size: {QueueSize}", _workQueue.Count);
        int iteration = 0;

        while (_workQueue.Count > 0)
        {
            iteration++;
            var modulePath = _workQueue.Dequeue();
            _logger.LogDebug("Iteration {Iteration}: Processing {ModuleName} (queue remaining: {QueueSize})",
                iteration, Path.GetFileName(modulePath), _workQueue.Count);

            if (_parsedModules.ContainsKey(modulePath))
            {
                _logger.LogDebug("  Already parsed, skipping.");
                continue;
            }

            // Read and parse the module
            _logger.LogDebug("  Reading file: {FilePath}", modulePath);
            var text = File.ReadAllText(modulePath);
            var source = new Source(text, modulePath);
            var fileId = _compilation.AddSource(source);
            _compilation.RegisterModule(modulePath, fileId);

            _logger.LogDebug("  Parsing module...");
            var lexer = new Lexer(source, fileId);
            var parser = new Parser(lexer);
            var moduleNode = parser.ParseModule();

            // Collect parser diagnostics
            foreach (var d in parser.Diagnostics)
                _diagnostics.Add(d);

            _parsedModules[modulePath] = moduleNode;
            _queuedModules.Remove(modulePath);

            _logger.LogDebug("  Found {ImportCount} imports", moduleNode.Imports.Count);

            // Queue all imports for processing
            foreach (var import in moduleNode.Imports)
            {
                var importPath = string.Join(".", import.Path);
                _logger.LogDebug("    Resolving import: {ImportPath}", importPath);

                var resolvedPath = _compilation.TryResolveImportPath(import.Path);

                if (resolvedPath == null)
                {
                    _logger.LogDebug("      Failed to resolve import: {ImportPath}", importPath);
                    // Report via diagnostics instead of throwing to allow graceful error handling
                    _diagnostics.Add(Diagnostic.Error(
                        message: $"Could not resolve import: {string.Join(".", import.Path)}",
                        span: import.Span,
                        hint: "Check that the module path is correct and that the file exists under stdlib or the project.",
                        code: "E0001"));
                    // Skip enqueueing this unresolved import and continue with others
                    continue;
                }

                _logger.LogDebug("      Resolved to: {ResolvedPath}", Path.GetFileName(resolvedPath));
                EnqueueModule(resolvedPath, import.Span, modulePath);
            }
        }

        _logger.LogDebug("Module compilation complete. Parsed {ModuleCount} modules.", _parsedModules.Count);
        return _parsedModules;
    }
}