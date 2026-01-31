#!/usr/bin/env dotnet run
#:property TargetFramework=net10.0
#:property LangVersion=14
#:property Nullable=enable
#:property ImplicitUsings=enable

#:package Microsoft.Extensions.Logging.Console@9.0.0

#:project src/FLang.CLI/FLang.CLI.csproj

using FLang.CLI;

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
var artifactsDir = Path.GetFullPath(Path.Combine(scriptDir, ".test-artifacts"));

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

    var result = harness.RunTest(testFile, artifactsDir);

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
