using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Semantics;
using Microsoft.Extensions.Logging;
using OmniSharp.Extensions.LanguageServer.Protocol.Client.Capabilities;
using OmniSharp.Extensions.LanguageServer.Protocol.Document;
using OmniSharp.Extensions.LanguageServer.Protocol.Models;
using FunctionType = FLang.Core.Types.FunctionType;
using NominalType = FLang.Core.Types.NominalType;
using PrimitiveType = FLang.Core.Types.PrimitiveType;
using ReferenceType = FLang.Core.Types.ReferenceType;
using Type = FLang.Core.Types.Type;
using ArrayType = FLang.Core.Types.ArrayType;
using TypeVar = FLang.Core.Types.TypeVar;

namespace FLang.Lsp.Handlers;

public class SignatureHelpHandler : SignatureHelpHandlerBase
{
    private readonly FLangWorkspace _workspace;
    private readonly ILogger<SignatureHelpHandler> _logger;

    public SignatureHelpHandler(FLangWorkspace workspace, ILogger<SignatureHelpHandler> logger)
    {
        _workspace = workspace;
        _logger = logger;
    }

    public override Task<SignatureHelp?> Handle(SignatureHelpParams request, CancellationToken cancellationToken)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var filePath = request.TextDocument.Uri.GetFileSystemPath();
        FLangLanguageServer.Log($"SignatureHelp: {filePath} @ {request.Position.Line}:{request.Position.Character}");

        var analysis = _workspace.GetAnalysis(filePath);
        if (analysis == null) return Task.FromResult<SignatureHelp?>(null);

        var fileId = PositionUtil.FindFileId(filePath, analysis.Compilation);
        if (fileId == null) return Task.FromResult<SignatureHelp?>(null);

        var normalizedPath = Path.GetFullPath(filePath);
        if (!analysis.ParsedModules.TryGetValue(normalizedPath, out var module))
            return Task.FromResult<SignatureHelp?>(null);

        var tc = analysis.TypeChecker;
        if (tc == null) return Task.FromResult<SignatureHelp?>(null);

        var source = analysis.Compilation.Sources[fileId.Value];
        var position = PositionUtil.ToSourcePosition(request.Position, source);

        // Find the enclosing call expression
        var call = AstNodeFinder.FindEnclosingCall(module, fileId.Value, position);
        if (call == null)
        {
            FLangLanguageServer.Log($"  No enclosing call found");
            return Task.FromResult<SignatureHelp?>(null);
        }

        var signatures = new List<SignatureInformation>();

        // Try resolved target first
        if (call.ResolvedTarget != null)
        {
            var sig = BuildSignature(call.ResolvedTarget, tc);
            if (sig != null) signatures.Add(sig);
        }
        // Fall back to function overloads
        else if (tc.Functions.TryGetValue(call.FunctionName, out var overloads))
        {
            foreach (var scheme in overloads)
            {
                var sig = BuildSignature(scheme.Node, tc);
                if (sig != null) signatures.Add(sig);
            }
        }

        if (signatures.Count == 0)
        {
            FLangLanguageServer.Log($"  No signatures found for {call.FunctionName}");
            return Task.FromResult<SignatureHelp?>(null);
        }

        // Determine active parameter by counting commas before cursor in the source text
        var activeParam = DetermineActiveParameter(call, position, source, fileId.Value);

        // For UFCS calls, the first parameter is implicit self — adjust display
        if (call.UfcsReceiver != null && activeParam >= 0)
            activeParam++; // shift to account for self param in signature

        FLangLanguageServer.Log($"  [total] {sw.ElapsedMilliseconds}ms -> {signatures.Count} sigs, activeParam={activeParam}");

        return Task.FromResult<SignatureHelp?>(new SignatureHelp
        {
            Signatures = new Container<SignatureInformation>(signatures),
            ActiveSignature = 0,
            ActiveParameter = activeParam
        });
    }

    private static SignatureInformation? BuildSignature(FunctionDeclarationNode fn, HmTypeChecker tc)
    {
        var paramInfos = new List<ParameterInformation>();
        var paramLabels = new List<string>();

        foreach (var p in fn.Parameters)
        {
            string paramType;
            if (tc.InferredTypes.TryGetValue(p, out var inferredType))
                paramType = FormatType(tc.Engine.Resolve(inferredType), tc);
            else
                paramType = FormatTypeNode(p.Type);

            var prefix = p.IsVariadic ? ".." : "";
            var label = $"{prefix}{p.Name}: {paramType}";
            if (p.DefaultValue != null)
                label += $" = {HoverHandler.FormatExpressionSnippet(p.DefaultValue)}";

            paramLabels.Add(label);
            paramInfos.Add(new ParameterInformation
            {
                Label = new ParameterInformationLabel(label)
            });
        }

        // Build return type
        string ret = "void";
        if (tc.InferredTypes.TryGetValue(fn, out var fnInferred))
        {
            var resolved = tc.Engine.Resolve(fnInferred);
            if (resolved is FunctionType fnType)
                ret = FormatType(fnType.ReturnType, tc);
            else
                ret = FormatType(resolved, tc);
        }
        else if (fn.ReturnType != null)
        {
            ret = FormatTypeNode(fn.ReturnType);
        }

        var sigLabel = $"fn {fn.Name}({string.Join(", ", paramLabels)}) {ret}";

        return new SignatureInformation
        {
            Label = sigLabel,
            Parameters = new Container<ParameterInformation>(paramInfos)
        };
    }

    private static int DetermineActiveParameter(CallExpressionNode call, int cursorPos, Source source, int fileId)
    {
        // Count how many arguments precede the cursor
        var args = call.Arguments;
        if (args.Count == 0) return 0;

        // Find cursor position relative to arguments
        for (var i = args.Count - 1; i >= 0; i--)
        {
            if (args[i].Span.FileId == fileId && cursorPos >= args[i].Span.Index)
                return i;
        }

        // Count commas between the call start and cursor position as fallback
        var callStart = call.Span.Index;
        var searchEnd = Math.Min(cursorPos, callStart + call.Span.Length);
        var commaCount = 0;
        var parenDepth = 0;

        for (var i = callStart; i < searchEnd && i < source.Text.Length; i++)
        {
            var ch = source.Text[i];
            if (ch == '(') parenDepth++;
            else if (ch == ')')
            {
                parenDepth--;
                if (parenDepth <= 0) break;
            }
            else if (ch == ',' && parenDepth == 1) commaCount++;
        }

        return commaCount;
    }

    private static string FormatType(Type type, HmTypeChecker tc)
    {
        var resolved = tc.Engine.Resolve(type);
        return resolved switch
        {
            TypeVar tv => $"?{tv.Id}",
            PrimitiveType p => p.Name,
            ReferenceType r => $"&{FormatType(r.InnerType, tc)}",
            ArrayType a => $"[{FormatType(a.ElementType, tc)}; {a.Length}]",
            FunctionType f => $"fn({string.Join(", ", f.ParameterTypes.Select(p => FormatType(p, tc)))}) {FormatType(f.ReturnType, tc)}",
            NominalType n when n.TypeArguments.Count == 0 => n.ShortName,
            NominalType n => $"{n.ShortName}({string.Join(", ", n.TypeArguments.Select(ta => FormatType(ta, tc)))})",
            _ => resolved.ToString()
        };
    }

    private static string FormatTypeNode(Frontend.Ast.Types.TypeNode type) => type switch
    {
        Frontend.Ast.Types.NamedTypeNode named => named.Name,
        Frontend.Ast.Types.ReferenceTypeNode refType => $"&{FormatTypeNode(refType.InnerType)}",
        Frontend.Ast.Types.NullableTypeNode nullable => $"{FormatTypeNode(nullable.InnerType)}?",
        Frontend.Ast.Types.GenericTypeNode generic => $"{generic.Name}({string.Join(", ", generic.TypeArguments.Select(FormatTypeNode))})",
        Frontend.Ast.Types.ArrayTypeNode array => $"[{FormatTypeNode(array.ElementType)}; {array.Length}]",
        Frontend.Ast.Types.SliceTypeNode slice => $"{FormatTypeNode(slice.ElementType)}[]",
        Frontend.Ast.Types.GenericParameterTypeNode gp => $"${gp.Name}",
        Frontend.Ast.Types.FunctionTypeNode func => $"fn({string.Join(", ", func.ParameterTypes.Select(FormatTypeNode))}) {FormatTypeNode(func.ReturnType)}",
        _ => type.GetType().Name
    };

    protected override SignatureHelpRegistrationOptions CreateRegistrationOptions(
        SignatureHelpCapability capability,
        ClientCapabilities clientCapabilities)
    {
        return new SignatureHelpRegistrationOptions
        {
            DocumentSelector = new TextDocumentSelector(
                new TextDocumentFilter { Language = "flang" }),
            TriggerCharacters = new Container<string>("(", ",")
        };
    }
}
