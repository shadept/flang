using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Types;
using FLang.Semantics;
using Microsoft.Extensions.Logging;
using OmniSharp.Extensions.LanguageServer.Protocol.Client.Capabilities;
using OmniSharp.Extensions.LanguageServer.Protocol.Document;
using OmniSharp.Extensions.LanguageServer.Protocol.Models;
using ArrayType = FLang.Core.Types.ArrayType;
using FunctionType = FLang.Core.Types.FunctionType;
using PrimitiveType = FLang.Core.Types.PrimitiveType;
using ReferenceType = FLang.Core.Types.ReferenceType;
using Type = FLang.Core.Types.Type;
using TypeVar = FLang.Core.Types.TypeVar;

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
        FLangLanguageServer.Log($"  [findNode] {sw.ElapsedMilliseconds - lap}ms -> {node?.GetType().Name ?? "null"}");

        if (node == null)
            return Task.FromResult<Hover?>(null);

        lap = sw.ElapsedMilliseconds;
        var hoverText = GetHoverText(node, analysis, position);
        FLangLanguageServer.Log($"  [getHoverText] {sw.ElapsedMilliseconds - lap}ms -> {(hoverText != null ? $"\"{hoverText}\"" : "null")}");

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

    private static string? GetHoverText(AstNode node, FileAnalysisResult analysis, int position)
    {
        // Import hover: show resolved file path (only when cursor is on the module path)
        if (node is ImportDeclarationNode import
            && position >= import.ModuleSpan.Index
            && position < import.ModuleSpan.Index + import.ModuleSpan.Length)
        {
            var modulePath = string.Join(".", import.Path);
            var relativePath = string.Join(Path.DirectorySeparatorChar, import.Path) + ".f";
            foreach (var includePath in analysis.Compilation.IncludePaths)
            {
                var fullPath = Path.GetFullPath(Path.Combine(includePath, relativePath));
                if (File.Exists(fullPath))
                    return $"import {modulePath}\n// {fullPath}";
            }
            return $"import {modulePath}";
        }

        if (analysis.TypeChecker == null) return null;
        var tc = analysis.TypeChecker;

        switch (node)
        {
            case IdentifierExpressionNode id:
                {
                    // Show function signature if it resolves to a function
                    if (id.ResolvedFunctionTarget is { } fn)
                        return FormatFunctionSignature(fn, tc);

                    // Show variable type
                    if (tc.InferredTypes.TryGetValue(id, out var type))
                    {
                        var display = FormatHmType(tc.Engine.Resolve(type), tc);
                        if (id.ResolvedVariableDeclaration != null)
                            return $"{(id.ResolvedVariableDeclaration.IsConst ? "const" : "let")} {id.Name}: {display}";
                        if (id.ResolvedParameterDeclaration != null)
                            return $"{id.Name}: {display}";
                        return $"{id.Name}: {display}";
                    }
                    break;
                }

            case CallExpressionNode call:
                {
                    if (call.ResolvedTarget is { } fn)
                        return FormatFunctionSignature(fn, tc);
                    if (tc.InferredTypes.TryGetValue(call, out var type))
                        return FormatHmType(tc.Engine.Resolve(type), tc);
                    break;
                }

            case VariableDeclarationNode varDecl:
                {
                    if (tc.InferredTypes.TryGetValue(varDecl, out var type))
                    {
                        var display = FormatHmType(tc.Engine.Resolve(type), tc);
                        return $"{(varDecl.IsConst ? "const" : "let")} {varDecl.Name}: {display}";
                    }
                    break;
                }

            case FunctionDeclarationNode fn:
                return FormatFunctionSignature(fn, tc);

            case FunctionParameterNode param:
                {
                    if (tc.InferredTypes.TryGetValue(param, out var type))
                        return $"{param.Name}: {FormatHmType(tc.Engine.Resolve(type), tc)}";
                    break;
                }

            case MemberAccessExpressionNode ma:
                {
                    if (tc.InferredTypes.TryGetValue(ma, out var type))
                        return $".{ma.FieldName}: {FormatHmType(tc.Engine.Resolve(type), tc)}";
                    break;
                }

            case VariablePatternNode varPat:
                {
                    if (tc.InferredTypes.TryGetValue(varPat, out var type))
                        return $"{varPat.Name}: {FormatHmType(tc.Engine.Resolve(type), tc)}";
                    break;
                }

            case EnumVariantPatternNode variantPat:
                {
                    if (tc.InferredTypes.TryGetValue(variantPat, out var type))
                        return $".{variantPat.VariantName}: {FormatHmType(tc.Engine.Resolve(type), tc)}";
                    break;
                }

            default:
                {
                    // Type annotations: resolve semantically when possible
                    if (node is NamedTypeNode named)
                    {
                        // If the name isn't a primitive or nominal type, it's a generic parameter
                        if (!IsPrimitiveTypeName(named.Name)
                            && !tc.NominalTypes.Values.Any(n => n.ShortName == named.Name))
                            return $"${named.Name}";
                    }
                    if (node is TypeNode typeNode)
                        return FormatTypeNode(typeNode);

                    // Generic expression type display
                    if (node is ExpressionNode && tc.InferredTypes.TryGetValue(node, out var type))
                        return FormatHmType(tc.Engine.Resolve(type), tc);
                    break;
                }
        }

        return null;
    }

    private static string FormatFunctionSignature(FunctionDeclarationNode fn, HmTypeChecker tc)
    {
        var pars = string.Join(", ", fn.Parameters.Select(p =>
        {
            if (tc.InferredTypes.TryGetValue(p, out var inferredType))
                return $"{p.Name}: {FormatHmType(tc.Engine.Resolve(inferredType), tc)}";
            return $"{p.Name}: {FormatTypeNode(p.Type)}";
        }));

        string ret = "void";
        if (tc.InferredTypes.TryGetValue(fn, out var fnInferred))
        {
            var resolved = tc.Engine.Resolve(fnInferred);
            if (resolved is FunctionType fnType)
                ret = FormatHmType(fnType.ReturnType, tc);
            else
                ret = FormatHmType(resolved, tc);
        }
        else if (fn.ReturnType != null)
        {
            ret = FormatTypeNode(fn.ReturnType);
        }

        return $"fn {fn.Name}({pars}) {ret}";
    }

    private static bool IsPrimitiveTypeName(string name) => name is
        "i8" or "i16" or "i32" or "i64" or "isize" or
        "u8" or "u16" or "u32" or "u64" or "usize" or
        "f32" or "f64" or "bool" or "char" or "void" or "never";

    /// <summary>
    /// Format an HM type for display. Placeholder NominalTypes from generic body checking
    /// display as "$T", "$U" etc. naturally via ShortName.
    /// </summary>
    private static string FormatHmType(Type type, HmTypeChecker tc)
    {
        var resolved = tc.Engine.Resolve(type);
        return resolved switch
        {
            TypeVar tv => $"?{tv.Id}",
            PrimitiveType p => p.Name,
            ReferenceType r => $"&{FormatHmType(r.InnerType, tc)}",
            ArrayType a => $"[{FormatHmType(a.ElementType, tc)}; {a.Length}]",
            FunctionType f => $"fn({string.Join(", ", f.ParameterTypes.Select(p => FormatHmType(p, tc)))}) {FormatHmType(f.ReturnType, tc)}",
            NominalType n when n.TypeArguments.Count == 0 => n.ShortName,
            NominalType n => $"{n.ShortName}({string.Join(", ", n.TypeArguments.Select(ta => FormatHmType(ta, tc)))})",
            _ => resolved.ToString()
        };
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
        ImportDeclarationNode imp => imp.ModuleSpan,
        _ => node.Span
    };

    protected override HoverRegistrationOptions CreateRegistrationOptions(
        HoverCapability capability,
        ClientCapabilities clientCapabilities)
    {
        return new HoverRegistrationOptions
        {
            DocumentSelector = TextDocumentSelector.ForLanguage("flang")
        };
    }
}
