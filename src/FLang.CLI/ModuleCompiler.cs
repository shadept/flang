using FLang.Core;
using FLang.Frontend;
using FLang.Frontend.Ast.Declarations;

namespace FLang.CLI;

public class ModuleCompiler
{
    private readonly Compilation _compilation;
    private readonly Dictionary<string, ModuleNode> _parsedModules = new();
    private readonly Queue<string> _workQueue = new();
    private readonly List<Diagnostic> _diagnostics = new();

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
        _workQueue.Enqueue(normalizedPath);
        _compilation.RegisterModule(normalizedPath, -1); // Reserve entry point

        // Always include core/string for built-in String support, even if not explicitly imported
        var preludeStringPath = Path.Combine(_compilation.StdlibPath, "core", "string.f");
        if (File.Exists(preludeStringPath))
        {
            var normPrelude = Path.GetFullPath(preludeStringPath);
            if (!_compilation.IsModuleAlreadyLoaded(normPrelude))
            {
                _workQueue.Enqueue(normPrelude);
                _compilation.RegisterModule(normPrelude, -1);
            }
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

                var normalizedImportPath = Path.GetFullPath(resolvedPath);

                if (!_compilation.IsModuleAlreadyLoaded(normalizedImportPath))
                {
                    _workQueue.Enqueue(normalizedImportPath);
                    _compilation.RegisterModule(normalizedImportPath, -1); // Reserve
                }
            }
        }

        return _parsedModules;
    }
}