using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using FLang.Core;

namespace FLang.CLI;

/// <summary>
/// Metadata parsed from test file //! directives.
/// </summary>
/// <summary>
/// An expected diagnostic code with optional message substring match.
/// </summary>
public record ExpectedDiagnostic(string Code, string? MessageContains = null);

public record TestMetadata(
    string TestName,
    int? ExpectedExitCode,
    List<string> ExpectedStdout,
    List<string> ExpectedStderr,
    List<ExpectedDiagnostic> ExpectedCompileErrors,
    List<ExpectedDiagnostic> ExpectedCompileWarnings,
    string? SkipReason);

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
/// Reusable test harness for running FLang integration tests.
/// Can be used from xUnit tests or standalone scripts.
/// </summary>
public class TestHarness
{
    private readonly Compiler _compiler = new();
    private readonly string _projectRoot;
    private readonly string _stdlibPath;
    private readonly string _harnessDir;

    public TestHarness(string? projectRoot = null)
    {
        DiagnosticPrinter.EnableColors = false;

        if (projectRoot != null)
        {
            _projectRoot = projectRoot;
        }
        else
        {
            // Discover project root from app directory (works in single-file publish)
            _projectRoot = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", ".."));
        }

        _stdlibPath = Path.GetFullPath(Path.Combine(_projectRoot, "..", "..", "stdlib"));
        _harnessDir = Path.Combine(_projectRoot, "Harness");
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
                compileErrors.Add(ParseExpectedDiagnostic(content[14..].Trim()));
            else if (content.StartsWith("COMPILE-WARNING:"))
                compileWarnings.Add(ParseExpectedDiagnostic(content[16..].Trim()));
            else if (content.StartsWith("SKIP:"))
                skipReason = content[5..].Trim();
        }

        return new TestMetadata(testName, exitCode, stdout, stderr, compileErrors, compileWarnings, skipReason);
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
    /// <param name="outputDir">Directory for build artifacts. When set, intermediate and output files are
    /// placed here (mirroring the harness subfolder structure) and are NOT cleaned up.
    /// When null, artifacts are placed next to the test file and cleaned up after the run.</param>
    /// <param name="timeout">Timeout for running the compiled executable (default 30 seconds).</param>
    /// <returns>The test result.</returns>
    public TestResult RunTest(string absoluteTestFile, string? outputDir = null, TimeSpan? timeout = null)
    {
        timeout ??= TimeSpan.FromSeconds(30);
        var stopwatch = Stopwatch.StartNew();
        var cleanupFiles = outputDir == null;

        var testFileName = Path.GetFileNameWithoutExtension(absoluteTestFile);
        var testDirectory = Path.GetDirectoryName(absoluteTestFile)!;

        // 1. Parse test metadata from //! comments
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
                true,
                null,
                stopwatch.Elapsed,
                Skipped: true,
                SkipReason: metadata.SkipReason);
        }

        // 2. Resolve output paths
        string artifactDir;
        if (outputDir != null)
        {
            // Mirror the harness subfolder structure inside outputDir
            var relativePath = Path.GetRelativePath(_harnessDir, testDirectory);
            artifactDir = Path.Combine(outputDir, relativePath);
            Directory.CreateDirectory(artifactDir);
        }
        else
        {
            artifactDir = testDirectory;
        }

        var outputFilePath = GetGeneratedExecutablePath(artifactDir, testFileName);
        var cFilePath = Path.ChangeExtension(outputFilePath, ".c");

        var options = new CompilerOptions(
            InputFilePath: absoluteTestFile,
            StdlibPath: _stdlibPath,
            OutputPath: outputFilePath,
            ReleaseBuild: false,
            DebugLogging: false
        );

        CompilationResult result;
        try
        {
            result = _compiler.Compile(options);
        }
        catch (Exception ex)
        {
            CleanupGeneratedFiles(cFilePath, null, cleanupFiles);
            return new TestResult(
                absoluteTestFile,
                metadata.TestName,
                false,
                $"Compiler crashed: {ex.Message}",
                stopwatch.Elapsed);
        }

        // Handle expected compile errors
        if (metadata.ExpectedCompileErrors.Count > 0)
        {
            if (result.Success)
            {
                CleanupGeneratedFiles(cFilePath, outputFilePath, cleanupFiles);
                return new TestResult(
                    absoluteTestFile,
                    metadata.TestName,
                    false,
                    $"Expected compilation to fail with errors [{string.Join(", ", metadata.ExpectedCompileErrors.Select(e => e.Code))}] but it succeeded",
                    stopwatch.Elapsed);
            }

            foreach (var expected in metadata.ExpectedCompileErrors)
            {
                var match = result.Diagnostics.FirstOrDefault(d =>
                    d.Code == expected.Code
                    && (expected.MessageContains == null || d.Message.Contains(expected.MessageContains, StringComparison.Ordinal)));

                if (match == null)
                {
                    var sb = new StringBuilder();
                    foreach (var diagnostic in result.Diagnostics)
                    {
                        sb.Append(DiagnosticPrinter.Print(diagnostic, result.CompilationContext));
                    }

                    var expectDesc = expected.MessageContains != null
                        ? $"{expected.Code} containing \"{expected.MessageContains}\""
                        : expected.Code;
                    return new TestResult(
                        absoluteTestFile,
                        metadata.TestName,
                        false,
                        $"Expected error {expectDesc} not found in diagnostics:\n{sb}",
                        stopwatch.Elapsed);
                }
            }

            // Expected compile failure satisfied
            CleanupGeneratedFiles(cFilePath, null, cleanupFiles);
            return new TestResult(absoluteTestFile, metadata.TestName, true, null, stopwatch.Elapsed);
        }

        // Handle expected compile warnings
        if (metadata.ExpectedCompileWarnings.Count > 0)
        {
            foreach (var expected in metadata.ExpectedCompileWarnings)
            {
                var match = result.Diagnostics.FirstOrDefault(d =>
                    d.Code == expected.Code
                    && d.Severity == DiagnosticSeverity.Warning
                    && (expected.MessageContains == null || d.Message.Contains(expected.MessageContains, StringComparison.Ordinal)));

                if (match == null)
                {
                    var sb = new StringBuilder();
                    foreach (var diagnostic in result.Diagnostics)
                    {
                        sb.Append(DiagnosticPrinter.Print(diagnostic, result.CompilationContext));
                    }

                    var expectDesc = expected.MessageContains != null
                        ? $"{expected.Code} containing \"{expected.MessageContains}\""
                        : expected.Code;
                    CleanupGeneratedFiles(cFilePath, result.Success ? result.ExecutablePath : null, cleanupFiles);
                    return new TestResult(
                        absoluteTestFile,
                        metadata.TestName,
                        false,
                        $"Expected warning {expectDesc} not found in diagnostics:\n{sb}",
                        stopwatch.Elapsed);
                }
            }
        }

        // Handle unexpected compile failure
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
            CleanupGeneratedFiles(cFilePath, null, cleanupFiles);
            return new TestResult(
                absoluteTestFile,
                metadata.TestName,
                false,
                $"Compiler reported success but did not produce an executable at {generatedExePath}",
                stopwatch.Elapsed);
        }

        // 3. Run the generated executable
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

            var exited = exeProcess.WaitForExit((int)timeout.Value.TotalMilliseconds);

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
                    $"Test execution timed out after {timeout.Value.TotalSeconds}s",
                    stopwatch.Elapsed);
            }

            stdoutThread.Join();
            stderrThread.Join();
            var actualExitCode = exeProcess.ExitCode;

            var actualStdout = stdoutContent.Split('\n').Select(s => s.TrimEnd('\r'))
                .Where(s => !string.IsNullOrEmpty(s)).ToList();
            var actualStderr = stderrContent.Split('\n').Select(s => s.TrimEnd('\r'))
                .Where(s => !string.IsNullOrEmpty(s)).ToList();

            // 4. Validate against metadata
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

            // 5. Clean up generated files
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

            // Also clean up .pdb files on Windows
            var pdbPath = Path.ChangeExtension(cFilePath, ".pdb");
            if (File.Exists(pdbPath)) File.Delete(pdbPath);
        }
        catch
        {
            // Ignore cleanup errors
        }
    }
}
