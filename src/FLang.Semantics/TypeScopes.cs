using FLang.Core.Types;
using Type = FLang.Core.Types.Type;

namespace FLang.Semantics;

/// <summary>
/// Scoped name-to-PolymorphicType mapping for the inference engine.
/// Supports push/pop for function bodies, lambdas.
/// </summary>
public class TypeScopes
{
    private readonly Stack<Dictionary<string, PolymorphicType>> _scopes = new();

    public TypeScopes()
    {
        // Start with a global scope
        _scopes.Push([]);
    }

    public void PushScope() => _scopes.Push([]);

    public void PopScope()
    {
        if (_scopes.Count <= 1)
            throw new InvalidOperationException("Cannot pop the global scope");
        _scopes.Pop();
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
                // If found at a depth <= barrier, it's across the barrier → not accessible
                if (depth <= barrier)
                    return null;
                return type;
            }
            depth--;
        }
        return null;
    }
}
