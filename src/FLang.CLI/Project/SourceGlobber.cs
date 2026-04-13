using Microsoft.Extensions.FileSystemGlobbing;
using Microsoft.Extensions.FileSystemGlobbing.Abstractions;

namespace FLang.CLI.Project;

public static class SourceGlobber
{
    public static List<string> Glob(string projectRoot, string pattern)
    {
        var matcher = new Matcher();
        matcher.AddInclude(pattern);
        matcher.AddExclude("**/*.generated.f");
        matcher.AddExclude("**/build/**");
        matcher.AddExclude("**/vendor/**");

        var directory = new DirectoryInfoWrapper(new DirectoryInfo(projectRoot));
        var result = matcher.Execute(directory);

        return result.Files
            .Select(f => Path.GetFullPath(Path.Combine(projectRoot, f.Path)))
            .OrderBy(f => f)
            .ToList();
    }
}
