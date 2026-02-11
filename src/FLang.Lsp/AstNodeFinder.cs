using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;

namespace FLang.Lsp;

/// <summary>
/// Finds the deepest AST node at a given source position.
/// </summary>
public static class AstNodeFinder
{
    public static AstNode? FindDeepestNodeAt(ModuleNode module, int fileId, int position)
    {
        AstNode? best = null;

        void Visit(AstNode? node)
        {
            if (node == null) return;

            var contained = Contains(node, fileId, position);
            if (contained)
                best = node;

            // Always recurse into containers whose children may have independent spans
            // (e.g. FunctionDeclarationNode span covers only the signature, not the body)
            if (contained || IsContainer(node))
            {
                foreach (var child in GetChildren(node))
                    Visit(child);
            }
        }

        Visit(module);
        return best;
    }

    private static bool Contains(AstNode node, int fileId, int position)
    {
        var span = node.Span;
        return span.FileId == fileId
            && span.Index <= position
            && position < span.Index + span.Length;
    }

    /// <summary>
    /// Nodes whose spans may not encompass their children's spans.
    /// We always recurse into these.
    /// </summary>
    private static bool IsContainer(AstNode node) => node is
        ModuleNode or
        FunctionDeclarationNode or
        TestDeclarationNode or
        BlockExpressionNode or
        MatchExpressionNode or
        MatchArmNode or
        IfExpressionNode or
        ForLoopNode or
        LoopNode or
        LambdaExpressionNode;

    private static IEnumerable<AstNode> GetChildren(AstNode node)
    {
        switch (node)
        {
            // === Declarations ===
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
                yield return fp.Type;
                break;

            case StructDeclarationNode sd:
                foreach (var f in sd.Fields) yield return f;
                break;

            case StructFieldNode sf:
                yield return sf.Type;
                break;

            case EnumDeclarationNode ed:
                foreach (var v in ed.Variants) yield return v;
                break;

            case EnumVariantNode ev:
                foreach (var t in ev.PayloadTypes) yield return t;
                break;

            case VariableDeclarationNode vd:
                if (vd.Type != null) yield return vd.Type;
                if (vd.Initializer != null) yield return vd.Initializer;
                break;

            case TestDeclarationNode td:
                foreach (var s in td.Body) yield return s;
                break;

            // === Expressions ===
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

            // === Statements ===
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

            // === Patterns ===
            case EnumVariantPatternNode evp:
                foreach (var sp in evp.SubPatterns)
                    yield return sp;
                break;

            // Leaves: IdentifierExpressionNode, IntegerLiteralNode, StringLiteralNode,
            // BooleanLiteralNode, NullLiteralNode, ImportDeclarationNode,
            // BreakStatementNode, ContinueStatementNode, TypeNodes, PatternNodes (leaf)
            // — no children to yield
        }
    }
}
