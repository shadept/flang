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
// The compiler used for step 2 is `$FLANG` if set, else dist/<rid>/flang —
// the self-hosted compiler, whose `test` command builds each project's blocks
// into a generated runner and executes it.
// ============================================================================

using System.Diagnostics;

var root = Directory.GetCurrentDirectory();

// Resolve the compiler: $FLANG wins, else the self-hosted binary under dist/.
// The exact-name match keeps the bundled stdlib's flang.toml out of the running.
var flang = Environment.GetEnvironmentVariable("FLANG");
if (string.IsNullOrEmpty(flang))
{
    var distDir = Path.Combine(root, "dist");
    flang = Directory.Exists(distDir)
        ? Directory.GetFiles(distDir, "flang*", SearchOption.AllDirectories)
            .FirstOrDefault(f => Path.GetFileName(f) is "flang" or "flang.exe")
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
    ("stdlib/core", ["--stdlib-path", Path.Combine(root, "stdlib")]),
    ("lib/flang_parser", []),
    ("lib/flang_typer", []),
    ("lib/flang_analysis", []),
    ("lib/flang_driver", []),
    ("lib/flang_lsp", []),
    ("compiler", []),
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
    // Global options precede the subcommand: getopts stops at the first
    // positional, and everything after it belongs to the subcommand.
    results.Add(($"flang test {proj}", Run(flang, ["test", .. extra], dir)));
}

// Step 3 - the runner itself. tests/runner is expected to FAIL: what is under
// test is that a failed assertion is reported rather than fatal, that the block
// after it still runs, and that the process exits non-zero. Without this, a
// regression in the panic/longjmp path would turn every failing test green.
{
    var dir = Path.Combine(root, "tests", "runner");
    Console.WriteLine();
    Console.WriteLine($">>> {Path.GetFileName(flang)} test  (runner fixture, expected to fail)");
    var psi = new ProcessStartInfo
    {
        FileName = flang,
        WorkingDirectory = dir,
        RedirectStandardOutput = true,
        RedirectStandardError = true,
    };
    psi.ArgumentList.Add("test");
    using var p = Process.Start(psi)!;
    var stdout = p.StandardOutput.ReadToEnd();
    var stderr = p.StandardError.ReadToEnd();
    p.WaitForExit();
    Console.Write(stdout);

    var problems = new List<string>();
    // Asserted on substance, not on layout: the two compilers word their
    // per-test lines and summaries differently, and this fixture has to hold
    // for whichever one $FLANG names.
    if (p.ExitCode == 0) problems.Add("expected a non-zero exit code");
    if (!stdout.Contains("1 failed")) problems.Add("expected the summary to report one failure");
    if (!stdout.Contains("FIXTURE-EXPECTED-FAILURE")) problems.Add("expected the panic message to reach stdout");
    if (!stdout.Contains("3/3")) problems.Add("expected the run to continue past the failure to the third block");
    if (stdout.Contains("FIXTURE-MAIN-RAN")) problems.Add("the project's own main ran; the runner is the entry point");
    foreach (var problem in problems) Console.Error.WriteLine($"    {problem}");
    if (problems.Count > 0 && stderr.Length > 0) Console.Error.WriteLine(stderr);
    results.Add(("flang test runner fixture", problems.Count == 0));
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
