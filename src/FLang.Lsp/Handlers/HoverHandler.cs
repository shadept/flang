using FLang.Core;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Types;
using Microsoft.Extensions.Logging;
using OmniSharp.Extensions.LanguageServer.Protocol.Client.Capabilities;
using OmniSharp.Extensions.LanguageServer.Protocol.Document;
using OmniSharp.Extensions.LanguageServer.Protocol.Models;

namespace FLang.Lsp.Handlers;

public class HoverHandler : HoverHandlerBase
{
    private readonly FLangWorkspace _workspace;
    private readonly ILogger<HoverHandler> _logger;

    public HoverHandler(FLangWorkspace workspace, ILogger<HoverHandler> logger)
    {
        _workspace = workspace;
        _logger = logger;
    }

    public override Task<Hover?> Handle(HoverParams request, CancellationToken cancellationToken)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var filePath = request.TextDocument.Uri.GetFileSystemPath();
        FLangLanguageServer.Log($"Hover: {filePath} @ {request.Position.Line}:{request.Position.Character}");

        var analysis = _workspace.GetAnalysis(filePath);
        if (analysis == null)
        {
            FLangLanguageServer.Log("  No analysis result");
            return Task.FromResult<Hover?>(null);
        }

        var fileId = PositionUtil.FindFileId(filePath, analysis.Compilation);
        if (fileId == null)
        {
            FLangLanguageServer.Log($"  FileId not found for {filePath}");
            return Task.FromResult<Hover?>(null);
        }

        var normalizedPath = Path.GetFullPath(filePath);
        if (!analysis.ParsedModules.TryGetValue(normalizedPath, out var module))
        {
            FLangLanguageServer.Log($"  Module not found for {normalizedPath}");
            return Task.FromResult<Hover?>(null);
        }

        var lap = sw.ElapsedMilliseconds;
        var source = analysis.Compilation.Sources[fileId.Value];
        var position = PositionUtil.ToSourcePosition(request.Position, source);
        var node = AstNodeFinder.FindDeepestNodeAt(module, fileId.Value, position);
        FLangLanguageServer.Log($"  [findNode] {sw.ElapsedMilliseconds - lap}ms → {node?.GetType().Name ?? "null"}");

        if (node == null)
            return Task.FromResult<Hover?>(null);

        lap = sw.ElapsedMilliseconds;
        var hoverText = GetHoverText(node, analysis);
        FLangLanguageServer.Log($"  [getHoverText] {sw.ElapsedMilliseconds - lap}ms → {(hoverText != null ? $"\"{hoverText}\"" : "null")}");

        if (hoverText == null)
            return Task.FromResult<Hover?>(null);

        var range = PositionUtil.ToLspRange(GetNameSpan(node), analysis.Compilation);
        FLangLanguageServer.Log($"  [total] {sw.ElapsedMilliseconds}ms");

        return Task.FromResult<Hover?>(new Hover
        {
            Contents = new MarkedStringsOrMarkupContent(new MarkupContent
            {
                Kind = MarkupKind.Markdown,
                Value = $"```flang\n{hoverText}\n```"
            }),
            Range = range
        });
    }

    private static string? GetHoverText(AstNode node, FileAnalysisResult analysis)
    {
        if (analysis.TypeChecker == null) return null;

        switch (node)
        {
            case IdentifierExpressionNode id:
                {
                    // Show function signature if it resolves to a function
                    if (id.ResolvedFunctionTarget is { } fn)
                        return FormatFunctionSignature(fn);

                    // Show variable type
                    if (analysis.TypeChecker.InferredTypes.TryGetValue(id, out var type))
                    {
                        var resolved = analysis.TypeChecker.Engine.Resolve(type);
                        if (id.ResolvedVariableDeclaration != null)
                            return $"{(id.ResolvedVariableDeclaration.IsConst ? "const" : "let")} {id.Name}: {resolved}";
                        if (id.ResolvedParameterDeclaration != null)
                            return $"{id.Name}: {resolved}";
                        return $"{id.Name}: {resolved}";
                    }
                    break;
                }

            case CallExpressionNode call:
                {
                    if (call.ResolvedTarget is { } fn)
                        return FormatFunctionSignature(fn);
                    if (analysis.TypeChecker.InferredTypes.TryGetValue(call, out var type))
                        return analysis.TypeChecker.Engine.Resolve(type).ToString();
                    break;
                }

            case VariableDeclarationNode varDecl:
                {
                    if (analysis.TypeChecker.InferredTypes.TryGetValue(varDecl, out var type))
                    {
                        var resolved = analysis.TypeChecker.Engine.Resolve(type);
                        return $"{(varDecl.IsConst ? "const" : "let")} {varDecl.Name}: {resolved}";
                    }
                    break;
                }

            case FunctionDeclarationNode fn:
                return FormatFunctionSignature(fn);

            case FunctionParameterNode param:
                {
                    if (analysis.TypeChecker.InferredTypes.TryGetValue(param, out var type))
                        return $"{param.Name}: {analysis.TypeChecker.Engine.Resolve(type)}";
                    break;
                }

            case MemberAccessExpressionNode ma:
                {
                    if (analysis.TypeChecker.InferredTypes.TryGetValue(ma, out var type))
                        return $".{ma.FieldName}: {analysis.TypeChecker.Engine.Resolve(type)}";
                    break;
                }

            default:
                {
                    // Generic expression type display
                    if (node is ExpressionNode && analysis.TypeChecker.InferredTypes.TryGetValue(node, out var type))
                        return analysis.TypeChecker.Engine.Resolve(type).ToString();
                    break;
                }
        }

        return null;
    }

    private static string FormatFunctionSignature(FunctionDeclarationNode fn)
    {
        var pars = string.Join(", ", fn.Parameters.Select(p =>
        {
            var typeStr = p.ResolvedType?.ToString() ?? FormatTypeNode(p.Type);
            return $"{p.Name}: {typeStr}";
        }));
        var ret = fn.ResolvedReturnType?.ToString() ?? (fn.ReturnType != null ? FormatTypeNode(fn.ReturnType) : "void");
        return $"fn {fn.Name}({pars}) {ret}";
    }

    private static string FormatTypeNode(TypeNode type) => type switch
    {
        NamedTypeNode named => named.Name,
        ReferenceTypeNode refType => $"&{FormatTypeNode(refType.InnerType)}",
        NullableTypeNode nullable => $"{FormatTypeNode(nullable.InnerType)}?",
        GenericTypeNode generic => $"{generic.Name}({string.Join(", ", generic.TypeArguments.Select(FormatTypeNode))})",
        ArrayTypeNode array => $"[{FormatTypeNode(array.ElementType)}; {array.Length}]",
        SliceTypeNode slice => $"{FormatTypeNode(slice.ElementType)}[]",
        GenericParameterTypeNode gp => $"${gp.Name}",
        FunctionTypeNode func => $"fn({string.Join(", ", func.ParameterTypes.Select(FormatTypeNode))}) {FormatTypeNode(func.ReturnType)}",
        AnonymousStructTypeNode anon => $".{{ {string.Join(", ", anon.Fields.Select(f => $"{f.FieldName}: {FormatTypeNode(f.FieldType)}"))} }}",
        _ => type.GetType().Name
    };

    internal static SourceSpan GetNameSpan(AstNode node) => node switch
    {
        FunctionDeclarationNode fn => fn.NameSpan,
        VariableDeclarationNode vd => vd.NameSpan,
        FunctionParameterNode fp => fp.NameSpan,
        StructDeclarationNode sd => sd.NameSpan,
        EnumDeclarationNode ed => ed.NameSpan,
        StructFieldNode sf => sf.NameSpan,
        EnumVariantNode ev => ev.NameSpan,
        _ => node.Span
    };

    protected override HoverRegistrationOptions CreateRegistrationOptions(
        HoverCapability capability,
        ClientCapabilities clientCapabilities)
    {
        return new HoverRegistrationOptions
        {
            DocumentSelector = new TextDocumentSelector(
                new TextDocumentFilter { Language = "flang" })
        };
    }
}
