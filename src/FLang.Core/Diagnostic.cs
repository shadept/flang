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
/// Represents a diagnostic message (error, warning, info, or hint) with source location.
/// </summary>
public class Diagnostic
{
    /// <summary>
    /// Initializes a new instance of the <see cref="Diagnostic"/> class.
    /// </summary>
    /// <param name="severity">The severity level of this diagnostic.</param>
    /// <param name="message">The diagnostic message text.</param>
    /// <param name="span">The source location where this diagnostic applies.</param>
    /// <param name="hintMessage">Optional hint or suggestion text to help fix the issue.</param>
    /// <param name="code">Optional diagnostic code (e.g., "E0001").</param>
    private Diagnostic(
        DiagnosticSeverity severity,
        string message,
        SourceSpan span,
        string? hintMessage = null,
        string? code = null)
    {
        Severity = severity;
        Message = message;
        Span = span;
        HintMessage = hintMessage;
        Code = code;
    }

    /// <summary>
    /// Gets the severity level of this diagnostic.
    /// </summary>
    public DiagnosticSeverity Severity { get; }

    /// <summary>
    /// Gets the diagnostic message text.
    /// </summary>
    public string Message { get; }

    /// <summary>
    /// Gets the source location where this diagnostic applies.
    /// </summary>
    public SourceSpan Span { get; }

    /// <summary>
    /// Gets the optional hint or suggestion text to help fix the issue.
    /// </summary>
    public string? HintMessage { get; }

    /// <summary>
    /// Gets the optional diagnostic code (e.g., "E0001").
    /// </summary>
    public string? Code { get; }

    /// <summary>
    /// Creates an error diagnostic.
    /// </summary>
    /// <param name="message">The error message text.</param>
    /// <param name="span">The source location where the error occurred.</param>
    /// <param name="hint">Optional hint text to help fix the error.</param>
    /// <param name="code">Optional error code (e.g., "E0001").</param>
    /// <returns>A new <see cref="Diagnostic"/> with error severity.</returns>
    public static Diagnostic Error(string message, SourceSpan span, string? hint = null, string? code = null)
    {
        return new Diagnostic(DiagnosticSeverity.Error, message, span, hint, code);
    }

    /// <summary>
    /// Creates a warning diagnostic.
    /// </summary>
    /// <param name="message">The warning message text.</param>
    /// <param name="span">The source location where the warning applies.</param>
    /// <param name="hint">Optional hint text to address the warning.</param>
    /// <param name="code">Optional warning code.</param>
    /// <returns>A new <see cref="Diagnostic"/> with warning severity.</returns>
    public static Diagnostic Warning(string message, SourceSpan span, string? hint = null, string? code = null)
    {
        return new Diagnostic(DiagnosticSeverity.Warning, message, span, hint, code);
    }

    /// <summary>
    /// Creates an informational diagnostic.
    /// </summary>
    /// <param name="message">The informational message text.</param>
    /// <param name="span">The source location where the information applies.</param>
    /// <param name="hint">Optional additional information.</param>
    /// <returns>A new <see cref="Diagnostic"/> with info severity.</returns>
    public static Diagnostic Info(string message, SourceSpan span, string? hint = null)
    {
        return new Diagnostic(DiagnosticSeverity.Info, message, span, hint);
    }

    /// <summary>
    /// Creates a hint diagnostic.
    /// </summary>
    /// <param name="message">The hint message text.</param>
    /// <param name="span">The source location where the hint applies.</param>
    /// <param name="hint">Optional additional suggestion text.</param>
    /// <returns>A new <see cref="Diagnostic"/> with hint severity.</returns>
    public static Diagnostic Hint(string message, SourceSpan span, string? hint = null)
    {
        return new Diagnostic(DiagnosticSeverity.Hint, message, span, hint);
    }
}