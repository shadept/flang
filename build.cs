#!/usr/bin/env dotnet run
#:property TargetFramework=net10.0
#:property LangVersion=14
#:property Nullable=enable
#:property ImplicitUsings=enable

// ============================================================================
// FLang Build Script - build the compiler with itself
//
//   1. find a compiler: dist/<rid>/flang, else the cold-start seed
//      boot/<rid>/flang-seed
//   2. build compiler/ with it (stage 1)
//   3. install that as dist/<rid>/flang -- THE compiler
//
// A clean clone has neither, and the seed is the way in: `make` (or
// build.bat) in boot/<rid> needs nothing but a C compiler. See boot/README.md.
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
        FLang Build Script - build the compiler with itself

        Builds compiler/ with an existing compiler and installs the result as
        dist/<rid>/flang, the compiler test.cs, test-all.cs and the docs use.
        The builder is dist/<rid>/flang when present, otherwise the cold-start
        seed at boot/<rid>/flang-seed.

        Usage:
          dotnet run build.cs                  Build for current platform
          dotnet run build.cs <rid>            Build for specific RID
          dotnet run build.cs -- --force       Rebuild even if already up to date
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

var exeExt = rid.StartsWith("win") ? ".exe" : "";
var distDir = Path.GetFullPath(Path.Combine(scriptDir, "dist", rid));
var finalExe = Path.Combine(distDir, $"flang{exeExt}");
var stagesDir = Path.Combine(distDir, "stages");
var compilerDir = Path.Combine(scriptDir, "compiler");
var stdlibSrc = Path.Combine(scriptDir, "stdlib");
var compilerExe = Path.Combine(compilerDir, "build", $"flang{exeExt}");

if (!File.Exists(Path.Combine(compilerDir, "flang.toml")))
{
    Console.Error.WriteLine("Error: compiler/flang.toml not found; cannot build the compiler.");
    return 1;
}

// The builder for stage 1. An installed compiler is preferred over the seed:
// it is at least as new, and the seed's whole job is the cold start.
var seedExe = Path.Combine(scriptDir, "boot", rid, $"flang-seed{exeExt}");
var builder = File.Exists(finalExe) ? finalExe : File.Exists(seedExe) ? seedExe : null;

if (builder == null)
{
    Console.Error.WriteLine($"""
        Error: no compiler to build with.

        Cold-start from the committed seed, which needs only a C compiler:

          cd boot/{rid}
          make                  # build.bat on Windows, from a VS developer prompt

        then re-run this script. See boot/README.md.
        """);
    return 1;
}

Console.ForegroundColor = ConsoleColor.Cyan;
Console.WriteLine($"=== Building the compiler for RID={rid} ===");
Console.ResetColor();
Console.WriteLine($"Builder: {builder}");
Console.WriteLine();

// `flang build` has no whole-project up-to-date check of its own, so it re-does
// the full ~10s compile every time. Guard it with the sources it actually reads.
var sourceRoots = new[]
{
    compilerDir,
    Path.Combine(scriptDir, "lib"),
    stdlibSrc,
};

if (!force && File.Exists(finalExe) && NewestInput(sourceRoots) <= File.GetLastWriteTimeUtc(finalExe))
{
    Console.WriteLine($"Compiler up to date: {finalExe} (--force to rebuild)");
}
else
{
    Console.WriteLine("=== Stage 1 ===");

    // Stage 1 runs from a copy whenever the builder is the file this script
    // installs over. Windows holds an executable's image open for a moment
    // after the process exits, so copying onto it races that release.
    var stage1Builder = builder;
    if (string.Equals(builder, finalExe, StringComparison.OrdinalIgnoreCase))
    {
        stage1Builder = Path.Combine(distDir, $"flang-builder{exeExt}");
        File.Copy(builder, stage1Builder, overwrite: true);
        MakeExecutable(stage1Builder);
    }

    // --release is what makes the compiler usable: an unoptimized stage-1
    // takes ~4.8x longer to compile anything than the same code built /O2,
    // and every downstream stage, test run and tool invocation pays it.
    // Windows keeps debug info either way (/Z7 is passed in both modes).
    if (Run(stage1Builder, $"build --release --stdlib-path \"{stdlibSrc}\"", compilerDir) != 0)
    {
        Console.Error.WriteLine($"Error: stage-1 build failed. {finalExe} was not updated.");
        return 1;
    }

    if (!File.Exists(compilerExe))
    {
        Console.Error.WriteLine($"Error: stage-1 build reported success but produced no binary under {Path.Combine(compilerDir, "build")}.");
        return 1;
    }

    // Deploy a stdlib copy beside the binary so `compiler/build/flang build`
    // resolves std.* without --stdlib-path. Installing a *copy* into dist/ is
    // also what keeps a self-build from overwriting the binary running it.
    Directory.CreateDirectory(distDir);
    CopyDir(stdlibSrc, Path.Combine(compilerDir, "build", "stdlib"));
    CopyDir(stdlibSrc, Path.Combine(distDir, "stdlib"));
    File.Copy(compilerExe, finalExe, overwrite: true);
    MakeExecutable(finalExe);

    Console.WriteLine($"Compiler: {finalExe} ({new FileInfo(finalExe).Length} bytes)");
}

// Stages 2 and 3: the compiler compiling itself, twice. The milestone is the
// fixpoint -- stage 2 and stage 3 must emit byte-identical C, which proves the
// compiler is a fixed point of its own translation.
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

// Compile the compiler project with `builder` and park the results in
// dist/<rid>/stages as <name>.exe / <name>.c. Returns the path of the kept C
// file, or null if the build failed.
//   -k  keeps the emitted C: the fixpoint compares C, not binaries -- PE and
//       Mach-O headers carry timestamps and paths that never match.
//   -r  optimizes, like stage 1. The fixpoint is unaffected either way (the
//       flag reaches the C compiler, not the emitted C), but a debug stage 2
//       would build stage 3 several times slower.
//   -s  points at the repo stdlib: a stage compiler runs from dist/<rid>/stages,
//       away from the stdlib copy deployed next to the installed compiler.
//   Options follow the subcommand -- the CLI parses each against the command
//   it comes after.
string? RunStage(string builder, string name)
{
    if (Run(builder, $"build -k -r -s \"{stdlibSrc}\"", compilerDir) != 0)
    {
        Console.Error.WriteLine($"Error: {name} build failed.");
        return null;
    }

    var emittedC = Path.Combine(compilerDir, "build", "flang.c");
    if (!File.Exists(compilerExe) || !File.Exists(emittedC))
    {
        Console.Error.WriteLine($"Error: {name} reported success but left no binary or no C beside it.");
        return null;
    }

    Directory.CreateDirectory(stagesDir);
    var exe = Path.Combine(stagesDir, $"{name}{exeExt}");
    var c = Path.Combine(stagesDir, $"{name}.c");
    File.Copy(compilerExe, exe, overwrite: true);
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
