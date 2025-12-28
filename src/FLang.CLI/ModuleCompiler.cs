using System.Diagnostics;
using FLang.Core;
using FLang.Frontend;
using FLang.Frontend.Ast.Declarations;

namespace FLang.CLI;

public class ModuleCompiler
{
    private readonly Compilation _compilation;
    private readonly Dictionary<string, ModuleNode> _parsedModules = new();
    private readonly Queue<string> _workQueue = new();
    private readonly HashSet<string> _queuedModules = new();
    private readonly List<Diagnostic> _diagnostics = new();

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

    public ModuleCompiler(Compilation compilation)
    {
        _compilation = compilation;
    }

    public IReadOnlyList<Diagnostic> Diagnostics => _diagnostics;

    public Dictionary<string, ModuleNode> CompileModules(string entryPointPath)
    {
        // Normalize the entry point path
        var normalizedPath = Path.GetFullPath(entryPointPath);

        // Queue the entry point for parsing
        EnqueueModule(normalizedPath);

        // Always include core prelude modules (String/Option/List/runtime helpers)
        var preludeModules = new[]
        {
            Path.Combine(_compilation.StdlibPath, "core", "string.f"),
            Path.Combine(_compilation.StdlibPath, "core", "option.f"),
            Path.Combine(_compilation.StdlibPath, "core", "list.f"),
            Path.Combine(_compilation.StdlibPath, "core", "runtime.f")
        };

        foreach (var preludePath in preludeModules)
        {
            if (!File.Exists(preludePath)) continue;
            EnqueueModule(Path.GetFullPath(preludePath));
        }

        while (_workQueue.Count > 0)
        {
            var modulePath = _workQueue.Dequeue();

            if (_parsedModules.ContainsKey(modulePath))
                continue;

            // Read and parse the module
            var text = File.ReadAllText(modulePath);
            var source = new Source(text, modulePath);
            var fileId = _compilation.AddSource(source);
            _compilation.RegisterModule(modulePath, fileId);

            var lexer = new Lexer(source, fileId);
            var parser = new Parser(lexer);
            var moduleNode = parser.ParseModule();

            // Collect parser diagnostics
            foreach (var d in parser.Diagnostics)
                _diagnostics.Add(d);

            _parsedModules[modulePath] = moduleNode;
            _queuedModules.Remove(modulePath);

            // Queue all imports for processing
            foreach (var import in moduleNode.Imports)
            {
                var resolvedPath = _compilation.TryResolveImportPath(import.Path);

                if (resolvedPath == null)
                {
                    // Report via diagnostics instead of throwing to allow graceful error handling
                    _diagnostics.Add(Diagnostic.Error(
                        message: $"Could not resolve import: {string.Join(".", import.Path)}",
                        span: import.Span,
                        hint: "Check that the module path is correct and that the file exists under stdlib or the project.",
                        code: "E0001"));
                    // Skip enqueueing this unresolved import and continue with others
                    continue;
                }

                EnqueueModule(resolvedPath, import.Span, modulePath);
            }
        }

        return _parsedModules;
    }
}