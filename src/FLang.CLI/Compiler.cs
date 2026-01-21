using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using FLang.Codegen.C;
using FLang.Core;
using FLang.Frontend.Ast.Declarations;
using FLang.IR;
using FLang.IR.Instructions;
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

        // 2. Type Checking

        var typeSolverLogger = loggerFactory.CreateLogger<TypeChecker>();
        var typeSolver = new TypeChecker(compilation, typeSolverLogger);

        // Phase 1: Register imports (before any type resolution)
        foreach (var kvp in parsedModules)
        {
            var modulePath = TypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            typeSolver.RegisterImports(kvp.Value, modulePath);
        }

        // Phase 2a: Collect struct names (without resolving fields)
        // This enables order-independent struct declarations
        foreach (var kvp in parsedModules)
        {
            var modulePath = TypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            typeSolver.CollectStructNames(kvp.Value, modulePath);
        }

        // Phase 2a-enum: Collect enum names (without resolving variant types)
        // This enables order-independent enum declarations
        foreach (var kvp in parsedModules)
        {
            var modulePath = TypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            typeSolver.CollectEnumNames(kvp.Value, modulePath);
        }

        // Phase 2b: Resolve struct field types (after all struct names registered)
        foreach (var kvp in parsedModules)
        {
            var modulePath = TypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            typeSolver.ResolveStructFields(kvp.Value, modulePath);
        }

        // Phase 2b-enum: Resolve enum variant types (after all type names registered)
        foreach (var kvp in parsedModules)
        {
            var modulePath = TypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            typeSolver.ResolveEnumVariants(kvp.Value, modulePath);
        }

        // Phase 3: Collect function signatures
        foreach (var kvp in parsedModules)
        {
            var modulePath = TypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            typeSolver.CollectFunctionSignatures(kvp.Value, modulePath);
        }

        // Phase 4: Type check module bodies
        foreach (var kvp in parsedModules)
        {
            var modulePath = TypeChecker.DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
            typeSolver.CheckModuleBodies(kvp.Value, modulePath);
        }

        typeSolver.VerifyAllTypesResolved();
        allDiagnostics.AddRange(typeSolver.Diagnostics);

        if (allDiagnostics.Any(d => d.Severity == DiagnosticSeverity.Error))
        {
            return new CompilationResult(false, null, allDiagnostics, compilation);
        }

        // 3. Lowering to FIR
        var loweringLogger = loggerFactory.CreateLogger<AstLowering>();
        var allFunctions = new List<Function>();
        var loweringDiagnostics = new List<Diagnostic>();

        // First pass: lower global constants from all modules
        foreach (var module in parsedModules.Values)
        {
            var globalConstDiagnostics = AstLowering.LowerGlobalConstants(module, compilation, loweringLogger);
            loweringDiagnostics.AddRange(globalConstDiagnostics);
        }

        // Collect all test declarations if running tests
        var allTests = new List<(TestDeclarationNode Test, Function Function)>();

        foreach (var module in parsedModules.Values)
        {
            foreach (var functionNode in module.Functions)
            {
                if (typeSolver.IsGenericFunction(functionNode)) continue;
                var (irFunction, diagnostics) = AstLowering.Lower(functionNode, compilation, typeSolver, loweringLogger);
                allFunctions.Add(irFunction);
                loweringDiagnostics.AddRange(diagnostics);
            }

            // Lower test declarations if running tests
            if (options.RunTests)
            {
                foreach (var testNode in module.Tests)
                {
                    var (testFunction, diagnostics) = AstLowering.LowerTest(testNode, compilation, typeSolver, loweringLogger);
                    allFunctions.Add(testFunction);
                    allTests.Add((testNode, testFunction));
                    loweringDiagnostics.AddRange(diagnostics);
                }
            }
        }

        foreach (var specFn in typeSolver.GetSpecializedFunctions())
        {
            var (irFunction, diagnostics) = AstLowering.Lower(specFn, compilation, typeSolver, loweringLogger);
            allFunctions.Add(irFunction);
            loweringDiagnostics.AddRange(diagnostics);
        }

        // Generate test runner if running tests
        if (options.RunTests && allTests.Count > 0)
        {
            var testRunner = GenerateTestRunner(allTests, allFunctions);
            allFunctions.Add(testRunner);
        }
        else if (options.RunTests && allTests.Count == 0)
        {
            allDiagnostics.Add(Diagnostic.Warning("No test blocks found in any module", SourceSpan.None, "W0001"));
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

    /// <summary>
    /// Generate a test runner main() function that calls all test functions and reports results.
    /// </summary>
    private Function GenerateTestRunner(
        List<(TestDeclarationNode Test, Function Function)> tests,
        List<Function> allFunctions)
    {
        // Remove existing main() if present (we're replacing it)
        var existingMain = allFunctions.FirstOrDefault(f => f.Name == "main");
        if (existingMain != null)
        {
            allFunctions.Remove(existingMain);
        }

        // Create the test runner main function
        var main = new Function("main") { ReturnType = TypeRegistry.I32 };

        var entry = new BasicBlock("entry");
        main.BasicBlocks.Add(entry);

        // Generate calls to each test function
        var tempCounter = 0;
        foreach (var (testNode, testFn) in tests)
        {
            // Call the test function (void return)
            var result = new LocalValue($"test_result_{tempCounter++}", TypeRegistry.Void);
            var call = new CallInstruction(testFn.Name, new List<Value>(), result);
            entry.Instructions.Add(call);
        }

        // Return 0 (all tests passed - if a test fails, panic() will exit with 1)
        entry.Instructions.Add(new ReturnInstruction(new ConstantValue(0) { Type = TypeRegistry.I32 }));

        return main;
    }
}