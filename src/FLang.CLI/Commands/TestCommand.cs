using System.Diagnostics;
using System.Runtime.InteropServices;
using FLang.CLI.Project;
using FLang.Core;
using FLang.Core.Project;

namespace FLang.CLI.Commands;

public static class TestCommand
{
    public static int Run(string[] args)
    {
        var releaseBuild = false;
        string? filter = null;
        string? stdlibPath = null;

        for (var i = 0; i < args.Length; i++)
        {
            if (args[i] == "--release") releaseBuild = true;
            else if (args[i] == "--stdlib-path" && i + 1 < args.Length) stdlibPath = args[++i];
            else if (!args[i].StartsWith('-')) filter = args[i];
            else
            {
                Console.Error.WriteLine($"error: unknown option '{args[i]}'");
                Console.Error.WriteLine("Usage: flang test [filter] [--release]");
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

        // Glob source files, optionally filtering
        var sourceFiles = SourceGlobber.Glob(projectRoot, project.Project.Source);
        if (filter != null)
            sourceFiles = sourceFiles.Where(f => f.Contains(filter, StringComparison.OrdinalIgnoreCase)).ToList();

        if (sourceFiles.Count == 0)
        {
            Console.Error.WriteLine(filter != null
                ? $"error: no source files matching filter '{filter}'"
                : $"error: no source files found matching '{project.Project.Source}'");
            return 1;
        }

        // Resolve platform build config
        var platformConfig = ProjectLoader.GetCurrentPlatformConfig(project.Build);

        // Resolve stdlib
        stdlibPath ??= Path.Combine(AppContext.BaseDirectory, "stdlib");

        // Create temp directory for test output
        var tempDir = Path.Combine(Path.GetTempPath(), "flang_test_" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(tempDir);

        var exeName = "test_runner";
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            exeName += ".exe";
        var outputPath = Path.Combine(tempDir, exeName);

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

        // Build include paths
        var sourceRoot = ProjectLoader.ResolveSourceRoot(project.Project.Source, projectRoot);
        var includePaths = new List<string>();
        if (sourceRoot != null)
            includePaths.Add(sourceRoot);

        // Without dependency resolution, test blocks cannot import the project's
        // libraries — same resolution path as `flang build`.
        List<ResolvedDependency> resolvedDeps;
        try { resolvedDeps = DependencyResolver.ResolveDirect(project, projectRoot); }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"error: {ex.Message}");
            return 1;
        }

        var depSourceRoots = new Dictionary<string, string>();
        var projectMetadata = new Dictionary<string, ProjectMetadata>();
        if (sourceRoot != null)
            projectMetadata[project.Project.Name] = new ProjectMetadata(
                project.Project.Name, project.Project.Version, sourceRoot);
        foreach (var dep in resolvedDeps)
        {
            depSourceRoots[dep.Name] = dep.SourceRoot;
            projectMetadata[dep.Name] = new ProjectMetadata(
                dep.Name, dep.Project.Project.Version, dep.SourceRoot);

            var depPlatform = ProjectLoader.GetCurrentPlatformConfig(dep.Project.Build);
            if (depPlatform?.Libs != null)
                foreach (var lib in depPlatform.Libs)
                    linkFlags.Add(ResolvePath(lib, dep.ProjectRoot));
            if (depPlatform?.Ldflags != null)
                linkFlags.AddRange(depPlatform.Ldflags);
            if (depPlatform?.Headers != null)
            {
                headerPaths ??= new List<string>();
                foreach (var h in depPlatform.Headers)
                    headerPaths.Add(ResolvePath(h, dep.ProjectRoot));
            }
        }

        var options = new CompilerOptions(
            InputFilePaths: sourceFiles,
            StdlibPath: stdlibPath,
            OutputPath: outputPath,
            ReleaseBuild: releaseBuild,
            RunTests: true,
            WorkingDirectory: projectRoot,
            IncludePaths: includePaths.Count > 0 ? includePaths : null,
            LinkFlags: linkFlags.Count > 0 ? linkFlags : null,
            HeaderPaths: headerPaths is { Count: > 0 } ? headerPaths : null,
            CompilerFlags: compilerFlags is { Count: > 0 } ? compilerFlags : null,
            ProjectName: project.Project.Name,
            ProjectSourceRoot: sourceRoot,
            ProjectGlobalImports: project.Imports?.Global,
            DependencySourceRoots: depSourceRoots.Count > 0 ? depSourceRoots : null,
            ProjectMetadata: projectMetadata.Count > 0 ? projectMetadata : null
        );

        var compiler = new Compiler();

        try
        {
            var result = compiler.Compile(options);

            foreach (var diagnostic in result.Diagnostics)
                DiagnosticPrinter.PrintToConsole(diagnostic, result.CompilationContext);

            if (!result.Success)
            {
                Console.Error.WriteLine("Test compilation failed.");
                return 1;
            }

            // Run the test executable
            if (result.ExecutablePath != null && File.Exists(result.ExecutablePath))
            {
                var psi = new ProcessStartInfo
                {
                    FileName = result.ExecutablePath,
                    UseShellExecute = false,
                    WorkingDirectory = projectRoot
                };

                using var process = Process.Start(psi);
                if (process != null)
                {
                    process.WaitForExit();
                    return process.ExitCode;
                }
            }

            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"error: {ex.Message}");
            return 1;
        }
        finally
        {
            try { Directory.Delete(tempDir, recursive: true); } catch { }
        }
    }

    private static string ResolvePath(string path, string projectRoot)
    {
        if (Path.IsPathRooted(path)) return path;
        return Path.GetFullPath(Path.Combine(projectRoot, path));
    }

}
