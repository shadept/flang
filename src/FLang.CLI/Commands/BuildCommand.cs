using System.Diagnostics;
using System.Runtime.InteropServices;
using FLang.CLI.Project;
using FLang.Core;

namespace FLang.CLI.Commands;

public static class BuildCommand
{
    public static int Run(string[] args)
    {
        var releaseBuild = false;
        var emitC = false;
        string? stdlibPath = null;

        for (var i = 0; i < args.Length; i++)
        {
            if (args[i] == "--release") releaseBuild = true;
            else if (args[i] == "--emit-c") emitC = true;
            else if (args[i] == "--stdlib-path" && i + 1 < args.Length) stdlibPath = args[++i];
            else
            {
                Console.Error.WriteLine($"error: unknown option '{args[i]}'");
                Console.Error.WriteLine("Usage: flang build [--release] [--emit-c]");
                return 1;
            }
        }

        // Find flang.toml
        var tomlPath = ProjectLoader.FindProjectFile(Directory.GetCurrentDirectory());
        if (tomlPath == null)
        {
            Console.Error.WriteLine("error: no flang.toml found in current directory or any parent directory");
            return 1;
        }

        var projectRoot = Path.GetDirectoryName(tomlPath)!;

        // Load project
        FlangProject project;
        try
        {
            project = ProjectLoader.Load(tomlPath);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"error: {ex.Message}");
            return 1;
        }

        // Glob source files
        var sourceFiles = SourceGlobber.Glob(projectRoot, project.Project.Source);
        if (sourceFiles.Count == 0)
        {
            Console.Error.WriteLine($"error: no source files found matching '{project.Project.Source}'");
            return 1;
        }

        // Resolve platform build config
        var platformConfig = ProjectLoader.GetCurrentPlatformConfig(project.Build);

        // Resolve stdlib
        stdlibPath ??= Path.Combine(AppContext.BaseDirectory, "stdlib");

        // Resolve output path
        var outputDir = Path.Combine(projectRoot, project.Project.Output);
        Directory.CreateDirectory(outputDir);

        var exeName = project.Project.Name;
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            exeName += ".exe";
        var outputPath = Path.Combine(outputDir, exeName);

        // Build link flags from platform config
        var linkFlags = new List<string>();
        if (platformConfig?.Libs != null)
            foreach (var lib in platformConfig.Libs)
                linkFlags.Add(ResolvePath(lib, projectRoot));
        if (platformConfig?.Ldflags != null)
            linkFlags.AddRange(platformConfig.Ldflags);

        // Build header paths from platform config
        var headerPaths = platformConfig?.Headers?.Select(h => ResolvePath(h, projectRoot)).ToList();

        // Build compiler flags from platform config
        var compilerFlags = platformConfig?.Cflags?.ToList();

        // Build include paths — add source root so imports between project files resolve
        var sourceRoot = ResolveSourceRoot(project.Project.Source, projectRoot);
        var includePaths = new List<string>();
        if (sourceRoot != null)
            includePaths.Add(sourceRoot);

        var options = new CompilerOptions(
            InputFilePaths: sourceFiles,
            StdlibPath: stdlibPath,
            OutputPath: outputPath,
            ReleaseBuild: releaseBuild,
            WorkingDirectory: projectRoot,
            IncludePaths: includePaths.Count > 0 ? includePaths : null,
            LinkFlags: linkFlags.Count > 0 ? linkFlags : null,
            HeaderPaths: headerPaths is { Count: > 0 } ? headerPaths : null,
            CompilerFlags: compilerFlags is { Count: > 0 } ? compilerFlags : null
        );

        var compiler = new Compiler();
        var stopwatch = Stopwatch.StartNew();

        try
        {
            var result = compiler.Compile(options);

            foreach (var diagnostic in result.Diagnostics)
                DiagnosticPrinter.PrintToConsole(diagnostic, result.CompilationContext);

            if (!result.Success)
            {
                Console.Error.WriteLine("Build failed.");
                return 1;
            }

            if (emitC)
            {
                var cFilePath = Path.Combine(outputDir, Path.GetFileNameWithoutExtension(exeName) + ".c");
                var generatedC = Path.Combine(outputDir, Path.GetFileNameWithoutExtension(exeName) + ".generated.c");
                if (File.Exists(cFilePath))
                    File.Copy(cFilePath, generatedC, overwrite: true);
            }

            stopwatch.Stop();
            Console.WriteLine($"Built {outputPath} in {stopwatch.ElapsedMilliseconds}ms");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"error: {ex.Message}");
            return 1;
        }
    }

    private static string ResolvePath(string path, string projectRoot)
    {
        if (Path.IsPathRooted(path)) return path;
        return Path.GetFullPath(Path.Combine(projectRoot, path));
    }

    private static string? ResolveSourceRoot(string sourceGlob, string projectRoot)
    {
        // Extract the static prefix from the glob (e.g., "src/**/*.f" -> "src")
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
}
