using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;
using ArrayType = FLang.Core.Types.ArrayType;
using FunctionType = FLang.Core.Types.FunctionType;
using ReferenceType = FLang.Core.Types.ReferenceType;
using Type = FLang.Core.Types.Type;

namespace FLang.Semantics;

public partial class HmTypeChecker
{
    // =========================================================================
    // Statement Checking — dispatches to specific handlers
    // =========================================================================

    private void CheckStatement(StatementNode stmt)
    {
        switch (stmt)
        {
            case VariableDeclarationNode varDecl:
                CheckVariableDeclaration(varDecl);
                break;
            case ReturnStatementNode ret:
                CheckReturn(ret);
                break;
            case ExpressionStatementNode exprStmt:
                InferExpression(exprStmt.Expression);
                break;
            case ForLoopNode forLoop:
                CheckForLoop(forLoop);
                break;
            case LoopNode loop:
                CheckLoop(loop);
                break;
            case BreakStatementNode:
            case ContinueStatementNode:
                break;
            case DeferStatementNode defer:
                InferExpression(defer.Expression);
                break;
            default:
                ReportError($"Unsupported statement kind: {stmt.GetType().Name}", stmt.Span);
                break;
        }
    }

    // =========================================================================
    // Variable declaration
    // =========================================================================

    private void CheckVariableDeclaration(VariableDeclarationNode varDecl)
    {
        Type? annotationType = null;
        if (varDecl.Type != null)
            annotationType = ResolveTypeNode(varDecl.Type);

        Type varType;
        if (varDecl.Initializer != null)
        {
            var initType = InferExpression(varDecl.Initializer);
            if (annotationType != null)
            {
                var unified = _engine.Unify(initType, annotationType, varDecl.Span);
                varType = unified.Type;
            }
            else
            {
                varType = initType;
            }
        }
        else if (annotationType != null)
        {
            varType = annotationType;
        }
        else
        {
            ReportError("Variable must have a type annotation or initializer", varDecl.Span);
            varType = _engine.FreshVar();
        }

        _scopes.Bind(varDecl.Name, varType);
        Record(varDecl, varType);
    }

    // =========================================================================
    // Return statement
    // =========================================================================

    private void CheckReturn(ReturnStatementNode ret)
    {
        if (_functionStack.Count == 0)
        {
            ReportError("Return statement outside of function", ret.Span);
            return;
        }

        var ctx = _functionStack.Peek();

        if (ret.Expression != null)
        {
            var exprType = InferExpression(ret.Expression);
            _engine.Unify(exprType, ctx.ReturnType, ret.Span);
        }
        else
        {
            // Bare return: return type must be void
            _engine.Unify(WellKnown.Void, ctx.ReturnType, ret.Span);
        }
    }

    // =========================================================================
    // For loop — iterator protocol: iter(&T) → next(&Iter) → Option[E]
    // =========================================================================

    private void CheckForLoop(ForLoopNode forLoop)
    {
        var iterableType = InferExpression(forLoop.IterableExpression);

        // Resolve iter(&T) → IteratorType
        var iterRef = new ReferenceType(iterableType);
        FunctionDeclarationNode? iterNode = null;
        var iterResult = TryResolveOperatorFunction("iter", [iterRef], forLoop.Span, out iterNode);
        if (iterResult == null)
        {
            // Try without reference
            iterResult = TryResolveOperatorFunction("iter", [iterableType], forLoop.Span, out iterNode);
        }

        Type elementType;
        if (iterResult != null)
        {
            forLoop.ResolvedIterFunction = iterNode;
            var iteratorType = iterResult;
            // Resolve next(&IteratorType) → Option[E]
            var nextRef = new ReferenceType(iteratorType);
            FunctionDeclarationNode? nextNode = null;
            var nextResult = TryResolveOperatorFunction("next", [nextRef], forLoop.Span, out nextNode);
            if (nextResult == null)
                nextResult = TryResolveOperatorFunction("next", [iteratorType], forLoop.Span, out nextNode);

            if (nextResult != null)
            {
                forLoop.ResolvedNextFunction = nextNode;
                var nextReturnType = _engine.Resolve(nextResult);
                if (nextReturnType is NominalType { Name: WellKnown.Option } optType
                    && optType.TypeArguments.Count > 0)
                {
                    elementType = optType.TypeArguments[0];
                }
                else
                {
                    ReportError("`next` must return Option type", forLoop.Span, "E2025");
                    elementType = _engine.FreshVar();
                }
            }
            else
            {
                ReportError("Iterator type has no `next` function", forLoop.Span, "E2023");
                elementType = _engine.FreshVar();
            }
        }
        else
        {
            // Try direct range/array/slice iteration
            elementType = TryResolveDirectIteration(iterableType, forLoop.Span);
        }

        // Record element type for lowering
        Record(forLoop, elementType);

        // Check body with loop variable in scope
        _scopes.PushScope();
        _scopes.Bind(forLoop.IteratorVariable, elementType);

        InferExpression(forLoop.Body);

        _scopes.PopScope();
    }

    /// <summary>
    /// For types with built-in iteration (arrays, slices, ranges), determine element type directly.
    /// </summary>
    private Type TryResolveDirectIteration(Type iterableType, SourceSpan span)
    {
        var resolved = _engine.Resolve(iterableType);

        if (resolved is ArrayType arrayType)
            return arrayType.ElementType;

        if (resolved is NominalType nominal)
        {
            if (nominal.Name == WellKnown.Slice && nominal.TypeArguments.Count > 0)
                return nominal.TypeArguments[0];
            if (nominal.Name == WellKnown.Range && nominal.TypeArguments.Count > 0)
                return nominal.TypeArguments[0];
        }

        ReportError("Type is not iterable", span, "E2021");
        return _engine.FreshVar();
    }

    // =========================================================================
    // Loop statement
    // =========================================================================

    private void CheckLoop(LoopNode loop)
    {
        InferExpression(loop.Body);
    }
}
