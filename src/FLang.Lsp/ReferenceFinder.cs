using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Types;
using FLang.Semantics;
using ReferenceType = FLang.Core.Types.ReferenceType;
using Type = FLang.Core.Types.Type;

namespace FLang.Lsp;

/// <summary>
/// Identity of the thing the user clicked on, used to find all references to it.
/// The compiler stores ref → def edges on each usage node (e.g. <see
/// cref="IdentifierExpressionNode.ResolvedVariableDeclaration"/>); find-references
/// inverts this by walking every AST node and matching against a target identity.
/// </summary>
public abstract record ReferenceTarget;

/// <summary>
/// A function or method. Identified by (file-path, char-offset, length) — *not*
/// by <see cref="SourceSpan"/>, because <see cref="SourceSpan.FileId"/> is
/// per-<see cref="Compilation"/>: the same source file gets different FileIds in
/// each open file's analysis, so a SourceSpan-keyed identity wouldn't match a
/// resolved-target read from another analysis. Generic specializations preserve
/// the original NameSpan, so this identity also covers them.
/// </summary>
public sealed record FunctionRefTarget(string FilePath, int Index, int Length, string Name) : ReferenceTarget;

/// <summary>
/// A local variable or function parameter. Identified by object reference, which
/// constrains the search to a single analysis (different analyses produce different
/// AST instances for the same source file). Locals only refer within their own
/// function body, so cross-analysis search isn't needed.
/// </summary>
public sealed record LocalDeclRefTarget(AstNode Decl) : ReferenceTarget;

/// <summary>
/// A field of a struct type. Identified by the owning type's FQN plus the field
/// name (the field node itself isn't unique across structs that share field names).
/// </summary>
public sealed record StructFieldRefTarget(string TypeFqn, string FieldName) : ReferenceTarget;

/// <summary>
/// A nominal type (struct or enum). Identified by FQN; ShortName is kept for
/// matching against type annotations that use the unqualified name.
/// </summary>
public sealed record NominalTypeRefTarget(string Fqn, string ShortName) : ReferenceTarget;

public static class ReferenceFinder
{
    /// <summary>
    /// Determine what the cursor is pointing at — either a declaration's name span,
    /// or a usage that resolves to one. Returns null when no resolvable symbol sits
    /// under the cursor.
    /// </summary>
    public static ReferenceTarget? ResolveTargetAt(
        ModuleNode module, int fileId, int position, FileAnalysisResult analysis)
    {
        var path = AstNodeFinder.FindDeepestNodePathAt(module, fileId, position);
        if (path.Count == 0) return null;

        // === Cursor on a declaration's NAME span ===
        for (var i = path.Count - 1; i >= 0; i--)
        {
            switch (path[i])
            {
                case FunctionDeclarationNode fn when ContainsPos(fn.NameSpan, fileId, position):
                    return MakeFunctionTarget(fn.NameSpan, fn.Name, analysis.Compilation);
                case VariableDeclarationNode v when ContainsPos(v.NameSpan, fileId, position):
                    return new LocalDeclRefTarget(v);
                case FunctionParameterNode p when ContainsPos(p.NameSpan, fileId, position):
                    return new LocalDeclRefTarget(p);
                case StructFieldNode f when ContainsPos(f.NameSpan, fileId, position):
                    {
                        var typeFqn = FindEnclosingNominalFqn(path, i, analysis);
                        return typeFqn != null ? new StructFieldRefTarget(typeFqn, f.Name) : null;
                    }
                case StructDeclarationNode sd when ContainsPos(sd.NameSpan, fileId, position):
                    {
                        var fqn = FindFqnByNameSpan(sd.NameSpan, analysis);
                        return fqn != null ? new NominalTypeRefTarget(fqn, sd.Name) : null;
                    }
                case EnumDeclarationNode ed when ContainsPos(ed.NameSpan, fileId, position):
                    {
                        var fqn = FindFqnByNameSpan(ed.NameSpan, analysis);
                        return fqn != null ? new NominalTypeRefTarget(fqn, ed.Name) : null;
                    }
            }
        }

        // === Cursor on a USAGE ===
        var node = path[^1];

        if (analysis.TypeChecker != null
            && node is BinaryExpressionNode or UnaryExpressionNode or IndexExpressionNode
                or AssignmentExpressionNode or CoalesceExpressionNode)
        {
            var op = analysis.TypeChecker.GetResolvedOperator(node);
            if (op != null)
                return MakeFunctionTarget(op.Function.NameSpan, op.Function.Name, analysis.Compilation);
        }

        switch (node)
        {
            case IdentifierExpressionNode id when id.ResolvedFunctionTarget != null:
                return MakeFunctionTarget(id.ResolvedFunctionTarget.NameSpan, id.ResolvedFunctionTarget.Name, analysis.Compilation);

            case IdentifierExpressionNode id when id.ResolvedVariableDeclaration != null:
                return new LocalDeclRefTarget(id.ResolvedVariableDeclaration);

            case IdentifierExpressionNode id when id.ResolvedParameterDeclaration != null:
                return new LocalDeclRefTarget(id.ResolvedParameterDeclaration);

            case IdentifierExpressionNode id:
                {
                    var fqn = TryResolveTypeFqnByShortName(id.Name, analysis);
                    return fqn != null ? new NominalTypeRefTarget(fqn, id.Name) : null;
                }

            case CallExpressionNode call when call.ResolvedTarget != null:
                return MakeFunctionTarget(call.ResolvedTarget.NameSpan, call.ResolvedTarget.Name, analysis.Compilation);

            case CallExpressionNode call when call.CalleeDeclaration is VariableDeclarationNode v:
                return new LocalDeclRefTarget(v);

            case CallExpressionNode call when call.CalleeDeclaration is FunctionParameterNode p:
                return new LocalDeclRefTarget(p);

            case CallExpressionNode call:
                {
                    var name = call.MethodName ?? call.FunctionName;
                    if (!string.IsNullOrEmpty(name))
                    {
                        var fqn = TryResolveTypeFqnByShortName(name, analysis);
                        if (fqn != null) return new NominalTypeRefTarget(fqn, name);
                    }
                    break;
                }

            case NamedTypeNode named:
                {
                    var fqn = TryResolveTypeFqnByShortName(named.Name, analysis);
                    return fqn != null ? new NominalTypeRefTarget(fqn, named.Name) : null;
                }

            case GenericTypeNode generic:
                {
                    var fqn = TryResolveTypeFqnByShortName(generic.Name, analysis);
                    return fqn != null ? new NominalTypeRefTarget(fqn, generic.Name) : null;
                }

            case MemberAccessExpressionNode ma:
                {
                    if (analysis.TypeChecker is { } tc
                        && tc.NodeTypes.TryGetValue(ma.Target, out var targetType))
                    {
                        var resolved = tc.Resolve(targetType);
                        var fqn = GetNominalFqn(resolved);
                        if (fqn != null)
                            return new StructFieldRefTarget(fqn, ma.FieldName);
                    }
                    break;
                }
        }

        return null;
    }

    /// <summary>
    /// Walk every parsed module in <paramref name="analysis"/> and collect spans
    /// of all references to <paramref name="target"/>. Call this once per open
    /// analysis to find cross-file references — callers in fs.f only show up in
    /// fs.f's analysis, not in the defining file's analysis.
    /// </summary>
    public static List<SourceSpan> FindReferences(
        ReferenceTarget target, FileAnalysisResult analysis, bool includeDeclaration)
    {
        var results = new HashSet<SourceSpan>();
        var tc = analysis.TypeChecker;
        var comp = analysis.Compilation;

        foreach (var module in analysis.ParsedModules.Values)
        {
            AstNodeFinder.Walk(module, node => CollectReference(node, target, tc, comp, results));
        }

        if (includeDeclaration)
        {
            var declSpan = GetDeclarationNameSpan(target, analysis);
            if (declSpan.HasValue) results.Add(declSpan.Value);
        }

        return [.. results];
    }

    // ─── per-node check ────────────────────────────────────────────────────

    private static void CollectReference(
        AstNode node, ReferenceTarget target, TypeCheckResult? tc, Compilation comp, HashSet<SourceSpan> results)
    {
        switch (target)
        {
            case FunctionRefTarget fn:
                CollectFunctionRef(node, fn, tc, comp, results);
                break;
            case LocalDeclRefTarget local:
                CollectLocalRef(node, local, results);
                break;
            case StructFieldRefTarget field:
                CollectFieldRef(node, field, tc, results);
                break;
            case NominalTypeRefTarget type:
                CollectTypeRef(node, type, results);
                break;
        }
    }

    private static void CollectFunctionRef(
        AstNode node, FunctionRefTarget target, TypeCheckResult? tc, Compilation comp, HashSet<SourceSpan> results)
    {
        switch (node)
        {
            case IdentifierExpressionNode id when id.ResolvedFunctionTarget is { } rt
                && MatchesFunctionTarget(rt.NameSpan, target, comp):
                results.Add(id.Span);
                return;
            case CallExpressionNode call when call.ResolvedTarget is { } rt
                && MatchesFunctionTarget(rt.NameSpan, target, comp):
                results.Add(call.FunctionNameSpan);
                return;
        }

        if (tc != null && node is BinaryExpressionNode or UnaryExpressionNode
            or IndexExpressionNode or AssignmentExpressionNode or CoalesceExpressionNode)
        {
            var op = tc.GetResolvedOperator(node);
            if (op != null && MatchesFunctionTarget(op.Function.NameSpan, target, comp))
                results.Add(node.Span);
        }
    }

    private static void CollectLocalRef(
        AstNode node, LocalDeclRefTarget target, HashSet<SourceSpan> results)
    {
        switch (node)
        {
            case IdentifierExpressionNode id
                when ReferenceEquals(id.ResolvedVariableDeclaration, target.Decl)
                    || ReferenceEquals(id.ResolvedParameterDeclaration, target.Decl):
                results.Add(id.Span);
                return;
            case CallExpressionNode call when ReferenceEquals(call.CalleeDeclaration, target.Decl):
                results.Add(call.FunctionNameSpan);
                return;
        }
    }

    private static void CollectFieldRef(
        AstNode node, StructFieldRefTarget target, TypeCheckResult? tc, HashSet<SourceSpan> results)
    {
        if (tc == null) return;
        if (node is not MemberAccessExpressionNode ma) return;
        if (ma.FieldName != target.FieldName) return;
        if (!tc.NodeTypes.TryGetValue(ma.Target, out var targetType)) return;

        var fqn = GetNominalFqn(tc.Resolve(targetType));
        if (fqn != target.TypeFqn) return;

        var nameSpan = new SourceSpan(
            ma.Span.FileId,
            ma.Span.Index + ma.Span.Length - target.FieldName.Length,
            target.FieldName.Length,
            ma.Span.Line);
        results.Add(nameSpan);
    }

    private static void CollectTypeRef(
        AstNode node, NominalTypeRefTarget target, HashSet<SourceSpan> results)
    {
        switch (node)
        {
            case NamedTypeNode nt when nt.Name == target.ShortName || nt.Name == target.Fqn:
                results.Add(nt.Span);
                return;
            case GenericTypeNode gt when gt.Name == target.ShortName || gt.Name == target.Fqn:
                results.Add(new SourceSpan(gt.Span.FileId, gt.Span.Index, gt.Name.Length, gt.Span.Line));
                return;
            case IdentifierExpressionNode id
                when (id.Name == target.ShortName || id.Name == target.Fqn)
                    && id.ResolvedFunctionTarget == null
                    && id.ResolvedVariableDeclaration == null
                    && id.ResolvedParameterDeclaration == null:
                results.Add(id.Span);
                return;
        }
    }

    // ─── helpers ───────────────────────────────────────────────────────────

    private static FunctionRefTarget MakeFunctionTarget(SourceSpan nameSpan, string name, Compilation comp)
    {
        var path = GetSourcePath(nameSpan, comp) ?? "";
        return new FunctionRefTarget(path, nameSpan.Index, nameSpan.Length, name);
    }

    private static bool MatchesFunctionTarget(SourceSpan candidate, FunctionRefTarget target, Compilation comp)
    {
        if (candidate.Index != target.Index || candidate.Length != target.Length) return false;
        var path = GetSourcePath(candidate, comp);
        return path != null && PathsEqual(path, target.FilePath);
    }

    private static string? GetSourcePath(SourceSpan span, Compilation comp)
    {
        if (span.FileId < 0 || span.FileId >= comp.Sources.Count) return null;
        return Path.GetFullPath(comp.Sources[span.FileId].FileName);
    }

    private static bool PathsEqual(string a, string b)
        => string.Equals(a, b, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    private static SourceSpan? GetDeclarationNameSpan(ReferenceTarget target, FileAnalysisResult analysis)
    {
        return target switch
        {
            FunctionRefTarget fn => FindFunctionDeclSpan(fn, analysis),
            LocalDeclRefTarget local => local.Decl switch
            {
                VariableDeclarationNode v => v.NameSpan,
                FunctionParameterNode p => p.NameSpan,
                _ => null,
            },
            NominalTypeRefTarget type when analysis.TypeChecker != null
                && analysis.TypeChecker.NominalSpans.TryGetValue(type.Fqn, out var s) => s,
            StructFieldRefTarget field => FindStructFieldNameSpan(field, analysis),
            _ => null,
        };
    }

    private static SourceSpan? FindFunctionDeclSpan(FunctionRefTarget target, FileAnalysisResult analysis)
    {
        // The declaration site is defined by (path, index, length). Reconstruct a
        // SourceSpan within *this* analysis only when the analysis actually parses
        // the defining file — otherwise let another analysis surface it.
        for (var i = 0; i < analysis.Compilation.Sources.Count; i++)
        {
            if (PathsEqual(Path.GetFullPath(analysis.Compilation.Sources[i].FileName), target.FilePath))
                return new SourceSpan(i, target.Index, target.Length, 0);
        }
        return null;
    }

    private static SourceSpan? FindStructFieldNameSpan(StructFieldRefTarget target, FileAnalysisResult analysis)
    {
        if (analysis.TypeChecker == null) return null;
        if (!analysis.TypeChecker.NominalSpans.TryGetValue(target.TypeFqn, out var typeSpan))
            return null;

        foreach (var module in analysis.ParsedModules.Values)
        {
            foreach (var sd in module.Structs)
            {
                if (sd.NameSpan != typeSpan) continue;
                foreach (var f in sd.Fields)
                {
                    if (f.Name == target.FieldName) return f.NameSpan;
                }
            }
        }
        return null;
    }

    private static string? FindEnclosingNominalFqn(
        IReadOnlyList<AstNode> path, int fieldIndex, FileAnalysisResult analysis)
    {
        for (var i = fieldIndex - 1; i >= 0; i--)
        {
            if (path[i] is StructDeclarationNode sd)
                return FindFqnByNameSpan(sd.NameSpan, analysis);
        }
        return null;
    }

    private static string? FindFqnByNameSpan(SourceSpan nameSpan, FileAnalysisResult analysis)
    {
        if (analysis.TypeChecker == null) return null;
        foreach (var (fqn, span) in analysis.TypeChecker.NominalSpans)
        {
            if (span == nameSpan) return fqn;
        }
        return null;
    }

    private static string? TryResolveTypeFqnByShortName(string name, FileAnalysisResult analysis)
    {
        if (analysis.TypeChecker == null) return null;
        foreach (var (fqn, _) in analysis.TypeChecker.NominalSpans)
        {
            if (fqn == name) return fqn;
            var dot = fqn.LastIndexOf('.');
            if (dot >= 0 && fqn[(dot + 1)..] == name) return fqn;
        }
        return null;
    }

    private static string? GetNominalFqn(Type type)
    {
        return type switch
        {
            NominalType n => n.Name,
            ReferenceType r => GetNominalFqn(r.InnerType),
            _ => null,
        };
    }

    private static bool ContainsPos(SourceSpan span, int fileId, int position)
        => span.FileId == fileId
            && span.Index <= position
            && position < span.Index + span.Length;
}
