using MediatR;
using OmniSharp.Extensions.LanguageServer.Protocol;
using OmniSharp.Extensions.LanguageServer.Protocol.Client.Capabilities;
using OmniSharp.Extensions.LanguageServer.Protocol.Models;
using OmniSharp.Extensions.LanguageServer.Protocol.Workspace;
using FileSystemWatcher = OmniSharp.Extensions.LanguageServer.Protocol.Models.FileSystemWatcher;

namespace FLang.Lsp.Handlers;

/// <summary>
/// Keeps analyses in sync with edits made OUTSIDE the editor — agents writing
/// files directly, git operations, external tools. VS Code only reports open
/// buffer edits via didChange; for everything else it watches the filesystem
/// on our behalf (per the glob registrations below) and reports through
/// workspace/didChangeWatchedFiles. The workspace debounces the burst and
/// re-analyzes each affected root once.
/// </summary>
public class DidChangeWatchedFilesHandler : DidChangeWatchedFilesHandlerBase
{
    private readonly FLangWorkspace _workspace;

    public DidChangeWatchedFilesHandler(FLangWorkspace workspace)
    {
        _workspace = workspace;
    }

    public override Task<Unit> Handle(DidChangeWatchedFilesParams request, CancellationToken cancellationToken)
    {
        var paths = new List<string>();
        foreach (var change in request.Changes)
        {
            string? path;
            try { path = change.Uri.GetFileSystemPath(); }
            catch { continue; }
            if (path != null) paths.Add(path);
        }

        if (paths.Count > 0)
        {
            FLangLanguageServer.Log($"didChangeWatchedFiles: {paths.Count} change(s)");
            _workspace.NotifyWatchedFilesChanged(paths);
        }
        return Unit.Task;
    }

    protected override DidChangeWatchedFilesRegistrationOptions CreateRegistrationOptions(
        DidChangeWatchedFilesCapability capability, ClientCapabilities clientCapabilities)
    {
        // Kind omitted: the LSP default is Create | Change | Delete.
        return new DidChangeWatchedFilesRegistrationOptions
        {
            Watchers = new Container<FileSystemWatcher>(
                new FileSystemWatcher { GlobPattern = "**/*.f" },
                new FileSystemWatcher { GlobPattern = "**/flang.toml" })
        };
    }
}
