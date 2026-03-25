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

    public override async Task<Hover?> Handle(HoverParams request, CancellationToken cancellationToken)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var filePath = request.TextDocument.Uri.GetFileSystemPath();
        FLangLanguageServer.Log($"Hover: {filePath} @ {request.Position.Line}:{request.Position.Character}");

        var analysis = await _workspace.GetAnalysisAsync(filePath);
        if (analysis == null)
        {
            FLangLanguageServer.Log("  No analysis result");
            return null;
        }

        var fileId = PositionUtil.FindFileId(filePath, analysis.Compilation);
        if (fileId == null)
        {
            FLangLanguageServer.Log($"  FileId not found for {filePath}");
            return null;
        }

        var normalizedPath = Path.GetFullPath(filePath);
        if (!analysis.ParsedModules.TryGetValue(normalizedPath, out var module))
        {
            FLangLanguageServer.Log($"  Module not found for {normalizedPath}");
            return null;
        }

        var lap = sw.ElapsedMilliseconds;
        var source = analysis.Compilation.Sources[fileId.Value];
        var position = PositionUtil.ToSourcePosition(request.Position, source);
        var node = AstNodeFinder.FindDeepestNodeAt(module, fileId.Value, position);
        FLangLanguageServer.Log($"  [findNode] {sw.ElapsedMilliseconds - lap}ms -> {node?.GetType().Name ?? "null"}");

        if (node == null)
            return null;

        lap = sw.ElapsedMilliseconds;
        var hoverText = GetHoverText(node, analysis, position);
        FLangLanguageServer.Log($"  [getHoverText] {sw.ElapsedMilliseconds - lap}ms -> {(hoverText != null ? $"\"{hoverText}\"" : "null")}");

        if (hoverText == null)
            return null;

        var range = PositionUtil.ToLspRange(GetNameSpan(node), analysis.Compilation);
        FLangLanguageServer.Log($"  [total] {sw.ElapsedMilliseconds}ms");

        return new Hover
        {
            Contents = new MarkedStringsOrMarkupContent(new MarkupContent
            {
                Kind = MarkupKind.Markdown,
                Value = $"```flang\n{hoverText}\n```"
            }),
            Range = range
        };
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
                    if (tc.NodeTypes.TryGetValue(id, out var type))
                    {
                        var display = FormatHmType(tc.Resolve(type), tc);
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
                    if (tc.NodeTypes.TryGetValue(call, out var type))
                        return FormatHmType(tc.Resolve(type), tc);
                    break;
                }

            case VariableDeclarationNode varDecl:
                {
                    if (tc.NodeTypes.TryGetValue(varDecl, out var type))
                    {
                        var display = FormatHmType(tc.Resolve(type), tc);
                        return $"{(varDecl.IsConst ? "const" : "let")} {varDecl.Name}: {display}";
                    }
                    break;
                }

            case FunctionDeclarationNode fn:
                return FormatFunctionSignature(fn, tc);

            case FunctionParameterNode param:
                {
                    if (tc.NodeTypes.TryGetValue(param, out var type))
                    {
                        var prefix = param.IsVariadic ? ".." : "";
                        var display = $"{prefix}{param.Name}: {FormatHmType(tc.Resolve(type), tc)}";
                        if (param.DefaultValue != null)
                            display += $" = {FormatExpressionSnippet(param.DefaultValue)}";
                        return display;
                    }
                    break;
                }

            case NamedArgumentExpressionNode namedArg:
                {
                    // Show the parameter this named argument refers to
                    if (tc.NodeTypes.TryGetValue(namedArg, out var type))
                        return $"{namedArg.Name}: {FormatHmType(tc.Resolve(type), tc)}";
                    break;
                }

            case MemberAccessExpressionNode ma:
                {
                    if (tc.NodeTypes.TryGetValue(ma, out var type))
                    {
                        var resolved = tc.Resolve(type);
                        // Enum payload variant constructor: fn(payload) -> EnumType
                        if (resolved is FunctionType ft
                            && ft.ReturnType is NominalType { Kind: NominalKind.Enum } enumType)
                        {
                            var payloadStr = string.Join(", ", ft.ParameterTypes.Select(p => FormatHmType(p, tc)));
                            return $".{ma.FieldName}({payloadStr}): {FormatHmType(enumType, tc)}";
                        }
                        // Payload-less enum variant
                        if (resolved is NominalType { Kind: NominalKind.Enum } directEnum)
                            return $".{ma.FieldName}: {FormatHmType(directEnum, tc)}";
                        return $".{ma.FieldName}: {FormatHmType(resolved, tc)}";
                    }
                    break;
                }

            case VariablePatternNode varPat:
                {
                    if (tc.NodeTypes.TryGetValue(varPat, out var type))
                        return $"{varPat.Name}: {FormatHmType(tc.Resolve(type), tc)}";
                    break;
                }

            case EnumVariantPatternNode variantPat:
                {
                    if (tc.NodeTypes.TryGetValue(variantPat, out var type))
                        return $".{variantPat.VariantName}: {FormatHmType(tc.Resolve(type), tc)}";
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
                    if (node is ExpressionNode && tc.NodeTypes.TryGetValue(node, out var type))
                        return FormatHmType(tc.Resolve(type), tc);
                    break;
                }
        }

        return null;
    }

    private static string FormatFunctionSignature(FunctionDeclarationNode fn, TypeCheckResult tc)
    {
        var pars = string.Join(", ", fn.Parameters.Select(p =>
        {
            var prefix = p.IsVariadic ? ".." : "";
            string label;
            if (tc.NodeTypes.TryGetValue(p, out var inferredType))
                label = $"{prefix}{p.Name}: {FormatHmType(tc.Resolve(inferredType), tc)}";
            else
                label = $"{prefix}{p.Name}: {FormatTypeNode(p.Type)}";
            if (p.DefaultValue != null)
                label += $" = {FormatExpressionSnippet(p.DefaultValue)}";
            return label;
        }));

        string ret = "void";
        if (tc.NodeTypes.TryGetValue(fn, out var fnInferred))
        {
            var resolved = tc.Resolve(fnInferred);
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

    /// <summary>
    /// Format a default value expression as a short source snippet for display.
    /// </summary>
    internal static string FormatExpressionSnippet(ExpressionNode expr) => expr switch
    {
        IntegerLiteralNode lit => lit.Value.ToString(),
        BooleanLiteralNode bl => bl.Value ? "true" : "false",
        StringLiteralNode sl => $"\"{sl.Value}\"",
        NullLiteralNode => "null",
        IdentifierExpressionNode id => id.Name,
        CallExpressionNode call => $"{call.FunctionName}(..)",
        ArrayLiteralExpressionNode arr => arr.Elements?.Count > 0
            ? $"[{string.Join(", ", arr.Elements.Select(FormatExpressionSnippet))}]"
            : "[]",
        UnaryExpressionNode un => $"{FormatUnaryOp(un.Operator)}{FormatExpressionSnippet(un.Operand)}",
        _ => ".."
    };

    private static string FormatUnaryOp(UnaryOperatorKind op) => op switch
    {
        UnaryOperatorKind.Negate => "-",
        UnaryOperatorKind.Not => "!",
        _ => "?"
    };

    private static bool IsPrimitiveTypeName(string name) => name is
        "i8" or "i16" or "i32" or "i64" or "isize" or
        "u8" or "u16" or "u32" or "u64" or "usize" or
        "f32" or "f64" or "bool" or "char" or "void" or "never";

    /// <summary>
    /// Format an HM type for display. Placeholder NominalTypes from generic body checking
    /// display as "$T", "$U" etc. naturally via ShortName.
    /// </summary>
    private static string FormatHmType(Type type, TypeCheckResult tc)
    {
        var resolved = tc.Resolve(type);
        return resolved switch
        {
            TypeVar tv => $"?{tv.Id}",
            PrimitiveType p => p.Name,
            ReferenceType r => $"&{FormatHmType(r.InnerType, tc)}",
            ArrayType a => $"[{FormatHmType(a.ElementType, tc)}; {a.Length}]",
            FunctionType f => $"fn({string.Join(", ", f.ParameterTypes.Select(p => FormatHmType(p, tc)))}) {FormatHmType(f.ReturnType, tc)}",
            NominalType { Kind: NominalKind.Tuple } n =>
                n.FieldsOrVariants.Count == 0 ? "()" : $"({string.Join(", ", n.FieldsOrVariants.Select(f => FormatHmType(f.Type, tc)))})",
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
        AnonymousStructTypeNode anon => $"struct {{ {string.Join(", ", anon.Fields.Select(f => $"{f.FieldName}: {FormatTypeNode(f.FieldType)}"))} }}",
        AnonymousEnumTypeNode anonEnum => $"enum {{ {string.Join(", ", anonEnum.Variants.Select(v => v.PayloadTypes.Count == 0 ? v.Name : $"{v.Name}({string.Join(", ", v.PayloadTypes.Select(FormatTypeNode))})"))} }}",
        _ => type.GetType().Name
    };

    internal static SourceSpan GetNameSpan(AstNode node) => node switch
    {
        FunctionDeclarationNode fn => fn.NameSpan,
        VariableDeclarationNode vd => vd.NameSpan,
        FunctionParameterNode fp => fp.NameSpan,
        NamedArgumentExpressionNode na => na.NameSpan,
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
