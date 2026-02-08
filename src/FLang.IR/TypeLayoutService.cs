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

            case TypeVar:
                // Unresolved type variable — shouldn't happen after type checking
                return IrVoidPrim;

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
        // If this NominalType has no fields, look up the registered version with fields
        var actual = nt;
        if (nt.FieldsOrVariants.Count == 0)
        {
            var registered = _nominalTypes.LookupNominalType(nt.Name);
            if (registered != null && registered.FieldsOrVariants.Count > 0)
                actual = registered;
        }

        // Build a cache key from name + type arguments
        var cacheKey = BuildCacheKey(actual);
        if (_cache.TryGetValue(cacheKey, out var cached))
            return cached;

        IrType result;
        if (actual.Kind == NominalKind.Enum)
            result = LowerEnum(actual, cacheKey);
        else
            result = LowerStruct(actual, cacheKey);

        _cache[cacheKey] = result;
        return result;
    }

    private IrStruct LowerStruct(NominalType nt, string cacheKey)
    {
        var cName = SanitizeCName(nt.Name);

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

    private IrEnum LowerEnum(NominalType nt, string cacheKey)
    {
        var cName = SanitizeCName(nt.Name);
        const int tagSize = 4;

        if (nt.FieldsOrVariants.Count == 0)
        {
            return new IrEnum(nt.Name, cName, tagSize, [], tagSize, 4);
        }

        var variants = new IrVariant[nt.FieldsOrVariants.Count];
        int largestPayload = 0;
        int maxPayloadAlignment = 1;
        bool allPayloadless = true;

        for (int i = 0; i < nt.FieldsOrVariants.Count; i++)
        {
            var (variantName, payloadHmType) = nt.FieldsOrVariants[i];

            // Check if payload-less: void sentinel means no payload
            IrType? payloadIrType = null;
            var resolved = _engine.Resolve(payloadHmType);
            if (resolved is PrimitiveType pt && pt.Name == "void")
            {
                // No payload
                variants[i] = new IrVariant(variantName, i, null, tagSize);
            }
            else
            {
                payloadIrType = LowerResolved(resolved);
                allPayloadless = false;
                largestPayload = Math.Max(largestPayload, payloadIrType.Size);
                maxPayloadAlignment = Math.Max(maxPayloadAlignment, payloadIrType.Alignment);
                variants[i] = new IrVariant(variantName, i, payloadIrType, tagSize);
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
                    '.' or '[' or ']' or ',' or ' ' => '_',
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
