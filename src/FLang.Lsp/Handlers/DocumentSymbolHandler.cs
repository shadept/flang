using FLang.Frontend.Ast.Declarations;
using Microsoft.Extensions.Logging;
using OmniSharp.Extensions.LanguageServer.Protocol.Client.Capabilities;
using OmniSharp.Extensions.LanguageServer.Protocol.Document;
using OmniSharp.Extensions.LanguageServer.Protocol.Models;
using Range = OmniSharp.Extensions.LanguageServer.Protocol.Models.Range;

namespace FLang.Lsp.Handlers;

public class DocumentSymbolHandler : DocumentSymbolHandlerBase
{
    private readonly FLangWorkspace _workspace;
    private readonly ILogger<DocumentSymbolHandler> _logger;

    public DocumentSymbolHandler(FLangWorkspace workspace, ILogger<DocumentSymbolHandler> logger)
    {
        _workspace = workspace;
        _logger = logger;
    }

    public override async Task<SymbolInformationOrDocumentSymbolContainer?> Handle(
        DocumentSymbolParams request,
        CancellationToken cancellationToken)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var filePath = request.TextDocument.Uri.GetFileSystemPath();
        FLangLanguageServer.Log($"DocumentSymbol: {filePath}");

        var analysis = await _workspace.GetAnalysisAsync(filePath);
        if (analysis == null) return null;

        var normalizedPath = Path.GetFullPath(filePath);
        if (!analysis.ParsedModules.TryGetValue(normalizedPath, out var module))
            return null;

        var symbols = new List<DocumentSymbol>();

        foreach (var fn in module.Functions)
        {
            var range = PositionUtil.ToLspRange(fn.Span, analysis.Compilation);
            if (range == null) continue;
            symbols.Add(new DocumentSymbol
            {
                Name = fn.Name,
                Kind = SymbolKind.Function,
                Range = range,
                SelectionRange = range
            });
        }

        foreach (var s in module.Structs)
        {
            var range = PositionUtil.ToLspRange(s.Span, analysis.Compilation);
            if (range == null) continue;

            var children = new List<DocumentSymbol>();
            foreach (var field in s.Fields)
            {
                var fieldRange = PositionUtil.ToLspRange(field.Span, analysis.Compilation);
                if (fieldRange == null) continue;
                children.Add(new DocumentSymbol
                {
                    Name = field.Name,
                    Kind = SymbolKind.Field,
                    Range = fieldRange,
                    SelectionRange = fieldRange
                });
            }

            symbols.Add(new DocumentSymbol
            {
                Name = s.Name,
                Kind = SymbolKind.Struct,
                Range = range,
                SelectionRange = range,
                Children = new Container<DocumentSymbol>(children)
            });
        }

        foreach (var e in module.Enums)
        {
            var range = PositionUtil.ToLspRange(e.Span, analysis.Compilation);
            if (range == null) continue;

            var children = new List<DocumentSymbol>();
            foreach (var variant in e.Variants)
            {
                var variantRange = PositionUtil.ToLspRange(variant.Span, analysis.Compilation);
                if (variantRange == null) continue;
                children.Add(new DocumentSymbol
                {
                    Name = variant.Name,
                    Kind = SymbolKind.EnumMember,
                    Range = variantRange,
                    SelectionRange = variantRange
                });
            }

            symbols.Add(new DocumentSymbol
            {
                Name = e.Name,
                Kind = SymbolKind.Enum,
                Range = range,
                SelectionRange = range,
                Children = new Container<DocumentSymbol>(children)
            });
        }

        foreach (var g in module.GlobalConstants)
        {
            var range = PositionUtil.ToLspRange(g.Span, analysis.Compilation);
            if (range == null) continue;
            symbols.Add(new DocumentSymbol
            {
                Name = g.Name,
                Kind = SymbolKind.Constant,
                Range = range,
                SelectionRange = range
            });
        }

        var result = new SymbolInformationOrDocumentSymbolContainer(
            symbols.Select(s => new SymbolInformationOrDocumentSymbol(s)));

        FLangLanguageServer.Log($"  [total] {sw.ElapsedMilliseconds}ms — {symbols.Count} symbols");
        return result;
    }

    protected override DocumentSymbolRegistrationOptions CreateRegistrationOptions(
        DocumentSymbolCapability capability,
        ClientCapabilities clientCapabilities)
    {
        return new DocumentSymbolRegistrationOptions
        {
            DocumentSelector = new TextDocumentSelector(
                new TextDocumentFilter { Language = "flang" })
        };
    }
}
