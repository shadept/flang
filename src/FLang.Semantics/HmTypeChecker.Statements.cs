using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend;
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
            case ExpressionStatementNode { Expression: IfExpressionNode ifStmt }:
                InferIfAsStatement(ifStmt);
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
            case WhileNode whileLoop:
                CheckWhileLoop(whileLoop);
                break;
            case DeferStatementNode defer:
                InferExpression(defer.Expression);
                break;
            case IfDirectiveStatementNode directive:
            {
                var active = TemplateEngine.EvaluateCondition(directive.Condition, _compilation.CompileTimeContext);
                var branch = active ? directive.ThenBody : directive.ElseBody;
                if (branch != null)
                    foreach (var s in branch)
                        CheckStatement(s);
                break;
            }
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
        // E2039: Const must have initializer
        if (varDecl.IsConst && varDecl.Initializer == null)
            ReportError($"Constant `{varDecl.Name}` must be initialized", varDecl.Span, "E2039");

        Type? annotationType = null;
        if (varDecl.Type != null)
            annotationType = ResolveTypeNode(varDecl.Type);

        Type varType;
        if (varDecl.Initializer != null)
        {
            var initType = InferExpression(varDecl.Initializer);
            if (annotationType != null)
            {
                // Unspecified fields are zero-initialized (codegen memsets the struct to 0)

                var unifySpan = varDecl.Initializer?.Span ?? varDecl.Span;
                var unified = _ctx.Engine.Unify(annotationType, initType, unifySpan);
                varType = unified.Type;
            }
            else
            {
                // E2026: Empty array literal without type annotation
                if (varDecl.Initializer is ArrayLiteralExpressionNode { IsRepeatSyntax: false } arrLit
                    && (arrLit.Elements == null || arrLit.Elements.Count == 0))
                {
                    ReportError("Empty array literal `[]` requires a type annotation", varDecl.Span, "E2026");
                }
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
            varType = _ctx.Engine.FreshVar();
        }

        // E2005: Prevent redeclaration of global constants.
        // Local same-scope re-declaration is permitted (for flexibility) but
        // flagged as W1002 so readers notice the earlier binding is shadowed.
        if (_ctx.Scopes.ExistsInCurrentScope(varDecl.Name)
            && !varDecl.Name.StartsWith('_'))
        {
            if (_ctx.Scopes.Depth == 1)
            {
                var diag = Diagnostic.Error($"Global `{varDecl.Name}` is already declared", varDecl.Span, code: "E2005");
                var existingDecl = _ctx.Scopes.LookupDeclaration(varDecl.Name);
                if (existingDecl != null)
                    diag.Notes.Add(Diagnostic.Info($"`{varDecl.Name}` first declared here", existingDecl.Span));
                _diagnostics.Add(diag);
            }
            else
            {
                var diag = Diagnostic.Warning(
                    $"`{varDecl.Name}` shadows an earlier declaration in the same scope",
                    varDecl.Span,
                    hint: "rename one of the bindings or prefix with `_` to suppress",
                    code: "W1002");
                var existingDecl = _ctx.Scopes.LookupDeclaration(varDecl.Name);
                if (existingDecl != null)
                    diag.Notes.Add(Diagnostic.Info($"`{varDecl.Name}` first declared here", existingDecl.Span));
                _diagnostics.Add(diag);
            }
        }

        _ctx.Scopes.Bind(varDecl.Name, varType, varDecl);
        Record(varDecl, varType);

        // Track const names for E2038 checking
        if (varDecl.IsConst)
            MarkConst(varDecl.Name);

        // Track for unused variable warnings (only inside function bodies)
        _ctx.CurrentFnDeclaredVars?.TryAdd(varDecl.Name, varDecl.Span);
    }

    // =========================================================================
    // Return statement
    // =========================================================================

    // =========================================================================
    // For loop — iterator protocol: iter(&T) -> next(&Iter) -> Option[E]
    // =========================================================================

    private void CheckForLoop(ForLoopNode forLoop)
    {
        var iterableType = InferExpression(forLoop.IterableExpression);

        // Resolve iter(&T) -> IteratorType
        var iterRef = new ReferenceType(iterableType);
        var iterResult = TryResolveOperator("iter", [iterRef], forLoop.Span, out var iterNode)
                      ?? TryResolveOperator("iter", [iterableType], forLoop.Span, out iterNode);

        Type elementType;
        if (iterResult != null)
        {
            forLoop.ResolvedIterFunction = iterNode;
            var iteratorType = iterResult;
            // Resolve next(&IteratorType) -> Option[E]
            var nextRef = new ReferenceType(iteratorType);
            var nextResult = TryResolveOperator("next", [nextRef], forLoop.Span, out var nextNode)
                          ?? TryResolveOperator("next", [iteratorType], forLoop.Span, out nextNode);

            if (nextResult != null)
            {
                forLoop.ResolvedNextFunction = nextNode;
                var nextReturnType = _ctx.Engine.Resolve(nextResult);
                if (nextReturnType is NominalType { Name: WellKnown.Option } optType
                    && optType.TypeArguments.Count > 0)
                {
                    elementType = optType.TypeArguments[0];
                }
                else
                {
                    ReportError("`next` must return Option type", forLoop.Span, "E2025");
                    elementType = _ctx.Engine.FreshVar();
                }
            }
            else
            {
                ReportError("Iterator type has no `next` function", forLoop.Span, "E2023");
                elementType = _ctx.Engine.FreshVar();
            }
        }
        else
        {
            // Try direct range/array/slice iteration
            elementType = TryResolveDirectIteration(iterableType, forLoop.IterableExpression.Span);
        }

        // Record element type for lowering
        Record(forLoop, elementType);

        // Check body with loop variable in scope
        PushScope();
        _ctx.Scopes.Bind(forLoop.IteratorVariable, elementType);

        InferExpression(forLoop.Body);

        PopScope();
    }

    /// <summary>
    /// For types with built-in iteration (arrays, slices, ranges), determine element type directly.
    /// </summary>
    private Type TryResolveDirectIteration(Type iterableType, SourceSpan span)
    {
        var resolved = _ctx.Engine.Resolve(iterableType);

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
        return _ctx.Engine.FreshVar();
    }

    // =========================================================================
    // Loop statement
    // =========================================================================

    private void CheckLoop(LoopNode loop)
    {
        InferExpression(loop.Body);
    }

    // =========================================================================
    // While loop — condition must be bool
    // =========================================================================

    private void CheckWhileLoop(WhileNode whileLoop)
    {
        var condType = InferExpression(whileLoop.Condition);
        _ctx.Engine.Unify(condType, WellKnown.Bool, whileLoop.Condition.Span);
        InferExpression(whileLoop.Body);
    }
}
