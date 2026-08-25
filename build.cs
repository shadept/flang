#!/usr/bin/env dotnet run
#:property TargetFramework=net10.0
#:property LangVersion=14
#:property Nullable=enable
#:property ImplicitUsings=enable

// ============================================================================
// FLang Build Script - Cross-platform build using dotnet run
//
// Bootstraps the whole chain in one command:
//   1. publish the C# reference compiler   -> dist/<rid>/flang-ref
//   2. build the self-hosted compiler with it (stage 1)
//   3. install that as dist/<rid>/flang    -- THE default compiler
//
// Everything downstream (test.cs, test-all.cs, the README) points at
// dist/<rid>/flang, so the default is always the self-hosted binary and the
// reference is one rename away.
//
// Usage:
//   dotnet run build.cs                  # Build for current platform
//   dotnet run build.cs <rid>            # Build for specific RID
//   dotnet run build.cs -- --help        # Show help
// ============================================================================

using System.Diagnostics;
using System.Runtime.InteropServices;

var wall = Stopwatch.StartNew();

var scriptDir = Directory.GetCurrentDirectory();

bool showHelp = args.Contains("--help") || args.Contains("-h");
bool force = args.Contains("--force") || args.Contains("-f");
// Stage 3 subsumes stage 2: it needs a stage-2 compiler to run.
bool stage3 = args.Contains("--stage3") || args.Contains("--fixpoint");
bool stage2 = stage3 || args.Contains("--stage2");
string? rid = args.FirstOrDefault(a => !a.StartsWith('-'));

if (showHelp)
{
    Console.WriteLine("""
        FLang Build Script - Cross-platform build

        Publishes the C# reference compiler to dist/<rid>/flang-ref, builds the
        self-hosted compiler with it, and installs that as dist/<rid>/flang --
        the default compiler used by test.cs, test-all.cs and the docs.

        Usage:
          dotnet run build.cs                  Build for current platform
          dotnet run build.cs <rid>            Build for specific RID
          dotnet run build.cs -- --force       Rebuild the self-hosted compiler even
                                               if it is already up to date
          dotnet run build.cs -- --stage2      Also build stage 2 (stage 1 compiles
                                               the compiler again)
          dotnet run build.cs -- --stage3      Also build stage 3 and check the
                                               stage-2 = stage-3 fixpoint (the
                                               emitted C must be byte-identical)
          dotnet run build.cs -- --help        Show this help

        Stage artifacts land in dist/<rid>/stages/ as stage{2,3}{.exe,.c}.

        RID is auto-detected from OS and architecture, e.g.:
          Windows x64   -> win-x64
          Linux x64     -> linux-x64
          macOS ARM64   -> darwin-arm64
        """);
    return 0;
}

// Auto-detect RID if not provided
if (rid == null)
{
    string os;
    if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        os = "win";
    else if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
        os = "linux";
    else if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        os = "darwin";
    else
    {
        Console.Error.WriteLine("Error: Could not detect platform. Please specify a RID.");
        return 1;
    }

    var arch = RuntimeInformation.OSArchitecture switch
    {
        Architecture.X64 => "x64",
        Architecture.Arm64 => "arm64",
        _ => null
    };

    if (arch == null)
    {
        Console.Error.WriteLine($"Error: Unsupported architecture {RuntimeInformation.OSArchitecture}. Please specify a RID.");
        return 1;
    }

    rid = $"{os}-{arch}";
}

// Map FLang RID to .NET RID (dotnet uses "osx" not "darwin")
var dotnetRid = rid.StartsWith("darwin") ? rid.Replace("darwin", "osx") : rid;

var exeExt = rid.StartsWith("win") ? ".exe" : "";
var distDir = Path.GetFullPath(Path.Combine(scriptDir, "dist", rid));
var finalExe = Path.Combine(distDir, $"flang{exeExt}");        // default: self-hosted
var refExe = Path.Combine(distDir, $"flang-ref{exeExt}");      // C# reference
var stdlibDir = Path.Combine(distDir, "stdlib");

Console.ForegroundColor = ConsoleColor.Cyan;
Console.WriteLine($"=== Building the reference compiler (Release) for RID={rid} ===");
Console.ResetColor();
Console.WriteLine();

// Publish. NuGet restore dominates a no-change publish (~15s vs ~1.3s), and it
// is a no-op the overwhelming majority of the time, so try --no-restore first
// and pay for a restore only when that fails (fresh clone, changed package
// refs). A genuine compile error costs one wasted fast pass.
var distRidProp = rid != dotnetRid ? $" -p:DistRid={rid}" : "";
var publishArgs = $"publish src/FLang.CLI/FLang.CLI.csproj -c Release -r {dotnetRid}{distRidProp} -p:DistExeName=flang-ref -nologo -v minimal";
if (Run("dotnet", publishArgs + " --no-restore") != 0)
{
    Console.WriteLine();
    Console.WriteLine("Publish failed without a restore; retrying with one...");
    if (Run("dotnet", publishArgs) != 0)
    {
        Console.Error.WriteLine("Error: dotnet publish failed.");
        return 1;
    }
}
if (Run("dotnet", "build test.cs") != 0)
{
    Console.Error.WriteLine("Error: dotnet build test.cs failed.");
    return 1;
}

Console.WriteLine();

// Verify output. `-p:DistExeName=flang-ref` keeps the publish off dist/<rid>/flang,
// which belongs to the self-hosted compiler installed below.
if (!File.Exists(refExe))
{
    Console.ForegroundColor = ConsoleColor.Yellow;
    Console.WriteLine($"Warning: Expected artifact not found at {refExe}");
    Console.WriteLine("The publish may have succeeded, but the post-publish copy step might have been skipped.");
    Console.WriteLine("Check the publish logs and the MSBuild target in src/FLang.CLI/FLang.CLI.csproj.");
    Console.ResetColor();
    return 1;
}

Console.WriteLine($"Reference compiler: {refExe} ({new FileInfo(refExe).Length} bytes)");

if (Directory.Exists(stdlibDir))
    Console.WriteLine($"Stdlib copied to:   {stdlibDir}");
else
    Console.WriteLine($"Note: stdlib folder not found at {stdlibDir}");

// Stage 1: build the self-hosted compiler with the reference, deploy a stdlib
// copy next to its binary so `bootstrap/build/flang build` resolves std.*
// without --stdlib-path, then install it as the default compiler. Installing a
// *copy* into dist/ is also what keeps a self-build from overwriting the very
// binary running it.
var bootstrapDir = Path.Combine(scriptDir, "bootstrap");
if (!File.Exists(Path.Combine(bootstrapDir, "flang.toml")))
{
    Console.Error.WriteLine("Error: bootstrap/flang.toml not found; cannot build the self-hosted compiler.");
    return 1;
}

// `flang build` has no whole-project up-to-date check of its own, so it re-does
// the full ~10s compile every time. Guard it with the sources it actually reads:
// the bootstrap and library trees, the stdlib, and src/ (which stands in for
// flang-ref -- the publish re-copies that binary unconditionally, so its own
// timestamp says nothing about whether the reference actually changed).
var sourceRoots = new[]
{
    bootstrapDir,
    Path.Combine(scriptDir, "lib"),
    Path.Combine(scriptDir, "stdlib"),
    Path.Combine(scriptDir, "src"),
};
var bootstrapExe = Path.Combine(bootstrapDir, "build", $"flang{exeExt}");
var stdlibSrc = Path.Combine(scriptDir, "stdlib");
var stagesDir = Path.Combine(distDir, "stages");

if (!force && File.Exists(finalExe) && NewestInput(sourceRoots) <= File.GetLastWriteTimeUtc(finalExe))
{
    Console.WriteLine();
    Console.WriteLine($"Self-hosted compiler up to date: {finalExe} (--force to rebuild)");
}
else
{
    Console.WriteLine();
    Console.WriteLine("=== Building the self-hosted compiler (stage 1) ===");
    // --release is what makes the compiler usable: an unoptimized stage-1
    // takes ~4.8x longer to compile anything than the same code built /O2,
    // and every downstream stage, test run and tool invocation pays it.
    // Windows keeps debug info either way (/Z7 is passed in both modes).
    if (Run(refExe, "build --release", bootstrapDir) != 0)
    {
        Console.Error.WriteLine($"Error: self-hosted build failed. {finalExe} was not updated; use flang-ref meanwhile.");
        return 1;
    }

    if (!File.Exists(bootstrapExe))
    {
        Console.Error.WriteLine($"Error: self-hosted build reported success but produced no binary under {Path.Combine(bootstrapDir, "build")}.");
        return 1;
    }

    CopyDir(stdlibSrc, Path.Combine(bootstrapDir, "build", "stdlib"));
    File.Copy(bootstrapExe, finalExe, overwrite: true);
    MakeExecutable(finalExe);

    Console.WriteLine($"Default compiler:   {finalExe} ({new FileInfo(finalExe).Length} bytes)");
}

// Stages 2 and 3: the self-hosted compiler compiling itself, twice. The
// milestone is the fixpoint -- stage 2 and stage 3 must emit byte-identical
// C, which proves the compiler is a fixed point of its own translation.
if (stage2)
{
    Console.WriteLine();
    Console.WriteLine("=== Building stage 2 (stage 1 compiles the compiler) ===");
    var stage2C = RunStage(finalExe, "stage2");
    if (stage2C == null) return 1;

    if (stage3)
    {
        Console.WriteLine();
        Console.WriteLine("=== Building stage 3 (stage 2 compiles the compiler) ===");
        var stage3C = RunStage(Path.Combine(stagesDir, $"stage2{exeExt}"), "stage3");
        if (stage3C == null) return 1;

        Console.WriteLine();
        if (!File.ReadAllBytes(stage2C).SequenceEqual(File.ReadAllBytes(stage3C)))
        {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine($"Fixpoint BROKEN: {stage2C} and {stage3C} differ.");
            Console.ResetColor();
            return 1;
        }
        Console.WriteLine($"Fixpoint holds: stage 2 and stage 3 emit identical C ({new FileInfo(stage2C).Length} bytes).");
    }
}

Console.WriteLine();
Console.ForegroundColor = ConsoleColor.Green;
Console.WriteLine($"Done in {wall.Elapsed.TotalSeconds:F1}s.");
Console.ResetColor();
return 0;

// --- Helpers ---

// Compile the bootstrap project with `compiler` and park the results in
// dist/<rid>/stages as <name>.exe / <name>.c. Returns the path of the kept C
// file, or null if the build failed.
//   -k  keeps the emitted C: the fixpoint compares C, not binaries -- PE and
//       Mach-O headers carry timestamps and paths that never match.
//   -r  optimizes, like stage 1. The fixpoint is unaffected either way (the
//       flag reaches the C compiler, not the emitted C), but a debug stage 2
//       would build stage 3 several times slower.
//   -s  points at the repo stdlib: a stage compiler runs from dist/<rid>/stages,
//       away from the stdlib copy deployed next to the default compiler.
//   Flags precede the subcommand -- the CLI stops parsing options at it.
string? RunStage(string compiler, string name)
{
    if (Run(compiler, $"-k -r -s \"{stdlibSrc}\" build", bootstrapDir) != 0)
    {
        Console.Error.WriteLine($"Error: {name} build failed.");
        return null;
    }

    var emittedC = Path.Combine(bootstrapDir, "build", "flang.c");
    if (!File.Exists(bootstrapExe) || !File.Exists(emittedC))
    {
        Console.Error.WriteLine($"Error: {name} reported success but left no binary or no C beside it.");
        return null;
    }

    Directory.CreateDirectory(stagesDir);
    var exe = Path.Combine(stagesDir, $"{name}{exeExt}");
    var c = Path.Combine(stagesDir, $"{name}.c");
    File.Copy(bootstrapExe, exe, overwrite: true);
    File.Copy(emittedC, c, overwrite: true);
    MakeExecutable(exe);

    Console.WriteLine($"{name}: {exe} ({new FileInfo(exe).Length} bytes), C: {c} ({new FileInfo(c).Length} bytes)");
    return c;
}

void MakeExecutable(string path)
{
    if (OperatingSystem.IsWindows()) return;
    File.SetUnixFileMode(path,
        UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute |
        UnixFileMode.GroupRead | UnixFileMode.GroupExecute |
        UnixFileMode.OtherRead | UnixFileMode.OtherExecute);
}

int Run(string fileName, string arguments, string? workingDir = null)
{
    var psi = new ProcessStartInfo
    {
        FileName = fileName,
        Arguments = arguments,
        UseShellExecute = false,
        WorkingDirectory = workingDir ?? scriptDir
    };

    using var process = Process.Start(psi)!;
    process.WaitForExit();
    return process.ExitCode;
}

// Newest write time across the given source trees, ignoring build output
// directories -- their contents are always newer than the inputs that made them.
DateTime NewestInput(IEnumerable<string> roots)
{
    var newest = DateTime.MinValue;
    foreach (var root in roots)
    {
        if (!Directory.Exists(root)) return DateTime.MaxValue;  // can't prove freshness -> rebuild
        foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
        {
            if (IsBuildOutput(Path.GetRelativePath(root, file))) continue;
            var t = File.GetLastWriteTimeUtc(file);
            if (t > newest) newest = t;
        }
    }
    return newest;
}

static bool IsBuildOutput(string relativePath) =>
    relativePath.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
        .Any(seg => seg is "build" or "bin" or "obj");

void CopyDir(string src, string dst)
{
    if (!Directory.Exists(src)) return;
    if (Directory.Exists(dst)) Directory.Delete(dst, true);
    Directory.CreateDirectory(dst);
    foreach (var file in Directory.GetFiles(src, "*", SearchOption.AllDirectories))
    {
        var target = Path.Combine(dst, Path.GetRelativePath(src, file));
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        File.Copy(file, target, true);
    }
}
