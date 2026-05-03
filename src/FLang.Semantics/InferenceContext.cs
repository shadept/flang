using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend.Ast.Declarations;
using Type = FLang.Core.Types.Type;

namespace FLang.Semantics;

/// <summary>
/// Transient working state during phase 4 (body checking).
/// Reset or irrelevant between functions.
/// </summary>
internal sealed class InferenceContext
{
    public InferenceEngine Engine { get; }
    public TypeScopes Scopes { get; }

    /// <summary>Parallel scope stack for tracking const-ness of variable declarations.</summary>
    public Stack<HashSet<string>> ConstScopes { get; } = new(new[] { new HashSet<string>() });

    /// <summary>Stack of functions currently being checked (for return type context).</summary>
    public Stack<FunctionContext> FunctionStack { get; } = new();

    /// <summary>Module currently being checked.</summary>
    public string? CurrentModulePath { get; set; }

    /// <summary>
    /// Stack of caller module paths for in-progress generic specializations.
    /// Visibility lookup for symbol resolution unions the current module's
    /// visibility with each entry's visibility, so a generic body can dispatch
    /// to user-defined overloads that the caller imports but the generic's
    /// defining module does not.
    /// </summary>
    public Stack<string> SpecializationCallers { get; } = new();

    /// <summary>True during CheckGenericFunctionBody.</summary>
    public bool IsCheckingGenericBody { get; set; }

    /// <summary>Lambda synthesis counter.</summary>
    public int NextLambdaId { get; set; }

    /// <summary>Scope barrier for non-capturing lambda enforcement.</summary>
    public int LambdaScopeBarrier { get; set; }

    /// <summary>Active generic type parameter names (during specialization).</summary>
    public Dictionary<string, int> ActiveTypeParams { get; } = [];

    /// <summary>Set by ResolveOverload when specialization is deferred.</summary>
    public (FunctionScheme Scheme, Type[] Params, Type Return)? DeferredSpecInfo { get; set; }

    /// <summary>Tracks variable declarations in the current function for unused variable warnings.</summary>
    public Dictionary<string, SourceSpan>? CurrentFnDeclaredVars { get; set; }

    /// <summary>Tracks variable usages in the current function for unused variable warnings.</summary>
    public HashSet<string>? CurrentFnUsedVars { get; set; }

    /// <summary>
    /// Depth of `defer` bodies currently being checked. The postfix `?` operator
    /// (RFC-009) is forbidden inside defer because the early `return` would
    /// short-circuit out of a scope that has already begun unwinding.
    /// </summary>
    public int DeferDepth { get; set; }

    /// <summary>Counter for synthesizing temporary names in `?` desugaring (RFC-009).</summary>
    public int NextTryId { get; set; }

    // Scope management helpers

    public void PushScope()
    {
        Scopes.PushScope();
        ConstScopes.Push([]);
    }

    public void PopScope()
    {
        Scopes.PopScope();
        ConstScopes.Pop();
    }

    public void MarkConst(string name)
    {
        ConstScopes.Peek().Add(name);
    }

    public bool IsConst(string name)
    {
        foreach (var scope in ConstScopes)
        {
            if (scope.Contains(name))
                return true;
        }
        return false;
    }

    public InferenceContext(InferenceEngine engine)
    {
        Engine = engine;
        Scopes = new TypeScopes();
    }
}
