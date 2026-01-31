using FLang.CLI;
using Xunit.Abstractions;

namespace FLang.Tests;

public class HarnessTests
{
    private readonly ITestOutputHelper _testOutputHelper;

    public HarnessTests(ITestOutputHelper testOutputHelper)
    {
        _testOutputHelper = testOutputHelper;
    }

    private static readonly TestHarness _harness;

    static HarnessTests()
    {
        var currentAssemblyPath = typeof(HarnessTests).Assembly.Location;
        var projectRoot = Path.GetFullPath(Path.Combine(currentAssemblyPath, "..", "..", "..", ".."));
        _harness = new TestHarness(projectRoot);
    }

    [Theory]
    [MemberData(nameof(GetTestFiles))]
    public void RunTest(string testFile)
    {
        var absoluteTestFile = Path.Combine(_harness.HarnessDir, testFile);
        _testOutputHelper.WriteLine($"[TEST_FILE] {absoluteTestFile}");

        var result = _harness.RunTest(absoluteTestFile);

        if (result.Skipped)
        {
            _testOutputHelper.WriteLine($"[SKIP] {result.SkipReason}");
            return;
        }

        if (!result.Passed)
        {
            Assert.Fail($"{result.TestName} ({absoluteTestFile}):\n{result.FailureMessage}");
        }
    }

    public static TheoryData<string> GetTestFiles()
    {
        var currentAssemblyPath = typeof(HarnessTests).Assembly.Location;
        var projectRoot = Path.GetFullPath(Path.Combine(currentAssemblyPath, "..", "..", "..", ".."));
        var harness = new TestHarness(projectRoot);

        var data = new TheoryData<string>();
        foreach (var file in harness.DiscoverTests())
        {
            var relativePath = Path.GetRelativePath(harness.HarnessDir, file);
            data.Add(relativePath);
        }
        return data;
    }
}
