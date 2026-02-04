using FLang.Core;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;
using Microsoft.Extensions.Logging;

namespace FLang.Semantics;

public partial class TypeChecker
{
    private void CheckStatement(StatementNode statement)
    {
        switch (statement)
        {
            case ReturnStatementNode ret:
                CheckReturnStatement(ret);
                break;
            case VariableDeclarationNode v:
                CheckVariableDeclaration(v);
                break;
            case ExpressionStatementNode es:
                CheckExpressionStatement(es);
                break;
            case ForLoopNode fl:
                CheckForLoop(fl);
                break;
            case LoopNode loop:
                CheckLoop(loop);
                break;
            case BreakStatementNode:
            case ContinueStatementNode:
                // No-op: these statements don't require type checking
                break;
            case DeferStatementNode ds:
                CheckDeferStatement(ds);
                break;
            default:
                throw new Exception($"Unknown statement type: {statement.GetType().Name}");
        }
    }

    private void CheckReturnStatement(ReturnStatementNode ret)
    {
        // Get expected return type from current function
        TypeBase? expectedReturnType = null;
        if (_functionStack.Count > 0)
        {
            var currentFunction = _functionStack.Peek();
            expectedReturnType = currentFunction.ReturnType != null ? ResolveTypeNode(currentFunction.ReturnType) : TypeRegistry.Void;
        }

        // Handle bare `return` for void functions
        if (ret.Expression == null)
        {
            if (expectedReturnType != null && !expectedReturnType.Equals(TypeRegistry.Void))
            {
                ReportError(
                    "bare `return` in non-void function",
                    ret.Span,
                    $"expected `{expectedReturnType.Name}`, use `return <expr>`",
                    "E2027");
            }
            return;
        }

        var et = CheckExpression(ret.Expression, expectedReturnType);
        _logger.LogDebug(
            "[TypeChecker] CheckReturnStatement: expectedReturnType={ExpectedType}, expressionType={ExprType}",
            expectedReturnType?.Name ?? "null", et.Name);

        // Early exit if expression failed type checking to prevent cascading unification errors
        if (IsNever(et)) return;

        if (expectedReturnType != null)
        {
            // Always unify to propagate type info (e.g., comptime_int → i32)
            var unified = UnifyTypes(expectedReturnType, et, ret.Expression.Span);

            // Wrap return expression with coercion node if needed
            ret.Expression = WrapWithCoercionIfNeeded(ret.Expression, et.Prune(), expectedReturnType.Prune());

            _logger.LogDebug(
                "[TypeChecker] After unification: unified={UnifiedType}",
                unified.Name);
        }
    }

    private void CheckVariableDeclaration(VariableDeclarationNode v)
    {
        // const declarations require an initializer
        if (v.IsConst && v.Initializer == null)
        {
            ReportError(
                "const declaration must have an initializer",
                v.Span,
                "const variables must be initialized at declaration",
                "E2039");
            if (v.Type != null)
            {
                v.ResolvedType = ResolveTypeNode(v.Type) ?? TypeRegistry.Never;
            }
            else
            {
                v.ResolvedType = TypeRegistry.Never;
            }
            DeclareVariable(v.Name, v.ResolvedType, v.Span, isConst: true);
            return;
        }

        var dt = ResolveTypeNode(v.Type);
        var it = v.Initializer != null ? CheckExpression(v.Initializer, dt) : null;

        // Early exit if initializer failed type checking to prevent cascading unification errors
        if (it != null && IsNever(it))
        {
            v.ResolvedType = TypeRegistry.Never;
            DeclareVariable(v.Name, v.ResolvedType, v.Span, v.IsConst);
            return;
        }

        if (it != null && dt != null)
        {
            // Capture the original initializer type BEFORE unification (for coercion detection)
            var originalInitType = it.Prune();

            // Unify initializer type with declared type - TypeVar.Prune() handles propagation
            var unified = UnifyTypes(it, dt, v.Initializer!.Span);

            // Wrap initializer with coercion node if needed
            // Use originalInitType (before unification) to correctly detect coercions like comptime_int -> Option
            v.Initializer = WrapWithCoercionIfNeeded(v.Initializer!, originalInitType, dt.Prune());

            v.ResolvedType = dt;
            DeclareVariable(v.Name, dt, v.Span, v.IsConst);
        }
        else
        {
            // Use declared type if available, otherwise inferred type from initializer
            var varType = dt ?? it;

            if (varType == null)
            {
                // Neither type annotation nor initializer present
                ReportError(
                    "cannot infer type",
                    v.Span,
                    "type annotations needed: variable declaration requires either a type annotation or an initializer",
                    "E2001");
                v.ResolvedType = TypeRegistry.Never;
                DeclareVariable(v.Name, TypeRegistry.Never, v.Span, v.IsConst);
            }
            else
            {
                // No immediate check for IsComptimeType - validation happens in VerifyAllTypesResolved
                v.ResolvedType = varType;
                DeclareVariable(v.Name, varType, v.Span, v.IsConst);
            }
        }
    }

    private void CheckExpressionStatement(ExpressionStatementNode es)
    {
        CheckExpression(es.Expression);
    }

    private void CheckForLoop(ForLoopNode fl)
    {
        PushScope();

        // 1. Resolve iterable expression type
        var iterableType = CheckExpression(fl.IterableExpression);

        // Track if we encountered any errors - if so, skip body checking
        var hadIteratorError = false;

        // 2. Resolve iter(&T) for the iterable type using a synthetic in-memory call
        //    This leverages the normal overload resolution and generic binding machinery.
        if (_functions.TryGetValue("iter", out _))
        {
            // Use a nested scope so the synthetic variable does not leak into the loop body
            PushScope();
            var iterableTempName = "__flang_for_iterable_tmp";
            DeclareVariable(iterableTempName, iterableType, fl.IterableExpression.Span);
            var iterableId = new IdentifierExpressionNode(fl.IterableExpression.Span, iterableTempName);
            var iterableAddr = new AddressOfExpressionNode(fl.IterableExpression.Span, iterableId);
            var iterCall = new CallExpressionNode(fl.Span, "iter", [iterableAddr]);

            // Track diagnostics before the call to detect failures
            var diagnosticsBefore = _diagnostics.Count;
            var iteratorType = CheckExpression(iterCall);
            var diagnosticsAfter = _diagnostics.Count;
            var hadError = diagnosticsAfter > diagnosticsBefore;

            // If iter(&T) failed, type is not iterable
            if (hadError)
            {
                // Check if the error is a resolution failure (E2004/E2011) or a body
                // specialization error. Only replace with E2021 for resolution failures.
                var lastDiagnostic = _diagnostics[^1];
                if (lastDiagnostic.Code == "E2004" || lastDiagnostic.Code == "E2011")
                {
                    _diagnostics.RemoveAt(_diagnostics.Count - 1);

                    var iterableTypeName = FormatTypeNameForDisplay(iterableType);
                    ReportError(
                        $"type `{iterableTypeName}` is not iterable",
                        fl.IterableExpression.Span,
                        $"define `fn iter(&{iterableTypeName})` that returns an iterator state struct type",
                        "E2021");
                }
                PopScope();
                hadIteratorError = true;
            }
            else if (iteratorType is StructType iteratorStruct)
            {
                // 3. Resolve next(&IteratorType) using another synthetic call
                PushScope();
                var iterTempName = "__flang_for_iterator_tmp";
                DeclareVariable(iterTempName, iteratorStruct, fl.Span);
                var iterId = new IdentifierExpressionNode(fl.Span, iterTempName);
                var iterAddr = new AddressOfExpressionNode(fl.Span, iterId);
                var nextCall = new CallExpressionNode(fl.Span, "next", [iterAddr]);

                var diagnosticsBeforeNext = _diagnostics.Count;
                var nextResultType = CheckExpression(nextCall);
                var diagnosticsAfterNext = _diagnostics.Count;
                var hadNextError = diagnosticsAfterNext > diagnosticsBeforeNext;

                // If next(&IteratorType) failed, check what kind of failure:
                // - Resolution failure (no matching function): replace with E2023
                // - Body specialization error (function found but body has type errors):
                //   keep the original errors as they are more informative
                if (hadNextError)
                {
                    // Only replace with E2023 if the function wasn't found at all.
                    // If nextCall.ResolvedTarget is set, the function was resolved but
                    // body specialization had errors - keep those errors as they are
                    // more informative than a generic "no next function" message.
                    var nextWasResolved = nextCall.ResolvedTarget != null;
                    if (!nextWasResolved)
                    {
                        _diagnostics.RemoveAt(_diagnostics.Count - 1);
                        var iteratorStructName = FormatTypeNameForDisplay(iteratorStruct);
                        ReportError(
                            $"iterator state type `{iteratorStructName}` has no `next` function",
                            fl.IterableExpression.Span,
                            $"define `fn next(&{iteratorStructName})` that returns an option type",
                            "E2023");
                    }
                    // else: body errors are already in _diagnostics, keep them
                    PopScope();
                    PopScope();
                    hadIteratorError = true;
                }
                // 4. Validate that next returns an Option[E] and extract element type
                else if (nextResultType is StructType optionStruct && TypeRegistry.IsOption(optionStruct)
                                                                   && optionStruct.TypeArguments.Count > 0)
                {
                    var elementType = optionStruct.TypeArguments[0];
                    // Write iterator protocol types to node
                    fl.IteratorType = iteratorStruct;
                    fl.ElementType = elementType;
                    fl.NextResultOptionType = optionStruct;
                    PopScope();
                    PopScope();
                    // Declare the loop variable with the inferred element type
                    // This must be done AFTER popping the nested scopes so the variable is in the outer for loop scope
                    DeclareVariable(fl.IteratorVariable, elementType, fl.Span);
                }
                else
                {
                    // E2025: next must return an Option type
                    var actualReturnType = FormatTypeNameForDisplay(nextResultType);

                    // Find the next function that was called to get its return type span for the hint
                    SourceSpan? nextReturnTypeSpan = null;
                    if (_functions.TryGetValue("next", out var nextCandidates))
                    {
                        // Find a next function that takes &iteratorStruct
                        foreach (var candidate in nextCandidates)
                        {
                            if (candidate.ParameterTypes.Count == 1 &&
                                candidate.ParameterTypes[0] is ReferenceType reTypeBase &&
                                reTypeBase.InnerType.Equals(iteratorStruct))
                            {
                                // Found the matching next function - get its return type span
                                if (candidate.AstNode.ReturnType != null)
                                {
                                    nextReturnTypeSpan = candidate.AstNode.ReturnType.Span;
                                }

                                break;
                            }
                        }
                    }

                    ReportError(
                        $"`next` function must return an option type, but it returns `{actualReturnType}`",
                        fl.IterableExpression.Span,
                        null, // No inline hint - we'll create a separate hint diagnostic
                        "E2025");

                    // Create a hint diagnostic pointing to the return type if we found it
                    if (nextReturnTypeSpan.HasValue)
                    {
                        _diagnostics.Add(Diagnostic.Hint(
                            $"change return type of `next` to `{actualReturnType}?` or `Option({actualReturnType})`",
                            nextReturnTypeSpan.Value, $"change to `{actualReturnType}?`"));
                    }

                    PopScope();
                    PopScope();
                    hadIteratorError = true;
                }
            }
            else
            {
                // iter was called successfully but returned a non-struct
                // This means iter exists and signature matched, but return type is wrong
                // This is similar to E2023 (missing next), but the issue is that iter returned wrong type
                // Use E2023 as it's the closest match (iterator state issue)
                var actualReturnType = FormatTypeNameForDisplay(iteratorType);

                // Find the iter function that was called to get its return type span for the hint
                SourceSpan? iterReturnTypeSpan = null;
                if (_functions.TryGetValue("iter", out var iterCandidates))
                {
                    // Find an iter function that takes &iterableType
                    foreach (var candidate in iterCandidates)
                    {
                        if (candidate.ParameterTypes.Count == 1 &&
                            candidate.ParameterTypes[0] is ReferenceType reTypeBase &&
                            reTypeBase.InnerType.Equals(iterableType))
                        {
                            // Found the matching iter function - get its return type span
                            if (candidate.AstNode.ReturnType != null)
                            {
                                iterReturnTypeSpan = candidate.AstNode.ReturnType.Span;
                            }

                            break;
                        }
                    }
                }

                ReportError(
                    $"`iter` function must return a struct, but it returns `{actualReturnType}`",
                    fl.Span,
                    null,
                    "E2023");

                // Create a hint diagnostic pointing to the return type if we found it
                if (iterReturnTypeSpan.HasValue)
                {
                    _diagnostics.Add(Diagnostic.Hint(
                        "change to a struct type",
                        iterReturnTypeSpan.Value));
                }

                PopScope();
                hadIteratorError = true;
            }
        }
        else
        {
            // No `iter` function at all; the specific error for this loop is that T is not iterable.
            // E2021: type T is not iterable
            var iterableTypeName = FormatTypeNameForDisplay(iterableType);
            ReportError(
                $"type `{iterableTypeName}` cannot be iterated",
                fl.IterableExpression.Span,
                $"implement the iterator protocol by defining `fn iter(&{iterableTypeName})`",
                "E2021");
            hadIteratorError = true;
        }

        // 5. Type-check loop body with the loop variable in scope (only if iterator setup succeeded)
        if (!hadIteratorError)
        {
            CheckExpression(fl.Body);
        }

        PopScope();
    }

    private void CheckLoop(LoopNode loop)
    {
        // Infinite loop: just type-check the body
        CheckExpression(loop.Body);
    }

    private void CheckDeferStatement(DeferStatementNode ds)
    {
        CheckExpression(ds.Expression);
    }
}
