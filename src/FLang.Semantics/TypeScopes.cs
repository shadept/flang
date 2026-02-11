using FLang.Core.Types;
using FLang.Frontend.Ast;
using Type = FLang.Core.Types.Type;

namespace FLang.Semantics;

/// <summary>
/// Scoped name-to-PolymorphicType mapping for the inference engine.
/// Supports push/pop for function bodies, lambdas.
/// </summary>
public class TypeScopes
{
    private readonly Stack<Dictionary<string, PolymorphicType>> _scopes = new();
    private readonly Stack<Dictionary<string, AstNode>> _declScopes = new();

    public TypeScopes()
    {
        // Start with a global scope
        _scopes.Push([]);
        _declScopes.Push([]);
    }

    public void PushScope()
    {
        _scopes.Push([]);
        _declScopes.Push([]);
    }

    public void PopScope()
    {
        if (_scopes.Count <= 1)
            throw new InvalidOperationException("Cannot pop the global scope");
        _scopes.Pop();
        _declScopes.Pop();
    }

    /// <summary>
    /// Bind a name to a polymorphic type scheme in the current (innermost) scope.
    /// </summary>
    public void Bind(string name, PolymorphicType type)
    {
        _scopes.Peek()[name] = type;
    }

    /// <summary>
    /// Bind a name to a monomorphic type in the current (innermost) scope.
    /// </summary>
    public void Bind(string name, Type type)
    {
        _scopes.Peek()[name] = new PolymorphicType(type);
    }

    /// <summary>
    /// Bind a name to a monomorphic type with its declaration node.
    /// </summary>
    public void Bind(string name, Type type, AstNode declaration)
    {
        _scopes.Peek()[name] = new PolymorphicType(type);
        _declScopes.Peek()[name] = declaration;
    }

    /// <summary>
    /// Bind a name to a polymorphic type scheme with its declaration node.
    /// </summary>
    public void Bind(string name, PolymorphicType type, AstNode declaration)
    {
        _scopes.Peek()[name] = type;
        _declScopes.Peek()[name] = declaration;
    }

    /// <summary>
    /// Current scope depth (number of scopes on the stack).
    /// </summary>
    public int Depth => _scopes.Count;

    /// <summary>
    /// Look up a name, searching from innermost to outermost scope.
    /// Returns null if not found.
    /// </summary>
    public PolymorphicType? Lookup(string name)
    {
        foreach (var scope in _scopes)
        {
            if (scope.TryGetValue(name, out var type))
                return type;
        }
        return null;
    }

    /// <summary>
    /// Look up the declaration node for a name, searching from innermost to outermost scope.
    /// Returns null if no declaration was tracked.
    /// </summary>
    public AstNode? LookupDeclaration(string name)
    {
        foreach (var scope in _declScopes)
        {
            if (scope.TryGetValue(name, out var decl))
                return decl;
        }
        return null;
    }

    /// <summary>
    /// Look up a name with scope barrier. Names found at or below the barrier depth
    /// are treated as not found (for non-capturing lambda enforcement).
    /// barrier == 0 means no barrier.
    /// </summary>
    public PolymorphicType? LookupWithBarrier(string name, int barrier)
    {
        if (barrier <= 0) return Lookup(name);

        int depth = _scopes.Count;
        foreach (var scope in _scopes)
        {
            if (scope.TryGetValue(name, out var type))
            {
                // depth goes from Count (innermost) down to 1 (outermost/global)
                // If found at a depth <= barrier, it's across the barrier -> not accessible
                if (depth <= barrier)
                    return null;
                return type;
            }
            depth--;
        }
        return null;
    }
}
