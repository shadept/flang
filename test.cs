#!/usr/bin/env dotnet run
#:property TargetFramework=net10.0
#:property LangVersion=14
#:property Nullable=enable
#:property ImplicitUsings=enable

#:package Microsoft.Extensions.Logging.Console@9.0.0

#:project src/FLang.CLI/FLang.CLI.csproj

using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using FLang.CLI;
using FLang.Core;

// ============================================================================
// FLang Test Runner - Unified cross-platform test script
// Usage:
//   dotnet run test.cs                   # Run all tests
//   dotnet run test.cs <filter>          # Run tests matching filter (name or path)
//   dotnet run test.cs -- --list         # List all tests
//   dotnet run test.cs -- --help         # Show help
// ============================================================================

var scriptDir = Directory.GetCurrentDirectory();

// Parse arguments (args is implicitly available in file-based apps)
bool showHelp = args.Contains("--help") || args.Contains("-h");
bool listOnly = args.Contains("--list") || args.Contains("-l");
bool verbose = args.Contains("--verbose") || args.Contains("-v");
bool noProgress = args.Contains("--no-progress");
bool keepFiles = args.Contains("--keep") || args.Contains("-k");
string? filter = args.FirstOrDefault(a => !a.StartsWith("-"));

if (showHelp)
{
    Console.WriteLine("""
        FLang Test Runner - Unified cross-platform test script

        Usage:
          dotnet run test.cs                   Run all tests
          dotnet run test.cs <filter>          Run tests matching filter (name or path)
          dotnet run test.cs -- --list         List all tests
          dotnet run test.cs -- --help         Show this help

        Note: Use '--' to separate dotnet options from test runner options.

        Options:
          --list, -l        List all tests without running them
          --verbose, -v     Show detailed output for each test
          --no-progress     Disable progress bar
          --keep, -k        Keep generated files (.c, .exe) after test
          --help, -h        Show this help message

        Filter:
          You can filter by test name or file path (partial match).
          Examples:
            dotnet run test.cs helloworld
            dotnet run test.cs basics/
            dotnet run test.cs array_basic.f
        """);
    return 0;
}

// Initialize harness with project root
var projectRoot = Path.GetFullPath(Path.Combine(scriptDir, "tests", "FLang.Tests"));
var harness = new TestHarness(projectRoot);

// Discover tests
List<string> testFiles;
try
{
    testFiles = harness.DiscoverTests();
}
catch (DirectoryNotFoundException ex)
{
    Console.ForegroundColor = ConsoleColor.Red;
    Console.WriteLine($"Error: {ex.Message}");
    Console.ResetColor();
    return 1;
}

// Apply filter if provided
if (!string.IsNullOrEmpty(filter))
{
    testFiles = testFiles.Where(f =>
    {
        var relativePath = Path.GetRelativePath(harness.HarnessDir, f);
        var fileName = Path.GetFileName(f);
        var testName = Path.GetFileNameWithoutExtension(f);

        // Try to match metadata test name too
        try
        {
            var metadata = TestHarness.ParseTestMetadata(f);
            if (!string.IsNullOrEmpty(metadata.TestName) &&
                metadata.TestName.Contains(filter, StringComparison.OrdinalIgnoreCase))
                return true;
        }
        catch { }

        return relativePath.Contains(filter, StringComparison.OrdinalIgnoreCase) ||
               fileName.Contains(filter, StringComparison.OrdinalIgnoreCase) ||
               testName.Contains(filter, StringComparison.OrdinalIgnoreCase);
    }).ToList();
}

if (testFiles.Count == 0)
{
    Console.ForegroundColor = ConsoleColor.Yellow;
    Console.WriteLine(filter != null
        ? $"No tests found matching filter: {filter}"
        : "No tests found.");
    Console.ResetColor();
    return 0;
}

// List mode
if (listOnly)
{
    Console.WriteLine($"Found {testFiles.Count} test(s):");
    foreach (var file in testFiles)
    {
        var relativePath = Path.GetRelativePath(harness.HarnessDir, file);
        Console.WriteLine($"  {relativePath}");
    }
    return 0;
}

// Run tests
Console.ForegroundColor = ConsoleColor.Cyan;
Console.WriteLine($"Running {testFiles.Count} test(s)...");
Console.ResetColor();

var passed = 0;
var failed = 0;
var skipped = 0;
var failedTests = new List<(string Path, string Name, string Message)>();
var skippedTests = new List<(string Path, string Name, string Reason)>();
var total = testFiles.Count;
var current = 0;

foreach (var testFile in testFiles)
{
    current++;
    var relativePath = Path.GetRelativePath(harness.HarnessDir, testFile);

    if (!noProgress && !verbose)
    {
        RenderProgressBar(current, total, relativePath);
    }

    if (verbose)
    {
        Console.ForegroundColor = ConsoleColor.Yellow;
        Console.WriteLine($"[RUN]  {relativePath}");
        Console.ResetColor();
    }

    var result = harness.RunTest(testFile, keepFiles);

    if (result.Skipped)
    {
        skipped++;
        skippedTests.Add((relativePath, result.TestName, result.SkipReason ?? ""));
        if (verbose)
        {
            Console.ForegroundColor = ConsoleColor.Yellow;
            Console.WriteLine($"[SKIP] {relativePath}: {result.SkipReason}");
            Console.ResetColor();
        }
    }
    else if (result.Passed)
    {
        passed++;
        if (verbose)
        {
            Console.ForegroundColor = ConsoleColor.Green;
            Console.WriteLine($"[PASS] {relativePath} ({result.Duration.TotalMilliseconds:F0}ms)");
            Console.ResetColor();
        }
    }
    else
    {
        failed++;
        failedTests.Add((relativePath, result.TestName, result.FailureMessage ?? "Unknown error"));

        // Always show failures immediately
        if (!noProgress && !verbose)
        {
            ClearProgressLine();
        }
        Console.ForegroundColor = ConsoleColor.Red;
        Console.WriteLine($"[FAIL] {relativePath}");
        if (verbose || failedTests.Count <= 10)
        {
            Console.WriteLine($"       {result.FailureMessage}");
        }
        Console.ResetColor();
    }
}

// Clear progress bar
if (!noProgress && !verbose)
{
    ClearProgressLine();
}

// Summary
Console.WriteLine();
Console.ForegroundColor = ConsoleColor.Cyan;
if (skipped > 0)
    Console.WriteLine($"Test Results: {passed} passed, {failed} failed, {skipped} skipped, {total} total");
else
    Console.WriteLine($"Test Results: {passed} passed, {failed} failed, {total} total");
Console.ResetColor();

if (failed > 0)
{
    Console.ForegroundColor = ConsoleColor.Red;
    Console.WriteLine("\nFailed tests:");
    foreach (var (path, name, _) in failedTests)
    {
        Console.WriteLine($"  - {path}");
    }
    Console.ResetColor();
    return 1;
}

Console.ForegroundColor = ConsoleColor.Green;
Console.WriteLine("\nAll tests passed!");
Console.ResetColor();
return 0;

// Helper functions
int GetConsoleWidth()
{
    try { return Console.WindowWidth; }
    catch { return 120; }  // Default width if no console
}

bool IsInteractive()
{
    try { _ = Console.WindowWidth; return true; }
    catch { return false; }
}

void RenderProgressBar(int current, int total, string currentTest)
{
    if (!IsInteractive()) return;  // Skip progress bar when not interactive

    const int width = 40;
    var percent = total > 0 ? (current * 100) / total : 0;
    var filled = total > 0 ? (current * width) / total : 0;
    var empty = width - filled;

    var filledBar = new string('#', filled);
    var emptyBar = new string('-', empty);

    // Truncate test name if too long
    var consoleWidth = GetConsoleWidth();
    var maxNameLength = consoleWidth - width - 20;
    if (maxNameLength < 10) maxNameLength = 10;
    var displayName = currentTest.Length > maxNameLength
        ? "..." + currentTest[(currentTest.Length - maxNameLength + 3)..]
        : currentTest;

    Console.Write($"\r[{filledBar}{emptyBar}] {current}/{total} ({percent}%) {displayName}");

    // Clear rest of line
    try
    {
        var clearLength = consoleWidth - Console.CursorLeft - 1;
        if (clearLength > 0)
            Console.Write(new string(' ', clearLength));
    }
    catch { }
}

void ClearProgressLine()
{
    if (!IsInteractive()) return;
    Console.Write("\r" + new string(' ', Math.Max(Math.Min(GetConsoleWidth() - 1, 120), 0)) + "\r");
}

// ============================================================================
// TestHarness - Core test execution logic
// ============================================================================

record TestMetadata(
    string TestName,
    int? ExpectedExitCode,
    List<string> ExpectedStdout,
    List<string> ExpectedStderr,
    List<string> ExpectedCompileErrors,
    string? SkipReason);

record TestResult(
    string TestFile,
    string TestName,
    bool Passed,
    string? FailureMessage,
    TimeSpan Duration,
    bool Skipped = false,
    string? SkipReason = null);

class TestHarness
{
    private readonly Compiler _compiler = new();
    private readonly string _projectRoot;
    private readonly string _stdlibPath;
    private readonly string _harnessDir;

    public TestHarness(string projectRoot)
    {
        DiagnosticPrinter.EnableColors = false;
        _projectRoot = projectRoot;
        _stdlibPath = Path.GetFullPath(Path.Combine(_projectRoot, "..", "..", "stdlib"));
        _harnessDir = Path.Combine(_projectRoot, "Harness");
    }

    public string HarnessDir => _harnessDir;

    public List<string> DiscoverTests()
    {
        if (!Directory.Exists(_harnessDir))
            throw new DirectoryNotFoundException($"Harness directory not found at: {_harnessDir}");

        return Directory.GetFiles(_harnessDir, "*.f", SearchOption.AllDirectories)
            .OrderBy(f => f)
            .ToList();
    }

    public static TestMetadata ParseTestMetadata(string testFile)
    {
        var lines = File.ReadAllLines(testFile);
        string testName = "";
        int? exitCode = null;
        var stdout = new List<string>();
        var stderr = new List<string>();
        var compileErrors = new List<string>();
        string? skipReason = null;

        foreach (var line in lines)
        {
            if (!line.TrimStart().StartsWith("//!"))
                continue;

            var content = line[(line.IndexOf("//!") + 3)..].Trim();

            if (content.StartsWith("TEST:"))
                testName = content[5..].Trim();
            else if (content.StartsWith("EXIT:"))
                exitCode = int.Parse(content[5..].Trim());
            else if (content.StartsWith("STDOUT:"))
                stdout.Add(content[7..].Trim());
            else if (content.StartsWith("STDERR:"))
                stderr.Add(content[7..].Trim());
            else if (content.StartsWith("COMPILE-ERROR:"))
                compileErrors.Add(content[14..].Trim());
            else if (content.StartsWith("SKIP:"))
                skipReason = content[5..].Trim();
        }

        return new TestMetadata(testName, exitCode, stdout, stderr, compileErrors, skipReason);
    }

    public TestResult RunTest(string absoluteTestFile, bool keepFiles = false, TimeSpan? timeout = null)
    {
        timeout ??= TimeSpan.FromSeconds(30);
        var stopwatch = Stopwatch.StartNew();

        var testFileName = Path.GetFileNameWithoutExtension(absoluteTestFile);
        var testDirectory = Path.GetDirectoryName(absoluteTestFile)!;

        var metadata = ParseTestMetadata(absoluteTestFile);
        if (string.IsNullOrEmpty(metadata.TestName))
        {
            return new TestResult(
                absoluteTestFile,
                testFileName,
                false,
                "Test file is missing //! TEST: directive",
                stopwatch.Elapsed);
        }

        // Handle SKIP directive
        if (metadata.SkipReason != null)
        {
            return new TestResult(
                absoluteTestFile,
                metadata.TestName,
                true, // Skipped tests are not failures
                null,
                stopwatch.Elapsed,
                Skipped: true,
                SkipReason: metadata.SkipReason);
        }

        var cFilePath = Path.ChangeExtension(absoluteTestFile, ".c");
        var outputFilePath = GetGeneratedExecutablePath(testDirectory, testFileName);

        var compilerConfig = CompilerDiscovery.GetCompilerForCompilation(cFilePath, outputFilePath, false);

        var options = new CompilerOptions(
            InputFilePath: absoluteTestFile,
            StdlibPath: _stdlibPath,
            CCompilerConfig: compilerConfig,
            ReleaseBuild: false,
            DebugLogging: false
        );

        var result = _compiler.Compile(options);

        if (metadata.ExpectedCompileErrors.Count > 0)
        {
            if (result.Success)
            {
                CleanupGeneratedFiles(cFilePath, outputFilePath, keepFiles);
                return new TestResult(
                    absoluteTestFile,
                    metadata.TestName,
                    false,
                    $"Expected compilation to fail with errors [{string.Join(", ", metadata.ExpectedCompileErrors)}] but it succeeded",
                    stopwatch.Elapsed);
            }

            foreach (var code in metadata.ExpectedCompileErrors)
            {
                if (result.Diagnostics.All(d => d.Code != code))
                {
                    var sb = new StringBuilder();
                    foreach (var diagnostic in result.Diagnostics)
                    {
                        sb.Append(DiagnosticPrinter.Print(diagnostic, result.CompilationContext));
                    }

                    return new TestResult(
                        absoluteTestFile,
                        metadata.TestName,
                        false,
                        $"Expected error {code} not found in diagnostics:\n{sb}",
                        stopwatch.Elapsed);
                }
            }

            CleanupGeneratedFiles(cFilePath, null, keepFiles);
            return new TestResult(absoluteTestFile, metadata.TestName, true, null, stopwatch.Elapsed);
        }

        if (!result.Success)
        {
            var sb = new StringBuilder();
            foreach (var diagnostic in result.Diagnostics)
            {
                sb.Append(DiagnosticPrinter.Print(diagnostic, result.CompilationContext));
            }

            return new TestResult(
                absoluteTestFile,
                metadata.TestName,
                false,
                $"Compilation failed:\n{sb}",
                stopwatch.Elapsed);
        }

        var generatedExePath = result.ExecutablePath!;

        if (!File.Exists(generatedExePath))
        {
            CleanupGeneratedFiles(cFilePath, null, keepFiles);
            return new TestResult(
                absoluteTestFile,
                metadata.TestName,
                false,
                $"Compiler reported success but did not produce an executable at {generatedExePath}",
                stopwatch.Elapsed);
        }

        try
        {
            var exeProcess = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = generatedExePath,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                }
            };

            exeProcess.Start();

            var stdoutTask = exeProcess.StandardOutput.ReadToEndAsync();
            var stderrTask = exeProcess.StandardError.ReadToEndAsync();

            var exited = exeProcess.WaitForExit((int)timeout.Value.TotalMilliseconds);

            if (!exited)
            {
                try { exeProcess.Kill(); } catch { }
                CleanupGeneratedFiles(cFilePath, generatedExePath, keepFiles);
                return new TestResult(
                    absoluteTestFile,
                    metadata.TestName,
                    false,
                    $"Test execution timed out after {timeout.Value.TotalSeconds}s",
                    stopwatch.Elapsed);
            }

            var actualExitCode = exeProcess.ExitCode;
            var stdoutContent = stdoutTask.Result;
            var stderrContent = stderrTask.Result;

            var actualStdout = stdoutContent.Split('\n').Select(s => s.TrimEnd('\r'))
                .Where(s => !string.IsNullOrEmpty(s)).ToList();
            var actualStderr = stderrContent.Split('\n').Select(s => s.TrimEnd('\r'))
                .Where(s => !string.IsNullOrEmpty(s)).ToList();

            var failures = new List<string>();

            if (metadata.ExpectedExitCode.HasValue && metadata.ExpectedExitCode.Value != actualExitCode)
            {
                failures.Add($"Expected exit code {metadata.ExpectedExitCode.Value} but got {actualExitCode}");
            }

            foreach (var expectedLine in metadata.ExpectedStdout)
            {
                if (!actualStdout.Contains(expectedLine))
                {
                    failures.Add($"Missing expected STDOUT line: '{expectedLine}'");
                    failures.Add($"Actual STDOUT: [{string.Join(", ", actualStdout.Select(s => $"'{s}'"))}]");
                }
            }

            foreach (var expectedLine in metadata.ExpectedStderr)
            {
                if (!actualStderr.Contains(expectedLine))
                {
                    failures.Add($"Missing expected STDERR line: '{expectedLine}'");
                    failures.Add($"Actual STDERR: [{string.Join(", ", actualStderr.Select(s => $"'{s}'"))}]");
                }
            }

            CleanupGeneratedFiles(cFilePath, generatedExePath, keepFiles);

            if (failures.Count > 0)
            {
                return new TestResult(
                    absoluteTestFile,
                    metadata.TestName,
                    false,
                    string.Join("\n", failures),
                    stopwatch.Elapsed);
            }

            return new TestResult(absoluteTestFile, metadata.TestName, true, null, stopwatch.Elapsed);
        }
        catch (Exception ex)
        {
            CleanupGeneratedFiles(cFilePath, generatedExePath, keepFiles);
            return new TestResult(
                absoluteTestFile,
                metadata.TestName,
                false,
                $"Exception running test: {ex.Message}",
                stopwatch.Elapsed);
        }
    }

    private static string GetGeneratedExecutablePath(string testDirectory, string testFileName)
    {
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            return Path.Combine(testDirectory, $"{testFileName}.exe");

        return Path.Combine(testDirectory, testFileName);
    }

    private static void CleanupGeneratedFiles(string cFilePath, string? exePath, bool keepFiles)
    {
        if (keepFiles) return;
        try
        {
            if (File.Exists(cFilePath)) File.Delete(cFilePath);
            if (exePath != null && File.Exists(exePath)) File.Delete(exePath);
            var pdbPath = Path.ChangeExtension(cFilePath, ".pdb");
            if (File.Exists(pdbPath)) File.Delete(pdbPath);
        }
        catch { }
    }
}
