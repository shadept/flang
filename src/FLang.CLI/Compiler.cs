using System.Diagnostics;
using System.Runtime.InteropServices;
using FLang.Codegen.C;
using FLang.Core;
using FLang.Frontend;
using FLang.Frontend.Ast;
using FLang.IR;
using FLang.Semantics;
using Microsoft.Extensions.Logging;

namespace FLang.CLI;

public record CompilerConfig(
    string Name,
    string ExecutablePath,
    string Arguments,
    Dictionary<string, string>? Environment);

public record CompilerOptions(
    string InputFilePath,
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
    IReadOnlyList<string>? LinkFlags = null
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
        // Default working directory to the directory of the input file if not specified
        var workingDir = options.WorkingDirectory
            ?? Path.GetDirectoryName(Path.GetFullPath(options.InputFilePath))
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

        // 1. Module Loading and Parsing
        var moduleCompilerLogger = loggerFactory.CreateLogger<ModuleCompiler>();
        var moduleCompiler = new ModuleCompiler(compilation, moduleCompilerLogger, new FileSystemSourceProvider());
        var parsedModules = moduleCompiler.CompileModules(options.InputFilePath);
        allDiagnostics.AddRange(moduleCompiler.Diagnostics);

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
            var modulePath = TemplateExpander.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
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
                : TemplateExpander.DeriveModulePath(key, compilation.IncludePaths, compilation.WorkingDirectory);

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
            hmChecker.CheckModuleBodies(kvp.Value, ResolveModulePath(kvp.Key));

        // Resolve specializations deferred due to unresolved TypeVars
        hmChecker.ResolvePendingSpecializations();

        foreach (var kvp in parsedModules)
            hmChecker.CheckGenericBodies(kvp.Value, ResolveModulePath(kvp.Key));

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
        var lowering = new HmAstLowering(typeCheckResult, layoutService);

        var moduleEntries = parsedModules.Select(kvp =>
        {
            return (ResolveModulePath(kvp.Key), kvp.Value);
        });

        var irModule = lowering.LowerModule(moduleEntries, options.RunTests);
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

        // Optimization passes: iterate inline+peephole until no more cascading opportunities
        for (int i = 0; i < 3; i++)
        {
            int fnCountBefore = irModule.Functions.Count;
            InliningPass.Run(irModule);
            PeepholeOptimizer.Optimize(irModule);
            if (irModule.Functions.Count == fnCountBefore) break;
        }

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
                Path.GetDirectoryName(Path.GetFullPath(options.InputFilePath))!,
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
            outputFilePath = Path.ChangeExtension(options.InputFilePath, ".exe");
            if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
                outputFilePath = Path.ChangeExtension(outputFilePath, null);
        }

        var outputDir = Path.GetDirectoryName(Path.GetFullPath(outputFilePath))!;
        var cFilePath = Path.Combine(outputDir, Path.GetFileNameWithoutExtension(outputFilePath) + ".c");
        File.WriteAllText(cFilePath, cCode);

        // 6. Discover native C source files from stdlib modules.
        //    Only link hand-written .c files — skip generated ones.
        var extraCFiles = new List<string>();
        var stdlibFullPath = Path.GetFullPath(options.StdlibPath);
        foreach (var modulePath in parsedModules.Keys)
        {
            if (!Path.GetFullPath(modulePath).StartsWith(stdlibFullPath)) continue;
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
        var compilerConfig = CompilerDiscovery.GetCompilerForCompilation(
            cFilePath, outputFilePath, options.ReleaseBuild,
            extraCFiles.Count > 0 ? extraCFiles : null,
            options.LinkFlags);

        if (compilerConfig == null)
        {
            allDiagnostics.Add(Diagnostic.Error("No C compiler configuration provided.", SourceSpan.None, "E0000"));
            return new CompilationResult(false, null, allDiagnostics, compilation);
        }

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

}
