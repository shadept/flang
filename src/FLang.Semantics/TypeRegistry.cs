using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend.Ast.Types;
using Type = FLang.Core.Types.Type;

namespace FLang.Semantics;

/// <summary>
/// One entry in the type-alias registry. `RhsTypeNode` is the parser
/// AST for the alias body; resolution to a concrete <see cref="Type"/>
/// is lazy (memoised in <see cref="TypeRegistry.ResolvedAliases"/>) so
/// the order of declarations within a module doesn't matter and cross-
/// module aliases work without a topological pre-pass.
/// </summary>
internal sealed record TypeAliasDecl(
    string Fqn,
    string? Module,
    bool IsPublic,
    TypeNode RhsTypeNode,
    SourceSpan NameSpan);

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

    /// <summary>FQN -> alias declaration. Indexed by `<modulePath>.<Name>`.</summary>
    public Dictionary<string, TypeAliasDecl> TypeAliasDecls { get; } = [];

    /// <summary>FQN -> resolved <see cref="Type"/>. Populated lazily on first use.</summary>
    public Dictionary<string, Type> ResolvedAliases { get; } = [];

    /// <summary>
    /// Look up a nominal type by FQN, module-prefixed name, or short name.
    /// When <paramref name="visibleModules"/> is provided, the short-name fallback
    /// only matches types whose defining module is visible to the caller.
    /// FQN-style references (containing a dot) bypass visibility — the whole
    /// point of an FQN is to be unambiguous.
    /// </summary>
    public NominalType? LookupNominalType(string name, string? currentModulePath = null, HashSet<string>? visibleModules = null)
    {
        // Direct FQN hit — always succeeds when the name contains a dot.
        // Visibility scoping only constrains bare-name resolution; an explicit
        // dotted reference is unambiguous and self-authorizing.
        if (NominalTypes.TryGetValue(name, out var type))
            return type;

        // Current-module-prefixed match.
        if (currentModulePath != null)
        {
            var fqn = $"{currentModulePath}.{name}";
            if (NominalTypes.TryGetValue(fqn, out type))
                return type;
        }

        // Short-name fallback. Restrict to types whose module is visible
        // when a visibility set is provided.
        foreach (var (fqn, nominal) in NominalTypes)
        {
            var dot = fqn.LastIndexOf('.');
            var shortName = dot >= 0 ? fqn[(dot + 1)..] : fqn;
            if (shortName != name) continue;

            if (visibleModules == null) return nominal;

            var modulePath = dot >= 0 ? fqn[..dot] : null;
            if (modulePath == null
                || modulePath == currentModulePath
                || visibleModules.Contains(modulePath))
                return nominal;
        }

        return null;
    }

    /// <summary>
    /// Like <see cref="LookupNominalType"/> but ignores visibility scoping.
    /// Used for diagnostics ("type exists in module X but is not imported here").
    /// </summary>
    public NominalType? LookupNominalTypeAny(string name)
        => LookupNominalType(name, currentModulePath: null, visibleModules: null);

    /// <summary>
    /// Look up a type alias declaration by FQN, module-prefixed name, or
    /// short name. Mirrors <see cref="LookupNominalType"/>'s visibility
    /// semantics: short-name matches respect <paramref name="visibleModules"/>;
    /// FQN-style references (containing a dot) bypass visibility.
    /// Returns the alias entry — callers resolve the body via
    /// <see cref="HmTypeChecker.TryResolveTypeAlias(string)"/>.
    /// </summary>
    public TypeAliasDecl? LookupAlias(string name, string? currentModulePath = null, HashSet<string>? visibleModules = null)
    {
        if (TypeAliasDecls.TryGetValue(name, out var direct))
            return direct;

        if (currentModulePath != null)
        {
            var fqn = $"{currentModulePath}.{name}";
            if (TypeAliasDecls.TryGetValue(fqn, out var prefixed))
                return prefixed;
        }

        foreach (var (fqn, entry) in TypeAliasDecls)
        {
            var dot = fqn.LastIndexOf('.');
            var shortName = dot >= 0 ? fqn[(dot + 1)..] : fqn;
            if (shortName != name) continue;

            if (visibleModules == null) return entry;

            var modulePath = dot >= 0 ? fqn[..dot] : null;
            if (modulePath == null
                || modulePath == currentModulePath
                || (entry.IsPublic && visibleModules.Contains(modulePath)))
                return entry;
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
