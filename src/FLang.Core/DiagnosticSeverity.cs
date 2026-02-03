using System.Diagnostics;

namespace FLang.Core;

/// <summary>
/// Represents the severity level of a diagnostic message.
/// </summary>
public enum DiagnosticSeverity
{
    /// <summary>
    /// A fatal error that prevents compilation.
    /// </summary>
    Error,

    /// <summary>
    /// A warning about potentially problematic code.
    /// </summary>
    Warning,

    /// <summary>
    /// An informational message.
    /// </summary>
    Info,

    /// <summary>
    /// A hint or suggestion for code improvement.
    /// </summary>
    Hint
}

/// <summary>
/// Extension methods for <see cref="DiagnosticSeverity"/>.
/// </summary>
public static class DiagnosticSeverityExtensions
{
    /// <summary>
    /// Gets the display text for a severity level.
    /// </summary>
    public static string ToText(this DiagnosticSeverity severity) => severity switch
    {
        DiagnosticSeverity.Error => "error",
        DiagnosticSeverity.Warning => "warning",
        DiagnosticSeverity.Info => "info",
        DiagnosticSeverity.Hint => "hint",
        _ => "unknown"
    };

    /// <summary>
    /// Gets the bold ANSI color for a severity level (used for headers).
    /// </summary>
    public static AnsiColor ToBoldColor(this DiagnosticSeverity severity) => severity switch
    {
        DiagnosticSeverity.Error => AnsiColor.BoldRed,
        DiagnosticSeverity.Warning => AnsiColor.BoldYellow,
        DiagnosticSeverity.Info => AnsiColor.BoldCyan,
        DiagnosticSeverity.Hint => AnsiColor.BoldGreen,
        _ => throw new UnreachableException()
    };

    /// <summary>
    /// Gets the regular ANSI color for a severity level (used for underlines).
    /// </summary>
    public static AnsiColor ToColor(this DiagnosticSeverity severity) => severity switch
    {
        DiagnosticSeverity.Error => AnsiColor.Red,
        DiagnosticSeverity.Warning => AnsiColor.Yellow,
        DiagnosticSeverity.Info => AnsiColor.Cyan,
        DiagnosticSeverity.Hint => AnsiColor.Green,
        _ => throw new UnreachableException()
    };
}

/// <summary>
/// ANSI terminal color codes.
/// </summary>
public enum AnsiColor
{
    None,
    Reset,
    Bold,
    Red,
    Green,
    Yellow,
    Blue,
    Cyan,
    BoldRed,
    BoldGreen,
    BoldYellow,
    BoldBlue,
    BoldCyan
}

/// <summary>
/// Extension methods for <see cref="AnsiColor"/>.
/// </summary>
public static class AnsiColorExtensions
{
    /// <summary>
    /// Gets the ANSI escape sequence for this color.
    /// </summary>
    public static string ToAnsi(this AnsiColor color) => color switch
    {
        AnsiColor.None => "",
        AnsiColor.Reset => "\x1b[0m",
        AnsiColor.Bold => "\x1b[1m",
        AnsiColor.Green => "\x1b[32m",
        AnsiColor.Red => "\x1b[31m",
        AnsiColor.Yellow => "\x1b[33m",
        AnsiColor.Blue => "\x1b[34m",
        AnsiColor.Cyan => "\x1b[36m",
        AnsiColor.BoldRed => "\x1b[1;31m",
        AnsiColor.BoldGreen => "\x1b[1;32m",
        AnsiColor.BoldYellow => "\x1b[1;33m",
        AnsiColor.BoldBlue => "\x1b[1;34m",
        AnsiColor.BoldCyan => "\x1b[1;36m",
        _ => throw new UnreachableException()
    };
}
