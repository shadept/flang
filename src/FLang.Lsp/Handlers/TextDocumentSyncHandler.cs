using MediatR;
using Microsoft.Extensions.Logging;
using OmniSharp.Extensions.LanguageServer.Protocol;
using OmniSharp.Extensions.LanguageServer.Protocol.Client.Capabilities;
using OmniSharp.Extensions.LanguageServer.Protocol.Document;
using OmniSharp.Extensions.LanguageServer.Protocol.Models;
using OmniSharp.Extensions.LanguageServer.Protocol.Server;
using OmniSharp.Extensions.LanguageServer.Protocol.Server.Capabilities;

namespace FLang.Lsp.Handlers;

public class TextDocumentSyncHandler : TextDocumentSyncHandlerBase
{
    private readonly FLangWorkspace _workspace;
    private readonly ILogger<TextDocumentSyncHandler> _logger;

    public TextDocumentSyncHandler(FLangWorkspace workspace, ILogger<TextDocumentSyncHandler> logger)
    {
        _logger = logger;
        _workspace = workspace;
    }

    public override TextDocumentAttributes GetTextDocumentAttributes(DocumentUri uri)
    {
        return new TextDocumentAttributes(uri, "flang");
    }

    public override Task<Unit> Handle(DidOpenTextDocumentParams request, CancellationToken cancellationToken)
    {
        var filePath = request.TextDocument.Uri.GetFileSystemPath();
        if (IsGeneratedFile(filePath)) return Unit.Task;
        FLangLanguageServer.Log($"didOpen: {filePath} ({request.TextDocument.Text.Length} chars)");

        _workspace.UpdateDocument(filePath, request.TextDocument.Text);
        var task = Task.Run(() => _workspace.AnalyzeFile(filePath), cancellationToken);
        _workspace.SetPendingAnalysis(filePath, task);

        return Unit.Task;
    }

    public override Task<Unit> Handle(DidChangeTextDocumentParams request, CancellationToken cancellationToken)
    {
        var filePath = request.TextDocument.Uri.GetFileSystemPath();
        if (IsGeneratedFile(filePath)) return Unit.Task;
        FLangLanguageServer.Log($"didChange: {filePath} ({request.ContentChanges.Count()} changes)");

        foreach (var change in request.ContentChanges)
        {
            _workspace.UpdateDocument(filePath, change.Text);
        }

        var task = Task.Run(() => _workspace.AnalyzeFile(filePath), cancellationToken);
        _workspace.SetPendingAnalysis(filePath, task);

        return Unit.Task;
    }

    public override Task<Unit> Handle(DidCloseTextDocumentParams request, CancellationToken cancellationToken)
    {
        var filePath = request.TextDocument.Uri.GetFileSystemPath();
        if (IsGeneratedFile(filePath)) return Unit.Task;
        FLangLanguageServer.Log($"didClose: {filePath}");

        _workspace.CloseDocument(filePath);

        return Unit.Task;
    }

    public override Task<Unit> Handle(DidSaveTextDocumentParams request, CancellationToken cancellationToken)
    {
        var filePath = request.TextDocument.Uri.GetFileSystemPath();
        if (IsGeneratedFile(filePath)) return Unit.Task;
        FLangLanguageServer.Log($"didSave: {filePath}");

        var task = Task.Run(() => _workspace.AnalyzeFile(filePath), cancellationToken);
        _workspace.SetPendingAnalysis(filePath, task);

        return Unit.Task;
    }

    private static bool IsGeneratedFile(string filePath) =>
        filePath.EndsWith(".generated.f", StringComparison.OrdinalIgnoreCase);

    protected override TextDocumentSyncRegistrationOptions CreateRegistrationOptions(
        TextSynchronizationCapability capability,
        ClientCapabilities clientCapabilities)
    {
        return new TextDocumentSyncRegistrationOptions
        {
            DocumentSelector = new TextDocumentSelector(
                new TextDocumentFilter { Language = "flang" }),
            Change = TextDocumentSyncKind.Full,
            Save = new SaveOptions { IncludeText = false }
        };
    }
}
