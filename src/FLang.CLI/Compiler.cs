using System.Diagnostics;
using System.Runtime.InteropServices;
using FLang.Codegen.C;
using FLang.Core;
using FLang.Frontend;
using FLang.Frontend.Ast.Declarations;
using FLang.IR;
using FLang.Semantics;
using Microsoft.Extensions.Logging;

namespace FLang.CLI;

public record CompilerConfig(
    string Name,
    string ExecutablePath,
    string Arguments,
    Dictionary<string, string>? Environment);

public static class FlangVersion
{
    public const string Current = "0.1.0-alpha";
}

public record CompilerOptions(
    IReadOnlyList<string> InputFilePaths,
    string StdlibPath,
    string? OutputPath = null,
    bool ReleaseBuild = false,
    string? EmitFir = null,
    bool DumpTemplates = false,
    bool DebugLogging = false,
    string? WorkingDirectory = null,
    IReadOnlyList<string>? IncludePaths = null,
    bool RunTests = false,
    bool EmitCfg = false,
    IReadOnlyList<string>? LinkFlags = null,
    IReadOnlyList<string>? HeaderPaths = null,
    IReadOnlyList<string>? CompilerFlags = null,
    string? ProjectName = null,
    string? ProjectSourceRoot = null,
    string? CacheDirectory = null,
    /// <summary>
    /// Modules to inject as implicit private imports into every Project-origin
    /// file. Sourced from `[imports].global` in flang.toml. Never applied to
    /// stdlib or third-party modules.
    /// </summary>
    IReadOnlyList<string>? ProjectGlobalImports = null,
    /// <summary>
    /// Direct dependencies' (name → source-root) mapping. An import whose first
    /// segment matches a key here resolves the remainder against the value
    /// (same shape as <see cref="ProjectName"/> / <see cref="ProjectSourceRoot"/>).
    /// </summary>
    IReadOnlyDictionary<string, string>? DependencySourceRoots = null,
    /// <summary>
    /// Per-project metadata (consuming project + each direct dep). Threaded into
    /// <see cref="Compilation.ProjectMetadata"/> so the `project_info()` intrinsic
    /// can resolve name + version for the call site's owning project.
    /// </summary>
    IReadOnlyDictionary<string, ProjectMetadata>? ProjectMetadata = null
);

public record CompilationResult(
    bool Success,
    string? ExecutablePath,
    IReadOnlyList<Diagnostic> Diagnostics,
    Compilation CompilationContext
);

public class Compiler
{
    public CompilationResult Compile(CompilerOptions options)
    {
        // Default working directory to the directory of the first input file if not specified
        var workingDir = options.WorkingDirectory
            ?? Path.GetDirectoryName(Path.GetFullPath(options.InputFilePaths[0]))
            ?? Directory.GetCurrentDirectory();

        var compilation = new Compilation();
        compilation.StdlibPath = options.StdlibPath;
        compilation.WorkingDirectory = workingDir;

        // Build include paths: stdlib first (most specific), then user paths, then working directory (fallback)
        compilation.IncludePaths.Add(options.StdlibPath);  // Stdlib first for correct module paths
        if (options.IncludePaths != null && options.IncludePaths.Count > 0)
        {
            foreach (var path in options.IncludePaths)
                compilation.IncludePaths.Add(path);
        }
        compilation.IncludePaths.Add(workingDir);  // Working dir last (fallback for entry point)

        // Project-name-based import resolution
        compilation.ProjectName = options.ProjectName;
        compilation.ProjectSourceRoot = options.ProjectSourceRoot;
        compilation.ProjectGlobalImports = options.ProjectGlobalImports ?? [];
        if (options.DependencySourceRoots != null)
            foreach (var (name, root) in options.DependencySourceRoots)
                compilation.DependencySourceRoots[name] = root;
        if (options.ProjectMetadata != null)
            foreach (var (name, meta) in options.ProjectMetadata)
                compilation.ProjectMetadata[name] = meta;

        // Build structured compile-time context for #if directives
        var ctx = compilation.CompileTimeContext;

        // platform.os, platform.arch
        string os, arch;
        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX)) os = "macos";
        else if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux)) os = "linux";
        else if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) os = "windows";
        else os = "unknown";

        arch = RuntimeInformation.OSArchitecture switch
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

        // runtime.testing, runtime.release, runtime.env
        var envDict = new Dictionary<string, object>();
        foreach (System.Collections.DictionaryEntry e in Environment.GetEnvironmentVariables())
            envDict[e.Key.ToString()!] = e.Value?.ToString() ?? "";

        ctx["runtime"] = new Dictionary<string, object>
        {
            ["testing"] = options.RunTests,
            ["release"] = options.ReleaseBuild,
            ["env"] = envDict
        };

        var allDiagnostics = new List<Diagnostic>();

        // Create logger factory for all compilation phases
        using var loggerFactory = LoggerFactory.Create(builder =>
        {
            builder.SetMinimumLevel(options.DebugLogging ? LogLevel.Debug : LogLevel.Warning);
            builder
                .AddConsoleFormatter<CustomDebugFormatter,
                    Microsoft.Extensions.Logging.Console.ConsoleFormatterOptions>();
            builder.AddConsole(o => o.FormatterName = "custom-debug");
        });

        // 0. FFI Header Processing — generates vendor/*.f before module discovery
        if (options.HeaderPaths is { Count: > 0 })
        {
            var headerParser = new FFI.CppAstHeaderParser();
            var bindingGenerator = new FFI.FLangBindingGenerator();
            var vendorDir = Path.Combine(workingDir, "vendor");
            Directory.CreateDirectory(vendorDir);

            foreach (var headerPath in options.HeaderPaths)
            {
                var fullHeaderPath = Path.GetFullPath(headerPath);
                var result = headerParser.Parse(fullHeaderPath);

                foreach (var warning in result.Warnings)
                    allDiagnostics.Add(Diagnostic.Warning($"FFI: {warning}", SourceSpan.None));

                if (result.Errors.Count > 0)
                {
                    foreach (var err in result.Errors)
                        allDiagnostics.Add(Diagnostic.Error($"FFI: {err}", SourceSpan.None));
                    continue;
                }

                var headerName = Path.GetFileNameWithoutExtension(headerPath);
                var flangSource = bindingGenerator.Generate(result, headerName);
                var vendorFile = Path.Combine(vendorDir, $"{headerName}.f");
                File.WriteAllText(vendorFile, flangSource);
            }
        }

        // 1. Module Loading and Parsing
        var moduleCompilerLogger = loggerFactory.CreateLogger<ModuleCompiler>();
        var moduleCompiler = new ModuleCompiler(compilation, moduleCompilerLogger, new FileSystemSourceProvider());
        var parsedModules = moduleCompiler.CompileModules(options.InputFilePaths);
        allDiagnostics.AddRange(moduleCompiler.Diagnostics);

        // `flang test` runs only the project's own `test {}` blocks. A dependency's
        // (and stdlib's) blocks are that project's concern, run from its directory —
        // otherwise every consumer re-runs the whole transitive suite. The project's
        // own sources are exactly the compilation's entry inputs; deps arrive via
        // module resolution, not this list.
        var testModules = new HashSet<ModuleNode>();
        if (options.RunTests)
        {
            var ownSources = new HashSet<string>(
                (options.InputFilePaths ?? []).Select(Path.GetFullPath),
                StringComparer.OrdinalIgnoreCase);
            foreach (var kvp in parsedModules)
                if (ownSources.Contains(Path.GetFullPath(kvp.Key)))
                    testModules.Add(kvp.Value);
        }

        if (options.DumpTemplates)
        {
            foreach (var kvp in parsedModules)
            {
                var mod = kvp.Value;
                if (mod.GeneratorDefinitions.Count == 0 && mod.GeneratorInvocations.Count == 0)
                    continue;

                Console.WriteLine($"=== {kvp.Key} ===");
                if (mod.GeneratorDefinitions.Count > 0)
                    Console.Write(TemplatePrinter.PrintAllDefinitions(mod.GeneratorDefinitions));
                if (mod.GeneratorInvocations.Count > 0)
                {
                    foreach (var inv in mod.GeneratorInvocations)
                    {
                        var argsStr = string.Join(", ", inv.Arguments.Select(a =>
                            a.Identifier ?? a.TypeExpr?.GetType().Name ?? "?"));
                        Console.WriteLine($"#{inv.Name}({argsStr})");
                    }
                }
            }
        }

        if (allDiagnostics.Any(d => d.Severity == DiagnosticSeverity.Error))
        {
            return new CompilationResult(false, null, allDiagnostics, compilation);
        }

        // Register imports into Compilation.ModuleImports/ModuleReExports.
        // This drives Visible[M] for symbol resolution.
        const string preludeModulePath = "core.prelude";
        foreach (var kvp in parsedModules)
        {
            var modulePath = TemplateExpander.DeriveModulePath(kvp.Key, compilation);

            // Auto-import core.prelude into every module (except the prelude itself).
            // The prelude is a curated re-export wall: `pub import core.option`, etc.
            // so this single private edge makes all core symbols visible.
            if (modulePath != preludeModulePath)
                compilation.RegisterImport(modulePath, preludeModulePath, isPublic: false);

            foreach (var import in kvp.Value.Imports)
            {
                var importedPath = string.Join(".", import.Path);
                compilation.RegisterImport(modulePath, importedPath, import.IsPublic);
            }

            // Project-level globals are injected as implicit private imports —
            // applied only to Project-origin modules so stdlib and (future)
            // third-party packages stay isolated from per-project config.
            if (compilation.ProjectGlobalImports.Count > 0
                && compilation.ModuleOrigins.TryGetValue(Path.GetFullPath(kvp.Key), out var origin)
                && origin == ModuleOrigin.Project)
            {
                foreach (var g in compilation.ProjectGlobalImports)
                    compilation.RegisterImport(modulePath, g, isPublic: false);
            }
        }

        // Wrap type checking, lowering, and codegen in a try-catch to convert
        // internal compiler errors into proper diagnostics with source locations.
        try
        {
        // 2. HM Type Checking — multi-phase across all modules
        // BFS insertion order from ModuleCompiler is already correct (prelude -> core -> user).
        // The 2-phase collect-then-resolve approach makes ordering within each phase irrelevant.
        var hmChecker = new HmTypeChecker(compilation);

        foreach (var kvp in parsedModules)
        {
            var modulePath = TemplateExpander.DeriveModulePath(kvp.Key, compilation);
            hmChecker.CollectNominalTypes(kvp.Value, modulePath);
        }

        // ── Source generator template expansion ──────────────────────────────
        // Runs after CollectNominalTypes (so generators can look up types and field AST nodes)
        // but before ResolveNominalTypes (so generated types are available as struct fields).
        var expansion = TemplateExpander.ExpandAll(parsedModules, compilation, hmChecker, allDiagnostics);
        var syntheticModulePaths = expansion.SyntheticModulePaths;

        // Helper: resolve module path for real and synthetic modules
        string ResolveModulePath(string key) =>
            syntheticModulePaths.TryGetValue(key, out var path)
                ? path
                : TemplateExpander.DeriveModulePath(key, compilation);

        foreach (var kvp in parsedModules)
            hmChecker.ResolveNominalTypes(kvp.Value, ResolveModulePath(kvp.Key));

        // Write .generated.f files so debuggers / error messages can reference real files
        foreach (var (genPath, genContent) in expansion.GeneratedFiles)
        {
            try { File.WriteAllText(genPath, genContent); }
            catch { /* best-effort */ }
        }

        if (allDiagnostics.Any(d => d.Severity == DiagnosticSeverity.Error))
        {
            return new CompilationResult(false, null, allDiagnostics, compilation);
        }

        foreach (var kvp in parsedModules)
            hmChecker.CollectFunctionSignatures(kvp.Value, ResolveModulePath(kvp.Key));

        foreach (var kvp in parsedModules)
            hmChecker.CheckGlobalConstants(kvp.Value, ResolveModulePath(kvp.Key));

        foreach (var kvp in parsedModules)
            hmChecker.CheckModuleBodies(kvp.Value, ResolveModulePath(kvp.Key), checkTests: testModules.Contains(kvp.Value));

        // Resolve specializations deferred due to unresolved TypeVars
        hmChecker.ResolvePendingSpecializations();

        foreach (var kvp in parsedModules)
            hmChecker.CheckGenericBodies(kvp.Value, ResolveModulePath(kvp.Key));

        // Resolve overloaded function references used as values
        // (e.g. `owned(p, deinit)` — picks the deinit matching the param type)
        hmChecker.ResolvePendingFnRefs();

        // Post-inference validation (unsuffixed literal checks: E2001, E2029, E2102)
        hmChecker.ValidatePostInference();

        allDiagnostics.AddRange(hmChecker.Diagnostics);

        if (allDiagnostics.Any(d => d.Severity == DiagnosticSeverity.Error))
        {
            return new CompilationResult(false, null, allDiagnostics, compilation);
        }

        // 3. Lowering to IrModule
        var layoutService = new TypeLayoutService(hmChecker.Engine, hmChecker);
        var typeCheckResult = hmChecker.BuildResult();
        var lowering = new HmAstLowering(typeCheckResult, layoutService, compilation);

        var moduleEntries = parsedModules.Select(kvp =>
        {
            return (ResolveModulePath(kvp.Key), kvp.Value);
        });

        var irModule = lowering.LowerModule(moduleEntries, options.RunTests, testModules);
        irModule.SourceFiles = compilation.Sources;
        allDiagnostics.AddRange(lowering.Diagnostics);

        if (allDiagnostics.Any(d => d.Severity == DiagnosticSeverity.Error))
        {
            return new CompilationResult(false, null, allDiagnostics, compilation);
        }

        if (irModule.Functions.Count == 0)
        {
            allDiagnostics.Add(Diagnostic.Error("No functions found in any module", SourceSpan.None, "E0000"));
            return new CompilationResult(false, null, allDiagnostics, compilation);
        }

        IrOptimizer.Run(irModule);

        // 4. Emit FIR (optional)
        if (options.EmitFir != null)
        {
            var firOutput = FirPrinter.PrintModule(irModule);
            if (options.EmitFir == "-")
            {
                Console.WriteLine("=== FIR ===");
                Console.WriteLine(firOutput);
            }
            else
            {
                File.WriteAllText(options.EmitFir, firOutput);
            }
        }

        // 4b. Emit CFG (optional)
        if (options.EmitCfg)
        {
            var cfgHtml = CfgHtmlExporter.Export(irModule);
            var cfgPath = Path.Combine(
                Path.GetDirectoryName(Path.GetFullPath(options.InputFilePaths[0]))!,
                "cfg.html");
            File.WriteAllText(cfgPath, cfgHtml);
        }

        // 5. Generate C Code
        var cCode = HmCCodeGenerator.GenerateProgram(irModule);

        // Resolve output and intermediate paths
        string outputFilePath;
        if (options.OutputPath != null)
        {
            outputFilePath = options.OutputPath;
        }
        else
        {
            outputFilePath = Path.ChangeExtension(options.InputFilePaths[0], ".exe");
            if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
                outputFilePath = Path.ChangeExtension(outputFilePath, null);
        }

        var outputDir = Path.GetDirectoryName(Path.GetFullPath(outputFilePath))!;
        var cFilePath = Path.Combine(outputDir, Path.GetFileNameWithoutExtension(outputFilePath) + ".c");
        File.WriteAllText(cFilePath, cCode);

        // 6. Discover native C source files from parsed modules.
        //    Any .f file with a companion .c file gets linked, whether it
        //    lives under the stdlib path or not.  Generated .c files are skipped.
        var extraCFiles = new List<string>();
        foreach (var modulePath in parsedModules.Keys)
        {
            var cFile = Path.ChangeExtension(modulePath, ".c");
            if (!File.Exists(cFile)) continue;
            // Skip generated .c files (they start with "/* Generated by FLang")
            try
            {
                using var reader = new StreamReader(cFile);
                var firstLine = reader.ReadLine();
                if (firstLine != null && firstLine.Contains("Generated by FLang")) continue;
            }
            catch { continue; }
            extraCFiles.Add(cFile);
        }

        // 7. Invoke C Compiler
        var selected = CompilerDiscovery.SelectCompiler();
        if (selected == null)
        {
            allDiagnostics.Add(Diagnostic.Error("No C compiler configuration provided.", SourceSpan.None, "E0000"));
            return new CompilationResult(false, null, allDiagnostics, compilation);
        }

        // 7a. Pre-compile native companion .c files through the build cache.
        //     This turns the final C-compiler invocation into "compile main.c +
        //     link a handful of pre-built .obj files", which is both faster on
        //     warm cache and eliminates the cl.exe basename-collision
        //     workaround (the .objs/ scratch directory) in steady state.
        var cachedObjs = new List<string>();
        if (extraCFiles.Count > 0)
        {
            // Cache colocates with build outputs by default. Callers can pin
            // an explicit shared cache (the test harness does this so parallel
            // workers don't each cold-recompile the stdlib companions).
            var cacheRoot = options.CacheDirectory ?? DefaultCacheRoot(options, workingDir);
            var flagsHash = BuildCache.ComputeFlagsHash(
                new CompilerConfig(selected.Name, selected.ExecutablePath, "", selected.Environment),
                options.ReleaseBuild, FlangVersion.Current, options.CompilerFlags);
            var cache = new BuildCache(cacheRoot, flagsHash);

            var stdlibFull = Path.GetFullPath(options.StdlibPath);
            foreach (var cSrc in extraCFiles)
            {
                var depName = ClassifyDep(cSrc, stdlibFull, options.ProjectName);
                var objPath = cache.GetOrCompile(depName, cSrc, (src, obj) =>
                {
                    var compileArgs = CompilerDiscovery.BuildCompileOnlyArgs(
                        selected, src, obj, options.ReleaseBuild, options.CompilerFlags);
                    return RunCompiler(selected, compileArgs);
                }, out var cacheError);

                if (cacheError != null)
                {
                    allDiagnostics.Add(Diagnostic.Error(
                        $"C compiler ({selected.Name}) failed: {cacheError}",
                        SourceSpan.None, "E0000"));
                    return new CompilationResult(false, null, allDiagnostics, compilation);
                }
                cachedObjs.Add(objPath);
            }
        }

        // 7b. Build the compile+link command for main.c + the cached .obj set.
        var linkArgs = CompilerDiscovery.BuildCompileAndLinkArgs(
            selected,
            cFilePath,
            outputFilePath,
            options.ReleaseBuild,
            extraCFiles: null,            // all extras pre-compiled via the cache
            extraObjFiles: cachedObjs.Count > 0 ? cachedObjs : null,
            options.LinkFlags,
            options.CompilerFlags);

        var execPath = selected.IsXcrun ? "xcrun" : selected.ExecutablePath;
        var finalArgs = selected.IsXcrun ? "clang " + linkArgs : linkArgs;
        var compilerConfig = new CompilerConfig(selected.Name, execPath, finalArgs, selected.Environment);

        var startInfo = new ProcessStartInfo
        {
            FileName = compilerConfig.ExecutablePath,
            Arguments = compilerConfig.Arguments,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        if (compilerConfig.Environment != null)
            foreach (var (key, value) in compilerConfig.Environment)
                startInfo.EnvironmentVariables[key] = value;

        using var process = new Process { StartInfo = startInfo };

        try
        {
            process.Start();

            // Read stdout/stderr BEFORE WaitForExit to avoid deadlock when
            // the pipe buffer fills up (classic .NET Process deadlock).
            var stdout = process.StandardOutput.ReadToEnd();
            var stderr = process.StandardError.ReadToEnd();
            process.WaitForExit();

            if (process.ExitCode != 0)
            {
                var errorMsg = $"C compiler ({compilerConfig.Name}) failed:\n{stdout}\n{stderr}";
                allDiagnostics.Add(Diagnostic.Error(errorMsg, SourceSpan.None, "E0000"));
                return new CompilationResult(false, null, allDiagnostics, compilation);
            }

            // Clean up intermediate files
            var objFilePath = Path.ChangeExtension(cFilePath, ".obj");
            if (File.Exists(objFilePath)) File.Delete(objFilePath);

            var cwdObj = Path.GetFileNameWithoutExtension(cFilePath) + ".obj";
            if (File.Exists(cwdObj)) File.Delete(cwdObj);
        }
        catch (Exception ex)
        {
            allDiagnostics.Add(Diagnostic.Error($"Error invoking C compiler ({compilerConfig.ExecutablePath}): {ex.Message}", SourceSpan.None, "E0000"));
            return new CompilationResult(false, null, allDiagnostics, compilation);
        }

        return new CompilationResult(true, outputFilePath, allDiagnostics, compilation);

        }
        catch (InternalCompilerError ice)
        {
            allDiagnostics.Add(Diagnostic.Error(
                $"internal compiler error: {ice.Message}",
                ice.Span, "Please report this bug.", "E0000"));
            return new CompilationResult(false, null, allDiagnostics, compilation);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException and not StackOverflowException)
        {
            allDiagnostics.Add(Diagnostic.Error(
                $"internal compiler error: {ex.Message}",
                SourceSpan.None, "Please report this bug.", "E0000"));
            return new CompilationResult(false, null, allDiagnostics, compilation);
        }
    }

    /// <summary>
    /// Decide which <c>deps/&lt;name&gt;/</c> bucket a companion <c>.c</c> file
    /// lives under. Anything inside the stdlib tree goes under
    /// <c>stdlib</c>; everything else is keyed by project name (or
    /// <c>local</c> for single-file builds).
    /// </summary>
    private static string ClassifyDep(string cSourcePath, string stdlibFullPath, string? projectName)
    {
        var full = Path.GetFullPath(cSourcePath);
        if (!string.IsNullOrEmpty(stdlibFullPath) &&
            full.StartsWith(stdlibFullPath, StringComparison.OrdinalIgnoreCase))
            return "stdlib";
        return string.IsNullOrWhiteSpace(projectName) ? "local" : projectName;
    }

    /// <summary>
    /// Default cache root colocates with build outputs: <c>&lt;outputDir&gt;/cache</c>.
    /// Falls back to <c>&lt;workingDir&gt;/cache</c> when no explicit OutputPath
    /// is set (single-file mode).
    /// </summary>
    private static string DefaultCacheRoot(CompilerOptions options, string workingDir)
    {
        if (!string.IsNullOrEmpty(options.OutputPath))
        {
            var outDir = Path.GetDirectoryName(Path.GetFullPath(options.OutputPath));
            if (!string.IsNullOrEmpty(outDir))
                return Path.Combine(outDir, "cache");
        }
        return Path.Combine(workingDir, "cache");
    }

    /// <summary>
    /// Run the selected compiler with the given argument string, returning
    /// the result in a shape the build cache's <c>CompileFn</c> expects.
    /// </summary>
    private static BuildCache.CompileResult RunCompiler(SelectedCompiler selected, string arguments)
    {
        var execPath = selected.IsXcrun ? "xcrun" : selected.ExecutablePath;
        var finalArgs = selected.IsXcrun ? "clang " + arguments : arguments;

        var psi = new ProcessStartInfo
        {
            FileName = execPath,
            Arguments = finalArgs,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        if (selected.Environment != null)
            foreach (var (k, v) in selected.Environment)
                psi.EnvironmentVariables[k] = v;

        try
        {
            using var p = Process.Start(psi);
            if (p == null)
                return new BuildCache.CompileResult(false, "", "failed to start compiler process");

            var stdout = p.StandardOutput.ReadToEnd();
            var stderr = p.StandardError.ReadToEnd();
            p.WaitForExit();
            return new BuildCache.CompileResult(p.ExitCode == 0, stdout, stderr);
        }
        catch (Exception ex)
        {
            return new BuildCache.CompileResult(false, "", ex.Message);
        }
    }
}
