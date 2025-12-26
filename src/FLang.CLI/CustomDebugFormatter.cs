using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Logging.Console;

namespace FLang.CLI;

public sealed class CustomDebugFormatter : ConsoleFormatter
{
    public CustomDebugFormatter() : base("custom-debug") { }

    public override void Write<TState>(
        in LogEntry<TState> logEntry,
        IExternalScopeProvider? scopeProvider,
        TextWriter textWriter)
    {
        var message = logEntry.Formatter?.Invoke(logEntry.State, logEntry.Exception);
        if (message is null) return;

        // Match old Logger.Debug format: "[DEBUG] {message}"
        textWriter.WriteLine($"[DEBUG] {message}");
    }
}
