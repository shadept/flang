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

    // Primitive-name candidate sets keyed by TypeVar.Id. A TypeVar registered
    // here can only unify with a PrimitiveType whose name is in the set, or
    // with another TypeVar (whose constraint then becomes the intersection).
    // Used to narrow char literals (codepoint 0-255) to `{u8, char}` so they
    // can't accidentally bind to `String` etc. during overload resolution.
    private readonly Dictionary<int, HashSet<string>> _primConstraints = [];

    // Undo log for TryUnify's checkpoint/rollback. Each checkpoint records the
    // set of constraint-dict mutations performed since it was pushed so they
    // can be rewound when the speculative region is discarded.
    private readonly Stack<List<ConstraintUndo>> _constraintUndoStack = new();
    private readonly record struct ConstraintUndo(int Id, HashSet<string>? OldValue);

    // Scoped error override — set via OverrideErrors()
    private string? _errorCodeOverride;
    private Func<string>? _errorMessageTemplate;

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

    /// <summary>
    /// Allocates a fresh TypeVar that may only be bound to a PrimitiveType
    /// whose name is in <paramref name="allowedPrimitives"/>. Attempts to
    /// unify against any other concrete type fail.
    /// </summary>
    public TypeVar FreshConstrainedVar(HashSet<string> allowedPrimitives)
    {
        var v = FreshVar();
        _primConstraints[v.Id] = allowedPrimitives;
        return v;
    }

    /// <summary>
    /// Returns the primitive-name candidate set bound to the representative of
    /// <paramref name="v"/>, or null if unconstrained.
    /// </summary>
    private HashSet<string>? GetConstraint(TypeVar v)
    {
        var rep = _unionFind.Find(v);
        if (rep is TypeVar tv && _primConstraints.TryGetValue(tv.Id, out var set))
            return set;
        return null;
    }

    private void SetConstraint(int id, HashSet<string>? value)
    {
        _primConstraints.TryGetValue(id, out var old);
        if (_constraintUndoStack.Count > 0)
            _constraintUndoStack.Peek().Add(new ConstraintUndo(id, old));
        if (value == null) _primConstraints.Remove(id);
        else _primConstraints[id] = value;
    }

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
        // Anonymous types (tuples, anon structs) carry structure in FieldsOrVariants;
        // resolve those too so bound TypeVars in field positions surface concrete types.
        var isAnon = n.Name.StartsWith("__anon_") && n.FieldsOrVariants.Count > 0;

        if (n.TypeArguments.Count == 0 && !isAnon) return n;

        var changed = false;
        var resolvedArgs = new Type[n.TypeArguments.Count];
        for (var i = 0; i < n.TypeArguments.Count; i++)
        {
            resolvedArgs[i] = Resolve(n.TypeArguments[i]);
            if (!ReferenceEquals(resolvedArgs[i], n.TypeArguments[i])) changed = true;
        }

        var resolvedFields = n.FieldsOrVariants;
        if (isAnon)
        {
            var newFields = new (string, Type)[n.FieldsOrVariants.Count];
            for (var i = 0; i < n.FieldsOrVariants.Count; i++)
            {
                var resolvedFieldType = Resolve(n.FieldsOrVariants[i].Type);
                newFields[i] = (n.FieldsOrVariants[i].Name, resolvedFieldType);
                if (!ReferenceEquals(resolvedFieldType, n.FieldsOrVariants[i].Type)) changed = true;
            }
            resolvedFields = newFields;
        }

        return changed ? new NominalType(n.Name, n.Kind, resolvedArgs, resolvedFields, n.IsSimd, n.IsForeign) : n;
    }

    // =========================================================================
    // Unify
    // =========================================================================

    /// <summary>
    /// Unify two types under a directional convention: <paramref name="actual"/>
    /// flows into <paramref name="expected"/>. Coercion rules are tried in the
    /// <c>actual → expected</c> direction only. This mirrors how integer
    /// widening is meant to work (i32 → i64 implicit, i64 → i32 rejected) and
    /// applies the same model uniformly to T → Option(T) wrapping and every
    /// other implicit conversion.
    ///
    /// Callers that need a genuinely symmetric "find a common type" operation
    /// — match-arm join, if/else branch join — must use <see cref="UnifyJoin"/>.
    /// </summary>
    public UnifyResult Unify(Type actual, Type expected, SourceSpan span)
    {
        var cost = 0;
        var result = UnifyInternal(actual, expected, span, ref cost, directional: true);
        return new UnifyResult(result, cost);
    }

    /// <summary>
    /// Symmetric unification for join contexts (if/else branches, match arm
    /// bodies). Coercion rules are tried in both directions, so a `T` branch
    /// and an `Option(T)` branch settle on `Option(T)` regardless of branch
    /// order. Use only when neither side is "the slot" — for value→slot flow
    /// use <see cref="Unify"/> instead.
    /// </summary>
    public UnifyResult UnifyJoin(Type a, Type b, SourceSpan span)
    {
        var cost = 0;
        var result = UnifyInternal(a, b, span, ref cost, directional: false);
        return new UnifyResult(result, cost);
    }

    private Type UnifyInternal(Type a, Type b, SourceSpan span, ref int cost, bool directional = true)
    {
        a = Resolve(a);
        b = Resolve(b);

        // Bottom type: never unifies with any type T, resolving to T
        if (a.Equals(WellKnown.Never)) return b;
        if (b.Equals(WellKnown.Never)) return a;

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

            // Constraint check: if bVar (or another var in the merged group)
            // carries a primitive-name candidate set, the value it binds to
            // must respect it.
            var bCons = GetConstraint(bVar);
            if (a is TypeVar aVar)
            {
                // TypeVar-TypeVar: intersect any existing constraints.
                var aCons = GetConstraint(aVar);
                HashSet<string>? merged;
                if (aCons == null && bCons == null) merged = null;
                else if (aCons == null) merged = bCons;
                else if (bCons == null) merged = aCons;
                else
                {
                    merged = [.. aCons];
                    merged.IntersectWith(bCons);
                    if (merged.Count == 0)
                    {
                        ReportError(
                            $"Type mismatch: incompatible primitive constraints `{FormatConstraint(aCons)}` and `{FormatConstraint(bCons)}`",
                            span, expected: b, actual: a);
                        return a;
                    }
                }

                _unionFind.Merge(a, b);
                // After merge, `a` is the rep. Move the merged constraint there
                // and clear bVar's entry so we don't carry two copies.
                if (merged != null) SetConstraint(aVar.Id, merged);
                else if (aCons != null) SetConstraint(aVar.Id, null);
                if (bCons != null) SetConstraint(bVar.Id, null);
                return a;
            }

            // Concrete `a` into possibly-constrained `bVar`.
            if (bCons != null)
            {
                if (a is PrimitiveType prim)
                {
                    if (!bCons.Contains(prim.Name))
                    {
                        ReportError(
                            $"Type mismatch: expected one of `{FormatConstraint(bCons)}`, got `{prim.Name}`",
                            span, expected: b, actual: a);
                        return a;
                    }
                }
                else
                {
                    ReportError(
                        $"Type mismatch: expected one of `{FormatConstraint(bCons)}`, got `{a}`",
                        span, expected: b, actual: a);
                    return a;
                }
                // Constraint discharged — drop entry to keep the dict bounded.
                SetConstraint(bVar.Id, null);
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
                    $"Function parameter count mismatch: expected {fb.ParameterTypes.Count}, got {fa.ParameterTypes.Count}",
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
                ReportError($"Array length mismatch: expected {ab.Length}, got {aa.Length}", span);
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

            // For anonymous types, also unify field/variant types to catch structural
            // mismatches (e.g. (i64, usize) vs (u64, usize) which share the name __anon__0__1).
            if (na.Name.StartsWith("__anon_")
                && na.FieldsOrVariants.Count > 0
                && na.FieldsOrVariants.Count == nb.FieldsOrVariants.Count)
            {
                for (var i = 0; i < na.FieldsOrVariants.Count; i++)
                    UnifyInternal(na.FieldsOrVariants[i].Type, nb.FieldsOrVariants[i].Type, span, ref cost);
            }

            return new NominalType(na.Name, na.Kind, unifiedArgs, na.FieldsOrVariants, na.IsSimd, na.IsForeign);
        }

        // Coercion fallback
        return TryCoerce(a, b, span, ref cost, directional);
    }

    private Type TryCoerce(Type a, Type b, SourceSpan span, ref int cost, bool directional = false)
    {
        foreach (var rule in _coercionRules)
        {
            // In directional mode `a` is the "from" (actual value) and `b` is
            // the "to" (expected slot). Skip the reverse direction so widening
            // rules like `T → Option(T)` can't be applied backwards to mask a
            // mismatch when the value is actually wider than the slot.
            var result = rule.TryApply(a, b, this);
            if (result != null)
            {
                cost++;
                return result;
            }

            if (!directional)
            {
                result = rule.TryApply(b, a, this);
                if (result != null)
                {
                    cost++;
                    return result;
                }
            }
        }

        ReportError($"Type mismatch: expected `{b}`, got `{a}`", span, expected: b, actual: a);
        return b;
    }

    // =========================================================================
    // TryUnify — speculative, always rolls back
    // =========================================================================

    public UnifyResult? TryUnify(Type a, Type b)
    {
        _unionFind.PushCheckpoint();
        _constraintUndoStack.Push([]);
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

            // Rewind constraint-dict mutations recorded since the checkpoint
            var undo = _constraintUndoStack.Pop();
            for (var i = undo.Count - 1; i >= 0; i--)
            {
                var entry = undo[i];
                if (entry.OldValue == null) _primConstraints.Remove(entry.Id);
                else _primConstraints[entry.Id] = entry.OldValue;
            }
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
                // Anonymous types (tuples, anon structs) carry their structure in
                // FieldsOrVariants, so TypeVars in field positions must also be generalized.
                if (n.Name.StartsWith("__anon_") && n.FieldsOrVariants.Count > 0)
                    foreach (var f in n.FieldsOrVariants) CollectFreeVars(f.Type, vars);
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

    /// <summary>
    /// Like Specialize, but also returns the mapping from old quantified var IDs to new TypeVar IDs.
    /// Used by the LSP to map TypeVars back to generic parameter names.
    /// </summary>
    public Type Specialize(PolymorphicType scheme, out Dictionary<int, TypeVar> substitutions)
    {
        substitutions = [];
        if (scheme.IsMonomorphic)
            return scheme.Body;

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
            NominalType n => SubstituteNominal(n, subs),
            _ => type
        };
    }

    private static NominalType SubstituteNominal(NominalType n, Dictionary<int, TypeVar> subs)
    {
        // Anonymous types (tuples, anon structs) carry their structure in FieldsOrVariants,
        // not in TypeArguments. Specialize must descend into those fields so each instantiation
        // of a generic tuple signature gets fresh TypeVars.
        if (n.Name.StartsWith("__anon_") && n.FieldsOrVariants.Count > 0)
        {
            var newFields = new (string, Type)[n.FieldsOrVariants.Count];
            for (var i = 0; i < n.FieldsOrVariants.Count; i++)
                newFields[i] = (n.FieldsOrVariants[i].Name, Substitute(n.FieldsOrVariants[i].Type, subs));
            return new NominalType(n.Name, n.Kind, n.TypeArguments, newFields, n.IsSimd, n.IsForeign);
        }

        if (n.TypeArguments.Count == 0)
            return n;

        return new NominalType(n.Name, n.Kind, [.. n.TypeArguments.Select(ta => Substitute(ta, subs))],
            n.FieldsOrVariants, n.IsSimd, n.IsForeign);
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
            NominalType n => ZonkNominal(n),
            PolymorphicType p => new PolymorphicType(p.QuantifiedVarIds, Zonk(p.Body)),
            _ => type
        };
    }

    private NominalType ZonkNominal(NominalType n)
    {
        // Anonymous types carry structure in FieldsOrVariants — zonk those too so TypeVars
        // resolve to their concrete bindings (mirrors Substitute for consistency).
        if (n.Name.StartsWith("__anon_") && n.FieldsOrVariants.Count > 0)
        {
            var newFields = new (string, Type)[n.FieldsOrVariants.Count];
            for (var i = 0; i < n.FieldsOrVariants.Count; i++)
                newFields[i] = (n.FieldsOrVariants[i].Name, Zonk(n.FieldsOrVariants[i].Type));
            return new NominalType(n.Name, n.Kind, n.TypeArguments, newFields, n.IsSimd, n.IsForeign);
        }

        if (n.TypeArguments.Count == 0)
            return n;

        return new NominalType(n.Name, n.Kind, [.. n.TypeArguments.Select(Zonk)], n.FieldsOrVariants, n.IsSimd, n.IsForeign);
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
    // Constraint formatting
    // =========================================================================

    private static string FormatConstraint(HashSet<string> set)
    {
        // Stable ordering so error text is deterministic across runs.
        var sorted = new List<string>(set);
        sorted.Sort(StringComparer.Ordinal);
        return string.Join(" | ", sorted);
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

    private void ReportError(string message, SourceSpan span, Type? expected = null, Type? actual = null)
    {
        var code = _errorCodeOverride ?? "E2002";
        var msg = message;
        if (_errorMessageTemplate != null && expected != null && actual != null)
            msg = _errorMessageTemplate()
                .Replace("{expected}", expected.ToString())
                .Replace("{actual}", actual.ToString());
        _diagnostics.Add(Diagnostic.Error(msg, span, null, code));
    }

    /// <summary>
    /// Returns a scope that overrides the error code and optionally the message
    /// for all unification errors reported within it.
    /// The template may use {expected} and {actual} placeholders for the types.
    /// </summary>
    public ErrorOverrideScope OverrideErrors(string errorCode, Func<string>? messageTemplate = null)
    {
        var prevCode = _errorCodeOverride;
        var prevTemplate = _errorMessageTemplate;
        _errorCodeOverride = errorCode;
        _errorMessageTemplate = messageTemplate;
        return new ErrorOverrideScope(this, prevCode, prevTemplate);
    }

    public readonly struct ErrorOverrideScope(
        InferenceEngine engine,
        string? prevCode,
        Func<string>? prevTemplate) : IDisposable
    {
        public void Dispose()
        {
            engine._errorCodeOverride = prevCode;
            engine._errorMessageTemplate = prevTemplate;
        }
    }

    public void ClearDiagnostics() => _diagnostics.Clear();
    public int DiagnosticCount => _diagnostics.Count;
    public Diagnostic GetDiagnostic(int index) => _diagnostics[index];
    public void AddDiagnostic(Diagnostic diag) => _diagnostics.Add(diag);
    public void TruncateDiagnostics(int count) => _diagnostics.RemoveRange(count, _diagnostics.Count - count);
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
    public static readonly PrimitiveType F32 = new("f32");
    public static readonly PrimitiveType F64 = new("f64");

    // Well-known nominal type FQNs
    public const string String = "core.string.String";
    public const string Option = "core.option.Option";
    public const string TryResult = "core.try.TryResult";
    public const string Slice = "core.slice.Slice";
    public const string Range = "core.range.Range";
    public const string TypeInfo = "core.rtti.Type";
    public const string RttiPrefix = "core.rtti.";

    // Built-in project metadata intrinsic — lowering replaces calls to
    // `project_info()` with a struct constant for the call site's project.
    public const string ProjectInfo = "core.rtti.ProjectInfo";
    public const string ProjectInfoFn = "project_info";
    public const string RttiModulePath = "core.rtti";
}
