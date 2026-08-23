using FLang.Core.Types;
using FLang.Frontend.Ast.Types;
using ArrayType = FLang.Core.Types.ArrayType;
using FunctionType = FLang.Core.Types.FunctionType;
using ReferenceType = FLang.Core.Types.ReferenceType;
using Type = FLang.Core.Types.Type;
using TypeRegistry = FLang.Core.TypeRegistry;
using TypeVar = FLang.Core.Types.TypeVar;

namespace FLang.Frontend;

/// <summary>Mirror of <c>core.rtti.TypeKind</c>; values are the runtime discriminants.</summary>
public enum TypeInfoKind { Primitive = 0, Array = 1, Struct = 2, Enum = 3, Function = 4 }

/// <summary>
/// The one shape of <c>core.rtti.TypeInfo</c> inside the compiler (RFC-021 §5).
/// Built from collected declarations for templates (layout unset) and from
/// resolved types for the runtime table (<see cref="Resolved"/> set); both go
/// through <see cref="TypeInfoBuilder"/> so the two views cannot drift.
/// Members are lazy so recursive types terminate.
/// </summary>
public sealed class TypeInfoModel(
    string name,
    TypeInfoKind? kind,
    Func<IReadOnlyList<FieldInfoModel>> fields,
    Func<IReadOnlyList<VariantInfoModel>> variants,
    Func<IReadOnlyList<ParamInfoModel>> parameters,
    Func<TypeInfoModel?> returnType,
    Type? resolved = null)
{
    /// <summary>Spelled type, re-parseable as a type expression (short name for nominals).</summary>
    public string Name { get; } = name;

    /// <summary>Null when the spelled type has no <c>TypeKind</c> (e.g. `&T`, `T?` at template time).</summary>
    public TypeInfoKind? Kind { get; } = kind;

    public IReadOnlyList<FieldInfoModel> Fields => _fields.Value;
    public IReadOnlyList<VariantInfoModel> Variants => _variants.Value;
    public IReadOnlyList<ParamInfoModel> Params => _params.Value;
    public TypeInfoModel? ReturnType => _returnType.Value;

    /// <summary>The resolved type behind a runtime-table entry; null at template time.</summary>
    public Type? Resolved { get; } = resolved;

    private readonly Lazy<IReadOnlyList<FieldInfoModel>> _fields = new(fields);
    private readonly Lazy<IReadOnlyList<VariantInfoModel>> _variants = new(variants);
    private readonly Lazy<IReadOnlyList<ParamInfoModel>> _params = new(parameters);
    private readonly Lazy<TypeInfoModel?> _returnType = new(returnType);
}

public sealed record FieldInfoModel(string Name, TypeInfoModel TypeInfo);
public sealed record VariantInfoModel(string Name);
public sealed record ParamInfoModel(string Name, TypeInfoModel TypeInfo);

public static class TypeInfoBuilder
{
    private static readonly IReadOnlyList<FieldInfoModel> NoFields = [];
    private static readonly IReadOnlyList<VariantInfoModel> NoVariants = [];
    private static readonly IReadOnlyList<ParamInfoModel> NoParams = [];

    // ── Template time: from collected declarations ─────────────────────────

    /// <summary>Lookups the template side needs: nominal by (short or qualified) name, and a nominal's field AST nodes by FQN.</summary>
    public sealed record DeclarationLookup(
        Func<string, NominalType?> Nominal,
        Func<string, IReadOnlyList<(string Name, TypeNode TypeNode)>?> FieldNodes);

    public static TypeInfoModel FromNominalDeclaration(NominalType nominal, DeclarationLookup lookup)
    {
        var kind = nominal.Kind == NominalKind.Enum ? TypeInfoKind.Enum : TypeInfoKind.Struct;
        return new TypeInfoModel(ShortName(nominal.Name), kind,
            fields: () =>
            {
                if (kind == TypeInfoKind.Enum) return NoFields;
                var nodes = lookup.FieldNodes(nominal.Name);
                if (nodes is { Count: > 0 })
                    return nodes.Select(f => new FieldInfoModel(f.Name, FromTypeNode(f.TypeNode, lookup))).ToList();
                return nominal.FieldsOrVariants
                    .Select(f => new FieldInfoModel(f.Name, Spelled(f.Type.ToString()!)))
                    .ToList();
            },
            variants: () =>
            {
                if (kind != TypeInfoKind.Enum) return NoVariants;
                // Before resolution the declared variants live in the field-AST
                // side table; FieldsOrVariants is filled in by ResolveNominalTypes.
                var nodes = lookup.FieldNodes(nominal.Name);
                var names = nodes is { Count: > 0 } ? nodes.Select(v => v.Name) : nominal.FieldsOrVariants.Select(v => v.Name);
                return names.Select(n => new VariantInfoModel(n)).ToList();
            },
            parameters: () => NoParams,
            returnType: () => null);
    }

    public static TypeInfoModel FromTypeNode(TypeNode node, DeclarationLookup lookup)
    {
        switch (node)
        {
            case NamedTypeNode named:
            {
                var nominal = lookup.Nominal(named.Name);
                if (nominal != null) return FromNominalDeclaration(nominal, lookup);
                return TypeRegistry.GetTypeByName(named.Name) != null
                    ? Leaf(named.Name, TypeInfoKind.Primitive)
                    : Spelled(named.Name);
            }
            case AnonymousStructTypeNode anon:
                return new TypeInfoModel(CompileTimeEvaluator.TypeNodeToString(anon), TypeInfoKind.Struct,
                    fields: () => anon.Fields.Select(f => new FieldInfoModel(f.FieldName, FromTypeNode(f.FieldType, lookup))).ToList(),
                    variants: () => NoVariants, parameters: () => NoParams, returnType: () => null);
            case FunctionTypeNode fn:
                return new TypeInfoModel(CompileTimeEvaluator.TypeNodeToString(fn), TypeInfoKind.Function,
                    fields: () => NoFields, variants: () => NoVariants,
                    parameters: () => fn.ParameterTypes.Select((pt, i) =>
                        new ParamInfoModel(fn.ParameterNames.Count > i && fn.ParameterNames[i] != null ? fn.ParameterNames[i]! : $"_{i}",
                            FromTypeNode(pt, lookup))).ToList(),
                    returnType: () => FromTypeNode(fn.ReturnType, lookup));
            case ArrayTypeNode:
                return Leaf(CompileTimeEvaluator.TypeNodeToString(node), TypeInfoKind.Array);
            default:
                return Spelled(CompileTimeEvaluator.TypeNodeToString(node));
        }
    }

    // ── Run time: from resolved types ──────────────────────────────────────

    public static TypeInfoModel FromResolved(Type type, ITypeResolver resolver)
    {
        var t = resolver.Resolve(type);
        Type Strip(Type x)
        {
            var r = resolver.Resolve(x);
            return r is ReferenceType rt ? resolver.Resolve(rt.InnerType) : r;
        }
        TypeInfoModel Sub(Type x) => FromResolved(Strip(x), resolver);

        return t switch
        {
            NominalType { Kind: NominalKind.Enum } e => new TypeInfoModel(e.Name, TypeInfoKind.Enum,
                fields: () => NoFields,
                variants: () => e.FieldsOrVariants.Select(v => new VariantInfoModel(v.Name)).ToList(),
                parameters: () => NoParams, returnType: () => null, resolved: t),
            NominalType s => new TypeInfoModel(s.Name, TypeInfoKind.Struct,
                fields: () => s.FieldsOrVariants
                    .Where(f => Strip(f.Type) is not TypeVar)
                    .Select(f => new FieldInfoModel(f.Name, Sub(f.Type))).ToList(),
                variants: () => NoVariants, parameters: () => NoParams, returnType: () => null, resolved: t),
            FunctionType fn => new TypeInfoModel(
                $"fn({string.Join(", ", fn.ParameterTypes.Select(p => resolver.Resolve(p).ToString()))}) {resolver.Resolve(fn.ReturnType)}",
                TypeInfoKind.Function,
                fields: () => NoFields, variants: () => NoVariants,
                parameters: () => fn.ParameterTypes.Select((p, i) => new ParamInfoModel($"_{i}", Sub(p))).ToList(),
                returnType: () => Strip(fn.ReturnType) is TypeVar ? null : Sub(fn.ReturnType),
                resolved: t),
            ArrayType => Leaf(t.ToString() ?? "unknown", TypeInfoKind.Array, t),
            _ => Leaf(t.ToString() ?? "unknown", TypeInfoKind.Primitive, t),
        };
    }

    // ── helpers ────────────────────────────────────────────────────────────

    private static TypeInfoModel Leaf(string name, TypeInfoKind kind, Type? resolved = null) =>
        new(name, kind, () => NoFields, () => NoVariants, () => NoParams, () => null, resolved);

    /// <summary>A spelled type with no classifiable kind at template time (`&T`, `T?`, `T[]`, unknown names).</summary>
    private static TypeInfoModel Spelled(string name) =>
        new(name, null, () => NoFields, () => NoVariants, () => NoParams, () => null);

    public static string ShortName(string fqn)
    {
        var dot = fqn.LastIndexOf('.');
        return dot >= 0 ? fqn[(dot + 1)..] : fqn;
    }
}
