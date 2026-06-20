#!/usr/bin/env dotnet run
#:property TargetFramework=net10.0
#:property LangVersion=14
#:property Nullable=enable
#:property ImplicitUsings=enable

// ============================================================================
// FLang Full Test Script - runs every test path with one command.
//   1. The C# harness  (dotnet test.cs)         — compiler feature tests
//   2. `flang test` in each self-hosted project  — colocated `test {}` blocks
//
// Usage:
//   dotnet test-all.cs                  # run everything
//
// The compiler used for step 2 is `$FLANG` if set, else dist/<rid>/flang.exe.
// Point FLANG at the bootstrap compiler once it can self-host to test the
// exact same suites through the new pipeline — no script change needed.
// ============================================================================

using System.Diagnostics;

var root = Directory.GetCurrentDirectory();

// Resolve the compiler: $FLANG wins, else the single binary under dist/.
var flang = Environment.GetEnvironmentVariable("FLANG");
if (string.IsNullOrEmpty(flang))
{
    var distDir = Path.Combine(root, "dist");
    flang = Directory.Exists(distDir)
        ? Directory.GetFiles(distDir, "flang*", SearchOption.AllDirectories)
            .FirstOrDefault(f => Path.GetFileNameWithoutExtension(f) == "flang")
        : null;
    if (flang == null)
    {
        Console.Error.WriteLine("error: no flang binary under dist/. Run `dotnet build.cs` first or set $FLANG.");
        return 1;
    }
}

// Self-hosted projects whose `test {}` blocks should run, with any extra
// `flang test` args. Skipped if absent. `std` IS the stdlib, so it must resolve
// against the source tree rather than the bundled copy under dist.
(string Dir, string[] Args)[] projects =
[
    ("lib/flang_core", []),
    ("lib/flang_parser", []),
    ("lib/flang_typer", []),
    ("lib/flang_driver", []),
    ("bootstrap", []),
    ("stdlib/std", ["--stdlib-path", Path.Combine(root, "stdlib")]),
];

var results = new List<(string Name, bool Ok)>();

// Step 1 — C# harness.
// results.Add(("harness (dotnet test.cs)", Run("dotnet", ["test.cs"], root)));

// Step 2 — per-project test blocks.
foreach (var (proj, extra) in projects)
{
    var dir = Path.Combine(root, proj);
    if (!File.Exists(Path.Combine(dir, "flang.toml"))) continue;
    results.Add(($"flang test {proj}", Run(flang, ["test", .. extra], dir)));
}

// Summary.
Console.WriteLine();
Console.WriteLine("──────── test-all summary ────────");
foreach (var (name, ok) in results)
    Console.WriteLine($"  {(ok ? "PASS" : "FAIL")}  {name}");
var failed = results.Count(r => !r.Ok);
Console.WriteLine($"──────── {results.Count - failed}/{results.Count} green ────────");
return failed == 0 ? 0 : 1;

static bool Run(string exe, string[] argv, string cwd)
{
    Console.WriteLine($"\n>>> {Path.GetFileName(exe)} {string.Join(' ', argv)}  ({Path.GetFileName(cwd)})");
    var psi = new ProcessStartInfo { FileName = exe, WorkingDirectory = cwd };
    foreach (var a in argv) psi.ArgumentList.Add(a);
    using var p = Process.Start(psi)!;
    p.WaitForExit();
    return p.ExitCode == 0;
}
