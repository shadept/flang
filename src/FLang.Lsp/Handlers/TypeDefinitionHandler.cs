using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using Microsoft.Extensions.Logging;
using OmniSharp.Extensions.LanguageServer.Protocol;
using OmniSharp.Extensions.LanguageServer.Protocol.Client.Capabilities;
using OmniSharp.Extensions.LanguageServer.Protocol.Document;
using OmniSharp.Extensions.LanguageServer.Protocol.Models;
using ReferenceType = FLang.Core.Types.ReferenceType;
using Type = FLang.Core.Types.Type;

namespace FLang.Lsp.Handlers;

public class TypeDefinitionHandler : TypeDefinitionHandlerBase
{
    private readonly FLangWorkspace _workspace;
    private readonly ILogger<TypeDefinitionHandler> _logger;

    public TypeDefinitionHandler(FLangWorkspace workspace, ILogger<TypeDefinitionHandler> logger)
    {
        _workspace = workspace;
        _logger = logger;
    }

    public override async Task<LocationOrLocationLinks?> Handle(TypeDefinitionParams request, CancellationToken cancellationToken)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var filePath = request.TextDocument.Uri.GetFileSystemPath();
        FLangLanguageServer.Log($"TypeDefinition: {filePath} @ {request.Position.Line}:{request.Position.Character}");

        var analysis = await _workspace.GetAnalysisAsync(filePath);
        if (analysis == null) return null;

        var fileId = PositionUtil.FindFileId(filePath, analysis.Compilation);
        if (fileId == null) return null;

        var normalizedPath = Path.GetFullPath(filePath);
        if (!analysis.ParsedModules.TryGetValue(normalizedPath, out var module))
            return null;

        var source = analysis.Compilation.Sources[fileId.Value];
        var position = PositionUtil.ToSourcePosition(request.Position, source);
        var node = AstNodeFinder.FindDeepestNodeAt(module, fileId.Value, position);
        if (node == null) return null;

        var tc = analysis.TypeChecker;
        if (tc == null) return null;

        // Get the inferred type for the node
        if (!tc.InferredTypes.TryGetValue(node, out var type))
            return null;

        var resolved = tc.Engine.Resolve(type);
        var typeName = GetNominalTypeName(resolved);
        if (typeName == null) return null;

        if (!tc.NominalSpans.TryGetValue(typeName, out var targetSpan))
            return null;

        if (targetSpan.FileId < 0)
            return null;

        var location = SpanToLocation(targetSpan, analysis.Compilation);
        FLangLanguageServer.Log($"  [total] {sw.ElapsedMilliseconds}ms -> {typeName}");
        if (location == null) return null;

        return new LocationOrLocationLinks(location);
    }

    private static string? GetNominalTypeName(Type type)
    {
        if (type is NominalType nominal)
            return nominal.Name;
        if (type is ReferenceType refType)
            return GetNominalTypeName(refType.InnerType);
        return null;
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
            Range = range
        };
    }

    protected override TypeDefinitionRegistrationOptions CreateRegistrationOptions(
        TypeDefinitionCapability capability,
        ClientCapabilities clientCapabilities)
    {
        return new TypeDefinitionRegistrationOptions
        {
            DocumentSelector = new TextDocumentSelector(
                new TextDocumentFilter { Language = "flang" })
        };
    }
}
