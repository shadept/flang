using System.Diagnostics;
using System.Runtime.InteropServices;
using FLang.CLI;
using FLang.Core;
using FLang.Lsp;

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
var lspMode = false;
var dumpTemplates = false;

// Handle "test" subcommand: flang test <file>
if (args.Length > 0 && args[0] == "test")
{
    runTests = true;
    args = args[1..]; // consume "test", parse remaining normally
}

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
    else if (args[i] == "--lsp")
        lspMode = true;
    else if (args[i] == "--dump-templates")
        dumpTemplates = true;
    else if (args[i] == "--version" || args[i] == "-v")
    {
        Console.WriteLine("flang 0.1.0-alpha");
        return;
    }
    else if (!args[i].StartsWith('-')) inputFilePath = args[i];

if (lspMode)
{
    stdlibPath ??= Path.Combine(AppContext.BaseDirectory, "stdlib");
    await FLangLanguageServer.RunAsync(stdlibPath);
    return;
}

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
    Console.WriteLine("FLang — an experimental language that transpiles to C");
    Console.WriteLine();
    Console.WriteLine("Usage: flang [options] <file>");
    Console.WriteLine("       flang test <file>          Compile and run test blocks");
    Console.WriteLine();
    Console.WriteLine("Options:");
    Console.WriteLine("  -o, --output <path>     Output executable path (default: same as input with .exe)");
    Console.WriteLine("  --stdlib-path <path>    Path to standard library directory");
    Console.WriteLine("  --emit-fir <file>       Emit FIR (intermediate representation) to file (use '-' for stdout)");
    Console.WriteLine("  --release               Enable C backend optimization (passes -O2 /O2)");
    Console.WriteLine("  --test                  Run test blocks instead of main()");
    Console.WriteLine("  --lsp                   Start Language Server Protocol server over stdio");
    Console.WriteLine("  --debug-logging         Enable detailed logs for the compiler stages");
    Console.WriteLine("  --demo-diagnostics      Show diagnostic system demo");
    Console.WriteLine("  --find-compilers        Probe and list available C compilers on this machine, then exit");
    Console.WriteLine("  -v, --version           Print version and exit");
    return;
}

var stopwatch = Stopwatch.StartNew();

// Set the default stdlib path if not provided
stdlibPath ??= Path.Combine(AppContext.BaseDirectory, "stdlib");

// When running tests, use a temp directory for output
string? tempDir = null;
if (runTests)
{
    tempDir = Path.Combine(Path.GetTempPath(), "flang_test_" + Guid.NewGuid().ToString("N")[..8]);
    Directory.CreateDirectory(tempDir);
    var exeName = "test_runner";
    if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        exeName += ".exe";
    outputPath = Path.Combine(tempDir, exeName);
}

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
    DumpTemplates: dumpTemplates,
    DebugLogging: debugLogging,
    RunTests: runTests
);

try
{
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

    if (runTests && result.ExecutablePath != null)
    {
        // Run the compiled test executable
        var testProcess = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = result.ExecutablePath,
                UseShellExecute = false
            }
        };
        testProcess.Start();
        testProcess.WaitForExit();

        if (testProcess.ExitCode != 0)
        {
            Console.Error.WriteLine($"\nTest failed with exit code {testProcess.ExitCode}");
            Environment.Exit(1);
        }
    }
    else
    {
        stopwatch.Stop();
        var elapsedMs = stopwatch.ElapsedMilliseconds;
        Console.WriteLine($"Compiled {inputFilePath} in {elapsedMs}ms");
    }
}
finally
{
    // Clean up temp directory
    if (tempDir != null && Directory.Exists(tempDir))
    {
        try { Directory.Delete(tempDir, recursive: true); }
        catch { /* best effort cleanup */ }
    }
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
