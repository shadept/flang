using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Tomlyn;
using Tomlyn.Model;

namespace FLang.Core.Project;

public static partial class ProjectLoader
{
    public const string ProjectFileName = "flang.toml";

    public static string? FindProjectFile(string startDir)
    {
        var dir = Path.GetFullPath(startDir);
        while (dir != null)
        {
            var candidate = Path.Combine(dir, ProjectFileName);
            if (File.Exists(candidate))
                return candidate;
            dir = Path.GetDirectoryName(dir);
        }
        return null;
    }

    public static FlangProject Load(string tomlPath)
    {
        var text = File.ReadAllText(tomlPath);
        var model = Toml.ToModel(text, tomlPath);

        if (!model.TryGetValue("project", out var projectObj) || projectObj is not TomlTable projectTable)
            throw new InvalidOperationException($"{tomlPath}: missing required [project] section");

        var name = GetRequiredString(projectTable, "name", tomlPath);
        var version = GetRequiredString(projectTable, "version", tomlPath);
        var source = GetOptionalString(projectTable, "source") ?? "src/**/*.f";
        var output = GetOptionalString(projectTable, "output") ?? "build";

        var projectInfo = new ProjectInfo(name, version, ExpandEnvVars(source), ExpandEnvVars(output));

        BuildSection? build = null;
        if (model.TryGetValue("build", out var buildObj) && buildObj is TomlTable buildTable)
            build = ParseBuildSection(buildTable);

        ImportsSection? imports = null;
        if (model.TryGetValue("imports", out var importsObj) && importsObj is TomlTable importsTable)
            imports = ParseImportsSection(importsTable);

        return new FlangProject(projectInfo, build, imports);
    }

    private static ImportsSection ParseImportsSection(TomlTable table)
    {
        return new ImportsSection(
            Global: GetOptionalStringArray(table, "global"));
    }

    public static PlatformBuildConfig? GetCurrentPlatformConfig(BuildSection? build)
    {
        if (build == null) return null;

        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX)) return build.Macos;
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux)) return build.Linux;
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) return build.Windows;
        return null;
    }

    public static string GetCurrentPlatformName()
    {
        if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX)) return "macos";
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux)) return "linux";
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) return "windows";
        return "unknown";
    }

    /// <summary>
    /// Extracts the static directory prefix from a source glob pattern.
    /// E.g., "src/**/*.f" → "src", "lib/core/**/*.f" → "lib/core"
    /// </summary>
    public static string? ResolveSourceRoot(string sourceGlob, string projectRoot)
    {
        var parts = sourceGlob.Replace('\\', '/').Split('/');
        var staticParts = new List<string>();
        foreach (var part in parts)
        {
            if (part.Contains('*') || part.Contains('?')) break;
            staticParts.Add(part);
        }
        if (staticParts.Count == 0) return null;
        var root = Path.Combine(projectRoot, Path.Combine(staticParts.ToArray()));
        return Directory.Exists(root) ? root : null;
    }

    public static string ExpandEnvVars(string value)
    {
        var errors = new List<string>();
        var result = EnvVarPattern().Replace(value, match =>
        {
            var varName = match.Groups[1].Success ? match.Groups[1].Value : match.Groups[2].Value;
            var envValue = Environment.GetEnvironmentVariable(varName);
            if (envValue == null)
                errors.Add(varName);
            return envValue ?? match.Value;
        });

        if (errors.Count > 0)
            throw new InvalidOperationException(
                $"undefined environment variable(s): {string.Join(", ", errors.Select(e => $"${e}"))}");

        return result;
    }

    [GeneratedRegex(@"\$\{(\w+)\}|\$(\w+)")]
    private static partial Regex EnvVarPattern();

    private static BuildSection ParseBuildSection(TomlTable buildTable)
    {
        PlatformBuildConfig? macos = null, linux = null, windows = null;

        if (buildTable.TryGetValue("macos", out var macObj) && macObj is TomlTable macTable)
            macos = ParsePlatformConfig(macTable);
        if (buildTable.TryGetValue("linux", out var linObj) && linObj is TomlTable linTable)
            linux = ParsePlatformConfig(linTable);
        if (buildTable.TryGetValue("windows", out var winObj) && winObj is TomlTable winTable)
            windows = ParsePlatformConfig(winTable);

        return new BuildSection(macos, linux, windows);
    }

    private static PlatformBuildConfig ParsePlatformConfig(TomlTable table)
    {
        return new PlatformBuildConfig(
            Headers: GetOptionalStringArray(table, "headers"),
            Libs: GetOptionalStringArray(table, "libs"),
            Cflags: GetOptionalStringArray(table, "cflags"),
            Ldflags: GetOptionalStringArray(table, "ldflags"));
    }

    private static string GetRequiredString(TomlTable table, string key, string context)
    {
        if (!table.TryGetValue(key, out var value) || value is not string s)
            throw new InvalidOperationException($"{context}: missing required field 'project.{key}'");
        return s;
    }

    private static string? GetOptionalString(TomlTable table, string key)
    {
        if (table.TryGetValue(key, out var value) && value is string s)
            return s;
        return null;
    }

    private static string[]? GetOptionalStringArray(TomlTable table, string key)
    {
        if (!table.TryGetValue(key, out var value)) return null;
        if (value is not TomlArray array) return null;
        return array.OfType<string>().Select(ExpandEnvVars).ToArray();
    }
}
