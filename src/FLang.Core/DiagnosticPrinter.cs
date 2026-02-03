using System.Text;

namespace FLang.Core;

/// <summary>
/// Provides utilities for formatting and printing diagnostics with source context and color output.
/// </summary>
public static class DiagnosticPrinter
{
    private const string NewLine = "\n\r";

    /// <summary>
    /// Gets or sets whether ANSI color codes should be included in diagnostic output.
    /// Default is true.
    /// </summary>
    public static bool EnableColors { get; set; } = true;

    /// <summary>
    /// Formats a diagnostic message with source context, line numbers, and color highlighting.
    /// </summary>
    /// <param name="diagnostic">The diagnostic to format.</param>
    /// <param name="compilation">The compilation context containing source files.</param>
    /// <returns>A formatted string with the diagnostic message, source location, and context lines.</returns>
    public static string Print(Diagnostic diagnostic, Compilation compilation)
    {
        var sb = new StringBuilder();

        // Header: error[E0001]: message
        var severityColor = diagnostic.Severity.ToBoldColor();
        var severityText = diagnostic.Severity.ToText();
        sb.Append(Color(severityColor, severityText));
        if (!string.IsNullOrEmpty(diagnostic.Code)) sb.Append(Color(severityColor, $"[{diagnostic.Code}]"));
        sb.Append(": ");
        sb.Append(Color(AnsiColor.Bold, diagnostic.Message));
        sb.Append(NewLine);

        // If FileId is -1, we don't have source information (e.g., C compiler error)
        if (diagnostic.Span.FileId == -1)
        {
            return sb.ToString();
        }

        // Get source information
        var source = compilation.Sources[diagnostic.Span.FileId];
        var (line, column) = source.GetLineAndColumn(diagnostic.Span.Index);

        // Location: --> filename:line:column
        sb.Append(Color(AnsiColor.BoldBlue, "  --> "));
        sb.Append($"{source.FileName}:{line + 1}:{column + 1}");
        sb.Append(NewLine);

        // Calculate the width needed for line numbers (including context)
        var startLine = Math.Max(0, line - 1);
        var endLine = Math.Min(source.LineEndings.Length, line + 1);
        var maxLineNumber = endLine + 1;
        var lineNumberWidth = maxLineNumber.ToString().Length;

        // Helper to print the gutter (the " | " part)
        void PrintGutter(string lineNumber = "")
        {
            if (string.IsNullOrEmpty(lineNumber))
                sb.Append(Color(AnsiColor.BoldBlue, $" {new string(' ', lineNumberWidth)} | "));
            else
                sb.Append(Color(AnsiColor.BoldBlue, $" {lineNumber.PadLeft(lineNumberWidth)} | "));
        }

        // Empty line before context
        PrintGutter();
        sb.Append(NewLine);

        // Show context: line before (if exists)
        if (line > 0)
        {
            var prevLine = line - 1;
            var prevLineText = source.GetLineText(prevLine);
            PrintGutter($"{prevLine + 1}");
            sb.Append(prevLineText + NewLine);
        }

        // Main error line
        var lineText = source.GetLineText(line);
        PrintGutter($"{line + 1}");
        sb.Append(lineText + NewLine);

        // Underline/caret pointing to error
        var underlineColor = diagnostic.Severity.ToColor();
        PrintGutter();

        // Add spaces before the underline
        for (var i = 0; i < column; i++) sb.Append(' ');

        // Add the underline (carets)
        var underlineLength = Math.Max(1, diagnostic.Span.Length);
        sb.Append(Color(underlineColor, new string('^', underlineLength)));

        // Add hint if present
        if (!string.IsNullOrEmpty(diagnostic.HintMessage))
        {
            sb.Append(' ');
            sb.Append(Color(underlineColor, diagnostic.HintMessage));
        }

        sb.Append(NewLine);

        // Show context: line after (if exists)
        if (line + 1 < source.LineEndings.Length ||
            (line + 1 == source.LineEndings.Length && source.Text.Length > source.GetLineEnd(line)))
        {
            var nextLine = line + 1;
            var nextLineText = source.GetLineText(nextLine);
            PrintGutter($"{nextLine + 1}");
            sb.Append(nextLineText + NewLine);
        }

        // Empty line at the end
        PrintGutter();
        sb.Append(NewLine);

        // Render notes as full diagnostics
        foreach (var note in diagnostic.Notes)
        {
            sb.Append(Print(note, compilation));
        }

        return sb.ToString();
    }

    /// <summary>
    /// Wraps text with ANSI color codes if colors are enabled.
    /// </summary>
    /// <param name="color">The ANSI color to apply.</param>
    /// <param name="text">The text to colorize.</param>
    /// <returns>The text wrapped in color codes if <see cref="EnableColors"/> is true; otherwise, the original text.</returns>
    private static string Color(AnsiColor color, string text)
    {
        if (!EnableColors)
            return text;
        return $"{color.ToAnsi()}{text}{AnsiColor.Reset.ToAnsi()}";
    }

    /// <summary>
    /// Formats and prints a diagnostic to the standard error stream.
    /// </summary>
    /// <param name="diagnostic">The diagnostic to print.</param>
    /// <param name="compilation">The compilation context containing source files.</param>
    public static void PrintToConsole(Diagnostic diagnostic, Compilation compilation)
    {
        Console.Error.Write(Print(diagnostic, compilation));
    }
}
