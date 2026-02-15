namespace FLang.Core;

/// <summary>
/// Exception thrown for internal compiler errors (ICEs) that should never occur
/// if the type checker and lowering are correct. Carries the source location
/// where the error was detected so it can be reported to the user.
/// </summary>
public class InternalCompilerError : Exception
{
    public SourceSpan Span { get; }

    public InternalCompilerError(string message, SourceSpan span)
        : base(message)
    {
        Span = span;
    }
}
