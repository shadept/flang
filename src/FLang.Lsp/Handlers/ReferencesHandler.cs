using FLang.Core;
using Microsoft.Extensions.Logging;
using OmniSharp.Extensions.LanguageServer.Protocol;
using OmniSharp.Extensions.LanguageServer.Protocol.Client.Capabilities;
using OmniSharp.Extensions.LanguageServer.Protocol.Document;
using OmniSharp.Extensions.LanguageServer.Protocol.Models;

namespace FLang.Lsp.Handlers;

public class ReferencesHandler : ReferencesHandlerBase
{
    private readonly FLangWorkspace _workspace;
    private readonly ILogger<ReferencesHandler> _logger;

    public ReferencesHandler(FLangWorkspace workspace, ILogger<ReferencesHandler> logger)
    {
        _workspace = workspace;
        _logger = logger;
    }

    public override async Task<LocationContainer?> Handle(ReferenceParams request, CancellationToken cancellationToken)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var filePath = request.TextDocument.Uri.GetFileSystemPath();
        FLangLanguageServer.Log($"References: {filePath} @ {request.Position.Line}:{request.Position.Character}");

        var analysis = await _workspace.GetAnalysisAsync(filePath);
        if (analysis == null) return null;

        var fileId = PositionUtil.FindFileId(filePath, analysis.Compilation);
        if (fileId == null) return null;

        var normalizedPath = Path.GetFullPath(filePath);
        if (!analysis.ParsedModules.TryGetValue(normalizedPath, out var module))
            return null;

        var source = analysis.Compilation.Sources[fileId.Value];
        var position = PositionUtil.ToSourcePosition(request.Position, source);

        var lap = sw.ElapsedMilliseconds;
        var target = ReferenceFinder.ResolveTargetAt(module, fileId.Value, position, analysis);
        FLangLanguageServer.Log($"  [resolveTarget] {sw.ElapsedMilliseconds - lap}ms -> {target?.GetType().Name ?? "null"}");
        if (target == null) return null;

        var includeDecl = request.Context?.IncludeDeclaration ?? false;
        lap = sw.ElapsedMilliseconds;
        var spans = ReferenceFinder.FindReferences(target, analysis, includeDecl);
        FLangLanguageServer.Log($"  [findRefs] {sw.ElapsedMilliseconds - lap}ms -> {spans.Count} hits");

        var locations = new List<Location>(spans.Count);
        foreach (var span in spans)
        {
            var loc = SpanToLocation(span, analysis.Compilation);
            if (loc != null) locations.Add(loc);
        }

        FLangLanguageServer.Log($"  [total] {sw.ElapsedMilliseconds}ms");
        return new LocationContainer(locations);
    }

    private static Location? SpanToLocation(SourceSpan span, Compilation compilation)
    {
        if (span.FileId < 0 || span.FileId >= compilation.Sources.Count)
            return null;

        var source = compilation.Sources[span.FileId];
        var range = PositionUtil.ToLspRange(span, compilation);
        if (range == null) return null;

        return new Location
        {
            Uri = DocumentUri.FromFileSystemPath(source.FileName),
            Range = range,
        };
    }

    protected override ReferenceRegistrationOptions CreateRegistrationOptions(
        ReferenceCapability capability,
        ClientCapabilities clientCapabilities)
    {
        return new ReferenceRegistrationOptions
        {
            DocumentSelector = new TextDocumentSelector(
                new TextDocumentFilter { Language = "flang" }),
        };
    }
}
