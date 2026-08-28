#!/usr/bin/env dotnet run
#:property TargetFramework=net10.0
#:property LangVersion=14
#:property Nullable=enable
#:property ImplicitUsings=enable

using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

// ============================================================================
// FLang Test Runner - the lit-style harness over tests/harness/*.f
// Usage:
//   dotnet run test.cs                   # Run all tests
//   dotnet run test.cs <filter>          # Run tests matching filter (name or path)
//   dotnet run test.cs -- --list         # List all tests
//   dotnet run test.cs -- --help         # Show help
//
// Each test is compiled by subprocessing a compiler binary and the produced
// executable is run against the `//!` expectations in the file. $FLANG names
// the compiler; without it, the default is dist/<rid>/flang.
// ============================================================================

var scriptDir = Directory.GetCurrentDirectory();

// Compiler selection must happen before the first TestHarness touch: it reads
// $FLANG in a static initializer.
if (Environment.GetEnvironmentVariable("FLANG") is not { Length: > 0 })
    Environment.SetEnvironmentVariable("FLANG", FindDefaultCompiler(scriptDir));

// Parse arguments (args is implicitly available in file-based apps)
bool showHelp = args.Contains("--help") || args.Contains("-h");
bool listOnly = args.Contains("--list") || args.Contains("-l");
bool verbose = args.Contains("--verbose") || args.Contains("-v");
bool noProgress = args.Contains("--no-progress");
bool sequential = args.Contains("--sequential") || args.Contains("-s");
string? filter = args.FirstOrDefault(a => !a.StartsWith('-') && a != "--sequential" && a != "-s");

if (showHelp)
{
    Console.WriteLine("""
        FLang Test Runner - the lit-style harness

        Usage:
          dotnet run test.cs                   Run all tests
          dotnet run test.cs <filter>          Run tests matching filter (name or path)
          dotnet run test.cs -- --list         List all tests
          dotnet run test.cs -- --help         Show this help

        Note: Use '--' to separate dotnet options from test runner options.

        Options:
          --list, -l        List all tests without running them
          --verbose, -v     Show detailed output for each test
          --sequential, -s  Run tests sequentially (default is parallel)
          --no-progress     Disable progress bar
          --help, -h        Show this help message

        Environment:
          FLANG             Compiler binary to compile each test with.
                            Defaults to dist/<rid>/flang.

        Filter:
          You can filter by test name or file path (partial match).
          Examples:
            dotnet run test.cs helloworld
            dotnet run test.cs basics/
            dotnet run test.cs array_basic.f
        """);
    return 0;
}

if (TestHarness.FlangBinary == null)
{
    Console.ForegroundColor = ConsoleColor.Red;
    Console.WriteLine("Error: no compiler found. Run `dotnet run build.cs` first, or set $FLANG.");
    Console.ResetColor();
    return 1;
}

var harness = new TestHarness(scriptDir);

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
    testFiles = [..testFiles.Where(f =>
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
    })];
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
var parallelism = (sequential || verbose) ? 1 : Environment.ProcessorCount;
Console.ForegroundColor = ConsoleColor.Cyan;
Console.WriteLine($"Compiling via FLANG={TestHarness.FlangBinary}");
Console.WriteLine($"Running {testFiles.Count} test(s){(parallelism > 1 ? $" in parallel ({parallelism} workers)" : "")}...");
Console.ResetColor();

var passed = 0;
var failed = 0;
var skipped = 0;
var failedTests = new List<(string Path, string Name, string Message)>();
var skippedTests = new List<(string Path, string Name, string Reason)>();
var total = testFiles.Count;
var current = 0;

var lockObj = new object();
var results = new (string RelativePath, TestResult Result)[total];
var wall = Stopwatch.StartNew();

Parallel.For(0, total, new ParallelOptions { MaxDegreeOfParallelism = parallelism },
    // Thread-local factory: each thread gets its own TestHarness to avoid shared state
    () => new TestHarness(scriptDir),
    (i, state, localHarness) =>
    {
        var testFile = testFiles[i];
        var relativePath = Path.GetRelativePath(localHarness.HarnessDir, testFile);

        if (verbose)
        {
            Console.ForegroundColor = ConsoleColor.Yellow;
            Console.WriteLine($"[RUN]  {relativePath}");
            Console.ResetColor();
        }

        var result = localHarness.RunTest(testFile);
        results[i] = (relativePath, result);
        // Verbose: print result immediately (safe since parallelism=1 in verbose mode)
        if (verbose)
        {
            if (result.Skipped)
            {
                Console.ForegroundColor = ConsoleColor.Yellow;
                Console.WriteLine($"[SKIP] {relativePath}: {result.SkipReason}");
                Console.ResetColor();
            }
            else if (result.Passed)
            {
                Console.ForegroundColor = ConsoleColor.Green;
                Console.WriteLine($"[PASS] {relativePath} ({result.Duration.TotalMilliseconds:F0}ms)");
                Console.ResetColor();
            }
            else
            {
                Console.ForegroundColor = ConsoleColor.Red;
                Console.WriteLine($"[FAIL] {relativePath}");
                Console.WriteLine($"       {result.FailureMessage}");
                Console.ResetColor();
            }
        }
        else if (!noProgress)
        {
            var done = Interlocked.Increment(ref current);
            lock (lockObj)
            {
                RenderProgressBar(done, total, relativePath);
            }
        }

        return localHarness;
    },
    _ => { } // No cleanup needed
);

wall.Stop();

if (!noProgress && !verbose)
{
    ClearProgressLine();
}

// Tally results in order
foreach (var (relativePath, result) in results)
{
    if (result.Skipped)
    {
        skipped++;
        skippedTests.Add((relativePath, result.TestName, result.SkipReason ?? ""));
    }
    else if (result.Passed)
    {
        passed++;
    }
    else
    {
        failed++;
        failedTests.Add((relativePath, result.TestName, result.FailureMessage ?? "Unknown error"));
        // Detail blocks for the first 10 only; the recap list below covers the rest.
        if (!verbose && failedTests.Count <= 10)
        {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine($"[FAIL] {relativePath}");
            Console.WriteLine($"       {result.FailureMessage}");
            Console.ResetColor();
        }
    }
}

// Summary
Console.WriteLine();
Console.ForegroundColor = ConsoleColor.Cyan;
Console.WriteLine($"Test Results: {passed} passed, {failed} failed, {skipped} skipped, {total} total");

var ran = results.Where(r => !r.Result.Skipped).ToList();
if (ran.Count > 0)
{
    var testTimeMs = ran.Sum(r => r.Result.Duration.TotalMilliseconds);
    var slowest = ran.MaxBy(r => r.Result.Duration);
    Console.WriteLine($"Time: {wall.Elapsed.TotalSeconds:F1}s wall, {testTimeMs / 1000:F1}s test time, mean {testTimeMs / ran.Count:F0}ms, slowest {slowest.Result.Duration.TotalMilliseconds:F0}ms ({slowest.RelativePath})");
}
Console.ResetColor();

if (failed > 0)
{
    // Skip the recap when every failure was already shown in full just above.
    if (verbose || failedTests.Count > 10)
    {
        Console.ForegroundColor = ConsoleColor.Red;
        Console.WriteLine(verbose
            ? "\nFailed tests:"
            : $"\nFailed tests (details above for first 10):");
        foreach (var (path, _, _) in failedTests)
        {
            Console.WriteLine($"  - {path}");
        }
        Console.ResetColor();
    }
    return 1;
}

Console.ForegroundColor = ConsoleColor.Green;
Console.WriteLine("\nAll tests passed!");
Console.ResetColor();
return 0;

// Helper functions

// The default compiler: dist/<rid>/flang, installed by `dotnet run build.cs`.
// The exact-name match keeps a bundled stdlib copy's own files out of the running.
static string? FindDefaultCompiler(string root)
{
    var dist = Path.Combine(root, "dist");
    return Directory.Exists(dist)
        ? Directory.GetFiles(dist, "flang*", SearchOption.AllDirectories)
            .FirstOrDefault(f => Path.GetFileName(f) is "flang" or "flang.exe")
        : null;
}

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
    var percent = total > 0 ? current * 100 / total : 0;
    var filled = total > 0 ? current * width / total : 0;
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
// The harness
// ============================================================================

/// <summary>
/// An expected diagnostic code with optional message substring match.
/// </summary>
public record ExpectedDiagnostic(string Code, string? MessageContains = null);

/// <summary>
/// Metadata parsed from test file //! directives.
/// </summary>
public record TestMetadata(
    string TestName,
    int? ExpectedExitCode,
    List<string> ExpectedStdout,
    List<string> ExpectedStderr,
    List<ExpectedDiagnostic> ExpectedCompileErrors,
    List<ExpectedDiagnostic> ExpectedCompileWarnings,
    List<ExpectedDiagnostic> ForbiddenCompileWarnings,
    string? SkipReason,
    string? TargetOs = null);

/// <summary>
/// Result of running a single test.
/// </summary>
public record TestResult(
    string TestFile,
    string TestName,
    bool Passed,
    string? FailureMessage,
    TimeSpan Duration,
    bool Skipped = false,
    string? SkipReason = null);

/// <summary>
/// Compiles each `tests/harness` file with the $FLANG compiler binary and checks the
/// produced executable against the file's own `//!` expectations.
/// </summary>
public class TestHarness
{
    private readonly string _stdlibPath;
    private readonly string _harnessDir;

    // The compiler binary each test is compiled by.
    public static string? FlangBinary { get; } =
        Environment.GetEnvironmentVariable("FLANG") is { Length: > 0 } v ? v : null;

    public TestHarness(string repoRoot)
    {
        _stdlibPath = Path.GetFullPath(Path.Combine(repoRoot, "stdlib"));
        _harnessDir = Path.GetFullPath(Path.Combine(repoRoot, "tests", "harness"));
    }

    /// <summary>
    /// Gets the harness directory containing test files.
    /// </summary>
    public string HarnessDir => _harnessDir;

    /// <summary>
    /// Discovers all test files in the harness directory.
    /// </summary>
    /// <returns>List of absolute paths to test files.</returns>
    public List<string> DiscoverTests()
    {
        if (!Directory.Exists(_harnessDir))
            throw new DirectoryNotFoundException($"Harness directory not found at: {_harnessDir}");

        return [.. Directory.GetFiles(_harnessDir, "*.f", SearchOption.AllDirectories)
            .Where(f => !f.EndsWith(".generated.f", StringComparison.OrdinalIgnoreCase))
            .OrderBy(f => f)];
    }

    /// <summary>
    /// Parses test metadata from //! comments in a test file.
    /// </summary>
    public static TestMetadata ParseTestMetadata(string testFile)
    {
        var lines = File.ReadAllLines(testFile);
        string testName = "";
        int? exitCode = null;
        var stdout = new List<string>();
        var stderr = new List<string>();
        var compileErrors = new List<ExpectedDiagnostic>();
        var compileWarnings = new List<ExpectedDiagnostic>();
        var forbiddenWarnings = new List<ExpectedDiagnostic>();
        string? skipReason = null;
        string? targetOs = null;

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
                compileErrors.Add(ParseExpectedDiagnostic(content[14..].Trim()));
            else if (content.StartsWith("NO-COMPILE-WARNING:"))
                forbiddenWarnings.Add(ParseExpectedDiagnostic(content[19..].Trim()));
            else if (content.StartsWith("COMPILE-WARNING:"))
                compileWarnings.Add(ParseExpectedDiagnostic(content[16..].Trim()));
            else if (content.StartsWith("SKIP:"))
                skipReason = content[5..].Trim();
            else if (content.StartsWith("TARGET-OS:"))
                targetOs = content[10..].Trim();
        }

        return new TestMetadata(testName, exitCode, stdout, stderr, compileErrors, compileWarnings, forbiddenWarnings, skipReason, targetOs);
    }

    /// <summary>
    /// Parses "E2002" or "E2002 some message text" into an ExpectedDiagnostic.
    /// </summary>
    private static ExpectedDiagnostic ParseExpectedDiagnostic(string value)
    {
        var spaceIdx = value.IndexOf(' ');
        if (spaceIdx < 0)
            return new ExpectedDiagnostic(value);
        var code = value[..spaceIdx];
        var message = value[(spaceIdx + 1)..].Trim();
        return new ExpectedDiagnostic(code, message.Length > 0 ? message : null);
    }

    /// <summary>
    /// Runs a single test and returns the result.
    /// </summary>
    /// <param name="absoluteTestFile">Absolute path to the test file.</param>
    /// <param name="timeout">Timeout for running the compiled executable (default 30 seconds).</param>
    /// <returns>The test result.</returns>
    public TestResult RunTest(string absoluteTestFile, TimeSpan? timeout = null)
    {
        timeout ??= TimeSpan.FromSeconds(30);
        var stopwatch = Stopwatch.StartNew();
        var testFileName = Path.GetFileNameWithoutExtension(absoluteTestFile);

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

        if (metadata.SkipReason != null)
        {
            return new TestResult(
                absoluteTestFile,
                metadata.TestName,
                true,
                null,
                stopwatch.Elapsed,
                Skipped: true,
                SkipReason: metadata.SkipReason);
        }

        return CompileAndRun(absoluteTestFile, metadata, timeout.Value, stopwatch);
    }

    // Runs the compiled test executable and validates exit code and
    // stdout/stderr expectations.
    private static TestResult RunExecutableAndValidate(
        string absoluteTestFile,
        TestMetadata metadata,
        string generatedExePath,
        string cFilePath,
        bool cleanupFiles,
        TimeSpan timeout,
        Stopwatch stopwatch)
    {
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

            // Read stdout/stderr on dedicated threads to avoid both:
            // 1. Pipe buffer deadlock (must read before/during WaitForExit)
            // 2. ThreadPool starvation (don't use async tasks in Parallel.For)
            string stdoutContent = "";
            string stderrContent = "";
            var stdoutThread = new Thread(() => stdoutContent = exeProcess.StandardOutput.ReadToEnd());
            var stderrThread = new Thread(() => stderrContent = exeProcess.StandardError.ReadToEnd());
            stdoutThread.Start();
            stderrThread.Start();

            var exited = exeProcess.WaitForExit((int)timeout.TotalMilliseconds);

            if (!exited)
            {
                try { exeProcess.Kill(); } catch { }
                stdoutThread.Join(1000);
                stderrThread.Join(1000);
                CleanupGeneratedFiles(cFilePath, generatedExePath, cleanupFiles);
                return new TestResult(
                    absoluteTestFile,
                    metadata.TestName,
                    false,
                    $"Test execution timed out after {timeout.TotalSeconds}s",
                    stopwatch.Elapsed);
            }

            stdoutThread.Join();
            stderrThread.Join();
            var actualExitCode = exeProcess.ExitCode;

            var actualStdout = stdoutContent.Split('\n').Select(s => s.TrimEnd('\r'))
                .Where(s => !string.IsNullOrEmpty(s)).ToList();
            var actualStderr = stderrContent.Split('\n').Select(s => s.TrimEnd('\r'))
                .Where(s => !string.IsNullOrEmpty(s)).ToList();

            // Validate against metadata
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

            CleanupGeneratedFiles(cFilePath, generatedExePath, cleanupFiles);

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
            CleanupGeneratedFiles(cFilePath, generatedExePath, cleanupFiles);
            return new TestResult(
                absoluteTestFile,
                metadata.TestName,
                false,
                $"Exception running test: {ex.Message}",
                stopwatch.Elapsed);
        }
    }

    // Compiles the test by subprocessing the compiler binary, then runs the
    // produced executable against the file's expectations. The CLI offers no
    // output-path control, so artifacts land next to the test file and are
    // always cleaned up.
    private TestResult CompileAndRun(string absoluteTestFile, TestMetadata metadata, TimeSpan timeout, Stopwatch stopwatch)
    {
        var testFileName = Path.GetFileNameWithoutExtension(absoluteTestFile);
        var testDirectory = Path.GetDirectoryName(absoluteTestFile)!;
        var exePath = GetGeneratedExecutablePath(testDirectory, testFileName);
        var cFilePath = Path.ChangeExtension(exePath, ".c");

        var psi = new ProcessStartInfo
        {
            FileName = FlangBinary!,
            WorkingDirectory = testDirectory,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        // Command first: the CLI parses options against the command they follow,
        // so an option ahead of it belongs to no command and is refused.
        psi.ArgumentList.Add("build");
        psi.ArgumentList.Add("--stdlib-path");
        psi.ArgumentList.Add(_stdlibPath);
        // A `TARGET-OS:` directive selects the compile-time context the `#if`
        // evaluator sees.
        if (metadata.TargetOs != null)
        {
            psi.ArgumentList.Add("--target-os");
            psi.ArgumentList.Add(metadata.TargetOs);
        }
        psi.ArgumentList.Add(absoluteTestFile);

        int exitCode;
        string stdout = "", stderr = "";
        try
        {
            using var proc = new Process { StartInfo = psi };
            proc.Start();
            var stdoutThread = new Thread(() => stdout = proc.StandardOutput.ReadToEnd());
            var stderrThread = new Thread(() => stderr = proc.StandardError.ReadToEnd());
            stdoutThread.Start();
            stderrThread.Start();

            // Compile timeout is independent of the (short) run timeout: the
            // compiler re-analyzes the full stdlib per invocation.
            if (!proc.WaitForExit((int)TimeSpan.FromMinutes(2).TotalMilliseconds))
            {
                try { proc.Kill(); } catch { }
                stdoutThread.Join(1000);
                stderrThread.Join(1000);
                CleanupGeneratedFiles(cFilePath, exePath, cleanup: true);
                return new TestResult(
                    absoluteTestFile,
                    metadata.TestName,
                    false,
                    "Compilation timed out after 120s",
                    stopwatch.Elapsed);
            }
            stdoutThread.Join();
            stderrThread.Join();
            exitCode = proc.ExitCode;
        }
        catch (Exception ex)
        {
            CleanupGeneratedFiles(cFilePath, exePath, cleanup: true);
            return new TestResult(
                absoluteTestFile,
                metadata.TestName,
                false,
                $"Failed to run compiler '{FlangBinary}': {ex.Message}",
                stopwatch.Elapsed);
        }

        var compilerOutput = string.IsNullOrWhiteSpace(stderr) ? stdout : $"{stdout}\n--- stderr ---\n{stderr}";

        if (metadata.ExpectedCompileErrors.Count > 0)
        {
            if (exitCode == 0)
            {
                CleanupGeneratedFiles(cFilePath, exePath, cleanup: true);
                return new TestResult(
                    absoluteTestFile,
                    metadata.TestName,
                    false,
                    $"Expected compilation to fail with errors [{string.Join(", ", metadata.ExpectedCompileErrors.Select(e => e.Code))}] but it succeeded",
                    stopwatch.Elapsed);
            }

            foreach (var expected in metadata.ExpectedCompileErrors)
            {
                if (!ContainsDiagnostic(compilerOutput, expected))
                {
                    CleanupGeneratedFiles(cFilePath, exePath, cleanup: true);
                    var expectDesc = expected.MessageContains != null
                        ? $"{expected.Code} containing \"{expected.MessageContains}\""
                        : expected.Code;
                    return new TestResult(
                        absoluteTestFile,
                        metadata.TestName,
                        false,
                        $"Expected error {expectDesc} not found in compiler output:\n{compilerOutput}",
                        stopwatch.Elapsed);
                }
            }

            CleanupGeneratedFiles(cFilePath, exePath, cleanup: true);
            return new TestResult(absoluteTestFile, metadata.TestName, true, null, stopwatch.Elapsed);
        }

        foreach (var expected in metadata.ExpectedCompileWarnings)
        {
            if (!ContainsDiagnostic(compilerOutput, expected))
            {
                CleanupGeneratedFiles(cFilePath, exePath, cleanup: true);
                var expectDesc = expected.MessageContains != null
                    ? $"{expected.Code} containing \"{expected.MessageContains}\""
                    : expected.Code;
                return new TestResult(
                    absoluteTestFile,
                    metadata.TestName,
                    false,
                    $"Expected warning {expectDesc} not found in compiler output:\n{compilerOutput}",
                    stopwatch.Elapsed);
            }
        }

        foreach (var forbidden in metadata.ForbiddenCompileWarnings)
        {
            if (ContainsDiagnostic(compilerOutput, forbidden))
            {
                CleanupGeneratedFiles(cFilePath, exePath, cleanup: true);
                return new TestResult(
                    absoluteTestFile,
                    metadata.TestName,
                    false,
                    $"Forbidden warning {forbidden.Code} found in compiler output:\n{compilerOutput}",
                    stopwatch.Elapsed);
            }
        }

        if (exitCode != 0)
        {
            CleanupGeneratedFiles(cFilePath, exePath, cleanup: true);
            return new TestResult(
                absoluteTestFile,
                metadata.TestName,
                false,
                $"Compilation failed (exit {exitCode}):\n{compilerOutput}",
                stopwatch.Elapsed);
        }

        // Trust the compiler's own "built <path>" report over the derived path.
        var builtLine = stdout.Split('\n').Select(s => s.Trim())
            .LastOrDefault(s => s.StartsWith("built ", StringComparison.Ordinal));
        if (builtLine != null)
        {
            var reported = Path.GetFullPath(builtLine[6..].Trim(), testDirectory);
            if (File.Exists(reported)) exePath = reported;
        }

        if (!File.Exists(exePath))
        {
            CleanupGeneratedFiles(cFilePath, null, cleanup: true);
            return new TestResult(
                absoluteTestFile,
                metadata.TestName,
                false,
                $"Compiler reported success but did not produce an executable at {exePath}:\n{compilerOutput}",
                stopwatch.Elapsed);
        }

        return RunExecutableAndValidate(absoluteTestFile, metadata, exePath, cFilePath, cleanupFiles: true, timeout, stopwatch);
    }

    // The compiler renders "severity[CODE]: message" lines.
    private static bool ContainsDiagnostic(string output, ExpectedDiagnostic expected)
    {
        return output.Contains($"[{expected.Code}]", StringComparison.Ordinal)
            && (expected.MessageContains == null || output.Contains(expected.MessageContains, StringComparison.Ordinal));
    }

    private static string GetGeneratedExecutablePath(string testDirectory, string testFileName)
    {
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            return Path.Combine(testDirectory, $"{testFileName}.exe");

        return Path.Combine(testDirectory, testFileName);
    }

    private static void CleanupGeneratedFiles(string cFilePath, string? exePath, bool cleanup)
    {
        if (!cleanup) return;
        try
        {
            if (File.Exists(cFilePath)) File.Delete(cFilePath);
            if (exePath != null && File.Exists(exePath)) File.Delete(exePath);

            // Also clean up .pdb/.obj files on Windows
            var pdbPath = Path.ChangeExtension(cFilePath, ".pdb");
            if (File.Exists(pdbPath)) File.Delete(pdbPath);
            var objPath = Path.ChangeExtension(cFilePath, ".obj");
            if (File.Exists(objPath)) File.Delete(objPath);
        }
        catch
        {
            // Ignore cleanup errors
        }
    }
}
