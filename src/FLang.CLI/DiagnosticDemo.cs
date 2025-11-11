using FLang.Core;

namespace FLang.CLI;

/// <summary>
/// Demonstrates the diagnostic system with sample errors.
/// Run with: dotnet run --project src/FLang.CLI -- --demo-diagnostics
/// </summary>
public static class DiagnosticDemo
{
    public static void Run()
    {
        Console.WriteLine("=== FLang Diagnostic System Demo ===\n");

        // Example 1: Type mismatch error
        var source1 = new Source(@"pub fn main() i32 {
    let x: i32 = ""hello""
    return x
}", "example1.f");

        var compilation1 = new Compilation();
        var fileId1 = compilation1.AddSource(source1);

        // Error at the string literal
        var errorSpan1 = new SourceSpan(fileId1, source1.Text.IndexOf("\"hello\""), 7);
        var diagnostic1 = Diagnostic.Error(
            "mismatched types",
            errorSpan1,
            "expected `i32`, found `String`",
            "E2002"
        );

        DiagnosticPrinter.PrintToConsole(diagnostic1, compilation1);
        Console.WriteLine();

        // Example 2: Undefined variable
        var source2 = new Source(@"pub fn main() i32 {
    let x: i32 = 10
    return y
}", "example2.f");

        var compilation2 = new Compilation();
        var fileId2 = compilation2.AddSource(source2);

        var errorSpan2 = new SourceSpan(fileId2, source2.Text.IndexOf("y"), 1);
        var diagnostic2 = Diagnostic.Error(
            "cannot find value `y` in this scope",
            errorSpan2,
            "not found in this scope",
            "E2004"
        );

        DiagnosticPrinter.PrintToConsole(diagnostic2, compilation2);
        Console.WriteLine();

        // Example 3: Warning
        var source3 = new Source(@"pub fn main() i32 {
    let unused: i32 = 42
    return 0
}", "example3.f");

        var compilation3 = new Compilation();
        var fileId3 = compilation3.AddSource(source3);

        var warnSpan = new SourceSpan(fileId3, source3.Text.IndexOf("unused"), 6);
        var diagnostic3 = Diagnostic.Warning(
            "unused variable: `unused`",
            warnSpan,
            "prefix with `_` to ignore",
            "W0001"
        );

        DiagnosticPrinter.PrintToConsole(diagnostic3, compilation3);
        Console.WriteLine();

        // Example 4: Multi-character error span
        var source4 = new Source(@"pub fn add(a: i32, b: i32) i32 {
    return a + b
}

pub fn main() i32 {
    return add(10, ""wrong"")
}", "example4.f");

        var compilation4 = new Compilation();
        var fileId4 = compilation4.AddSource(source4);

        var errorSpan4 = new SourceSpan(fileId4, source4.Text.IndexOf("\"wrong\""), 7);
        var diagnostic4 = Diagnostic.Error(
            "mismatched types",
            errorSpan4,
            "expected `i32`, found `String`",
            "E2002"
        );

        DiagnosticPrinter.PrintToConsole(diagnostic4, compilation4);
    }
}