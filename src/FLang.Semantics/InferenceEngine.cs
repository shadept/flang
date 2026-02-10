using FLang.Core;
using FLang.Core.Types;
using ArrayType = FLang.Core.Types.ArrayType;
using FunctionType = FLang.Core.Types.FunctionType;
using NominalType = FLang.Core.Types.NominalType;
using PrimitiveType = FLang.Core.Types.PrimitiveType;
using ReferenceType = FLang.Core.Types.ReferenceType;
using Type = FLang.Core.Types.Type;
using TypeVar = FLang.Core.Types.TypeVar;

namespace FLang.Semantics;

/// <summary>
/// Result of a unification: the unified type and how many coercions were applied.
/// </summary>
public readonly record struct UnifyResult(Type Type, int Cost);

/// <summary>
/// Coercion rule for the new inference engine.
/// </summary>
public interface IInferenceCoercionRule
{
    /// <summary>
    /// Attempts to coerce from one type to another.
    /// May call back into engine.Unify/engine.Resolve for recursive checks.
    /// Returns the coerced type on success, null on failure.
    /// </summary>
    Type? TryApply(Type from, Type to, InferenceEngine engine);
}

/// <summary>
/// Hindley-Milner type inference engine.
/// Owns the DisjointSet for union-find. Provides Unify, Generalize, Specialize, Zonk.
/// </summary>
public class InferenceEngine : ITypeResolver
{
    private readonly DisjointSet<Type> _unionFind = new();
    private readonly List<IInferenceCoercionRule> _coercionRules = [];
    private readonly List<Diagnostic> _diagnostics = [];
    private int _currentLevel;

    public IReadOnlyList<Diagnostic> Diagnostics => _diagnostics;

    public InferenceEngine()
    {
        _currentLevel = 0;
    }

    /// <summary>
    /// Register a coercion rule.
    /// </summary>
    public void AddCoercionRule(IInferenceCoercionRule rule) => _coercionRules.Add(rule);

    // =========================================================================
    // Level management (for let-generalization)
    // =========================================================================

    public void EnterLevel() => _currentLevel++;
    public void ExitLevel() => _currentLevel--;

    // =========================================================================
    // Fresh variables
    // =========================================================================

    public TypeVar FreshVar() => new(_currentLevel);

    // =========================================================================
    // Resolve — deep-resolve a type through the DisjointSet
    // =========================================================================

    public Type Resolve(Type type)
    {
        return type switch
        {
            TypeVar v => ResolveVar(v),
            FunctionType f => ResolveFunction(f),
            ReferenceType r => new ReferenceType(Resolve(r.InnerType)),
            ArrayType a => new ArrayType(Resolve(a.ElementType), a.Length),
            NominalType n => ResolveNominal(n),
            _ => type // PrimitiveType, PolymorphicType
        };
    }

    private Type ResolveVar(TypeVar v)
    {
        var rep = _unionFind.Find(v);
        if (rep is TypeVar && ReferenceEquals(rep, v)) return v; // unbound
        if (rep is TypeVar tv) return ResolveVar(tv); // chain
        return Resolve(rep); // bound to concrete — resolve it too
    }

    private FunctionType ResolveFunction(FunctionType f)
    {
        var changed = false;
        var resolvedParams = new Type[f.ParameterTypes.Count];
        for (var i = 0; i < f.ParameterTypes.Count; i++)
        {
            resolvedParams[i] = Resolve(f.ParameterTypes[i]);
            if (!ReferenceEquals(resolvedParams[i], f.ParameterTypes[i])) changed = true;
        }

        var resolvedReturn = Resolve(f.ReturnType);
        if (!ReferenceEquals(resolvedReturn, f.ReturnType)) changed = true;
        return changed ? new FunctionType(resolvedParams, resolvedReturn) : f;
    }

    private NominalType ResolveNominal(NominalType n)
    {
        if (n.TypeArguments.Count == 0) return n;
        var changed = false;
        var resolvedArgs = new Type[n.TypeArguments.Count];
        for (var i = 0; i < n.TypeArguments.Count; i++)
        {
            resolvedArgs[i] = Resolve(n.TypeArguments[i]);
            if (!ReferenceEquals(resolvedArgs[i], n.TypeArguments[i])) changed = true;
        }

        return changed ? new NominalType(n.Name, n.Kind, resolvedArgs, n.FieldsOrVariants) : n;
    }

    // =========================================================================
    // Unify
    // =========================================================================

    public UnifyResult Unify(Type a, Type b, SourceSpan span)
    {
        var cost = 0;
        var result = UnifyInternal(a, b, span, ref cost);
        return new UnifyResult(result, cost);
    }

    private Type UnifyInternal(Type a, Type b, SourceSpan span, ref int cost)
    {
        a = Resolve(a);
        b = Resolve(b);

        // Identity
        if (a.Equals(b))
        {
            // NominalType.Equals only checks Name+TypeArguments, not FieldsOrVariants.
            // For anonymous structs with no TypeArguments, also unify field types
            // to resolve TypeVars in field positions (e.g., tuple literals).
            if (!ReferenceEquals(a, b)
                && a is NominalType na2 && b is NominalType nb2
                && na2.TypeArguments.Count == 0
                && na2.FieldsOrVariants.Count == nb2.FieldsOrVariants.Count
                && na2.FieldsOrVariants.Count > 0)
            {
                for (int i = 0; i < na2.FieldsOrVariants.Count; i++)
                    UnifyInternal(na2.FieldsOrVariants[i].Type, nb2.FieldsOrVariants[i].Type, span, ref cost);
            }
            return a;
        }

        // TypeVar binding
        if (a is TypeVar || b is TypeVar)
        {
            // Ensure b is the variable
            if (a is TypeVar)
                (a, b) = (b, a);

            var bVar = (TypeVar)b;
            if (OccursIn(bVar, a))
            {
                ReportError($"Cyclic type: {a} contains {b}", span);
                return a;
            }

            // Merge: concrete type becomes the representative
            _unionFind.Merge(a, b);
            return a;
        }

        // Structural: function types (invariant — no coercion on params or return)
        if (a is FunctionType fa && b is FunctionType fb)
        {
            if (fa.ParameterTypes.Count != fb.ParameterTypes.Count)
            {
                ReportError(
                    $"Function parameter count mismatch: expected {fa.ParameterTypes.Count}, got {fb.ParameterTypes.Count}",
                    span);
                return a;
            }

            var unifiedParams = new Type[fa.ParameterTypes.Count];
            for (var i = 0; i < fa.ParameterTypes.Count; i++)
            {
                int paramCost = 0;
                unifiedParams[i] = UnifyInternal(fa.ParameterTypes[i], fb.ParameterTypes[i], span, ref paramCost);
                if (paramCost > 0)
                {
                    ReportError($"Function parameter type mismatch: `{fa.ParameterTypes[i]}` vs `{fb.ParameterTypes[i]}`", span);
                    return a;
                }
            }
            int retCost = 0;
            var unifiedReturn = UnifyInternal(fa.ReturnType, fb.ReturnType, span, ref retCost);
            if (retCost > 0)
            {
                ReportError($"Function return type mismatch: `{fa.ReturnType}` vs `{fb.ReturnType}`", span);
                return a;
            }
            return new FunctionType(unifiedParams, unifiedReturn);
        }

        // Structural: reference types
        if (a is ReferenceType ra && b is ReferenceType rb)
            return new ReferenceType(UnifyInternal(ra.InnerType, rb.InnerType, span, ref cost));

        // Structural: array types
        if (a is ArrayType aa && b is ArrayType ab)
        {
            if (aa.Length != ab.Length)
            {
                ReportError($"Array length mismatch: expected {aa.Length}, got {ab.Length}", span);
                return a;
            }

            return new ArrayType(UnifyInternal(aa.ElementType, ab.ElementType, span, ref cost), aa.Length);
        }

        // Structural: nominal types (structs, enums, etc.)
        if (a is NominalType na && b is NominalType nb)
        {
            if (na.Name != nb.Name)
                return TryCoerce(a, b, span, ref cost);

            if (na.TypeArguments.Count != nb.TypeArguments.Count)
            {
                ReportError($"Generic arity mismatch for `{na.Name}`", span);
                return a;
            }

            var unifiedArgs = new Type[na.TypeArguments.Count];
            for (var i = 0; i < na.TypeArguments.Count; i++)
                unifiedArgs[i] = UnifyInternal(na.TypeArguments[i], nb.TypeArguments[i], span, ref cost);

            return new NominalType(na.Name, na.Kind, unifiedArgs, na.FieldsOrVariants);
        }

        // Coercion fallback
        return TryCoerce(a, b, span, ref cost);
    }

    private Type TryCoerce(Type a, Type b, SourceSpan span, ref int cost)
    {
        foreach (var rule in _coercionRules)
        {
            var result = rule.TryApply(a, b, this);
            if (result != null)
            {
                cost++;
                return result;
            }

            result = rule.TryApply(b, a, this);
            if (result != null)
            {
                cost++;
                return result;
            }
        }

        ReportError($"Type mismatch: expected `{a}`, got `{b}`", span);
        return a;
    }

    // =========================================================================
    // TryUnify — speculative, always rolls back
    // =========================================================================

    public UnifyResult? TryUnify(Type a, Type b)
    {
        _unionFind.PushCheckpoint();
        var diagCount = _diagnostics.Count;
        try
        {
            var result = Unify(a, b, SourceSpan.None);
            var hadErrors = _diagnostics.Count > diagCount;
            return hadErrors ? null : result;
        }
        catch
        {
            return null;
        }
        finally
        {
            // Remove any diagnostics from speculative unification
            if (_diagnostics.Count > diagCount)
                _diagnostics.RemoveRange(diagCount, _diagnostics.Count - diagCount);

            _unionFind.Rollback();
        }
    }

    // =========================================================================
    // Generalize — quantify TypeVars deeper than current level
    // =========================================================================

    public PolymorphicType Generalize(Type type)
    {
        type = Resolve(type);
        var freeVars = new HashSet<int>();
        CollectFreeVars(type, freeVars);
        return new PolymorphicType(freeVars, type);
    }

    private void CollectFreeVars(Type type, HashSet<int> vars)
    {
        switch (type)
        {
            case TypeVar v:
                if (v.Level > _currentLevel)
                    vars.Add(v.Id);
                break;
            case FunctionType f:
                foreach (var p in f.ParameterTypes) CollectFreeVars(p, vars);
                CollectFreeVars(f.ReturnType, vars);
                break;
            case ReferenceType r:
                CollectFreeVars(r.InnerType, vars);
                break;
            case ArrayType a:
                CollectFreeVars(a.ElementType, vars);
                break;
            case NominalType n:
                foreach (var ta in n.TypeArguments) CollectFreeVars(ta, vars);
                break;
        }
    }

    // =========================================================================
    // Specialize — instantiate a PolymorphicType with fresh TypeVars
    // =========================================================================

    public Type Specialize(PolymorphicType scheme)
    {
        if (scheme.IsMonomorphic)
            return scheme.Body;

        var substitutions = new Dictionary<int, TypeVar>();
        foreach (var id in scheme.QuantifiedVarIds)
            substitutions[id] = FreshVar();

        return Substitute(scheme.Body, substitutions);
    }

    private static Type Substitute(Type type, Dictionary<int, TypeVar> subs)
    {
        return type switch
        {
            TypeVar v => subs.TryGetValue(v.Id, out var replacement) ? replacement : v,
            FunctionType f => new FunctionType([.. f.ParameterTypes.Select(p => Substitute(p, subs))],
                Substitute(f.ReturnType, subs)),
            ReferenceType r => new ReferenceType(Substitute(r.InnerType, subs)),
            ArrayType a => new ArrayType(Substitute(a.ElementType, subs), a.Length),
            NominalType n => n.TypeArguments.Count == 0
                ? n
                : new NominalType(n.Name, n.Kind, [.. n.TypeArguments.Select(ta => Substitute(ta, subs))], n.FieldsOrVariants),
            _ => type
        };
    }

    // =========================================================================
    // Zonk — replace all TypeVars with their resolved concrete types
    // =========================================================================

    /// <summary>
    /// Final pass: resolve all TypeVars to concrete types.
    /// Unresolved TypeVars for integer literals default to isize.
    /// </summary>
    public Type Zonk(Type type)
    {
        return type switch
        {
            TypeVar v => ZonkVar(v),
            FunctionType f => new FunctionType([.. f.ParameterTypes.Select(Zonk)], Zonk(f.ReturnType)),
            ReferenceType r => new ReferenceType(Zonk(r.InnerType)),
            ArrayType a => new ArrayType(Zonk(a.ElementType), a.Length),
            NominalType n => n.TypeArguments.Count == 0
                ? n
                : new NominalType(n.Name, n.Kind, [.. n.TypeArguments.Select(Zonk)], n.FieldsOrVariants),
            PolymorphicType p => new PolymorphicType(p.QuantifiedVarIds, Zonk(p.Body)),
            _ => type
        };
    }

    private Type ZonkVar(TypeVar tv)
    {
        var resolved = Resolve(tv);
        if (resolved is TypeVar)
        {
            ReportError($"Could not infer type for `{tv}`", SourceSpan.None);
            return tv;
        }

        return Zonk(resolved);
    }

    // =========================================================================
    // Occurs check
    // =========================================================================

    private bool OccursIn(TypeVar tv, Type type)
    {
        type = Resolve(type);
        return type switch
        {
            TypeVar other => ReferenceEquals(tv, other),
            FunctionType f => f.ParameterTypes.Any(p => OccursIn(tv, p)) || OccursIn(tv, f.ReturnType),
            ReferenceType r => OccursIn(tv, r.InnerType),
            ArrayType a => OccursIn(tv, a.ElementType),
            NominalType n => n.TypeArguments.Any(ta => OccursIn(tv, ta)),
            _ => false
        };
    }

    // =========================================================================
    // Diagnostics
    // =========================================================================

    private void ReportError(string message, SourceSpan span)
    {
        _diagnostics.Add(Diagnostic.Error(message, span, null, "E2002"));
    }

    public void ClearDiagnostics() => _diagnostics.Clear();
}

/// <summary>
/// Well-known primitive type instances.
/// </summary>
public static class WellKnown
{
    public static readonly PrimitiveType Never = new("never");
    public static readonly PrimitiveType Void = new("void");
    public static readonly PrimitiveType Bool = new("bool");
    public static readonly PrimitiveType I8 = new("i8");
    public static readonly PrimitiveType I16 = new("i16");
    public static readonly PrimitiveType I32 = new("i32");
    public static readonly PrimitiveType I64 = new("i64");
    public static readonly PrimitiveType U8 = new("u8");
    public static readonly PrimitiveType U16 = new("u16");
    public static readonly PrimitiveType U32 = new("u32");
    public static readonly PrimitiveType U64 = new("u64");
    public static readonly PrimitiveType Char = new("char");
    public static readonly PrimitiveType ISize = new("isize");
    public static readonly PrimitiveType USize = new("usize");

    // Well-known nominal type FQNs
    public const string String = "core.string.String";
    public const string Option = "core.option.Option";
    public const string Slice = "core.slice.Slice";
    public const string Range = "core.range.Range";
    public const string TypeInfo = "core.rtti.Type";
    public const string RttiPrefix = "core.rtti.";
}
