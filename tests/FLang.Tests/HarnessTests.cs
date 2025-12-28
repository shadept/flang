using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using FLang.CLI;
using FLang.Core;
using Xunit.Sdk;

namespace FLang.Tests;

public class HarnessTests
{
    private static readonly Compiler _compiler = new();
    private static readonly string _projectRoot;
    private static readonly string _stdlibPath;
    private static readonly string _harnessDir;

    static HarnessTests()
    {
        DiagnosticPrinter.EnableColors = false;
        var currentAssemblyPath = typeof(HarnessTests).Assembly.Location;
        _projectRoot = Path.GetFullPath(Path.Combine(currentAssemblyPath, "..", "..", "..", ".."));
        _stdlibPath = Path.GetFullPath(Path.Combine(_projectRoot, "..", "..", "stdlib"));
        _harnessDir = Path.Combine(_projectRoot, "Harness");
    }

    [Theory]
    [MemberData(nameof(GetTestFiles))]
    public void RunTest(string testFile)
    {
        // Resolve relative path (from Harness dir) to absolute
        var absoluteTestFile = Path.Combine(_harnessDir, testFile);
        Console.WriteLine($"[TEST_FILE] {absoluteTestFile}");
        var testFileName = Path.GetFileNameWithoutExtension(absoluteTestFile);
        var testDirectory = Path.GetDirectoryName(absoluteTestFile)!;

        // 1. Parse test metadata from //! comments
        var metadata = ParseTestMetadata(absoluteTestFile);
        if (string.IsNullOrEmpty(metadata.TestName))
            Assert.Fail($"Test file {absoluteTestFile} is missing //! TEST: directive");

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

        if (metadata.ExpectedCompileErrors.Count > 0)
        {
            if (result.Success)
            {
                Assert.Fail($"Expected compilation to fail with errors [{string.Join(", ", metadata.ExpectedCompileErrors)}] but it succeeded for test file: {absoluteTestFile}");
            }

            foreach (var code in metadata.ExpectedCompileErrors)
            {
                if (!result.Diagnostics.Any(d => d.Code == code))
                {
                    var sb = new StringBuilder();
                    foreach (var diagnostic in result.Diagnostics)
                    {
                        sb.Append(DiagnosticPrinter.Print(diagnostic, result.CompilationContext));
                    }
                    Assert.Fail($"Expected error {code} not found in diagnostics for {metadata.TestName} ({absoluteTestFile}):\n{sb}");
                }
            }
            return; // Skip running executable on expected compile failures
        }

        if (!result.Success)
        {
            var sb = new StringBuilder();
            foreach (var diagnostic in result.Diagnostics)
            {
                sb.Append(DiagnosticPrinter.Print(diagnostic, result.CompilationContext));
            }
            Assert.Fail($"Compilation failed for {metadata.TestName} ({absoluteTestFile}):\n\r{sb}");
        }

        var generatedExePath = result.ExecutablePath!;

        if (!File.Exists(generatedExePath))
        {
            Assert.Fail($"Compiler reported success but did not produce an executable at {generatedExePath} for test file: {absoluteTestFile}");
        }

        // 3. Run the generated executable
        var exeProcess = Process.Start(new ProcessStartInfo
        {
            FileName = generatedExePath,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        })!;
        exeProcess.WaitForExit();

        var actualExitCode = exeProcess.ExitCode;
        var actualStdout = exeProcess.StandardOutput.ReadToEnd().Split('\n').Select(s => s.TrimEnd('\r'))
            .Where(s => !string.IsNullOrEmpty(s)).ToList();
        var actualStderr = exeProcess.StandardError.ReadToEnd().Split('\n').Select(s => s.TrimEnd('\r'))
            .Where(s => !string.IsNullOrEmpty(s)).ToList();

        // 4. Validate against metadata
        if (metadata.ExpectedExitCode.HasValue) Assert.Equal(metadata.ExpectedExitCode.Value, actualExitCode);

        foreach (var expectedLine in metadata.ExpectedStdout) Assert.Contains(expectedLine, actualStdout);
        foreach (var expectedLine in metadata.ExpectedStderr) Assert.Contains(expectedLine, actualStderr);

        // 5. Clean up generated files
        File.Delete(cFilePath);
        File.Delete(generatedExePath);
    }

    private static TestMetadata ParseTestMetadata(string testFile)
    {
        var lines = File.ReadAllLines(testFile);
        string testName = null;
        int? exitCode = null;
        var stdout = new List<string>();
        var stderr = new List<string>();
        var compileErrors = new List<string>();

        foreach (var line in lines)
        {
            if (!line.TrimStart().StartsWith("//!"))
                continue;

            var content = line.Substring(line.IndexOf("//!") + 3).Trim();

            if (content.StartsWith("TEST:"))
                testName = content.Substring(5).Trim();
            else if (content.StartsWith("EXIT:"))
                exitCode = int.Parse(content.Substring(5).Trim());
            else if (content.StartsWith("STDOUT:"))
                stdout.Add(content.Substring(7).Trim());
            else if (content.StartsWith("STDERR:"))
                stderr.Add(content.Substring(7).Trim());
            else if (content.StartsWith("COMPILE-ERROR:"))
                compileErrors.Add(content.Substring(14).Trim());
        }

        return new TestMetadata(testName, exitCode, stdout, stderr, compileErrors);
    }

    public static IEnumerable<object[]> GetTestFiles()
    {
        if (!Directory.Exists(_harnessDir))
            throw new DirectoryNotFoundException($"Harness directory not found at: {_harnessDir}");

        // Recursively find all .f files in Harness and subdirectories
        // Return paths relative to Harness directory for cleaner IDE presentation
        foreach (var file in Directory.GetFiles(_harnessDir, "*.f", SearchOption.AllDirectories))
        {
            var relativePath = Path.GetRelativePath(_harnessDir, file);
            yield return [relativePath];
        }
    }

    private static string GetGeneratedExecutablePath(string testDirectory, string testFileName)
    {
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            return Path.Combine(testDirectory, $"{testFileName}.exe");

        // Non-Windows: CLI strips extension (Path.ChangeExtension(..., null))
        return Path.Combine(testDirectory, testFileName);
    }

    private record TestMetadata(
        string TestName,
        int? ExpectedExitCode,
        List<string> ExpectedStdout,
        List<string> ExpectedStderr,
        List<string> ExpectedCompileErrors);
}