using System.Diagnostics;
using System.Runtime.InteropServices;
using FLang.Codegen.C;
using FLang.Core;
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
    CompilerConfig? CCompilerConfig = null,
    bool ReleaseBuild = false,
    string? EmitFir = null,
    bool DebugLogging = false,
    string? WorkingDirectory = null,
    IReadOnlyList<string>? IncludePaths = null,
    bool RunTests = false
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
        var moduleCompiler = new ModuleCompiler(compilation, moduleCompilerLogger);
        var parsedModules = moduleCompiler.CompileModules(options.InputFilePath);
        allDiagnostics.AddRange(moduleCompiler.Diagnostics);

        if (allDiagnostics.Any(d => d.Severity == DiagnosticSeverity.Error))
        {
            return new CompilationResult(false, null, allDiagnostics, compilation);
        }

        // 2. HM Type Checking — multi-phase across all modules
        // BFS insertion order from ModuleCompiler is already correct (prelude → core → user).
        // The 2-phase collect-then-resolve approach makes ordering within each phase irrelevant.
        var hmChecker = new HmTypeChecker(compilation);

        foreach (var kvp in parsedModules)
        {
            var modulePath = HmTypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            hmChecker.CollectNominalTypes(kvp.Value, modulePath);
        }

        foreach (var kvp in parsedModules)
        {
            var modulePath = HmTypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            hmChecker.ResolveNominalTypes(kvp.Value, modulePath);
        }

        foreach (var kvp in parsedModules)
        {
            var modulePath = HmTypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            hmChecker.CollectFunctionSignatures(kvp.Value, modulePath);
        }

        foreach (var kvp in parsedModules)
        {
            var modulePath = HmTypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            hmChecker.CheckGlobalConstants(kvp.Value, modulePath);
        }

        foreach (var kvp in parsedModules)
        {
            var modulePath = HmTypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            hmChecker.CheckModuleBodies(kvp.Value, modulePath);
        }

        // Post-inference validation (unsuffixed literal checks: E2001, E2029, E2102)
        hmChecker.ValidatePostInference();

        allDiagnostics.AddRange(hmChecker.Diagnostics);

        if (allDiagnostics.Any(d => d.Severity == DiagnosticSeverity.Error))
        {
            return new CompilationResult(false, null, allDiagnostics, compilation);
        }

        // 3. Lowering to IrModule
        var layoutService = new TypeLayoutService(hmChecker.Engine, hmChecker);
        var lowering = new HmAstLowering(hmChecker, layoutService, hmChecker.Engine);

        var moduleEntries = parsedModules.Select(kvp =>
        {
            var modulePath = HmTypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            return (modulePath, kvp.Value);
        });

        var irModule = lowering.LowerModule(moduleEntries);
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

        // 6. Invoke C Compiler
        var compilerConfig = options.CCompilerConfig;

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
            process.WaitForExit();

            if (process.ExitCode != 0)
            {
                var stdout = process.StandardOutput.ReadToEnd();
                var stderr = process.StandardError.ReadToEnd();
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
}
