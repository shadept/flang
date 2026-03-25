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

        // Check for duplicate overloads (same name + same parameter types)
        // Allow duplicate foreign declarations (extern decls across modules)
        foreach (var existing in overloads)
        {
            if (existing.IsForeign && scheme.IsForeign) continue;
            if (HasSameParameterSignature(existing.Node, scheme.Node))
            {
                reportError(
                    $"duplicate definition of function `{scheme.Name}` with the same parameter types",
                    scheme.Node.NameSpan, "E2103");
                break;
            }
        }

        overloads.Add(scheme);
    }

    public List<FunctionScheme>? Lookup(string name, string? currentModulePath)
    {
        if (!Functions.TryGetValue(name, out var overloads)) return null;

        // Filter out non-public functions from other modules
        if (currentModulePath != null)
        {
            var visible = overloads.Where(f => f.IsPublic || f.ModulePath == currentModulePath).ToList();
            return visible.Count > 0 ? visible : null;
        }

        return overloads;
    }

    /// <summary>
    /// Checks whether two function declarations have the same parameter signature
    /// by comparing their AST type nodes structurally.
    /// </summary>
    private static bool HasSameParameterSignature(FunctionDeclarationNode a, FunctionDeclarationNode b)
    {
        if (a.Parameters.Count != b.Parameters.Count) return false;
        for (var i = 0; i < a.Parameters.Count; i++)
        {
            if (!TypeNodeEquals(a.Parameters[i].Type, b.Parameters[i].Type))
                return false;
        }
        return true;
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
