using System.Diagnostics;
using FLang.Core;
using Xunit;

namespace FLang.Tests;

public class HarnessTests
{
    private record TestMetadata(string TestName, int? ExpectedExitCode, List<string> ExpectedStdout, List<string> ExpectedStderr);

    [Theory]
    [MemberData(nameof(GetTestFiles))]
    public void RunTest(string testFile)
    {
        // Get project root directory
        var currentAssemblyPath = typeof(HarnessTests).Assembly.Location;
        var projectRoot = Path.GetFullPath(Path.Combine(currentAssemblyPath, "..", "..", "..", "..", "..", ".."));
        var harnessDir = Path.Combine(projectRoot, "tests", "FLang.Tests", "Harness");

        // Resolve relative path (from Harness dir) to absolute
        var absoluteTestFile = Path.Combine(harnessDir, testFile);
        var testFileName = Path.GetFileNameWithoutExtension(absoluteTestFile);
        var testDirectory = Path.GetDirectoryName(absoluteTestFile);

        // 1. Parse test metadata from //! comments
        var metadata = ParseTestMetadata(absoluteTestFile);
        if (string.IsNullOrEmpty(metadata.TestName))
        {
            Assert.Fail($"Test file {testFile} is missing //! TEST: directive");
        }

        // 2. Invoke FLang.CLI to compile the .f file
        var stdlibPath = Path.Combine(projectRoot, "stdlib");
        var cliProcess = Process.Start(new ProcessStartInfo
        {
            FileName = "dotnet",
            Arguments = $"run --project \"src/FLang.CLI/FLang.CLI.csproj\" -- --stdlib-path \"{stdlibPath}\" \"{absoluteTestFile}\"",
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = projectRoot
        });
        cliProcess.WaitForExit();

        if (cliProcess.ExitCode != 0)
        {
            var error = cliProcess.StandardError.ReadToEnd();
            Assert.Fail($"FLang.CLI compilation failed for {metadata.TestName} with exit code {cliProcess.ExitCode}:\n{error}");
        }

        // 3. Run the generated executable
        var generatedExePath = Path.Combine(testDirectory, $"{testFileName}.exe");

        if (!File.Exists(generatedExePath))
        {
            Assert.Fail($"FLang.CLI did not produce an executable at {generatedExePath}. CLI Output:\n{cliProcess.StandardOutput.ReadToEnd()}\n{cliProcess.StandardError.ReadToEnd()}");
        }

        var exeProcess = Process.Start(new ProcessStartInfo
        {
            FileName = generatedExePath,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        });
        exeProcess.WaitForExit();

        var actualExitCode = exeProcess.ExitCode;
        var actualStdout = exeProcess.StandardOutput.ReadToEnd().Split('\n').Select(s => s.TrimEnd('\r')).Where(s => !string.IsNullOrEmpty(s)).ToList();
        var actualStderr = exeProcess.StandardError.ReadToEnd().Split('\n').Select(s => s.TrimEnd('\r')).Where(s => !string.IsNullOrEmpty(s)).ToList();

        // 4. Validate against metadata
        if (metadata.ExpectedExitCode.HasValue)
        {
            Assert.Equal(metadata.ExpectedExitCode.Value, actualExitCode);
        }

        foreach (var expectedLine in metadata.ExpectedStdout)
        {
            Assert.Contains(expectedLine, actualStdout);
        }

        foreach (var expectedLine in metadata.ExpectedStderr)
        {
            Assert.Contains(expectedLine, actualStderr);
        }

        // 5. Clean up generated files
        File.Delete(Path.ChangeExtension(absoluteTestFile, ".c"));
        File.Delete(generatedExePath);
    }

    private static TestMetadata ParseTestMetadata(string testFile)
    {
        var lines = File.ReadAllLines(testFile);
        string testName = null;
        int? exitCode = null;
        var stdout = new List<string>();
        var stderr = new List<string>();

        foreach (var line in lines)
        {
            if (!line.TrimStart().StartsWith("//!"))
                continue;

            var content = line.Substring(line.IndexOf("//!") + 3).Trim();

            if (content.StartsWith("TEST:"))
            {
                testName = content.Substring(5).Trim();
            }
            else if (content.StartsWith("EXIT:"))
            {
                exitCode = int.Parse(content.Substring(5).Trim());
            }
            else if (content.StartsWith("STDOUT:"))
            {
                stdout.Add(content.Substring(7).Trim());
            }
            else if (content.StartsWith("STDERR:"))
            {
                stderr.Add(content.Substring(7).Trim());
            }
        }

        return new TestMetadata(testName, exitCode, stdout, stderr);
    }

    public static IEnumerable<object[]> GetTestFiles()
    {
        var currentAssemblyPath = typeof(HarnessTests).Assembly.Location;
        var projectRoot = Path.GetFullPath(Path.Combine(currentAssemblyPath, "..", "..", "..", "..", "..", ".."));
        var harnessDir = Path.Combine(projectRoot, "tests", "FLang.Tests", "Harness");

        if (!Directory.Exists(harnessDir))
        {
            throw new DirectoryNotFoundException($"Harness directory not found at: {harnessDir}");
        }

        // Recursively find all .f files in Harness and subdirectories
        // Return paths relative to Harness directory for cleaner IDE presentation
        foreach (var file in Directory.GetFiles(harnessDir, "*.f", SearchOption.AllDirectories))
        {
            var relativePath = Path.GetRelativePath(harnessDir, file);
            yield return new object[] { relativePath };
        }
    }
}