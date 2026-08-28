#!/usr/bin/env dotnet run
#:property TargetFramework=net10.0
#:property LangVersion=14
#:property Nullable=enable
#:property ImplicitUsings=enable

// ============================================================================
// FLang Seed Promotion - advance the committed bootstrap seed in boot/
//
// The seed is the self-hosted compiler as generated C99 (one file per target
// OS family, plus the stdlib runtime sidecars), the artifact a clean clone
// cold-starts from with nothing but a C compiler. See boot/README.md and
// docs/architecture.md (Bootstrap seed).
//
// Promotion is deliberate and gated:
//   1. dotnet run build.cs -- --stage3     stage-2 = stage-3 C byte-identical
//   2. dotnet run test.cs (FLANG=stage2)   full harness green under stage 2
//   3. stage2 -E -T <os> -A <arch> build   emit seed C for every target
//   4. copy C + sidecars into boot/<target>/
//
// Nothing is committed or tagged here - review the boot/ diff, then commit
// and tag it seed/<date> (or seed/<version>).
//
// Usage:
//   dotnet run promote.cs
// ============================================================================

using System.Diagnostics;
using System.Runtime.InteropServices;

var scriptDir = Directory.GetCurrentDirectory();

// Seed targets: one per supported OS family, arch chosen to match the CI
// matrix. `platform.arch` only reaches the emitted C through comptime #if -
// both supported arches are 64-bit, so layout is arch-independent - but the
// baked host_arch() string should match the machine the seed runs on.
(string dir, string os, string arch)[] targets =
[
    ("win-x64", "windows", "x86_64"),
    ("linux-x64", "linux", "x86_64"),
    ("darwin-arm64", "macos", "arm64"),
];

string hostRid;
if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
    hostRid = "win-x64";
else if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
    hostRid = "linux-x64";
else
    hostRid = "darwin-arm64";

var exeExt = hostRid.StartsWith("win") ? ".exe" : "";
var stagesDir = Path.Combine(scriptDir, "dist", hostRid, "stages");
var stage2Exe = Path.Combine(stagesDir, $"stage2{exeExt}");
var bootstrapDir = Path.Combine(scriptDir, "bootstrap");
var stdlibDir = Path.Combine(scriptDir, "stdlib");
var bootDir = Path.Combine(scriptDir, "boot");

// --- Gate 1: stage-2 = stage-3 fixpoint ---
Banner("Gate 1: build stage 3 and check the stage-2 = stage-3 fixpoint");
if (Run("dotnet", "run build.cs -- --stage3") != 0)
{
    Console.Error.WriteLine("promote: fixpoint gate failed - not touching boot/.");
    return 1;
}

// --- Gate 2: full harness under the stage-2 compiler ---
// test.cs compiles through $FLANG when set. stage2 runs from stages/, so it
// needs a stdlib copy beside it (default stdlib root is <exe dir>/stdlib).
Banner("Gate 2: full harness under stage 2");
CopyDir(stdlibDir, Path.Combine(stagesDir, "stdlib"));
if (Run("dotnet", "run test.cs", env: ("FLANG", stage2Exe)) != 0)
{
    Console.Error.WriteLine("promote: harness gate failed under stage 2 - not touching boot/.");
    return 1;
}

// --- Emit and install the seeds ---
foreach (var (dir, os, arch) in targets)
{
    Banner($"Seed: {dir} (-T {os} -A {arch})");
    // Options follow the command: the self-hosted CLI parses each option
    // against the command it comes after, and refuses one that precedes it.
    if (Run(stage2Exe, $"build -E -s \"{stdlibDir}\" -T {os} -A {arch}", bootstrapDir) != 0)
    {
        Console.Error.WriteLine($"promote: seed emission failed for {dir} - boot/ may be partially updated, review before committing.");
        return 1;
    }

    var emitted = Path.Combine(bootstrapDir, "build", "flang.c");
    var seedDir = Path.Combine(bootDir, dir);
    Directory.CreateDirectory(seedDir);
    File.Copy(emitted, Path.Combine(seedDir, "flang.c"), overwrite: true);

    // Runtime sidecars: the hand-written companion .c files the generated C
    // links against. Copied flat (names are unique) so each seed directory is
    // a closed set - HEAD's stdlib may drift, the seed must not care.
    foreach (var c in Directory.EnumerateFiles(stdlibDir, "*.c", SearchOption.AllDirectories))
        File.Copy(c, Path.Combine(seedDir, Path.GetFileName(c)), overwrite: true);

    Console.WriteLine($"  -> {seedDir} ({new FileInfo(Path.Combine(seedDir, "flang.c")).Length} bytes)");
}

// --- Stamp ---
var vm = System.Text.RegularExpressions.Regex.Match(
    File.ReadAllText(Path.Combine(bootstrapDir, "flang.toml")), "version\\s*=\\s*\"([^\"]+)\"");
var version = vm.Success ? vm.Groups[1].Value : "unknown";
var commit = Capture("git", "rev-parse HEAD")?.Trim() ?? "unknown";
var dirty = !string.IsNullOrWhiteSpace(Capture("git", "status --porcelain --untracked-files=no"));
File.WriteAllText(Path.Combine(bootDir, "SEED"),
    $"flang {version}\ncommit {commit}{(dirty ? " (dirty tree)" : "")}\ndate {DateTime.UtcNow:yyyy-MM-dd}\n");
if (dirty)
{
    Console.ForegroundColor = ConsoleColor.Yellow;
    Console.WriteLine("Note: working tree is dirty - boot/SEED's commit does not fully describe the seed.");
    Console.WriteLine("Commit the source changes first, then re-run promote, so the stamp is honest.");
    Console.ResetColor();
}

Banner("Done");
Console.WriteLine("""
    boot/ updated. Nothing was committed. Next:
      1. Review the diff:  git diff --stat boot/
      2. Commit boot/ (and only boot/) as its own commit.
      3. Tag it:           git tag seed/<date-or-version>
    """);
return 0;

// --- Helpers ---

void Banner(string msg)
{
    Console.WriteLine();
    Console.ForegroundColor = ConsoleColor.Cyan;
    Console.WriteLine($"=== {msg} ===");
    Console.ResetColor();
}

int Run(string fileName, string arguments, string? workingDir = null, (string k, string v)? env = null)
{
    var psi = new ProcessStartInfo
    {
        FileName = fileName,
        Arguments = arguments,
        UseShellExecute = false,
        WorkingDirectory = workingDir ?? scriptDir
    };
    if (env is { } e)
        psi.Environment[e.k] = e.v;

    using var process = Process.Start(psi)!;
    process.WaitForExit();
    return process.ExitCode;
}

string? Capture(string fileName, string arguments)
{
    var psi = new ProcessStartInfo
    {
        FileName = fileName,
        Arguments = arguments,
        UseShellExecute = false,
        RedirectStandardOutput = true,
        WorkingDirectory = scriptDir
    };
    using var process = Process.Start(psi)!;
    var stdout = process.StandardOutput.ReadToEnd();
    process.WaitForExit();
    return process.ExitCode == 0 ? stdout : null;
}

void CopyDir(string src, string dst)
{
    if (Directory.Exists(dst)) Directory.Delete(dst, true);
    Directory.CreateDirectory(dst);
    foreach (var file in Directory.GetFiles(src, "*", SearchOption.AllDirectories))
    {
        var target = Path.Combine(dst, Path.GetRelativePath(src, file));
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        File.Copy(file, target, true);
    }
}
