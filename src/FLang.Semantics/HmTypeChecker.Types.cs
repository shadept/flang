using FLang.Core.Types;
using FLang.Frontend.Ast.Types;
using Type = FLang.Core.Types.Type;

namespace FLang.Semantics;

public partial class HmTypeChecker
{
    /// <summary>
    /// Resolve a parser TypeNode to an inference Type.
    /// </summary>
    private Type ResolveTypeNode(TypeNode typeNode)
    {
        return typeNode switch
        {
            NamedTypeNode named => ResolveNamedType(named),
            ReferenceTypeNode refType => ResolveReferenceType(refType),
            NullableTypeNode nullable => ResolveNullableType(nullable),
            GenericTypeNode generic => ResolveGenericType(generic),
            ArrayTypeNode array => new ArrayType(ResolveTypeNode(array.ElementType), array.Length),
            SliceTypeNode slice => ResolveSliceType(slice),
            GenericParameterTypeNode genParam => ResolveGenericParam(genParam),
            FunctionTypeNode fnType => new FunctionType([.. fnType.ParameterTypes.Select(ResolveTypeNode)], ResolveTypeNode(fnType.ReturnType)),
            AnonymousStructTypeNode anonStruct => ResolveAnonymousStructType(anonStruct),
            _ => throw new NotSupportedException($"Unknown TypeNode: {typeNode.GetType().Name}")
        };
    }

    private Type ResolveReferenceType(ReferenceTypeNode refType)
    {
        var inner = ResolveTypeNode(refType.InnerType);
        // E2006: Cannot create reference to function type (already pointer-sized)
        if (inner is FunctionType)
        {
            ReportError("Cannot create reference to function type", refType.Span, "E2006");
            return inner; // Return the function type directly
        }
        return new ReferenceType(inner);
    }

    private Type ResolveNamedType(NamedTypeNode named)
    {
        // Built-in primitives
        var primitive = ResolvePrimitive(named.Name);
        if (primitive != null)
            return primitive;

        // Look up nominal type (struct/enum)
        var nominal = LookupNominalType(named.Name);
        if (nominal != null)
            return nominal;

        // Check scope for type parameters (bare T from generic context)
        var scheme = _scopes.Lookup(named.Name);
        if (scheme != null)
            return _engine.Specialize(scheme);

        ReportError($"Unknown type `{named.Name}`", named.Span, "E2003");
        return _engine.FreshVar();
    }

    private static PrimitiveType? ResolvePrimitive(string name)
    {
        return name switch
        {
            "never" => WellKnown.Never,
            "void" => WellKnown.Void,
            "i8" => WellKnown.I8,
            "i16" => WellKnown.I16,
            "i32" => WellKnown.I32,
            "i64" => WellKnown.I64,
            "isize" => WellKnown.ISize,
            "u8" => WellKnown.U8,
            "u16" => WellKnown.U16,
            "u32" => WellKnown.U32,
            "u64" => WellKnown.U64,
            "usize" => WellKnown.USize,
            "bool" => WellKnown.Bool,
            "char" => WellKnown.Char,
            _ => null
        };
    }

    private NominalType ResolveNullableType(NullableTypeNode nullable)
    {
        var innerType = ResolveTypeNode(nullable.InnerType);
        var option = LookupNominalType(WellKnown.Option)
            ?? throw new InvalidOperationException($"Well-known type `{WellKnown.Option}` not registered");
        return new NominalType(option.Name, option.Kind, [innerType], option.FieldsOrVariants);
    }

    private NominalType ResolveSliceType(SliceTypeNode slice)
    {
        var elementType = ResolveTypeNode(slice.ElementType);
        var sliceNominal = LookupNominalType(WellKnown.Slice)
            ?? throw new InvalidOperationException($"Well-known type `{WellKnown.Slice}` not registered");
        return new NominalType(sliceNominal.Name, sliceNominal.Kind, [elementType], sliceNominal.FieldsOrVariants);
    }

    private Type ResolveGenericType(GenericTypeNode generic)
    {
        var typeArgs = generic.TypeArguments.Select(ResolveTypeNode).ToArray();

        var nominal = LookupNominalType(generic.Name);
        if (nominal != null)
            return new NominalType(nominal.Name, nominal.Kind, typeArgs, nominal.FieldsOrVariants);

        ReportError($"Unknown generic type `{generic.Name}`", generic.Span, "E2003");
        return _engine.FreshVar();
    }

    private Type ResolveGenericParam(GenericParameterTypeNode genParam)
    {
        // Generic parameters should be bound in scope as TypeVars during fn signature collection
        var scheme = _scopes.Lookup(genParam.Name);
        if (scheme != null)
            return scheme.Body;

        ReportError($"Unbound generic parameter `{genParam.Name}`", genParam.Span, "E2003");
        return _engine.FreshVar();
    }

    private NominalType ResolveAnonymousStructType(AnonymousStructTypeNode anonStruct)
    {
        var fields = anonStruct.Fields
            .Select(f => (f.FieldName, Type: ResolveTypeNode(f.FieldType)))
            .ToArray();

        // Anonymous structs get a synthetic name based on field structure
        var name = $"__anon_{string.Join("_", fields.Select(f => f.FieldName))}";
        return new NominalType(name, NominalKind.Struct, [], fields);
    }

    // =========================================================================
    // Type argument substitution
    // =========================================================================

    /// <summary>
    /// Substitute template TypeVars with concrete type arguments in a type.
    /// Used when accessing fields of generic nominal types.
    /// </summary>
    private Type SubstituteTypeArgs(Type type, IReadOnlyList<Type> templateArgs, IReadOnlyList<Type> instanceArgs)
    {
        // Build substitution map: template TypeVar Id → instance type
        var substMap = new Dictionary<int, Type>();
        for (int i = 0; i < templateArgs.Count && i < instanceArgs.Count; i++)
        {
            if (templateArgs[i] is TypeVar tv)
                substMap[tv.Id] = instanceArgs[i];
        }

        if (substMap.Count == 0) return type;
        return SubstituteTypeVars(type, substMap);
    }

    private Type SubstituteTypeVars(Type type, Dictionary<int, Type> substMap)
    {
        var resolved = _engine.Resolve(type);

        return resolved switch
        {
            TypeVar tv when substMap.TryGetValue(tv.Id, out var replacement) => replacement,
            TypeVar => resolved,
            PrimitiveType => resolved,
            ReferenceType refType => new ReferenceType(SubstituteTypeVars(refType.InnerType, substMap)),
            ArrayType arrType => new ArrayType(SubstituteTypeVars(arrType.ElementType, substMap), arrType.Length),
            FunctionType fnType => new FunctionType(
                fnType.ParameterTypes.Select(p => SubstituteTypeVars(p, substMap)).ToArray(),
                SubstituteTypeVars(fnType.ReturnType, substMap)),
            // Don't substitute into FieldsOrVariants — they can be self-referential.
            // Field substitution happens lazily in ResolveFieldAccess.
            NominalType nominal => new NominalType(
                nominal.Name,
                nominal.Kind,
                nominal.TypeArguments.Select(a => SubstituteTypeVars(a, substMap)).ToArray(),
                nominal.FieldsOrVariants),
            _ => resolved
        };
    }
}
