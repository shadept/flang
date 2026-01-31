using System.Diagnostics;
using System.Runtime.InteropServices;
using FLang.CLI;
using FLang.Core;

// Parse command-line arguments
string? inputFilePath = null;
string? stdlibPath = null;
string? emitFir = null;
string? outputPath = null;
var demoDiagnostics = false;
var releaseBuild = false;
var findCompilersOnly = false;
var debugLogging = false;
var runTests = false;

for (var i = 0; i < args.Length; i++)
    if (args[i] == "--stdlib-path" && i + 1 < args.Length)
        stdlibPath = args[++i];
    else if (args[i] == "--emit-fir" && i + 1 < args.Length)
        emitFir = args[++i];
    else if ((args[i] == "-o" || args[i] == "--output") && i + 1 < args.Length)
        outputPath = args[++i];
    else if (args[i] == "--demo-diagnostics")
        demoDiagnostics = true;
    else if (args[i] == "--release")
        releaseBuild = true;
    else if (args[i] == "--find-compilers")
        findCompilersOnly = true;
    else if (args[i] == "--debug-logging")
        debugLogging = true;
    else if (args[i] == "--test")
        runTests = true;
    else if (!args[i].StartsWith("-")) inputFilePath = args[i];

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
    Console.WriteLine("  -o, --output <path>     Output executable path (default: same as input with .exe)");
    Console.WriteLine("  --stdlib-path <path>    Path to standard library directory");
    Console.WriteLine("  --emit-fir <file>       Emit FIR (intermediate representation) to file (use '-' for stdout)");
    Console.WriteLine("  --release               Enable C backend optimization (passes -O2 /O2)");
    Console.WriteLine("  --test                  Run test blocks instead of main()");
    Console.WriteLine("  --debug-logging         Enable detailed logs for the compiler stages");
    Console.WriteLine("  --demo-diagnostics      Show diagnostic system demo");
    Console.WriteLine("  --find-compilers        Probe and list available C compilers on this machine, then exit");
    return;
}

// Set the default stdlib path if not provided
stdlibPath ??= Path.Combine(AppContext.BaseDirectory, "stdlib");

// Resolve output path: default to input file location with platform extension
if (outputPath == null)
{
    outputPath = Path.ChangeExtension(inputFilePath, ".exe");
    if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        outputPath = Path.ChangeExtension(outputPath, null);
}

// Intermediate .c file goes next to the output
var outputDir = Path.GetDirectoryName(Path.GetFullPath(outputPath))!;
var cFilePath = Path.Combine(outputDir, Path.GetFileNameWithoutExtension(outputPath) + ".c");

var compilerConfig = CompilerDiscovery.GetCompilerForCompilation(cFilePath, outputPath, releaseBuild);

var compiler = new Compiler();
var options = new CompilerOptions(
    InputFilePath: inputFilePath,
    StdlibPath: stdlibPath,
    OutputPath: outputPath,
    CCompilerConfig: compilerConfig,
    ReleaseBuild: releaseBuild,
    EmitFir: emitFir,
    DebugLogging: debugLogging,
    RunTests: runTests
);

var result = compiler.Compile(options);

foreach (var diagnostic in result.Diagnostics)
{
    DiagnosticPrinter.PrintToConsole(diagnostic, result.CompilationContext);
}

if (!result.Success)
{
    if (compilerConfig == null)
    {
        PrintCompilerDiscoveryHints();
    }
    Console.Error.WriteLine($"Error: Compilation failed with {result.Diagnostics.Count(d => d.Severity == DiagnosticSeverity.Error)} error(s)");
    Environment.Exit(1);
}

// --- Utilities: compiler discovery and configuration ---

/// <summary>
/// Print available C compilers to the console.
/// </summary>
static void PrintAvailableCompilers()
{
    var results = CompilerDiscovery.FindCompilersOrderedByPreference();

    Console.WriteLine("Compiler discovery (ordered by preference):");
    int idx = 1;
    foreach (var (name, path, source) in results)
    {
        var status = path != null ? "FOUND" : "not found";
        var pathText = path ?? "<unavailable>";
        Console.WriteLine($"  {idx}. {name,-15} : {status} -> {pathText}");
        idx++;
    }

    if (results.All(r => r.path == null))
    {
        Console.WriteLine();
        PrintCompilerDiscoveryHints();
    }
}

static void PrintCompilerDiscoveryHints()
{
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
