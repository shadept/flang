using FLang.Core;
using FLang.Frontend.Ast.Declarations;
using Microsoft.Extensions.Logging;
using OmniSharp.Extensions.LanguageServer.Protocol;
using OmniSharp.Extensions.LanguageServer.Protocol.Client.Capabilities;
using OmniSharp.Extensions.LanguageServer.Protocol.Models;
using OmniSharp.Extensions.LanguageServer.Protocol.Workspace;

namespace FLang.Lsp.Handlers;

/// <summary>
/// Handles <c>workspace/symbol</c> — the Ctrl-T / <c>#</c> "symbol search"
/// surface. Enumerates every top-level decl across every open file's analysis
/// (functions, structs &amp; fields, enums &amp; variants, global constants) and
/// filters by a substring match. Dedup'd by (file-path, name, span) since the
/// same source file appears in multiple analyses' transitive module graphs.
/// </summary>
public class WorkspaceSymbolsHandler : WorkspaceSymbolsHandlerBase
{
    private readonly FLangWorkspace _workspace;
    private readonly ILogger<WorkspaceSymbolsHandler> _logger;

    public WorkspaceSymbolsHandler(FLangWorkspace workspace, ILogger<WorkspaceSymbolsHandler> logger)
    {
        _workspace = workspace;
        _logger = logger;
    }

    public override Task<Container<WorkspaceSymbol>?> Handle(WorkspaceSymbolParams request, CancellationToken cancellationToken)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var query = request.Query ?? "";
        FLangLanguageServer.Log($"WorkspaceSymbol: query=\"{query}\"");

        var analyses = _workspace.GetAllAnalyses();

        // Dedup by (file-path, symbol-name, start-offset) — the same module is
        // re-parsed in every analysis that imports it, so without dedup a single
        // logical symbol shows up N times.
        var seen = new HashSet<(string, string, int)>();
        var symbols = new List<WorkspaceSymbol>();

        foreach (var analysis in analyses)
        {
            foreach (var (path, module) in analysis.ParsedModules)
            {
                var fullPath = Path.GetFullPath(path);
                foreach (var sym in EnumerateSymbols(module, fullPath, analysis.Compilation))
                {
                    if (!MatchesQuery(sym.Name, query)) continue;
                    var loc = sym.Location.Location!;
                    var key = (fullPath, sym.Name, loc.Range.Start.Line * 10000 + loc.Range.Start.Character);
                    if (seen.Add(key)) symbols.Add(sym);
                }
            }
        }

        FLangLanguageServer.Log($"  [total] {sw.ElapsedMilliseconds}ms — {analyses.Count} analyses, {symbols.Count} symbols");
        return Task.FromResult<Container<WorkspaceSymbol>?>(new Container<WorkspaceSymbol>(symbols));
    }

    private static IEnumerable<WorkspaceSymbol> EnumerateSymbols(
        ModuleNode module, string fullPath, Compilation compilation)
    {
        var uri = DocumentUri.FromFileSystemPath(fullPath);

        foreach (var fn in module.Functions)
        {
            var s = MakeSymbol(fn.Name, SymbolKind.Function, uri, fn.NameSpan, compilation);
            if (s != null) yield return s;
        }

        foreach (var s in module.Structs)
        {
            var sym = MakeSymbol(s.Name, SymbolKind.Struct, uri, s.NameSpan, compilation);
            if (sym != null) yield return sym;

            foreach (var field in s.Fields)
            {
                var fsym = MakeSymbol(field.Name, SymbolKind.Field, uri, field.NameSpan, compilation, container: s.Name);
                if (fsym != null) yield return fsym;
            }
        }

        foreach (var e in module.Enums)
        {
            var sym = MakeSymbol(e.Name, SymbolKind.Enum, uri, e.NameSpan, compilation);
            if (sym != null) yield return sym;

            foreach (var variant in e.Variants)
            {
                var vsym = MakeSymbol(variant.Name, SymbolKind.EnumMember, uri, variant.Span, compilation, container: e.Name);
                if (vsym != null) yield return vsym;
            }
        }

        foreach (var g in module.GlobalConstants)
        {
            var sym = MakeSymbol(g.Name, SymbolKind.Constant, uri, g.NameSpan, compilation);
            if (sym != null) yield return sym;
        }
    }

    private static WorkspaceSymbol? MakeSymbol(
        string name, SymbolKind kind, DocumentUri uri, SourceSpan span, Compilation compilation, string? container = null)
    {
        var range = PositionUtil.ToLspRange(span, compilation);
        if (range == null) return null;
        return new WorkspaceSymbol
        {
            Name = name,
            Kind = kind,
            Location = new Location { Uri = uri, Range = range },
            ContainerName = container,
        };
    }

    /// <summary>
    /// Case-insensitive subsequence match: every character of <paramref name="query"/>
    /// must appear in <paramref name="name"/> in order. Empty query matches all.
    /// Clients (VS Code, Helix) re-rank on their end so we err loose; this just
    /// gates obvious non-matches without burning cycles on the wire.
    /// </summary>
    public static bool MatchesQuery(string name, string query)
    {
        if (string.IsNullOrEmpty(query)) return true;
        var ni = 0;
        var qi = 0;
        while (ni < name.Length && qi < query.Length)
        {
            if (char.ToLowerInvariant(name[ni]) == char.ToLowerInvariant(query[qi])) qi++;
            ni++;
        }
        return qi == query.Length;
    }

    protected override WorkspaceSymbolRegistrationOptions CreateRegistrationOptions(
        WorkspaceSymbolCapability capability,
        ClientCapabilities clientCapabilities)
    {
        return new WorkspaceSymbolRegistrationOptions();
    }
}
