using System.Diagnostics;
using System.Runtime.InteropServices;

namespace FLang.CLI;

/// <summary>
/// Selected compiler plus its environment. Selection happens once per build;
/// argument construction (for compile-only or compile+link) is layered on top.
/// </summary>
public record SelectedCompiler(string Name, string ExecutablePath, Dictionary<string, string>? Environment)
{
    public bool IsMsvc => Name.Contains("cl.exe");
    public bool IsXcrun => Name.Contains("xcrun");
}

public static class CompilerDiscovery
{
    /// <summary>
    /// Picks the best available C compiler, returning the binary path plus the
    /// environment it requires (cl.exe needs INCLUDE/LIB/PATH). Returns
    /// <c>null</c> when no toolchain is available.
    /// </summary>
    public static SelectedCompiler? SelectCompiler()
    {
        var available = FindCompilersOrderedByPreference();
        var pick = available.FirstOrDefault(c => c.path != null);
        if (pick.path == null) return null;

        Dictionary<string, string>? env = null;
        string exe = pick.path;
        if (pick.name.Contains("cl.exe"))
        {
            var (clPath, clEnv) = FindClExeWithEnvironment();
            env = clEnv;
            if (clPath != null) exe = clPath;
        }
        return new SelectedCompiler(pick.name, exe, env);
    }

    /// <summary>
    /// Back-compat wrapper: select + build compile+link arguments in one call.
    /// Prefer <see cref="SelectCompiler"/> + <see cref="BuildCompileAndLinkArgs"/>
    /// in new code so the same selection can feed both the object-cache compile
    /// and the final link.
    /// </summary>
    public static CompilerConfig? GetCompilerForCompilation(string cFilePath, string outputFilePath, bool releaseBuild,
        IReadOnlyList<string>? extraCFiles = null, IReadOnlyList<string>? linkFlags = null,
        IReadOnlyList<string>? compilerFlags = null, IReadOnlyList<string>? extraObjFiles = null)
    {
        var selected = SelectCompiler();
        if (selected == null) return null;

        var args = BuildCompileAndLinkArgs(selected, cFilePath, outputFilePath, releaseBuild,
            extraCFiles, extraObjFiles, linkFlags, compilerFlags);

        var execPath = selected.IsXcrun ? "xcrun" : selected.ExecutablePath;
        var finalArgs = selected.IsXcrun ? "clang " + args : args;
        return new CompilerConfig(selected.Name, execPath, finalArgs, selected.Environment);
    }

    /// <summary>
    /// Builds the compile+link command: main <c>.c</c> plus any still-to-compile
    /// extras (<paramref name="extraCFiles"/>) plus any pre-compiled objects
    /// (<paramref name="extraObjFiles"/>, from <see cref="BuildCache"/>).
    /// </summary>
    public static string BuildCompileAndLinkArgs(
        SelectedCompiler selected,
        string cFilePath,
        string outputFilePath,
        bool releaseBuild,
        IReadOnlyList<string>? extraCFiles,
        IReadOnlyList<string>? extraObjFiles,
        IReadOnlyList<string>? linkFlags,
        IReadOnlyList<string>? compilerFlags)
    {
        if (selected.IsMsvc)
        {
            var objFilePath = Path.ChangeExtension(Path.GetFullPath(outputFilePath), ".obj");
            var msvcArgs = new List<string> { "/nologo", "/Z7", "/WX" };
            if (releaseBuild) msvcArgs.Add("/O2");
            if (compilerFlags != null) msvcArgs.AddRange(compilerFlags);

            // cl.exe /Fo<file> is only valid for a single source file; with
            // multiple sources we must pass a directory. Also, cl derives
            // .obj names from source basenames, so concurrent compilations
            // that share a companion .c file (e.g. stdlib fs.c) would
            // collide on the same fs.obj. When we have non-cached .c extras,
            // use a per-output intermediate directory to keep parallel test
            // runs isolated. Pre-compiled .obj extras bypass this entirely.
            if (extraCFiles is { Count: > 0 })
            {
                var parentDir = Path.GetDirectoryName(objFilePath) ?? ".";
                var outputStem = Path.GetFileNameWithoutExtension(outputFilePath);
                var objDir = Path.Combine(parentDir, outputStem + ".objs");
                Directory.CreateDirectory(objDir);
                msvcArgs.Add($"/Fo\"{objDir}{Path.DirectorySeparatorChar}{Path.DirectorySeparatorChar}\"");
            }
            else
            {
                msvcArgs.Add($"/Fo\"{objFilePath}\"");
            }
            msvcArgs.Add($"/Fe\"{outputFilePath}\"");
            msvcArgs.Add($"\"{cFilePath}\"");
            if (extraCFiles != null)
                foreach (var f in extraCFiles)
                    msvcArgs.Add($"\"{f}\"");
            if (extraObjFiles != null)
                foreach (var o in extraObjFiles)
                    msvcArgs.Add($"\"{o}\"");
            if (linkFlags != null) msvcArgs.AddRange(linkFlags);
            return string.Join(" ", msvcArgs);
        }

        var unixArgs = new List<string> { "-Werror", "-Wno-pointer-sign" };
        if (releaseBuild) unixArgs.Add("-O2");
        if (compilerFlags != null) unixArgs.AddRange(compilerFlags);
        unixArgs.Add($"-g -o \"{outputFilePath}\"");
        unixArgs.Add($"\"{cFilePath}\"");
        if (extraCFiles != null)
            foreach (var f in extraCFiles)
                unixArgs.Add($"\"{f}\"");
        if (extraObjFiles != null)
            foreach (var o in extraObjFiles)
                unixArgs.Add($"\"{o}\"");
        unixArgs.Add("-lm");
        if (linkFlags != null) unixArgs.AddRange(linkFlags);
        return string.Join(" ", unixArgs);
    }

    /// <summary>
    /// Builds a compile-only command (<c>cl /c</c> or <c>cc -c</c>) for a
    /// single source → single object, matching the flag set that
    /// <see cref="BuildCompileAndLinkArgs"/> would use.
    /// </summary>
    public static string BuildCompileOnlyArgs(
        SelectedCompiler selected,
        string sourcePath,
        string objPath,
        bool releaseBuild,
        IReadOnlyList<string>? compilerFlags)
    {
        if (selected.IsMsvc)
        {
            var msvcArgs = new List<string> { "/nologo", "/Z7", "/WX", "/c" };
            if (releaseBuild) msvcArgs.Add("/O2");
            if (compilerFlags != null) msvcArgs.AddRange(compilerFlags);
            msvcArgs.Add($"/Fo\"{objPath}\"");
            msvcArgs.Add($"\"{sourcePath}\"");
            return string.Join(" ", msvcArgs);
        }

        var unixArgs = new List<string> { "-Werror", "-Wno-pointer-sign", "-g", "-c" };
        if (releaseBuild) unixArgs.Add("-O2");
        if (compilerFlags != null) unixArgs.AddRange(compilerFlags);
        unixArgs.Add($"-o \"{objPath}\"");
        unixArgs.Add($"\"{sourcePath}\"");
        return string.Join(" ", unixArgs);
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
