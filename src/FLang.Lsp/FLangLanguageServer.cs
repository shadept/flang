using FLang.Lsp.Handlers;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using OmniSharp.Extensions.LanguageServer.Server;

namespace FLang.Lsp;

public static class FLangLanguageServer
{
    public static async Task RunAsync(string? stdlibPath = null)
    {
        // LSP uses stdout for protocol messages, so log to stderr
        Log("FLang LSP server starting...");
        Log($"stdlib path: {stdlibPath ?? "(auto)"}");

        var server = await LanguageServer.From(options =>
        {
            options
                .WithInput(Console.OpenStandardInput())
                .WithOutput(Console.OpenStandardOutput())
                .ConfigureLogging(builder =>
                {
                    builder.SetMinimumLevel(LogLevel.Debug);
                    builder.AddProvider(new StderrLoggerProvider());
                })
                .WithServices(services =>
                {
                    services.AddSingleton(new LspConfig { StdlibPath = stdlibPath });
                    services.AddSingleton<FLangWorkspace>();
                })
                .WithHandler<TextDocumentSyncHandler>()
                .WithHandler<HoverHandler>()
                .WithHandler<DefinitionHandler>()
                .WithHandler<TypeDefinitionHandler>()
                .WithHandler<ReferencesHandler>()
                .WithHandler<WorkspaceSymbolsHandler>()
                .WithHandler<DocumentSymbolHandler>()
                .WithHandler<InlayHintHandler>()
                .WithHandler<SignatureHelpHandler>()
                .OnInitialize((server, request, ct) =>
                {
                    Log($"Initialize: rootPath={request.RootPath}, rootUri={request.RootUri}");
                    var workspace = server.Services.GetService<FLangWorkspace>();
                    if (workspace != null)
                    {
                        if (request.RootPath is not null)
                            workspace.WorkingDirectory = request.RootPath;
                        else if (request.RootUri is not null)
                            workspace.WorkingDirectory = request.RootUri.GetFileSystemPath();

                        // Fire-and-forget eager indexing so workspace/symbol and
                        // find-references see the full project + stdlib without
                        // requiring the user to open each file first. Done off
                        // the initialize callback so we don't stall the handshake.
                        // We deliberately don't forward `ct` — that token is
                        // scoped to the initialize *request*, and we want the
                        // indexer to keep running after that request returns.
                        _ = Task.Run(() =>
                        {
                            try { workspace.IndexWorkspace(); }
                            catch (Exception ex) { Log($"IndexWorkspace crashed: {ex}"); }
                        }, CancellationToken.None);
                    }
                    return Task.CompletedTask;
                });
        }).ConfigureAwait(false);

        Log("Server initialized, waiting for requests...");
        await server.WaitForExit.ConfigureAwait(false);
        Log("Server exiting.");
    }

    internal static void Log(string message)
    {
        Console.Error.WriteLine($"[flang-lsp] {message}");
    }
}

public class LspConfig
{
    public string? StdlibPath { get; set; }
}

/// <summary>
/// Logging provider that writes to stderr so it doesn't interfere with LSP stdio transport.
/// </summary>
internal class StderrLoggerProvider : ILoggerProvider
{
    public ILogger CreateLogger(string categoryName) => new StderrLogger(categoryName);
    public void Dispose() { }
}

internal class StderrLogger(string category) : ILogger
{
    private static readonly IDisposable NoopScope = new NoopDisposable();
    public IDisposable BeginScope<TState>(TState state) where TState : notnull => NoopScope;
    private class NoopDisposable : IDisposable { public void Dispose() { } }
    public bool IsEnabled(LogLevel logLevel) => logLevel >= LogLevel.Debug;
    public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
    {
        // Filter out noisy OmniSharp internals
        if (category.StartsWith("OmniSharp") && logLevel < LogLevel.Warning)
            return;

        var msg = formatter(state, exception);
        Console.Error.WriteLine($"[flang-lsp:{logLevel}] {msg}");
        if (exception != null)
            Console.Error.WriteLine($"  {exception}");
    }
}
