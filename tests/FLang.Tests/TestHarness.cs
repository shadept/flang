using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using FLang.CLI;
using FLang.Core;

namespace FLang.Tests;

/// <summary>
/// Metadata parsed from test file //! directives.
/// </summary>
public record TestMetadata(
    string TestName,
    int? ExpectedExitCode,
    List<string> ExpectedStdout,
    List<string> ExpectedStderr,
    List<string> ExpectedCompileErrors);

/// <summary>
/// Result of running a single test.
/// </summary>
public record TestResult(
    string TestFile,
    string TestName,
    bool Passed,
    string? FailureMessage,
    TimeSpan Duration);

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
            // Discover project root from assembly location
            var currentAssemblyPath = typeof(TestHarness).Assembly.Location;
            _projectRoot = Path.GetFullPath(Path.Combine(currentAssemblyPath, "..", "..", "..", ".."));
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

        return Directory.GetFiles(_harnessDir, "*.f", SearchOption.AllDirectories)
            .OrderBy(f => f)
            .ToList();
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
        var compileErrors = new List<string>();

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
        }

        return new TestMetadata(testName, exitCode, stdout, stderr, compileErrors);
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
        var testDirectory = Path.GetDirectoryName(absoluteTestFile)!;

        // 1. Parse test metadata from //! comments
        var metadata = ParseTestMetadata(absoluteTestFile);
        if (string.IsNullOrEmpty(metadata.TestName))
        {
            return new TestResult(
                absoluteTestFile,
                testFileName,
                false,
                $"Test file is missing //! TEST: directive",
                stopwatch.Elapsed);
        }

        // 2. Call Compiler directly
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

        // Handle expected compile errors
        if (metadata.ExpectedCompileErrors.Count > 0)
        {
            if (result.Success)
            {
                CleanupGeneratedFiles(cFilePath, outputFilePath);
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

            // Expected compile failure satisfied
            CleanupGeneratedFiles(cFilePath, null);
            return new TestResult(absoluteTestFile, metadata.TestName, true, null, stopwatch.Elapsed);
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
            CleanupGeneratedFiles(cFilePath, null);
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

            // Use async read to avoid deadlocks
            var stdoutTask = exeProcess.StandardOutput.ReadToEndAsync();
            var stderrTask = exeProcess.StandardError.ReadToEndAsync();

            var exited = exeProcess.WaitForExit((int)timeout.Value.TotalMilliseconds);

            if (!exited)
            {
                try { exeProcess.Kill(); } catch { }
                CleanupGeneratedFiles(cFilePath, generatedExePath);
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
            CleanupGeneratedFiles(cFilePath, generatedExePath);

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
            CleanupGeneratedFiles(cFilePath, generatedExePath);
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

    private static void CleanupGeneratedFiles(string cFilePath, string? exePath)
    {
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
