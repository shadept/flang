using System.Text;
using FLang.Core.Types;
using Type = FLang.Core.Types.Type;

namespace FLang.IR;

/// <summary>
/// Converts HM Type to IrType with pre-computed layout (size, alignment, offsets).
/// Caches results to ensure the same HM Type always produces the same IrType instance.
/// </summary>
public class TypeLayoutService
{
    private readonly Dictionary<string, IrType> _cache = [];
    private readonly ITypeResolver _engine;
    private readonly INominalTypeRegistry _nominalTypes;

    public TypeLayoutService(ITypeResolver engine, INominalTypeRegistry nominalTypes)
    {
        _engine = engine;
        _nominalTypes = nominalTypes;
    }

    // Well-known IrType primitives (cached singletons)
    public static readonly IrPrimitive IrVoidPrim = new("void", 0, 1);
    public static readonly IrPrimitive IrNeverPrim = new("never", 0, 1);
    public static readonly IrPrimitive IrBool = new("bool", 1, 1);
    public static readonly IrPrimitive IrI8 = new("i8", 1, 1);
    public static readonly IrPrimitive IrI16 = new("i16", 2, 2);
    public static readonly IrPrimitive IrI32 = new("i32", 4, 4);
    public static readonly IrPrimitive IrI64 = new("i64", 8, 8);
    public static readonly IrPrimitive IrU8 = new("u8", 1, 1);
    public static readonly IrPrimitive IrU16 = new("u16", 2, 2);
    public static readonly IrPrimitive IrU32 = new("u32", 4, 4);
    public static readonly IrPrimitive IrU64 = new("u64", 8, 8);
    public static readonly IrPrimitive IrISize = new("isize", 8, 8);
    public static readonly IrPrimitive IrUSize = new("usize", 8, 8);
    public static readonly IrPrimitive IrChar = new("char", 4, 4);

    private static readonly Dictionary<string, IrPrimitive> PrimitiveLookup = new()
    {
        ["void"] = IrVoidPrim,
        ["never"] = IrNeverPrim,
        ["bool"] = IrBool,
        ["i8"] = IrI8,
        ["i16"] = IrI16,
        ["i32"] = IrI32,
        ["i64"] = IrI64,
        ["u8"] = IrU8,
        ["u16"] = IrU16,
        ["u32"] = IrU32,
        ["u64"] = IrU64,
        ["isize"] = IrISize,
        ["usize"] = IrUSize,
        ["char"] = IrChar,
    };

    /// <summary>
    /// Lower an HM Type to an IrType with fully computed layout.
    /// The type should be fully resolved/zonked before calling this.
    /// </summary>
    public IrType Lower(Type hmType)
    {
        var resolved = _engine.Resolve(hmType);
        return LowerResolved(resolved);
    }

    private IrType LowerResolved(Type type)
    {
        switch (type)
        {
            case PrimitiveType pt:
                return LowerPrimitive(pt);

            case ReferenceType rt:
                return new IrPointer(LowerResolved(rt.InnerType));

            case ArrayType at:
                return new IrArray(LowerResolved(at.ElementType), at.Length);

            case FunctionType ft:
                var paramTypes = new IrType[ft.ParameterTypes.Count];
                for (var i = 0; i < ft.ParameterTypes.Count; i++)
                    paramTypes[i] = LowerResolved(ft.ParameterTypes[i]);
                return new IrFunctionPtr(paramTypes, LowerResolved(ft.ReturnType));

            case NominalType nt:
                return LowerNominal(nt);

            case TypeVar tv:
                // Unresolved type variable — default to i32 (unsuffixed integer literals)
                return IrI32;

            default:
                return IrVoidPrim;
        }
    }

    private static IrPrimitive LowerPrimitive(PrimitiveType pt)
    {
        return PrimitiveLookup.TryGetValue(pt.Name, out var irPrim) ? irPrim : IrVoidPrim;
    }

    private IrType LowerNominal(NominalType nt)
    {
        // Build cache key from the CONCRETE type (nt), not the template
        var cacheKey = BuildCacheKey(nt);
        if (_cache.TryGetValue(cacheKey, out var cached))
            return cached;

        // Niche optimization: Option[&T] → IrPointer(T, IsNullable: true)
        // Only applies when the type argument is a reference/pointer type.
        if (nt.Name == "core.option.Option" && nt.TypeArguments.Count == 1)
        {
            var innerResolved = _engine.Resolve(nt.TypeArguments[0]);
            if (innerResolved is ReferenceType)
            {
                var innerIr = LowerResolved(innerResolved);
                if (innerIr is IrPointer innerPtr)
                {
                    var nicheType = new IrPointer(innerPtr.Pointee, IsNullable: true);
                    _cache[cacheKey] = nicheType;
                    return nicheType;
                }
            }
        }

        // Produce a concrete NominalType with fields populated from the template.
        // Generic types carry template FieldsOrVariants (with TypeVars) — we must
        // always substitute those TypeVars with the concrete type arguments.
        var concrete = nt;

        if (nt.TypeArguments.Count > 0)
        {
            // If any type argument is still an unresolved TypeVar, this is a generic
            // template definition — skip it, it should never be emitted as concrete C code.
            foreach (var ta in nt.TypeArguments)
            {
                if (_engine.Resolve(ta) is TypeVar)
                    return IrVoidPrim;
            }

            // Look up the template to get the TypeVar → type-arg mapping
            var template = _nominalTypes.LookupNominalType(nt.Name);
            if (template != null && template.TypeArguments.Count == nt.TypeArguments.Count)
            {
                // Build substitution: template TypeVar id → concrete type arg
                var subst = new Dictionary<int, Type>();
                for (int i = 0; i < template.TypeArguments.Count; i++)
                {
                    var templateArg = _engine.Resolve(template.TypeArguments[i]);
                    if (templateArg is TypeVar tv)
                        subst[tv.Id] = _engine.Resolve(nt.TypeArguments[i]);
                }

                // Use template's fields (the canonical source) and substitute TypeVars
                var sourceFields = template.FieldsOrVariants.Count > 0
                    ? template.FieldsOrVariants
                    : nt.FieldsOrVariants;

                if (subst.Count > 0 && sourceFields.Count > 0)
                {
                    var concreteFields = new List<(string Name, Type Type)>();
                    foreach (var (fname, ftype) in sourceFields)
                        concreteFields.Add((fname, SubstituteTypeArgs(_engine.Resolve(ftype), subst)));

                    concrete = new NominalType(nt.Name, template.Kind, nt.TypeArguments, concreteFields);
                }
            }
        }
        else if (nt.FieldsOrVariants.Count == 0)
        {
            // Non-generic type with no fields — look up the template definition
            var template = _nominalTypes.LookupNominalType(nt.Name);
            if (template != null && template.FieldsOrVariants.Count > 0)
                concrete = template;
        }

        // Pre-register a stub to break recursive cycles (self-referencing types via pointers).
        // LowerStruct/LowerEnum will produce the real result and we update the cache.
        // Use the cache key for the CName so each specialization gets a unique C identifier.
        var cName = SanitizeCName(cacheKey);
        IrType stub;
        if (concrete.Kind == NominalKind.Enum)
            stub = new IrEnum(concrete.Name, cName, 4, [], 4, 4);
        else
            stub = new IrStruct(concrete.Name, cName, [], 0, 1);
        _cache[cacheKey] = stub;

        IrType result;
        if (concrete.Kind == NominalKind.Enum)
            result = LowerEnum(concrete, cacheKey, cName);
        else
            result = LowerStruct(concrete, cacheKey, cName);

        _cache[cacheKey] = result;
        return result;
    }

    private IrStruct LowerStruct(NominalType nt, string cacheKey, string cName)
    {
        if (nt.FieldsOrVariants.Count == 0)
        {
            return new IrStruct(nt.Name, cName, [], 0, 1);
        }

        var fields = new IrField[nt.FieldsOrVariants.Count];
        int offset = 0;
        int maxAlignment = 1;

        for (int i = 0; i < nt.FieldsOrVariants.Count; i++)
        {
            var (name, fieldHmType) = nt.FieldsOrVariants[i];
            var fieldIrType = LowerResolved(_engine.Resolve(fieldHmType));
            var alignment = fieldIrType.Alignment;
            maxAlignment = Math.Max(maxAlignment, alignment);
            offset = AlignUp(offset, alignment);
            fields[i] = new IrField(name, fieldIrType, offset);
            offset += fieldIrType.Size;
        }

        var totalSize = AlignUp(offset, maxAlignment);
        return new IrStruct(nt.Name, cName, fields, totalSize, maxAlignment);
    }

    private IrEnum LowerEnum(NominalType nt, string cacheKey, string cName)
    {
        const int tagSize = 4;

        if (nt.FieldsOrVariants.Count == 0)
        {
            return new IrEnum(nt.Name, cName, tagSize, [], tagSize, 4);
        }

        // Look up tag values from the type or its template
        var tagValues = nt.TagValues;
        if (tagValues == null)
        {
            var template = _nominalTypes.LookupNominalType(nt.Name);
            if (template != null)
                tagValues = template.TagValues;
        }

        var variants = new IrVariant[nt.FieldsOrVariants.Count];
        int largestPayload = 0;
        int maxPayloadAlignment = 1;
        bool allPayloadless = true;

        for (int i = 0; i < nt.FieldsOrVariants.Count; i++)
        {
            var (variantName, payloadHmType) = nt.FieldsOrVariants[i];
            var tag = tagValues != null && tagValues.TryGetValue(variantName, out var explicitTag)
                ? (int)explicitTag : i;

            // Check if payload-less: void sentinel means no payload
            IrType? payloadIrType = null;
            var resolved = _engine.Resolve(payloadHmType);
            if (resolved is PrimitiveType pt && pt.Name == "void")
            {
                // No payload
                variants[i] = new IrVariant(variantName, tag, null, tagSize);
            }
            else
            {
                payloadIrType = LowerResolved(resolved);
                allPayloadless = false;
                largestPayload = Math.Max(largestPayload, payloadIrType.Size);
                maxPayloadAlignment = Math.Max(maxPayloadAlignment, payloadIrType.Alignment);
                variants[i] = new IrVariant(variantName, tag, payloadIrType, tagSize);
            }
        }

        int alignment;
        int totalSize;

        if (allPayloadless)
        {
            // Naked-ish enum: just the tag
            alignment = 4;
            totalSize = tagSize;
        }
        else
        {
            alignment = Math.Max(4, maxPayloadAlignment);
            totalSize = tagSize + largestPayload;
            totalSize = AlignUp(totalSize, alignment);
        }

        return new IrEnum(nt.Name, cName, tagSize, variants, totalSize, alignment);
    }

    private string BuildCacheKey(NominalType nt)
    {
        if (nt.TypeArguments.Count == 0)
            return nt.Name;

        var parts = new List<string> { nt.Name };
        foreach (var ta in nt.TypeArguments)
        {
            var resolved = _engine.Resolve(ta);
            parts.Add(resolved.ToString()!);
        }
        return string.Join("|", parts);
    }

    /// <summary>
    /// Replace TypeVars in a type according to the substitution map.
    /// </summary>
    private static Type SubstituteTypeArgs(Type type, Dictionary<int, Type>? subst)
    {
        if (subst == null || subst.Count == 0) return type;
        return SubstituteRec(type, subst);
    }

    private static Type SubstituteRec(Type type, Dictionary<int, Type> subst) => type switch
    {
        TypeVar tv when subst.TryGetValue(tv.Id, out var concrete) => concrete,
        ReferenceType rt => new ReferenceType(SubstituteRec(rt.InnerType, subst)),
        ArrayType at => new ArrayType(SubstituteRec(at.ElementType, subst), at.Length),
        FunctionType ft => new FunctionType(
            ft.ParameterTypes.Select(p => SubstituteRec(p, subst)).ToArray(),
            SubstituteRec(ft.ReturnType, subst)),
        NominalType nt when nt.TypeArguments.Count > 0 => new NominalType(
            nt.Name, nt.Kind,
            nt.TypeArguments.Select(a => SubstituteRec(a, subst)).ToList(),
            nt.FieldsOrVariants),
        _ => type
    };

    public static string SanitizeCName(string fqn)
    {
        // string.Create lets us work directly on the string's memory before it is marked as immutable.
        return string.Create(fqn.Length, fqn, (span, original) =>
        {
            for (int i = 0; i < original.Length; i++)
            {
                char c = original[i];
                // Check all 5 conditions in one single pass through the string
                span[i] = c switch
                {
                    '.' or '[' or ']' or ',' or ' ' or '|' or '&' or '(' or ')' => '_',
                    _ => c
                };
            }
        });
    }

    private static int AlignUp(int offset, int alignment)
    {
        if (alignment <= 0) return offset;
        return (offset + alignment - 1) / alignment * alignment;
    }
}
