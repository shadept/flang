using System;
using System.Text;

namespace FLang.Core;

public static class DiagnosticPrinter
{
    // ANSI color codes
    private const string Reset = "\x1b[0m";
    private const string Bold = "\x1b[1m";
    private const string Red = "\x1b[31m";
    private const string Yellow = "\x1b[33m";
    private const string Blue = "\x1b[34m";
    private const string Cyan = "\x1b[36m";
    private const string BoldRed = "\x1b[1;31m";
    private const string BoldYellow = "\x1b[1;33m";
    private const string BoldBlue = "\x1b[1;34m";
    private const string BoldCyan = "\x1b[1;36m";

    public static bool EnableColors { get; set; } = true;

    public static string Print(Diagnostic diagnostic, Compilation compilation)
    {
        var sb = new StringBuilder();

        // Get source information
        var source = compilation.Sources[diagnostic.Span.FileId];
        var (line, column) = source.GetLineAndColumn(diagnostic.Span.Index);

        // Format: error[E0001]: message
        var severityColor = diagnostic.Severity switch
        {
            DiagnosticSeverity.Error => BoldRed,
            DiagnosticSeverity.Warning => BoldYellow,
            DiagnosticSeverity.Info => BoldBlue,
            DiagnosticSeverity.Hint => BoldCyan,
            _ => ""
        };

        var severityText = diagnostic.Severity switch
        {
            DiagnosticSeverity.Error => "error",
            DiagnosticSeverity.Warning => "warning",
            DiagnosticSeverity.Info => "info",
            DiagnosticSeverity.Hint => "hint",
            _ => "unknown"
        };

        // Header: error[E0001]: message
        sb.Append(Color(severityColor, severityText));
        if (!string.IsNullOrEmpty(diagnostic.Code))
        {
            sb.Append(Color(severityColor, $"[{diagnostic.Code}]"));
        }
        sb.Append(": ");
        sb.Append(Color(Bold, diagnostic.Message));
        sb.AppendLine();

        // Location: --> filename:line:column
        sb.Append(Color(BoldBlue, "  --> "));
        sb.Append($"{source.FileName}:{line + 1}:{column + 1}");
        sb.AppendLine();

        // Calculate the width needed for line numbers (including context)
        var startLine = Math.Max(0, line - 1);
        var endLine = Math.Min(source.LineEndings.Length, line + 1);
        var maxLineNumber = endLine + 1;
        var lineNumberWidth = maxLineNumber.ToString().Length;

        // Helper to print the gutter (the " | " part)
        void PrintGutter(string lineNumber = "")
        {
            if (string.IsNullOrEmpty(lineNumber))
            {
                sb.Append(Color(BoldBlue, $" {new string(' ', lineNumberWidth)} | "));
            }
            else
            {
                sb.Append(Color(BoldBlue, $" {lineNumber.PadLeft(lineNumberWidth)} | "));
            }
        }

        // Empty line before context
        PrintGutter();
        sb.AppendLine();

        // Show context: line before (if exists)
        if (line > 0)
        {
            var prevLine = line - 1;
            var prevLineText = source.GetLineText(prevLine);
            PrintGutter($"{prevLine + 1}");
            sb.AppendLine(prevLineText);
        }

        // Main error line
        var lineText = source.GetLineText(line);
        PrintGutter($"{line + 1}");
        sb.AppendLine(lineText);

        // Underline/caret pointing to error
        var underlineColor = diagnostic.Severity switch
        {
            DiagnosticSeverity.Error => Red,
            DiagnosticSeverity.Warning => Yellow,
            DiagnosticSeverity.Info => Blue,
            DiagnosticSeverity.Hint => Cyan,
            _ => ""
        };

        PrintGutter();

        // Add spaces before the underline
        for (int i = 0; i < column; i++)
        {
            sb.Append(' ');
        }

        // Add the underline (carets)
        var underlineLength = Math.Max(1, diagnostic.Span.Length);
        sb.Append(Color(underlineColor, new string('^', underlineLength)));

        // Add hint if present
        if (!string.IsNullOrEmpty(diagnostic.Hint))
        {
            sb.Append(' ');
            sb.Append(Color(underlineColor, diagnostic.Hint));
        }

        sb.AppendLine();

        // Show context: line after (if exists)
        if (line + 1 < source.LineEndings.Length || (line + 1 == source.LineEndings.Length && source.Text.Length > source.GetLineEnd(line)))
        {
            var nextLine = line + 1;
            var nextLineText = source.GetLineText(nextLine);
            PrintGutter($"{nextLine + 1}");
            sb.AppendLine(nextLineText);
        }

        // Empty line at end
        PrintGutter();
        sb.AppendLine();

        return sb.ToString();
    }

    private static string Color(string colorCode, string text)
    {
        if (!EnableColors)
            return text;
        return $"{colorCode}{text}{Reset}";
    }

    public static void PrintToConsole(Diagnostic diagnostic, Compilation compilation)
    {
        Console.Error.Write(Print(diagnostic, compilation));
    }
}
