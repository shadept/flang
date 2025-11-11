using System;
using System.Collections.Generic;
using System.IO;
using FLang.Core;
using FLang.Frontend;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;

namespace FLang.CLI;

public class ModuleCompiler
{
    private readonly Compilation _compilation;
    private readonly Queue<string> _workQueue = new();
    private readonly Dictionary<string, ModuleNode> _parsedModules = new();

    public ModuleCompiler(Compilation compilation)
    {
        _compilation = compilation;
    }

    public Dictionary<string, ModuleNode> CompileModules(string entryPointPath)
    {
        // Normalize the entry point path
        var normalizedPath = Path.GetFullPath(entryPointPath);

        // Queue the entry point for parsing
        _workQueue.Enqueue(normalizedPath);
        _compilation.RegisterModule(normalizedPath, -1); // Reserve entry point

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

            _parsedModules[modulePath] = moduleNode;

            // Queue all imports for processing
            foreach (var import in moduleNode.Imports)
            {
                var resolvedPath = _compilation.TryResolveImportPath(import.Path);

                if (resolvedPath == null)
                {
                    throw new Exception($"Could not resolve import: {string.Join(".", import.Path)}");
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
