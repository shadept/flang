using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend.Ast.Types;

namespace FLang.Semantics;

/// <summary>
/// Nominal type declarations collected during phases 1-2.
/// Frozen after ResolveNominalTypes completes.
/// </summary>
internal sealed class TypeRegistry : INominalTypeRegistry
{
    public Dictionary<string, NominalType> NominalTypes { get; } = [];
    public Dictionary<string, SourceSpan> NominalSpans { get; } = [];
    public Dictionary<string, IReadOnlyList<(string Name, TypeNode TypeNode)>> FieldTypeNodes { get; } = [];
    public Dictionary<string, string?> DeprecatedTypes { get; } = [];

    /// <summary>
    /// Look up a nominal type by FQN, module-prefixed name, or short name.
    /// </summary>
    public NominalType? LookupNominalType(string name, string? currentModulePath = null)
    {
        if (NominalTypes.TryGetValue(name, out var type))
            return type;

        // Try with current module prefix
        if (currentModulePath != null)
        {
            var fqn = $"{currentModulePath}.{name}";
            if (NominalTypes.TryGetValue(fqn, out type))
                return type;
        }

        // Try all registered types for short name match
        foreach (var (fqn, nominal) in NominalTypes)
        {
            var shortName = fqn.Contains('.') ? fqn[(fqn.LastIndexOf('.') + 1)..] : fqn;
            if (shortName == name)
                return nominal;
        }

        return null;
    }

    /// <summary>
    /// INominalTypeRegistry implementation — used by TypeLayoutService.
    /// Always does FQN-only lookup (no module context).
    /// </summary>
    NominalType? INominalTypeRegistry.LookupNominalType(string name)
        => LookupNominalType(name);

    public bool Contains(string fqn) => NominalTypes.ContainsKey(fqn);
}
