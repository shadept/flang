using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;
using FLang.Frontend.Ast.Types;

namespace FLang.Lsp;

/// <summary>
/// Finds the deepest AST node at a given source position.
/// </summary>
public static class AstNodeFinder
{
    /// <summary>
    /// Finds the enclosing CallExpressionNode whose argument span contains the given position.
    /// Returns the call node and the deepest node at the position.
    /// </summary>
    public static CallExpressionNode? FindEnclosingCall(ModuleNode module, int fileId, int position)
    {
        CallExpressionNode? enclosingCall = null;

        void Visit(AstNode? node)
        {
            if (node == null) return;

            // Track call expressions whose span contains the position
            if (node is CallExpressionNode call && Contains(call, fileId, position))
                enclosingCall = call;

            var contained = Contains(node, fileId, position);
            if (contained || IsContainer(node))
            {
                foreach (var child in GetChildren(node))
                    Visit(child);
            }
        }

        Visit(module);
        return enclosingCall;
    }

    public static AstNode? FindDeepestNodeAt(ModuleNode module, int fileId, int position)
    {
        var path = FindDeepestNodePathAt(module, fileId, position);
        return path.Count == 0 ? null : path[^1];
    }

    /// <summary>
    /// Returns the AST path from the module root down to the deepest node containing the position.
    /// The deepest node is the last element. Intermediate ancestors are the real AST parents
    /// (which may themselves not contain the position — e.g. FunctionDeclarationNode whose span
    /// covers only its signature). Returns an empty list if no node contains the position.
    /// </summary>
    public static IReadOnlyList<AstNode> FindDeepestNodePathAt(ModuleNode module, int fileId, int position)
    {
        var stack = new List<AstNode>();
        List<AstNode>? best = null;

        void Visit(AstNode? node)
        {
            if (node == null) return;

            stack.Add(node);

            var contained = Contains(node, fileId, position);
            if (contained)
                best = [.. stack];

            // Always recurse into containers whose children may have independent spans
            // (e.g. FunctionDeclarationNode span covers only the signature, not the body)
            if (contained || IsContainer(node))
            {
                foreach (var child in GetChildren(node))
                    Visit(child);
            }

            stack.RemoveAt(stack.Count - 1);
        }

        Visit(module);
        return best ?? [];
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
        WhileNode or
        LambdaExpressionNode;

    /// <summary>
    /// Recursively visit every node in the tree rooted at <paramref name="root"/>.
    /// </summary>
    public static void Walk(AstNode? root, Action<AstNode> visit)
    {
        if (root == null) return;
        visit(root);
        foreach (var child in GetChildren(root))
            Walk(child, visit);
    }

    public static IEnumerable<AstNode> GetChildren(AstNode node)
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
                if (fp.DefaultValue != null) yield return fp.DefaultValue;
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
                if (arm.Guard != null) yield return arm.Guard;
                yield return arm.ResultExpr;
                break;

            case ArrayLiteralExpressionNode arr:
                if (arr.Elements != null)
                    foreach (var e in arr.Elements) yield return e;
                if (arr.RepeatValue != null) yield return arr.RepeatValue;
                if (arr.RepeatCountExpression != null) yield return arr.RepeatCountExpression;
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

            case ReturnNode ret:
                if (ret.Expression != null) yield return ret.Expression;
                break;

            // === Statements ===
            case ExpressionStatementNode es:
                yield return es.Expression;
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

            case WhileNode whileLoop:
                yield return whileLoop.Condition;
                yield return whileLoop.Body;
                break;

            // === Patterns ===
            case EnumVariantPatternNode evp:
                foreach (var sp in evp.SubPatterns)
                    yield return sp;
                break;
            case OrPatternNode orp:
                foreach (var alt in orp.Alternatives)
                    yield return alt;
                break;
            case TuplePatternNode tupp:
                foreach (var el in tupp.Elements)
                    yield return el;
                break;
            case StructPatternNode strp:
                foreach (var f in strp.Fields)
                    yield return f.Pattern;
                break;

            // Type nodes: descend into compound types to reach the named type inside
            case ReferenceTypeNode rt:
                yield return rt.InnerType;
                break;
            case NullableTypeNode nt:
                yield return nt.InnerType;
                break;
            case GenericTypeNode gt:
                foreach (var ta in gt.TypeArguments) yield return ta;
                break;
            case ArrayTypeNode at:
                yield return at.ElementType;
                break;
            case SliceTypeNode st:
                yield return st.ElementType;
                break;
            case FunctionTypeNode ft:
                foreach (var pt in ft.ParameterTypes) yield return pt;
                yield return ft.ReturnType;
                break;

                // Leaves: IdentifierExpressionNode, IntegerLiteralNode, StringLiteralNode,
                // BooleanLiteralNode, NullLiteralNode, ImportDeclarationNode,
                // BreakNode, ContinueNode, NamedTypeNode, PatternNodes (leaf)
                // — no children to yield
        }
    }
}
