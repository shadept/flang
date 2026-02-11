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

namespace FLang.Lsp.Handlers;

public class DefinitionHandler : DefinitionHandlerBase
{
    private readonly FLangWorkspace _workspace;
    private readonly ILogger<DefinitionHandler> _logger;

    public DefinitionHandler(FLangWorkspace workspace, ILogger<DefinitionHandler> logger)
    {
        _workspace = workspace;
        _logger = logger;
    }

    public override Task<LocationOrLocationLinks?> Handle(DefinitionParams request, CancellationToken cancellationToken)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var filePath = request.TextDocument.Uri.GetFileSystemPath();
        FLangLanguageServer.Log($"Definition: {filePath} @ {request.Position.Line}:{request.Position.Character}");

        var analysis = _workspace.GetAnalysis(filePath);
        if (analysis == null) return Task.FromResult<LocationOrLocationLinks?>(null);

        var fileId = PositionUtil.FindFileId(filePath, analysis.Compilation);
        if (fileId == null) return Task.FromResult<LocationOrLocationLinks?>(null);

        var normalizedPath = Path.GetFullPath(filePath);
        if (!analysis.ParsedModules.TryGetValue(normalizedPath, out var module))
            return Task.FromResult<LocationOrLocationLinks?>(null);

        var lap = sw.ElapsedMilliseconds;
        var source = analysis.Compilation.Sources[fileId.Value];
        var position = PositionUtil.ToSourcePosition(request.Position, source);
        var node = AstNodeFinder.FindDeepestNodeAt(module, fileId.Value, position);
        FLangLanguageServer.Log($"  [findNode] {sw.ElapsedMilliseconds - lap}ms → {node?.GetType().Name ?? "null"}");
        if (node == null) return Task.FromResult<LocationOrLocationLinks?>(null);

        lap = sw.ElapsedMilliseconds;
        var targetSpan = ResolveDefinitionTarget(node, analysis);
        FLangLanguageServer.Log($"  [resolve] {sw.ElapsedMilliseconds - lap}ms → {(targetSpan.HasValue ? $"FileId={targetSpan.Value.FileId} Idx={targetSpan.Value.Index}" : "null")}");
        if (targetSpan == null || targetSpan.Value.FileId < 0)
            return Task.FromResult<LocationOrLocationLinks?>(null);

        var location = SpanToLocation(targetSpan.Value, analysis.Compilation);
        FLangLanguageServer.Log($"  [total] {sw.ElapsedMilliseconds}ms");
        if (location == null) return Task.FromResult<LocationOrLocationLinks?>(null);

        return Task.FromResult<LocationOrLocationLinks?>(new LocationOrLocationLinks(location));
    }

    private static SourceSpan? ResolveDefinitionTarget(AstNode node, FileAnalysisResult analysis)
    {
        switch (node)
        {
            case CallExpressionNode call when call.ResolvedTarget != null:
                return call.ResolvedTarget.NameSpan;

            case IdentifierExpressionNode id:
            {
                if (id.ResolvedFunctionTarget != null)
                    return id.ResolvedFunctionTarget.NameSpan;
                if (id.ResolvedVariableDeclaration != null)
                    return id.ResolvedVariableDeclaration.NameSpan;
                if (id.ResolvedParameterDeclaration != null)
                    return id.ResolvedParameterDeclaration.NameSpan;

                // Try type resolution: if identifier refers to a nominal type
                if (analysis.TypeChecker?.NominalSpans != null)
                {
                    if (analysis.TypeChecker.NominalSpans.TryGetValue(id.Name, out var span))
                        return span;
                }
                break;
            }

            case MemberAccessExpressionNode ma:
            {
                // Try to find the struct field definition in parsed AST
                if (analysis.TypeChecker != null
                    && analysis.TypeChecker.InferredTypes.TryGetValue(ma.Target, out var targetType))
                {
                    var resolved = analysis.TypeChecker.Engine.Resolve(targetType);
                    var typeName = GetNominalTypeName(resolved);
                    if (typeName != null)
                    {
                        // Search parsed modules for struct declaration with matching field
                        foreach (var module in analysis.ParsedModules.Values)
                        {
                            foreach (var structDecl in module.Structs)
                            {
                                if (structDecl.Name == typeName || typeName.EndsWith("." + structDecl.Name))
                                {
                                    foreach (var field in structDecl.Fields)
                                    {
                                        if (field.Name == ma.FieldName)
                                            return field.NameSpan;
                                    }
                                }
                            }
                        }
                    }
                }
                break;
            }
        }

        return null;
    }

    private static string? GetNominalTypeName(FLang.Core.Types.Type type)
    {
        if (type is NominalType nominal)
            return nominal.Name;
        if (type is FLang.Core.Types.ReferenceType refType)
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

    protected override DefinitionRegistrationOptions CreateRegistrationOptions(
        DefinitionCapability capability,
        ClientCapabilities clientCapabilities)
    {
        return new DefinitionRegistrationOptions
        {
            DocumentSelector = new TextDocumentSelector(
                new TextDocumentFilter { Language = "flang" })
        };
    }
}
