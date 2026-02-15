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
        var (startLine, startColumn) = source.GetLineAndColumn(diagnostic.Span.Index);
        var spanEnd = diagnostic.Span.Index + Math.Max(1, diagnostic.Span.Length) - 1;
        var (endLine, endColumn) = source.GetLineAndColumn(Math.Min(spanEnd, source.Text.Length - 1));

        // Location: --> filename:line:column
        sb.Append(Color(AnsiColor.BoldBlue, "  --> "));
        sb.Append($"{source.FileName}:{startLine + 1}:{startColumn + 1}");
        sb.Append(NewLine);

        // Calculate the width needed for line numbers (including context lines)
        var lastVisibleLine = Math.Min(source.LineEndings.Length, endLine + 1);
        var lineNumberWidth = Math.Max(1, (lastVisibleLine + 1).ToString().Length);

        // Helper to print the gutter (the " | " part)
        void PrintGutter(string lineNumber = "")
        {
            if (string.IsNullOrEmpty(lineNumber))
                sb.Append(Color(AnsiColor.BoldBlue, $" {new string(' ', lineNumberWidth)} | "));
            else
                sb.Append(Color(AnsiColor.BoldBlue, $" {lineNumber.PadLeft(lineNumberWidth)} | "));
        }

        var underlineColor = diagnostic.Severity.ToColor();
        var isMultiLine = startLine != endLine;

        // Empty line before context
        PrintGutter();
        sb.Append(NewLine);

        // Context line before the span
        if (startLine > 0)
        {
            PrintGutter($"{startLine}");
            sb.Append(source.GetLineText(startLine - 1) + NewLine);
        }

        if (!isMultiLine)
        {
            // Single-line span
            var lineText = source.GetLineText(startLine);
            PrintGutter($"{startLine + 1}");
            sb.Append(lineText + NewLine);

            PrintGutter();
            for (var i = 0; i < startColumn; i++) sb.Append(' ');
            var underlineLength = Math.Max(1, Math.Min(diagnostic.Span.Length, lineText.Length - startColumn));
            sb.Append(Color(underlineColor, new string('^', underlineLength)));
            if (!string.IsNullOrEmpty(diagnostic.HintMessage))
            {
                sb.Append(' ');
                sb.Append(Color(underlineColor, diagnostic.HintMessage));
            }
            sb.Append(NewLine);
        }
        else
        {
            // Multi-line span: show each spanned line with its underline
            for (var lineIdx = startLine; lineIdx <= endLine; lineIdx++)
            {
                var lineText = source.GetLineText(lineIdx);
                PrintGutter($"{lineIdx + 1}");
                sb.Append(lineText + NewLine);

                int underStart, underLen;
                if (lineIdx == startLine)
                {
                    underStart = startColumn;
                    underLen = Math.Max(1, lineText.Length - startColumn);
                }
                else if (lineIdx == endLine)
                {
                    underStart = 0;
                    underLen = Math.Max(1, endColumn + 1);
                }
                else
                {
                    underStart = 0;
                    underLen = Math.Max(1, lineText.Length);
                }

                PrintGutter();
                for (var i = 0; i < underStart; i++) sb.Append(' ');
                sb.Append(Color(underlineColor, new string('^', underLen)));
                if (lineIdx == endLine && !string.IsNullOrEmpty(diagnostic.HintMessage))
                {
                    sb.Append(' ');
                    sb.Append(Color(underlineColor, diagnostic.HintMessage));
                }
                sb.Append(NewLine);
            }
        }

        // Context line after the span
        var afterLine = isMultiLine ? endLine + 1 : startLine + 1;
        if (afterLine < source.LineEndings.Length ||
            (afterLine == source.LineEndings.Length && source.Text.Length > source.GetLineEnd(afterLine - 1)))
        {
            PrintGutter($"{afterLine + 1}");
            sb.Append(source.GetLineText(afterLine) + NewLine);
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
