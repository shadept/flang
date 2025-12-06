using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using FLang.CLI;
using FLang.Codegen.C;
using FLang.Core;
using FLang.IR;
using FLang.Semantics;

// Parse command-line arguments
string? inputFilePath = null;
string? stdlibPath = null;
string? emitFir = null;
var demoDiagnostics = false;
var releaseBuild = false;
var findCompilersOnly = false;

for (var i = 0; i < args.Length; i++)
    if (args[i] == "--stdlib-path" && i + 1 < args.Length)
        stdlibPath = args[++i];
    else if (args[i] == "--emit-fir" && i + 1 < args.Length)
        emitFir = args[++i];
    else if (args[i] == "--demo-diagnostics")
        demoDiagnostics = true;
    else if (args[i] == "--release")
        releaseBuild = true;
    else if (args[i] == "--find-compilers")
        findCompilersOnly = true;
    else if (!args[i].StartsWith("--")) inputFilePath = args[i];

if (demoDiagnostics)
{
    DiagnosticDemo.Run();
    return;
}

// Handle compiler discovery-only mode regardless of input file presence
if (findCompilersOnly)
{
    PrintAvailableCompilers();
    return;
}

if (inputFilePath == null)
{
    Console.WriteLine("Usage: flang [options] <file>");
    Console.WriteLine("Options:");
    Console.WriteLine("  --stdlib-path <path>    Path to standard library directory");
    Console.WriteLine("  --emit-fir <file>       Emit FIR (intermediate representation) to file (use '-' for stdout)");
    Console.WriteLine("  --release               Enable C backend optimization (passes -O2 /O2)");
    Console.WriteLine("  --demo-diagnostics      Show diagnostic system demo");
    Console.WriteLine("  --find-compilers        Probe and list available C compilers on this machine, then exit");
    return;
}

// Set the default stdlib path if not provided
if (stdlibPath == null) stdlibPath = Path.Combine(AppContext.BaseDirectory, "stdlib");

var compilation = new Compilation();
compilation.StdlibPath = stdlibPath;

// Compile all modules (entry point + imports)
var moduleCompiler = new ModuleCompiler(compilation);
var parsedModules = moduleCompiler.CompileModules(inputFilePath);

// Report module loading/import resolution diagnostics (e.g., unresolved imports)
if (moduleCompiler.Diagnostics.Any())
{
    foreach (var diagnostic in moduleCompiler.Diagnostics)
        DiagnosticPrinter.PrintToConsole(diagnostic, compilation);

    Console.Error.WriteLine($"Error: Module loading failed with {moduleCompiler.Diagnostics.Count} error(s)");
    Environment.Exit(1);
}

// Type checking pass
var typeSolver = new TypeSolver(compilation);

// First pass: collect all struct definitions and function signatures from all modules
foreach (var module in parsedModules.Values)
{
    typeSolver.CollectStructDefinitions(module);
    typeSolver.CollectFunctionSignatures(module);
}

// Second pass: type check all function bodies
foreach (var module in parsedModules.Values) typeSolver.CheckModuleBodies(module);

typeSolver.EnsureAllTypesResolved();

// Check for type errors
if (typeSolver.Diagnostics.Any())
{
    foreach (var diagnostic in typeSolver.Diagnostics) DiagnosticPrinter.PrintToConsole(diagnostic, compilation);

    Console.Error.WriteLine($"Error: Type checking failed with {typeSolver.Diagnostics.Count} error(s)");
    Environment.Exit(1);
}

// Lower all functions from all modules to FIR
var allFunctions = new List<Function>();
var loweringDiagnostics = new List<Diagnostic>();

foreach (var module in parsedModules.Values)
foreach (var functionNode in module.Functions)
{
    // Skip lowering generic templates; only lower instantiated specializations
    if (typeSolver.IsGenericFunction(functionNode)) continue;
    var (irFunction, diagnostics) = AstLowering.Lower(functionNode, compilation, typeSolver);
    allFunctions.Add(irFunction);
    loweringDiagnostics.AddRange(diagnostics);
}

// Lower any generic specializations requested by type checking
foreach (var specFn in typeSolver.GetSpecializedFunctions())
{
    var (irFunction, diagnostics) = AstLowering.Lower(specFn, compilation, typeSolver);
    allFunctions.Add(irFunction);
    loweringDiagnostics.AddRange(diagnostics);
}

// Check for lowering errors
if (loweringDiagnostics.Count != 0)
{
    foreach (var diagnostic in loweringDiagnostics) DiagnosticPrinter.PrintToConsole(diagnostic, compilation);

    Console.Error.WriteLine($"Error: FIR lowering failed with {loweringDiagnostics.Count} error(s)");
    Environment.Exit(1);
}

if (allFunctions.Count == 0)
{
    Console.Error.WriteLine("Error: No functions found in any module");
    Environment.Exit(1);
}

// Emit FIR if requested (for all functions)
if (emitFir != null)
{
    var firBuilder = new StringBuilder();
    foreach (var func in allFunctions) firBuilder.AppendLine(FirPrinter.Print(func));

    var firOutput = firBuilder.ToString();
    if (emitFir == "-")
    {
        Console.WriteLine("=== FIR ===");
        Console.WriteLine(firOutput);
    }
    else
    {
        File.WriteAllText(emitFir, firOutput);
        // Console.WriteLine($"FIR emitted to {emitFir}");
    }
}

// Generate C code for all functions with proper hoisting/deduplication
var headerBuilder = new StringBuilder();
headerBuilder.AppendLine("#include <stdio.h>");
headerBuilder.AppendLine("#include <stdint.h>");
headerBuilder.AppendLine("#include <string.h>");
headerBuilder.AppendLine();

// Always emit String struct - it's a core compiler type
headerBuilder.AppendLine("struct String {");
headerBuilder.AppendLine("    uint8_t* ptr;");
headerBuilder.AppendLine("    uintptr_t len;");
headerBuilder.AppendLine("};");
headerBuilder.AppendLine();

// Collect struct definitions and extern prototypes uniquely
var structBlocks = new Dictionary<string, string>(); // name -> block
var externPrototypes = new HashSet<string>();
var functionBodies = new StringBuilder();

foreach (var func in allFunctions)
{
    var funcCode = CCodeGenerator.Generate(func);
    var lines = funcCode.Split(["\r\n", "\n"], StringSplitOptions.None);

    bool inStruct = false;
    string currentStructName = "";
    var currentStructLines = new List<string>();

    foreach (var line in lines)
    {
        if (string.IsNullOrWhiteSpace(line) || line.StartsWith("#include"))
            continue;

        var trimmed = line.TrimStart();
        // Detect struct definition: "struct Name {" but NOT variable declarations like "struct Name var = ..."
        if (!inStruct && trimmed.StartsWith("struct ") && trimmed.Contains("{") && !trimmed.Contains("="))
        {
            // Begin struct block
            var afterStruct = trimmed.Substring("struct ".Length);
            var name = afterStruct.Split([' ', '{'], StringSplitOptions.RemoveEmptyEntries)[0];
            inStruct = true;
            currentStructName = name;
            currentStructLines.Clear();
            currentStructLines.Add(line);
            continue;
        }

        if (inStruct)
        {
            currentStructLines.Add(line);
            if (trimmed.StartsWith("};"))
            {
                // End of struct block
                var block = string.Join("\n", currentStructLines);
                structBlocks.TryAdd(currentStructName, block);
                inStruct = false;
                currentStructName = "";
                currentStructLines.Clear();
            }

            continue;
        }

        if (trimmed.StartsWith("extern "))
        {
            externPrototypes.Add(line.Trim());
            continue;
        }

        // Otherwise, it's part of a function or static data
        functionBodies.AppendLine(line);
    }
}

// Emit unique struct definitions first
foreach (var block in structBlocks.Values)
{
    headerBuilder.AppendLine(block);
    headerBuilder.AppendLine();
}

// Emit prototypes for all non-foreign functions to avoid forward-declaration issues
foreach (var f in allFunctions)
{
    if (f.IsForeign) continue;
    var plist = string.Join(", ", f.Parameters.Select(p =>
    {
        var paramType = TypeRegistry.ToCType(p.Type);
        // If parameter is a struct (not a pointer to struct), emit as pointer
        if (p.Type is StructType)
            paramType += "*";
        return $"{paramType} {p.Name}";
    }));
    if (f.Parameters.Count == 0) plist = "void";
    var protoName = f.Name == "main"
        ? "main"
        : NameMangler.GenericFunction(f.Name, f.Parameters.Select(p => p.Type).ToList());
    headerBuilder.AppendLine($"{TypeRegistry.ToCType(f.ReturnType)} {protoName}({plist});");
}

// Emit unique extern prototypes next
foreach (var proto in externPrototypes)
    headerBuilder.AppendLine(proto);

headerBuilder.AppendLine();

var cCode = headerBuilder.ToString() + functionBodies.ToString();

var cFilePath = Path.ChangeExtension(inputFilePath, ".c");
File.WriteAllText(cFilePath, cCode);

var outputFilePath = Path.ChangeExtension(inputFilePath, ".exe");
if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
    outputFilePath = Path.ChangeExtension(outputFilePath, null);

// Get compiler configuration for compilation
var compiler = GetCompilerForCompilation(cFilePath, outputFilePath, releaseBuild);

if (compiler == null)
{
    Console.Error.WriteLine("Error: Could not find any C compiler.");

    if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
    {
        Console.Error.WriteLine(
            "Hint (macOS): Install Xcode Command Line Tools with 'xcode-select --install', then try again. You can also verify with 'xcrun --find clang'.");
        Console.Error.WriteLine(
            "Alternatively, set the CC environment variable to your compiler, e.g., 'export CC=clang'.");
    }
    else if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
    {
        Console.Error.WriteLine(
            "Hint (Unix): Install a C compiler (clang or gcc) and ensure it is on your PATH, or set the CC environment variable.");
    }
    else
    {
        Console.Error.WriteLine(
            "Hint (Windows): Install Visual Studio Build Tools (with C++), or install gcc (e.g., via MSYS2/MinGW) and ensure it is on PATH.");
    }

    Environment.Exit(1);
}

// Invoke the C compiler
var startInfo = new ProcessStartInfo
{
    FileName = compiler.ExecutablePath,
    Arguments = compiler.Arguments,
    RedirectStandardOutput = true,
    RedirectStandardError = true,
    UseShellExecute = false,
    CreateNoWindow = true
};

// Add custom environment variables if provided (needed for cl.exe)
if (compiler.Environment != null)
    foreach (var (key, value) in compiler.Environment)
        startInfo.EnvironmentVariables[key] = value;

var process = new Process { StartInfo = startInfo };

try
{
    process.Start();
    process.WaitForExit();

    if (process.ExitCode != 0)
    {
        Console.Error.WriteLine($"C compiler ({compiler.Name}) failed:");
        var stdout = process.StandardOutput.ReadToEnd();
        var stderr = process.StandardError.ReadToEnd();
        if (!string.IsNullOrWhiteSpace(stdout)) Console.Error.WriteLine(stdout);
        if (!string.IsNullOrWhiteSpace(stderr)) Console.Error.WriteLine(stderr);
        Environment.Exit(1);
    }

    // Clean up intermediate files (cl.exe creates .obj files)
    var objFilePath = Path.ChangeExtension(inputFilePath, ".obj");
    if (File.Exists(objFilePath)) File.Delete(objFilePath);

    var baseNameObj = Path.GetFileNameWithoutExtension(inputFilePath) + ".obj";
    if (File.Exists(baseNameObj)) File.Delete(baseNameObj);
}
catch (Exception ex)
{
    Console.Error.WriteLine($"Error invoking C compiler ({compiler.ExecutablePath}): {ex.Message}");
    Environment.Exit(1);
}

// --- Utilities: compiler discovery and configuration ---

/// <summary>
/// Get the first available C compiler configured for compilation.
/// Returns null if no compiler is found.
/// </summary>
static CompilerConfig? GetCompilerForCompilation(string cFilePath, string outputFilePath, bool releaseBuild)
{
    var availableCompilers = FindCompilersOrderedByPreference();
    var selected = availableCompilers.FirstOrDefault(c => c.path != null);

    if (selected.path == null)
        return null;

    string executablePath = selected.path;
    string arguments;
    Dictionary<string, string>? environment = null;

    // Check if this is MSVC (cl.exe)
    if (selected.name.Contains("cl.exe"))
    {
        var (clPath, clEnv) = FindClExeWithEnvironment();
        environment = clEnv;

        var msvcArgs = new List<string> { "/nologo" };
        if (releaseBuild) msvcArgs.Add("/O2");
        msvcArgs.Add($"/Fe\"{outputFilePath}\"");
        msvcArgs.Add($"\"{cFilePath}\"");
        arguments = string.Join(" ", msvcArgs);
    }
    else
    {
        // Unix-like compilers (gcc, clang, cc, xcrun)
        var unixArgs = new List<string>();
        if (releaseBuild) unixArgs.Add("-O2");
        unixArgs.Add($"-g -o \"{outputFilePath}\"");
        unixArgs.Add($"\"{cFilePath}\"");

        // Special handling for xcrun
        if (selected.name.Contains("xcrun"))
        {
            executablePath = "xcrun";
            arguments = "clang " + string.Join(" ", unixArgs);
        }
        else
        {
            arguments = string.Join(" ", unixArgs);
        }
    }

    return new CompilerConfig(selected.name, executablePath, arguments, environment);
}

/// <summary>
/// Find available C compilers ordered by preference.
/// Returns a list of (name, path, source) tuples where:
/// - name: Display name of the compiler
/// - path: Full path to the compiler (null if not found)
/// - source: How the compiler was discovered ("env", "xcrun", "vswhere", "path")
/// </summary>
static List<(string name, string? path, string source)> FindCompilersOrderedByPreference()
{
    var results = new List<(string name, string? path, string source)>();

    if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
    {
        // 1) CC environment variable (highest priority)
        var ccEnv = Environment.GetEnvironmentVariable("CC");
        if (!string.IsNullOrWhiteSpace(ccEnv))
        {
            string? resolved = null;
            var cc = ccEnv.Trim();
            if (cc.Contains('/') || cc.Contains(Path.DirectorySeparatorChar) || Path.IsPathRooted(cc))
            {
                resolved = File.Exists(cc) ? Path.GetFullPath(cc) : null;
            }
            else
            {
                resolved = ResolveCommandPath(cc);
            }

            results.Add(("$CC" + " (" + cc + ")", resolved, "env"));
        }

        // 2) macOS xcrun --find clang
        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        {
            var xcrunFound = ResolveCommandPath("xcrun") != null;
            string? xcrunClang = null;
            if (xcrunFound)
                xcrunClang = RunAndCaptureFirstLine("xcrun", "--find clang");
            results.Add(("xcrun clang", string.IsNullOrWhiteSpace(xcrunClang) ? null : xcrunClang, "xcrun"));
        }

        // 3) PATH lookups
        foreach (var name in new[] { "clang", "cc", "gcc" })
            results.Add((name, ResolveCommandPath(name), "path"));
    }
    else
    {
        // Windows: MSVC via vswhere/env + PATH fallbacks
        var (clPath, _) = FindClExeWithEnvironment();
        if (clPath != null)
            results.Add(("cl.exe", clPath, "vswhere"));
        else
            results.Add(("cl.exe", ResolveCommandPath("cl.exe"), "path"));

        results.Add(("gcc", ResolveCommandPath("gcc"), "path"));
    }

    return results;
}

/// <summary>
/// Print available C compilers to the console.
/// </summary>
static void PrintAvailableCompilers()
{
    var results = FindCompilersOrderedByPreference();

    Console.WriteLine("Compiler discovery (ordered by preference):");
    int idx = 1;
    foreach (var r in results)
    {
        var status = r.path != null ? "FOUND" : "not found";
        var pathText = r.path ?? "<unavailable>";
        Console.WriteLine($"  {idx}. {r.name,-15} : {status} -> {pathText}");
        idx++;
    }

    if (results.All(r => r.path == null))
    {
        Console.WriteLine();
        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        {
            Console.WriteLine(
                "Hint (macOS): Install Xcode Command Line Tools with 'xcode-select --install'. You can verify with 'xcrun --find clang'.");
            Console.WriteLine("Alternatively, set the CC environment variable, e.g., 'export CC=clang'.");
        }
        else if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            Console.WriteLine(
                "Hint (Unix): Install clang or gcc and ensure it is on your PATH, or set CC to your compiler.");
        }
        else
        {
            Console.WriteLine(
                "Hint (Windows): Install Visual Studio Build Tools (with C++), or install gcc (e.g., via MSYS2/MinGW) and ensure it is on PATH.");
        }
    }
}

static string? ResolveCommandPath(string command)
{
    try
    {
        var isWindows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
        var fileName = isWindows ? "where" : "which";
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = command,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        using var p = Process.Start(psi);
        if (p == null) return null;
        var output = p.StandardOutput.ReadToEnd();
        p.WaitForExit();
        var line = output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        if (string.IsNullOrWhiteSpace(line)) return null;
        return line.Trim();
    }
    catch
    {
        return null;
    }
}

static string? RunAndCaptureFirstLine(string fileName, string arguments)
{
    try
    {
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        using var p = Process.Start(psi);
        if (p == null) return null;
        var output = p.StandardOutput.ReadToEnd();
        p.WaitForExit();
        var line = output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        if (string.IsNullOrWhiteSpace(line)) return null;
        return line.Trim();
    }
    catch
    {
        return null;
    }
}

static (string?, Dictionary<string, string>?) FindClExeWithEnvironment()
{
    // Try vswhere first (most reliable for modern VS installations)
    var vswherePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
        "Microsoft Visual Studio", "Installer", "vswhere.exe");

    string? vsInstallPath = null;

    if (File.Exists(vswherePath))
        try
        {
            var process = Process.Start(new ProcessStartInfo
            {
                FileName = vswherePath,
                Arguments =
                    "-latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath",
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true
            });

            if (process != null)
            {
                vsInstallPath = process.StandardOutput.ReadToEnd().Trim();
                process.WaitForExit();

                if (string.IsNullOrEmpty(vsInstallPath) || !Directory.Exists(vsInstallPath))
                    vsInstallPath = null;
            }
        }
        catch
        {
        }

    // Fallback: check common installation directories
    if (vsInstallPath == null)
    {
        var commonBasePaths = new[]
        {
            @"C:\Program Files (x86)\Microsoft Visual Studio\2022",
            @"C:\Program Files (x86)\Microsoft Visual Studio\2019",
            @"C:\Program Files (x86)\Microsoft Visual Studio\2017"
        };

        var editions = new[] { "Community", "Professional", "Enterprise", "BuildTools" };

        foreach (var basePath in commonBasePaths)
        {
            foreach (var edition in editions)
            {
                var testPath = Path.Combine(basePath, edition);
                if (Directory.Exists(testPath))
                {
                    vsInstallPath = testPath;
                    break;
                }
            }

            if (vsInstallPath != null) break;
        }
    }

    if (vsInstallPath == null)
        return (null, null);

    // Find the MSVC toolset version
    var vcToolsPath = Path.Combine(vsInstallPath, "VC", "Tools", "MSVC");
    if (!Directory.Exists(vcToolsPath))
        return (null, null);

    string? toolsetVersion = null;
    try
    {
        toolsetVersion = Directory.GetDirectories(vcToolsPath)
            .Select(Path.GetFileName)
            .OrderByDescending(v => v)
            .FirstOrDefault();
    }
    catch
    {
    }

    if (toolsetVersion == null)
        return (null, null);

    var clPath = Path.Combine(vcToolsPath, toolsetVersion, "bin", "Hostx64", "x64", "cl.exe");
    if (!File.Exists(clPath))
        return (null, null);

    // Set up the environment variables needed for cl.exe
    var env = new Dictionary<string, string>();

    var toolsetDir = Path.Combine(vcToolsPath, toolsetVersion);
    var includeDir = Path.Combine(toolsetDir, "include");
    var libDir = Path.Combine(toolsetDir, "lib", "x64");

    // Windows SDK paths
    var windowsSdkDir = @"C:\Program Files (x86)\Windows Kits\10";
    string? sdkVersion = null;

    if (Directory.Exists(windowsSdkDir))
    {
        var sdkIncludePath = Path.Combine(windowsSdkDir, "Include");
        if (Directory.Exists(sdkIncludePath))
            try
            {
                sdkVersion = Directory.GetDirectories(sdkIncludePath)
                    .Select(Path.GetFileName)
                    .OrderByDescending(v => v)
                    .FirstOrDefault();
            }
            catch
            {
            }
    }

    // Build INCLUDE path
    var includePaths = new List<string> { includeDir };
    if (sdkVersion != null)
    {
        includePaths.Add(Path.Combine(windowsSdkDir, "Include", sdkVersion, "ucrt"));
        includePaths.Add(Path.Combine(windowsSdkDir, "Include", sdkVersion, "um"));
        includePaths.Add(Path.Combine(windowsSdkDir, "Include", sdkVersion, "shared"));
    }

    env["INCLUDE"] = string.Join(";", includePaths);

    // Build LIB path
    var libPaths = new List<string> { libDir };
    if (sdkVersion != null)
    {
        libPaths.Add(Path.Combine(windowsSdkDir, "Lib", sdkVersion, "ucrt", "x64"));
        libPaths.Add(Path.Combine(windowsSdkDir, "Lib", sdkVersion, "um", "x64"));
    }

    env["LIB"] = string.Join(";", libPaths);

    // Add cl.exe directory to PATH
    var binDir = Path.GetDirectoryName(clPath);
    if (binDir != null) env["PATH"] = binDir + ";" + Environment.GetEnvironmentVariable("PATH");

    return (clPath, env);
}

/// <summary>
/// Represents a fully configured C compiler ready for invocation.
/// </summary>
record CompilerConfig(string Name, string ExecutablePath, string Arguments, Dictionary<string, string>? Environment);
