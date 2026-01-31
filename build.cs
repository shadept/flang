#!/usr/bin/env dotnet run
#:property TargetFramework=net10.0
#:property LangVersion=14
#:property Nullable=enable
#:property ImplicitUsings=enable

// ============================================================================
// FLang Build Script - Cross-platform build using dotnet run
// Usage:
//   dotnet run build.cs                  # Build for current platform
//   dotnet run build.cs <rid>            # Build for specific RID
//   dotnet run build.cs -- --restore     # Restore packages before building
//   dotnet run build.cs -- --help        # Show help
// ============================================================================

using System.Diagnostics;
using System.Runtime.InteropServices;

var scriptDir = Directory.GetCurrentDirectory();

bool showHelp = args.Contains("--help") || args.Contains("-h");
bool restore = args.Contains("--restore");
string? rid = args.FirstOrDefault(a => !a.StartsWith("-"));

if (showHelp)
{
    Console.WriteLine("""
        FLang Build Script - Cross-platform build

        Usage:
          dotnet run build.cs                  Build for current platform
          dotnet run build.cs <rid>            Build for specific RID
          dotnet run build.cs -- --restore     Restore packages before building
          dotnet run build.cs -- --help        Show this help

        RID defaults:
          Windows  -> win-x64
          Linux    -> linux-x64
          macOS    -> osx-x64
        """);
    return 0;
}

// Auto-detect RID if not provided
if (rid == null)
{
    if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        rid = "win-x64";
    else if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux))
        rid = "linux-x64";
    else if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
        rid = "osx-x64";
    else
    {
        Console.Error.WriteLine("Error: Could not detect platform. Please specify a RID.");
        return 1;
    }
}

var exeExt = rid.StartsWith("win") ? ".exe" : "";
var distDir = Path.GetFullPath(Path.Combine(scriptDir, "dist", rid));
var finalExe = Path.Combine(distDir, $"flang{exeExt}");
var stdlibDir = Path.Combine(distDir, "stdlib");

Console.ForegroundColor = ConsoleColor.Cyan;
Console.WriteLine($"=== Building FLang.CLI (Release) for RID={rid} ===");
Console.ResetColor();
Console.WriteLine();

// Restore (optional)
if (restore)
{
    if (Run("dotnet", $"restore flang.sln -r {rid} -nologo -v minimal") != 0)
    {
        Console.Error.WriteLine("Error: dotnet restore failed.");
        return 1;
    }
}

// Publish
var publishArgs = $"publish src/FLang.CLI/FLang.CLI.csproj -c Release -r {rid} --no-restore -nologo -v minimal";
if (Run("dotnet", publishArgs) != 0)
{
    Console.Error.WriteLine("Error: dotnet publish failed.");
    return 1;
}

Console.WriteLine();

// Verify output
if (!File.Exists(finalExe))
{
    Console.ForegroundColor = ConsoleColor.Yellow;
    Console.WriteLine($"Warning: Expected artifact not found at {finalExe}");
    Console.WriteLine("The publish may have succeeded, but the post-publish copy step might have been skipped.");
    Console.WriteLine("Check the publish logs and the MSBuild target in src/FLang.CLI/FLang.CLI.csproj.");
    Console.ResetColor();
    return 1;
}

var size = new FileInfo(finalExe).Length;
Console.WriteLine($"Success: {finalExe} ({size} bytes)");

if (Directory.Exists(stdlibDir))
    Console.WriteLine($"Stdlib copied to: {stdlibDir}");
else
    Console.WriteLine($"Note: stdlib folder not found at {stdlibDir}");

Console.WriteLine();
Console.ForegroundColor = ConsoleColor.Green;
Console.WriteLine("Done.");
Console.ResetColor();
return 0;

// --- Helpers ---

int Run(string fileName, string arguments)
{
    var psi = new ProcessStartInfo
    {
        FileName = fileName,
        Arguments = arguments,
        UseShellExecute = false,
        WorkingDirectory = scriptDir
    };

    using var process = Process.Start(psi)!;
    process.WaitForExit();
    return process.ExitCode;
}
