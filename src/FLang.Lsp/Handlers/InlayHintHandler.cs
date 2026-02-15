using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;
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

public class InlayHintHandler : InlayHintsHandlerBase
{
    private readonly FLangWorkspace _workspace;
    private readonly ILogger<InlayHintHandler> _logger;

    public InlayHintHandler(FLangWorkspace workspace, ILogger<InlayHintHandler> logger)
    {
        _workspace = workspace;
        _logger = logger;
    }

    public override async Task<InlayHintContainer?> Handle(InlayHintParams request, CancellationToken cancellationToken)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var filePath = request.TextDocument.Uri.GetFileSystemPath();
        FLangLanguageServer.Log($"InlayHint: {filePath} @ range {request.Range.Start.Line}-{request.Range.End.Line}");

        var analysis = await _workspace.GetAnalysisAsync(filePath);
        if (analysis == null) return null;

        var fileId = PositionUtil.FindFileId(filePath, analysis.Compilation);
        if (fileId == null) return null;

        var normalizedPath = Path.GetFullPath(filePath);
        if (!analysis.ParsedModules.TryGetValue(normalizedPath, out var module))
            return null;

        var tc = analysis.TypeChecker;
        if (tc == null) return null;

        var source = analysis.Compilation.Sources[fileId.Value];
        var rangeStart = PositionUtil.ToSourcePosition(request.Range.Start, source);
        var rangeEnd = PositionUtil.ToSourcePosition(request.Range.End, source);

        var hints = new List<InlayHint>();
        CollectHints(module, fileId.Value, rangeStart, rangeEnd, tc, analysis.Compilation, hints);

        FLangLanguageServer.Log($"  [total] {sw.ElapsedMilliseconds}ms -> {hints.Count} hints");
        return new InlayHintContainer(hints);
    }

    private static void CollectHints(AstNode node, int fileId, int rangeStart, int rangeEnd,
        HmTypeChecker tc, Compilation compilation, List<InlayHint> hints)
    {
        // Variable type hints: show inferred type when no explicit annotation
        if (node is VariableDeclarationNode varDecl
            && varDecl.Type == null
            && varDecl.Initializer != null
            && varDecl.NameSpan.FileId == fileId
            && IsInRange(varDecl.NameSpan, rangeStart, rangeEnd))
        {
            if (tc.InferredTypes.TryGetValue(varDecl, out var type))
            {
                var display = FormatType(tc.Engine.Resolve(type), tc);
                var pos = SpanEndToPosition(varDecl.NameSpan, compilation);
                if (pos != null)
                {
                    hints.Add(new InlayHint
                    {
                        Position = pos,
                        Label = new StringOrInlayHintLabelParts($": {display}"),
                        Kind = InlayHintKind.Type,
                        PaddingLeft = false,
                        PaddingRight = true
                    });
                }
            }
        }

        // Parameter name hints at call sites
        if (node is CallExpressionNode call
            && call.ResolvedTarget != null
            && call.Span.FileId == fileId
            && IsInRange(call.Span, rangeStart, rangeEnd))
        {
            var fn = call.ResolvedTarget;
            var parameters = fn.Parameters;
            var args = call.Arguments;

            // For UFCS calls, skip the implicit self parameter
            var paramOffset = call.UfcsReceiver != null ? 1 : 0;
            var positionalIndex = paramOffset;

            for (var i = 0; i < args.Count; i++)
            {
                // Named arguments already display their name — no hint needed
                if (args[i] is NamedArgumentExpressionNode)
                    continue;

                if (positionalIndex >= parameters.Count) break;

                var param = parameters[positionalIndex];

                // Variadic params collect remaining args into a slice — skip hints
                if (param.IsVariadic) break;

                var paramName = param.Name;
                positionalIndex++;

                // Skip self parameter hints
                if (paramName == "self") continue;

                // Skip if the argument text matches the parameter name (redundant)
                if (args[i] is IdentifierExpressionNode argId && argId.Name == paramName)
                    continue;

                var argSpan = args[i].Span;
                if (argSpan.FileId != fileId) continue;

                var pos = SpanStartToPosition(argSpan, compilation);
                if (pos != null)
                {
                    hints.Add(new InlayHint
                    {
                        Position = pos,
                        Label = new StringOrInlayHintLabelParts($"{paramName} = "),
                        Kind = InlayHintKind.Parameter,
                        PaddingLeft = false,
                        PaddingRight = false
                    });
                }
            }
        }

        // Recurse into children
        foreach (var child in GetChildren(node))
            CollectHints(child, fileId, rangeStart, rangeEnd, tc, compilation, hints);
    }

    private static bool IsInRange(SourceSpan span, int rangeStart, int rangeEnd)
    {
        var spanEnd = span.Index + span.Length;
        return spanEnd >= rangeStart && span.Index <= rangeEnd;
    }

    private static Position? SpanEndToPosition(SourceSpan span, Compilation compilation)
    {
        if (span.FileId < 0 || span.FileId >= compilation.Sources.Count) return null;
        var source = compilation.Sources[span.FileId];
        var endIndex = Math.Min(span.Index + span.Length, source.Text.Length);
        var (line, col) = source.GetLineAndColumn(endIndex);
        return new Position(line, col);
    }

    private static Position? SpanStartToPosition(SourceSpan span, Compilation compilation)
    {
        if (span.FileId < 0 || span.FileId >= compilation.Sources.Count) return null;
        var source = compilation.Sources[span.FileId];
        var (line, col) = source.GetLineAndColumn(span.Index);
        return new Position(line, col);
    }

    private static string FormatType(Type type, HmTypeChecker tc)
    {
        var resolved = tc.Engine.Resolve(type);
        return resolved switch
        {
            TypeVar tv => $"?Unbounded",
            PrimitiveType p => p.Name,
            ReferenceType r => $"&{FormatType(r.InnerType, tc)}",
            ArrayType a => $"[{FormatType(a.ElementType, tc)}; {a.Length}]",
            FunctionType f => $"fn({string.Join(", ", f.ParameterTypes.Select(p => FormatType(p, tc)))}) {FormatType(f.ReturnType, tc)}",
            NominalType { Kind: NominalKind.Tuple } n =>
                n.FieldsOrVariants.Count == 0 ? "()" : $"({string.Join(", ", n.FieldsOrVariants.Select(f => FormatType(f.Type, tc)))})",
            NominalType n when n.TypeArguments.Count == 0 => n.ShortName,
            NominalType n => $"{n.ShortName}({string.Join(", ", n.TypeArguments.Select(ta => FormatType(ta, tc)))})",
            _ => resolved.ToString()
        };
    }

    /// <summary>
    /// Walk AST children — mirrors AstNodeFinder.GetChildren but as a static method here
    /// to avoid coupling to AstNodeFinder's internal iterator.
    /// </summary>
    private static IEnumerable<AstNode> GetChildren(AstNode node)
    {
        switch (node)
        {
            case ModuleNode m:
                foreach (var i in m.Imports) yield return i;
                foreach (var g in m.GlobalConstants) yield return g;
                foreach (var s in m.Structs) yield return s;
                foreach (var e in m.Enums) yield return e;
                foreach (var f in m.Functions) yield return f;
                foreach (var t in m.Tests) yield return t;
                break;

            case FunctionDeclarationNode fn:
                foreach (var p in fn.Parameters) yield return p;
                if (fn.ReturnType != null) yield return fn.ReturnType;
                foreach (var s in fn.Body) yield return s;
                break;

            case FunctionParameterNode fp:
                if (fp.DefaultValue != null) yield return fp.DefaultValue;
                break;

            case VariableDeclarationNode vd:
                if (vd.Type != null) yield return vd.Type;
                if (vd.Initializer != null) yield return vd.Initializer;
                break;

            case TestDeclarationNode td:
                foreach (var s in td.Body) yield return s;
                break;

            case BinaryExpressionNode bin:
                yield return bin.Left;
                yield return bin.Right;
                break;

            case UnaryExpressionNode un:
                yield return un.Operand;
                break;

            case CallExpressionNode call:
                if (call.UfcsReceiver != null) yield return call.UfcsReceiver;
                foreach (var a in call.Arguments) yield return a;
                break;

            case NamedArgumentExpressionNode namedArg:
                yield return namedArg.Value;
                break;

            case MemberAccessExpressionNode ma:
                yield return ma.Target;
                break;

            case IndexExpressionNode idx:
                yield return idx.Base;
                yield return idx.Index;
                break;

            case AssignmentExpressionNode assign:
                yield return assign.Target;
                yield return assign.Value;
                break;

            case BlockExpressionNode block:
                foreach (var s in block.Statements) yield return s;
                if (block.TrailingExpression != null) yield return block.TrailingExpression;
                break;

            case IfExpressionNode ife:
                yield return ife.Condition;
                yield return ife.ThenBranch;
                if (ife.ElseBranch != null) yield return ife.ElseBranch;
                break;

            case MatchExpressionNode match:
                yield return match.Scrutinee;
                foreach (var arm in match.Arms) yield return arm;
                break;

            case MatchArmNode arm:
                yield return arm.Pattern;
                yield return arm.ResultExpr;
                break;

            case ArrayLiteralExpressionNode arr:
                if (arr.Elements != null)
                    foreach (var e in arr.Elements) yield return e;
                if (arr.RepeatValue != null) yield return arr.RepeatValue;
                break;

            case StructConstructionExpressionNode sc:
                yield return sc.TypeName;
                foreach (var (_, expr) in sc.Fields) yield return expr;
                break;

            case AnonymousStructExpressionNode anon:
                foreach (var (_, expr) in anon.Fields) yield return expr;
                break;

            case CastExpressionNode cast:
                yield return cast.Expression;
                yield return cast.TargetType;
                break;

            case LambdaExpressionNode lam:
                foreach (var s in lam.Body) yield return s;
                break;

            case RangeExpressionNode range:
                if (range.Start != null) yield return range.Start;
                if (range.End != null) yield return range.End;
                break;

            case DereferenceExpressionNode deref:
                yield return deref.Target;
                break;

            case AddressOfExpressionNode addr:
                yield return addr.Target;
                break;

            case CoalesceExpressionNode coal:
                yield return coal.Left;
                yield return coal.Right;
                break;

            case NullPropagationExpressionNode np:
                yield return np.Target;
                break;

            case ImplicitCoercionNode ic:
                yield return ic.Inner;
                break;

            case ExpressionStatementNode es:
                yield return es.Expression;
                break;

            case ReturnStatementNode ret:
                if (ret.Expression != null) yield return ret.Expression;
                break;

            case DeferStatementNode def:
                yield return def.Expression;
                break;

            case ForLoopNode forLoop:
                yield return forLoop.IterableExpression;
                yield return forLoop.Body;
                break;

            case LoopNode loop:
                yield return loop.Body;
                break;

            case EnumVariantPatternNode evp:
                foreach (var sp in evp.SubPatterns)
                    yield return sp;
                break;
        }
    }

    public override Task<InlayHint> Handle(InlayHint request, CancellationToken cancellationToken)
    {
        // No lazy resolve — hints are fully computed upfront
        return Task.FromResult(request);
    }

    protected override InlayHintRegistrationOptions CreateRegistrationOptions(
        InlayHintClientCapabilities capability,
        ClientCapabilities clientCapabilities)
    {
        return new InlayHintRegistrationOptions
        {
            DocumentSelector = new TextDocumentSelector(
                new TextDocumentFilter { Language = "flang" })
        };
    }
}
