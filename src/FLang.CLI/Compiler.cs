using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using FLang.Codegen.C;
using FLang.Core;
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
    CompilerConfig? CCompilerConfig = null,
    bool ReleaseBuild = false,
    string? EmitFir = null,
    bool DebugLogging = false,
    string? WorkingDirectory = null,
    IReadOnlyList<string>? IncludePaths = null
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

        // Build include paths: working directory, stdlib, then any additional paths
        compilation.IncludePaths.Add(workingDir);  // Working dir first (input file's directory)
        compilation.IncludePaths.Add(options.StdlibPath);  // Then stdlib
        if (options.IncludePaths != null && options.IncludePaths.Count > 0)
        {
            foreach (var path in options.IncludePaths)
                compilation.IncludePaths.Add(path);
        }

        var allDiagnostics = new List<Diagnostic>();

        // 1. Module Loading and Parsing
        var moduleCompiler = new ModuleCompiler(compilation);
        var parsedModules = moduleCompiler.CompileModules(options.InputFilePath);
        allDiagnostics.AddRange(moduleCompiler.Diagnostics);

        if (allDiagnostics.Any(d => d.Severity == DiagnosticSeverity.Error))
        {
            return new CompilationResult(false, null, allDiagnostics, compilation);
        }

        // 2. Type Checking
        using var loggerFactory = LoggerFactory.Create(builder =>
        {
            builder.SetMinimumLevel(options.DebugLogging ? LogLevel.Debug : LogLevel.Warning);
            builder
                .AddConsoleFormatter<CustomDebugFormatter,
                    Microsoft.Extensions.Logging.Console.ConsoleFormatterOptions>();
            builder.AddConsole(o => o.FormatterName = "custom-debug");
        });

        var typeSolverLogger = loggerFactory.CreateLogger<TypeChecker>();
        var typeSolver = new TypeChecker(compilation, typeSolverLogger);

        // Phase 1: Collect struct definitions from all modules
        foreach (var kvp in parsedModules)
        {
            var modulePath = TypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            typeSolver.CollectStructDefinitions(kvp.Value, modulePath);
        }

        // Phase 2: Collect function signatures
        foreach (var kvp in parsedModules)
        {
            var modulePath = TypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            typeSolver.CollectFunctionSignatures(kvp.Value, modulePath);
        }

        // Phase 3: Register imports (must happen after all structs collected)
        foreach (var kvp in parsedModules)
        {
            var modulePath = TypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            typeSolver.RegisterImports(kvp.Value, modulePath);
        }

        // Phase 4: Type check module bodies
        foreach (var kvp in parsedModules)
        {
            var modulePath = TypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            typeSolver.CheckModuleBodies(kvp.Value, modulePath);
        }

        typeSolver.EnsureAllTypesResolved();
        allDiagnostics.AddRange(typeSolver.Diagnostics);

        if (allDiagnostics.Any(d => d.Severity == DiagnosticSeverity.Error))
        {
            return new CompilationResult(false, null, allDiagnostics, compilation);
        }

        // 3. Lowering to FIR
        var allFunctions = new List<Function>();
        var loweringDiagnostics = new List<Diagnostic>();

        foreach (var module in parsedModules.Values)
        {
            foreach (var functionNode in module.Functions)
            {
                if (typeSolver.IsGenericFunction(functionNode)) continue;
                var (irFunction, diagnostics) = AstLowering.Lower(functionNode, compilation, typeSolver);
                allFunctions.Add(irFunction);
                loweringDiagnostics.AddRange(diagnostics);
            }
        }

        foreach (var specFn in typeSolver.GetSpecializedFunctions())
        {
            var (irFunction, diagnostics) = AstLowering.Lower(specFn, compilation, typeSolver);
            allFunctions.Add(irFunction);
            loweringDiagnostics.AddRange(diagnostics);
        }

        allDiagnostics.AddRange(loweringDiagnostics);

        if (allDiagnostics.Any(d => d.Severity == DiagnosticSeverity.Error))
        {
            return new CompilationResult(false, null, allDiagnostics, compilation);
        }

        if (allFunctions.Count == 0)
        {
            allDiagnostics.Add(Diagnostic.Error("No functions found in any module", SourceSpan.None, "E0000"));
            return new CompilationResult(false, null, allDiagnostics, compilation);
        }

        // 4. Emit FIR (optional)
        if (options.EmitFir != null)
        {
            var firBuilder = new StringBuilder();
            foreach (var func in allFunctions) firBuilder.AppendLine(FirPrinter.Print(func));

            var firOutput = firBuilder.ToString();
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
        var cCode = CCodeGenerator.GenerateProgram(allFunctions);
        var cFilePath = Path.ChangeExtension(options.InputFilePath, ".c");
        File.WriteAllText(cFilePath, cCode);

        var outputFilePath = Path.ChangeExtension(options.InputFilePath, ".exe");
        if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            outputFilePath = Path.ChangeExtension(outputFilePath, null);

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
            var objFilePath = Path.ChangeExtension(options.InputFilePath, ".obj");
            if (File.Exists(objFilePath)) File.Delete(objFilePath);

            var baseNameObj = Path.GetFileNameWithoutExtension(options.InputFilePath) + ".obj";
            if (File.Exists(baseNameObj)) File.Delete(baseNameObj);
        }
        catch (Exception ex)
        {
            allDiagnostics.Add(Diagnostic.Error($"Error invoking C compiler ({compilerConfig.ExecutablePath}): {ex.Message}", SourceSpan.None, "E0000"));
            return new CompilationResult(false, null, allDiagnostics, compilation);
        }

        return new CompilationResult(true, outputFilePath, allDiagnostics, compilation);
    }
}