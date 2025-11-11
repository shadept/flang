namespace FLang.Core;

public enum DiagnosticSeverity
{
    Error,
    Warning,
    Info,
    Hint
}

public class Diagnostic
{
    public DiagnosticSeverity Severity { get; }
    public string Message { get; }
    public SourceSpan Span { get; }
    public string? Hint { get; }
    public string? Code { get; }

    public Diagnostic(
        DiagnosticSeverity severity,
        string message,
        SourceSpan span,
        string? hint = null,
        string? code = null)
    {
        Severity = severity;
        Message = message;
        Span = span;
        Hint = hint;
        Code = code;
    }

    public static Diagnostic Error(string message, SourceSpan span, string? hint = null, string? code = null)
        => new Diagnostic(DiagnosticSeverity.Error, message, span, hint, code);

    public static Diagnostic Warning(string message, SourceSpan span, string? hint = null, string? code = null)
        => new Diagnostic(DiagnosticSeverity.Warning, message, span, hint, code);

    public static Diagnostic CreateInfo(string message, SourceSpan span, string? hint = null)
        => new Diagnostic(DiagnosticSeverity.Info, message, span, hint);

    public static Diagnostic CreateHint(string message, SourceSpan span, string? hint = null)
        => new Diagnostic(DiagnosticSeverity.Hint, message, span, hint);
}
