using FLang.Core;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Types;

namespace FLang.Semantics;

/// <summary>
/// Function overload sets collected during phase 3.
/// Frozen after CollectFunctionSignatures completes.
/// </summary>
internal sealed class FunctionRegistry
{
    public Dictionary<string, List<FunctionScheme>> Functions { get; } = [];
    public Dictionary<string, string?> DeprecatedFunctions { get; } = [];

    public void Register(FunctionScheme scheme, Action<string, SourceSpan, string> reportError)
    {
        if (!Functions.TryGetValue(scheme.Name, out var overloads))
        {
            overloads = [];
            Functions[scheme.Name] = overloads;
        }

        // Check for duplicate overloads. The full signature is
        // (parameter types, return type) — overload resolution already
        // considers the return type when picking a candidate, so two
        // functions sharing only parameter types but differing in
        // return type are legitimately distinct (e.g. parallel
        // `from_string(s: String) NodeKind?` / `… TokenKind?` emitted
        // by `#enum_utils`). Allow duplicate foreign declarations
        // (extern decls across modules).
        foreach (var existing in overloads)
        {
            // A duplicate definition is a same-module concern; the same
            // signature in another module is a distinct function, resolved
            // by visibility at the call site, not rejected here.
            if (existing.ModulePath != scheme.ModulePath) continue;
            if (existing.IsForeign && scheme.IsForeign) continue;
            if (HasSameFullSignature(existing.Node, scheme.Node))
            {
                reportError(
                    $"duplicate definition of function `{scheme.Name}` with the same signature",
                    scheme.Node.NameSpan, "E2103");
                break;
            }
        }

        overloads.Add(scheme);
    }

    public List<FunctionScheme>? Lookup(string name, string? currentModulePath, HashSet<string>? visibleModules = null)
    {
        if (!Functions.TryGetValue(name, out var overloads)) return null;

        // No module context: return everything (used by codegen / template expansion).
        if (currentModulePath == null) return overloads;

        // With visibility scoping: function is visible iff defined in the current
        // module, OR public AND its module is in the visible set (direct imports
        // + transitively re-exported `pub import`s).
        if (visibleModules != null)
        {
            var visible = overloads.Where(f =>
                f.ModulePath == currentModulePath
                || (f.IsPublic && f.ModulePath != null && visibleModules.Contains(f.ModulePath))
                || f.ModulePath == null  // synthesized / lambda-host fns are not module-scoped
                || f.IsForeign  // extern C symbols are globally linkable, not module-scoped
            ).ToList();
            return visible.Count > 0 ? visible : null;
        }

        // Fallback: legacy behavior — public-from-anywhere or same-module.
        var fallback = overloads.Where(f => f.IsPublic || f.ModulePath == currentModulePath || f.IsForeign).ToList();
        return fallback.Count > 0 ? fallback : null;
    }

    /// <summary>
    /// Lookup ignoring visibility — returns all overloads regardless of imports.
    /// Used to produce helpful diagnostics ("function exists in module X but is not imported").
    /// </summary>
    public List<FunctionScheme>? LookupAny(string name)
        => Functions.TryGetValue(name, out var overloads) ? overloads : null;

    /// <summary>
    /// Checks whether two function declarations share parameter AND return
    /// type signatures by comparing their AST type nodes structurally.
    /// Return type counts: FLang treats the full signature (params + return)
    /// as the function's identity, so two functions sharing only parameter
    /// types but differing in return type are legitimately distinct
    /// declarations (e.g. parallel `from_string(s: String) E?` emitted by
    /// `#enum_utils` for sibling enums). They register here without error;
    /// call-site disambiguation by expected return type is a separate
    /// concern in <c>ResolveOverload</c> and must be context-driven —
    /// uncontextualised ambiguous calls remain a hard-to-disambiguate
    /// hole today, but registering them is a prerequisite to ever
    /// fixing that.
    /// </summary>
    private static bool HasSameFullSignature(FunctionDeclarationNode a, FunctionDeclarationNode b)
    {
        if (a.Parameters.Count != b.Parameters.Count) return false;
        for (var i = 0; i < a.Parameters.Count; i++)
        {
            if (!TypeNodeEquals(a.Parameters[i].Type, b.Parameters[i].Type))
                return false;
        }
        // A missing return type on either side means "infer / unit" —
        // treat them as equal so the duplicate check still catches the
        // common case of two `fn foo()` declarations with no annotation.
        if (a.ReturnType == null && b.ReturnType == null) return true;
        if (a.ReturnType == null || b.ReturnType == null) return false;
        return TypeNodeEquals(a.ReturnType, b.ReturnType);
    }

    /// <summary>
    /// Structural equality of two AST type nodes.
    /// </summary>
    private static bool TypeNodeEquals(TypeNode a, TypeNode b)
    {
        return (a, b) switch
        {
            (NamedTypeNode na, NamedTypeNode nb) => na.Name == nb.Name,
            (ReferenceTypeNode ra, ReferenceTypeNode rb) => TypeNodeEquals(ra.InnerType, rb.InnerType),
            (NullableTypeNode na, NullableTypeNode nb) => TypeNodeEquals(na.InnerType, nb.InnerType),
            (GenericTypeNode ga, GenericTypeNode gb) =>
                ga.Name == gb.Name
                && ga.TypeArguments.Count == gb.TypeArguments.Count
                && ga.TypeArguments.Zip(gb.TypeArguments).All(p => TypeNodeEquals(p.First, p.Second)),
            (ArrayTypeNode aa, ArrayTypeNode ab) =>
                aa.Length == ab.Length && TypeNodeEquals(aa.ElementType, ab.ElementType),
            (SliceTypeNode sa, SliceTypeNode sb) => TypeNodeEquals(sa.ElementType, sb.ElementType),
            (GenericParameterTypeNode ga, GenericParameterTypeNode gb) => ga.Name == gb.Name,
            (FunctionTypeNode fa, FunctionTypeNode fb) =>
                fa.ParameterTypes.Count == fb.ParameterTypes.Count
                && fa.ParameterTypes.Zip(fb.ParameterTypes).All(p => TypeNodeEquals(p.First, p.Second))
                && TypeNodeEquals(fa.ReturnType, fb.ReturnType),
            (AnonymousStructTypeNode sa, AnonymousStructTypeNode sb) =>
                sa.Fields.Count == sb.Fields.Count
                && sa.Fields.Zip(sb.Fields).All(p => p.First.FieldName == p.Second.FieldName && TypeNodeEquals(p.First.FieldType, p.Second.FieldType)),
            (AnonymousEnumTypeNode ea, AnonymousEnumTypeNode eb) =>
                ea.Variants.Count == eb.Variants.Count
                && ea.Variants.Zip(eb.Variants).All(p =>
                    p.First.Name == p.Second.Name
                    && p.First.PayloadTypes.Count == p.Second.PayloadTypes.Count
                    && p.First.PayloadTypes.Zip(p.Second.PayloadTypes).All(q => TypeNodeEquals(q.First, q.Second))),
            _ => false
        };
    }
}
