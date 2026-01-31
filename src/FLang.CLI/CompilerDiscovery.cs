using System.Diagnostics;
using System.Runtime.InteropServices;

namespace FLang.CLI;

public static class CompilerDiscovery
{
    public static CompilerConfig? GetCompilerForCompilation(string cFilePath, string outputFilePath, bool releaseBuild)
    {
        var availableCompilers = FindCompilersOrderedByPreference();
        var selected = availableCompilers.FirstOrDefault(c => c.path != null);

        if (selected.path == null)
            return null;

        string executablePath = selected.path;
        string arguments;
        Dictionary<string, string>? environment = null;

        if (selected.name.Contains("cl.exe"))
        {
            var (clPath, clEnv) = FindClExeWithEnvironment();
            environment = clEnv;

            var msvcArgs = new List<string> { "/nologo", "/ZI", "/WX" };
            if (releaseBuild) msvcArgs.Add("/O2");
            msvcArgs.Add($"/Fe\"{outputFilePath}\"");
            msvcArgs.Add($"\"{cFilePath}\"");
            arguments = string.Join(" ", msvcArgs);
        }
        else
        {
            var unixArgs = new List<string> { "-Werror" };
            if (releaseBuild) unixArgs.Add("-O2");
            unixArgs.Add($"-g -o \"{outputFilePath}\"");
            unixArgs.Add($"\"{cFilePath}\"");

            if (selected.name.Contains("xcrun"))
            {
                executablePath = "xcrun";
                arguments = "clang " + string.Join(" ", unixArgs);
            }
            else
            {
                arguments = string.Join(" ", unixArgs);
            }
        }

        return new CompilerConfig(selected.name, executablePath, arguments, environment);
    }

    public static List<(string name, string? path, string source)> FindCompilersOrderedByPreference()
    {
        var results = new List<(string name, string? path, string source)>();

        if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            var ccEnv = Environment.GetEnvironmentVariable("CC");
            if (!string.IsNullOrWhiteSpace(ccEnv))
            {
                string? resolved = null;
                var cc = ccEnv.Trim();
                if (cc.Contains('/') || cc.Contains(Path.DirectorySeparatorChar) || Path.IsPathRooted(cc))
                {
                    resolved = File.Exists(cc) ? Path.GetFullPath(cc) : null;
                }
                else
                {
                    resolved = ResolveCommandPath(cc);
                }

                results.Add(("$CC" + " (" + cc + ")", resolved, "env"));
            }

            if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
            {
                var xcrunFound = ResolveCommandPath("xcrun") != null;
                string? xcrunClang = null;
                if (xcrunFound)
                    xcrunClang = RunAndCaptureFirstLine("xcrun", "--find clang");
                results.Add(("xcrun clang", string.IsNullOrWhiteSpace(xcrunClang) ? null : xcrunClang, "xcrun"));
            }

            foreach (var name in new[] { "clang", "cc", "gcc" })
                results.Add((name, ResolveCommandPath(name), "path"));
        }
        else
        {
            var (clPath, _) = FindClExeWithEnvironment();
            if (clPath != null)
                results.Add(("cl.exe", clPath, "vswhere"));
            else
                results.Add(("cl.exe", ResolveCommandPath("cl.exe"), "path"));

            results.Add(("gcc", ResolveCommandPath("gcc"), "path"));
        }

        return results;
    }

    public static string? ResolveCommandPath(string command)
    {
        try
        {
            var isWindows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
            var fileName = isWindows ? "where" : "which";
            var psi = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = command,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using var p = Process.Start(psi);
            if (p == null) return null;
            var output = p.StandardOutput.ReadToEnd();
            p.WaitForExit();
            var line = output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
            if (string.IsNullOrWhiteSpace(line)) return null;
            return line.Trim();
        }
        catch
        {
            return null;
        }
    }

    private static string? RunAndCaptureFirstLine(string fileName, string arguments)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = fileName,
                Arguments = arguments,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using var p = Process.Start(psi);
            if (p == null) return null;
            var output = p.StandardOutput.ReadToEnd();
            p.WaitForExit();
            var line = output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
            if (string.IsNullOrWhiteSpace(line)) return null;
            return line.Trim();
        }
        catch
        {
            return null;
        }
    }

    private static (string?, Dictionary<string, string>?) FindClExeWithEnvironment()
    {
        var vswherePath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            "Microsoft Visual Studio", "Installer", "vswhere.exe");

        string? vsInstallPath = null;

        if (File.Exists(vswherePath))
            try
            {
                var process = Process.Start(new ProcessStartInfo
                {
                    FileName = vswherePath,
                    Arguments =
                        "-latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath",
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                });

                if (process != null)
                {
                    vsInstallPath = process.StandardOutput.ReadToEnd().Trim();
                    process.WaitForExit();

                    if (string.IsNullOrEmpty(vsInstallPath) || !Directory.Exists(vsInstallPath))
                        vsInstallPath = null;
                }
            }
            catch
            {
            }

        if (vsInstallPath == null)
        {
            var commonBasePaths = new[]
            {
                @"C:\Program Files (x86)\Microsoft Visual Studio\2022",
                @"C:\Program Files (x86)\Microsoft Visual Studio\2019",
                @"C:\Program Files (x86)\Microsoft Visual Studio\2017"
            };

            var editions = new[] { "Community", "Professional", "Enterprise", "BuildTools" };

            foreach (var basePath in commonBasePaths)
            {
                foreach (var edition in editions)
                {
                    var testPath = Path.Combine(basePath, edition);
                    if (Directory.Exists(testPath))
                    {
                        vsInstallPath = testPath;
                        break;
                    }
                }

                if (vsInstallPath != null) break;
            }
        }

        if (vsInstallPath == null)
            return (null, null);

        var vcToolsPath = Path.Combine(vsInstallPath, "VC", "Tools", "MSVC");
        if (!Directory.Exists(vcToolsPath))
            return (null, null);

        string? toolsetVersion = null;
        try
        {
            toolsetVersion = Directory.GetDirectories(vcToolsPath)
                .Select(Path.GetFileName)
                .OrderByDescending(v => v)
                .FirstOrDefault();
        }
        catch
        {
        }

        if (toolsetVersion == null)
            return (null, null);

        var clPath = Path.Combine(vcToolsPath, toolsetVersion, "bin", "Hostx64", "x64", "cl.exe");
        if (!File.Exists(clPath))
            return (null, null);

        var env = new Dictionary<string, string>();

        var toolsetDir = Path.Combine(vcToolsPath, toolsetVersion);
        var includeDir = Path.Combine(toolsetDir, "include");
        var libDir = Path.Combine(toolsetDir, "lib", "x64");

        var windowsSdkDir = @"C:\Program Files (x86)\Windows Kits\10";
        string? sdkVersion = null;

        if (Directory.Exists(windowsSdkDir))
        {
            var sdkIncludePath = Path.Combine(windowsSdkDir, "Include");
            if (Directory.Exists(sdkIncludePath))
                try
                {
                    sdkVersion = Directory.GetDirectories(sdkIncludePath)
                        .Select(Path.GetFileName)
                        .OrderByDescending(v => v)
                        .FirstOrDefault();
                }
                catch
                {
                }
        }

        var includePaths = new List<string> { includeDir };
        if (sdkVersion != null)
        {
            includePaths.Add(Path.Combine(windowsSdkDir, "Include", sdkVersion, "ucrt"));
            includePaths.Add(Path.Combine(windowsSdkDir, "Include", sdkVersion, "um"));
            includePaths.Add(Path.Combine(windowsSdkDir, "Include", sdkVersion, "shared"));
        }

        env["INCLUDE"] = string.Join(";", includePaths);

        var libPaths = new List<string> { libDir };
        if (sdkVersion != null)
        {
            libPaths.Add(Path.Combine(windowsSdkDir, "Lib", sdkVersion, "ucrt", "x64"));
            libPaths.Add(Path.Combine(windowsSdkDir, "Lib", sdkVersion, "um", "x64"));
        }

        env["LIB"] = string.Join(";", libPaths);

        var binDir = Path.GetDirectoryName(clPath);
        if (binDir != null) env["PATH"] = binDir + ";" + Environment.GetEnvironmentVariable("PATH");

        return (clPath, env);
    }
}
