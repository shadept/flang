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

        var cursorAnalysis = await _workspace.GetAnalysisAsync(filePath);
        if (cursorAnalysis == null) return null;

        var fileId = PositionUtil.FindFileId(filePath, cursorAnalysis.Compilation);
        if (fileId == null) return null;

        var normalizedPath = Path.GetFullPath(filePath);
        if (!cursorAnalysis.ParsedModules.TryGetValue(normalizedPath, out var module))
            return null;

        var source = cursorAnalysis.Compilation.Sources[fileId.Value];
        var position = PositionUtil.ToSourcePosition(request.Position, source);

        var lap = sw.ElapsedMilliseconds;
        var target = ReferenceFinder.ResolveTargetAt(module, fileId.Value, position, cursorAnalysis);
        FLangLanguageServer.Log($"  [resolveTarget] {sw.ElapsedMilliseconds - lap}ms -> {target?.GetType().Name ?? "null"}");
        if (target == null) return null;

        var includeDecl = request.Context?.IncludeDeclaration ?? false;

        // Locals are scoped to a single function body — only the originating
        // analysis has the AST instance we're comparing against by reference.
        // Functions / types / fields need the workspace-wide sweep so callers in
        // unrelated open files (e.g. fs.f calling stdlib's string_builder) are
        // found from a cursor on the defining file.
        var analyses = target is LocalDeclRefTarget
            ? [cursorAnalysis]
            : _workspace.GetAllAnalyses();

        // Dedup across analyses: each analysis parses every reachable module so
        // the same source location surfaces multiple times with different
        // SourceSpan.FileId values. Key on (path, range) instead.
        var seen = new HashSet<(string, int, int, int, int)>();
        var locations = new List<Location>();
        var totalRaw = 0;

        lap = sw.ElapsedMilliseconds;
        foreach (var analysis in analyses)
        {
            var spans = ReferenceFinder.FindReferences(target, analysis, includeDecl);
            totalRaw += spans.Count;
            foreach (var span in spans)
            {
                var loc = SpanToLocation(span, analysis.Compilation);
                if (loc == null) continue;
                var key = (
                    loc.Uri.ToString(),
                    loc.Range.Start.Line, loc.Range.Start.Character,
                    loc.Range.End.Line, loc.Range.End.Character);
                if (seen.Add(key)) locations.Add(loc);
            }
        }
        FLangLanguageServer.Log($"  [findRefs] {sw.ElapsedMilliseconds - lap}ms — {analyses.Count} analyses, {totalRaw} raw / {locations.Count} unique");

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
