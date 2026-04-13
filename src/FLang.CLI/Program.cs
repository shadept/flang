using System.Diagnostics;
using System.Runtime.InteropServices;
using FLang.CLI;
using FLang.CLI.Commands;
using FLang.Core;
using FLang.Lsp;

// Project subcommands: init, build, test (project mode)
if (args.Length > 0)
{
    switch (args[0])
    {
        case "init":
            Environment.Exit(InitCommand.Run(args[1..]));
            return;
        case "build":
            Environment.Exit(BuildCommand.Run(args[1..]));
            return;
        case "test" when !args.Skip(1).Any(a => a.EndsWith(".f")):
            // Project test mode — no .f file means project mode
            Environment.Exit(TestCommand.Run(args[1..]));
            return;
    }
}

// Parse command-line arguments (single-file mode)
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
var emitC = false;
var emitCfg = false;
var linkFlags = new List<string>();
var headerPaths = new List<string>();

// Handle "test" subcommand: flang test <file> or flang --flags test <file>
{
    var argsList = new List<string>(args);
    var testIdx = argsList.IndexOf("test");
    if (testIdx >= 0)
    {
        runTests = true;
        argsList.RemoveAt(testIdx);
        args = argsList.ToArray();
    }
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
    else if (args[i] == "--emit-c")
        emitC = true;
    else if (args[i] == "--emit-cfg")
        emitCfg = true;
    else if (args[i] == "--link" && i + 1 < args.Length)
        linkFlags.Add(args[++i]);
    else if (args[i] == "-I" && i + 1 < args.Length)
        headerPaths.Add(args[++i]);
    else if (args[i] == "-L" && i + 1 < args.Length)
        linkFlags.Add(args[++i]);
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
    Console.WriteLine("Usage: flang [options] <file>              Compile a single file");
    Console.WriteLine("       flang init <name>                   Create a new project");
    Console.WriteLine("       flang build [--release]             Build project from flang.toml");
    Console.WriteLine("       flang test [filter] [--release]     Run test blocks from project");
    Console.WriteLine("       flang test <file>                   Compile and run test blocks");
    Console.WriteLine();
    Console.WriteLine("Options:");
    Console.WriteLine("  -o, --output <path>     Output executable path (default: same as input with .exe)");
    Console.WriteLine("  --stdlib-path <path>    Path to standard library directory");
    Console.WriteLine("  --emit-c                Emit the generated C code next to the input file (.generated.c)");
    Console.WriteLine("  --emit-cfg              Emit control flow graph as cfg.html next to the input file");
    Console.WriteLine("  --emit-fir <file>       Emit FIR (intermediate representation) to file (use '-' for stdout)");
    Console.WriteLine("  --release               Enable C backend optimization (passes -O2 /O2)");
    Console.WriteLine("  --test                  Run test blocks instead of main()");
    Console.WriteLine("  --lsp                   Start Language Server Protocol server over stdio");
    Console.WriteLine("  -I <header>             Parse C header and generate FFI bindings in vendor/");
    Console.WriteLine("  -L <lib>                Link against a C library (passed to the C compiler)");
    Console.WriteLine("  --link <flags>          Additional linker flags");
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

var compiler = new Compiler();
var options = new CompilerOptions(
    InputFilePaths: [inputFilePath],
    StdlibPath: stdlibPath,
    OutputPath: outputPath,
    ReleaseBuild: releaseBuild,
    EmitFir: emitFir,
    DumpTemplates: dumpTemplates,
    DebugLogging: debugLogging,
    RunTests: runTests,
    EmitCfg: emitCfg,
    LinkFlags: linkFlags.Count > 0 ? linkFlags : null,
    HeaderPaths: headerPaths.Count > 0 ? headerPaths : null
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
        Console.Error.WriteLine($"Error: Compilation failed with {result.Diagnostics.Count(d => d.Severity == DiagnosticSeverity.Error)} error(s)");
        Environment.Exit(1);
    }

    // --emit-c: copy the intermediate .c file before running tests
    var cFilePath = Path.Combine(
        Path.GetDirectoryName(Path.GetFullPath(outputPath))!,
        Path.GetFileNameWithoutExtension(outputPath) + ".c");
    if (emitC && File.Exists(cFilePath))
    {
        var emitCDest = Path.ChangeExtension(inputFilePath, ".generated.c");
        try { File.Copy(cFilePath, emitCDest, overwrite: true); Console.WriteLine($"C code emitted to {emitCDest}"); }
        catch { /* best effort */ }
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
