using System.Text;
using FLang.Core.Types;
using Type = FLang.Core.Types.Type;

namespace FLang.IR;

/// <summary>
/// Converts HM Type to IrType with pre-computed layout (size, alignment, offsets).
/// Caches results to ensure the same HM Type always produces the same IrType instance.
/// </summary>
public class TypeLayoutService(ITypeResolver engine, INominalTypeRegistry nominalTypes)
{
    private readonly Dictionary<string, IrType> _cache = [];
    private readonly List<(string Key, NominalType Nt, string CName)> _deferredRelower = [];
    // CNames currently queued for re-lower. A type whose by-value field is
    // tentative (sized against a stub) must itself be re-flagged, otherwise
    // it caches the wrong size and never gets fixed.
    private readonly HashSet<string> _deferredCNames = [];
    private int _loweringDepth;
    private readonly ITypeResolver _engine = engine;
    private readonly INominalTypeRegistry _nominalTypes = nominalTypes;

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
    public static readonly IrPrimitive IrF32 = new("f32", 4, 4);
    public static readonly IrPrimitive IrF64 = new("f64", 8, 8);

    /// <summary>
    /// Returns true when the type is a large value type that should be passed
    /// by implicit reference at the ABI level. For normal structs the threshold
    /// is 8 bytes; for #simd structs it equals the SIMD register size.
    /// </summary>
    public static bool IsLargeValue(IrType type) => type switch
    {
        IrStruct s => s.Size > s.RegisterSize,
        IrEnum { Size: > 8 } => true,
        _ => false
    };

    /// <summary>
    /// Returns true when the type uses C calling convention (passed by value, no implicit reference).
    /// Foreign structs (#foreign struct) follow C ABI; regular FLang structs use FLang calling convention.
    /// </summary>
    public static bool UsesCCallingConvention(IrType type) => type is IrStruct { IsForeign: true };

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
        ["f32"] = IrF32,
        ["f64"] = IrF64,
    };

    /// <summary>
    /// Resolve an IrStruct that may be a stale stub (empty fields from cycle-breaking)
    /// to the canonical version from the cache. Returns the input if not a stub.
    /// </summary>
    public IrStruct ResolveStruct(IrStruct s)
    {
        if (s.Fields.Length > 0) return s;
        // Look up by CName in the cache
        foreach (var cached in _cache.Values)
        {
            if (cached is IrStruct cs && cs.CName == s.CName && cs.Fields.Length > 0)
                return cs;
        }
        return s; // Genuinely empty struct
    }

    /// <summary>
    /// Resolve an IrEnum that may be stale (from cycle-breaking or deferred re-lowering)
    /// to the canonical version from the cache. Returns the input if it is already canonical.
    /// </summary>
    public IrEnum ResolveEnum(IrEnum e)
    {
        // Look up by CName in the cache — always prefer the cached version
        foreach (var cached in _cache.Values)
        {
            if (cached is IrEnum ce && ce.CName == e.CName && ce.Size >= e.Size)
                return ce;
        }
        return e;
    }

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

        // Niche optimization: Option(&T) -> IrPointer(T, IsNullable: true)
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

            // Look up the template to get the TypeVar -> type-arg mapping
            var template = _nominalTypes.LookupNominalType(nt.Name);
            if (template != null && template.TypeArguments.Count == nt.TypeArguments.Count)
            {
                // Build substitution: template TypeVar id -> concrete type arg
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

                    concrete = new NominalType(nt.Name, template.Kind, nt.TypeArguments, concreteFields, template.IsSimd, template.IsForeign);
                }
            }
        }
        else
        {
            // Non-generic type — check if the template has IsSimd/IsForeign or more fields
            var template = _nominalTypes.LookupNominalType(nt.Name);
            if (template != null)
            {
                if (nt.FieldsOrVariants.Count == 0 && template.FieldsOrVariants.Count > 0)
                    concrete = template;
                else if ((template.IsSimd && !nt.IsSimd) || (template.IsForeign && !nt.IsForeign))
                    concrete = new NominalType(nt.Name, nt.Kind, nt.TypeArguments, nt.FieldsOrVariants, template.IsSimd, template.IsForeign);
            }
        }

        // Pre-register a stub in the cache as an "already being lowered" sentinel.
        // Without this, mutually-recursive types (e.g., Expr → List(Expr) → &Expr → Expr)
        // would infinite-loop. The stub's size is meaningless — it exists only to make
        // the cache lookup at line 140 return early instead of recursing. Pointer fields
        // (&T) don't need the pointee's size so the stub is harmless for them. By-value
        // fields that hit the stub will get incorrect sizes; _deferredRelower fixes those
        // up after all dependencies have their final sizes (see re-lower pass below).
        // Foreign structs use their original C name; others get a mangled C identifier.
        var cName = concrete.IsForeign
            ? concrete.Name.Split('.').Last()
            : SanitizeCName(cacheKey);
        IrType stub;
        if (concrete.Kind == NominalKind.Enum)
            stub = new IrEnum(concrete.Name, cName, 4, [], 4, 4);
        else
            stub = new IrStruct(concrete.Name, cName, [], 0, 1, 8);
        _cache[cacheKey] = stub;
        _loweringDepth++;

        IrType result;
        if (concrete.Kind == NominalKind.Enum)
            result = LowerEnum(concrete, cacheKey, cName);
        else
            result = LowerStruct(concrete, cacheKey, cName);

        _cache[cacheKey] = result;
        _loweringDepth--;

        // Iterate the re-lower queue. Cycles like Stmt ↔ Expr need multiple
        // passes: a re-lowered type's new size invalidates consumers whose
        // captured PayloadType.Size referenced the old value. We keep stale
        // cache entries during a pass so nested LowerResolved doesn't see
        // a cache miss and reinsert a stub. Bounded for termination.
        if (_loweringDepth == 0 && _deferredRelower.Count > 0)
        {
            const int maxIterations = 16;
            for (int iter = 0; iter < maxIterations && _deferredRelower.Count > 0; iter++)
            {
                var toRelower = new List<(string Key, NominalType Nt, string CName)>(_deferredRelower);
                _deferredRelower.Clear();
                _deferredCNames.Clear();

                var oldSizes = new Dictionary<string, int>(toRelower.Count);
                foreach (var (k, _, cn) in toRelower)
                {
                    if (_cache.TryGetValue(k, out var oldT))
                        oldSizes[k] = IrTypeSize(oldT);
                    _deferredCNames.Add(cn);
                }

                foreach (var (key, nt2, cn) in toRelower)
                {
                    // Drop self so we don't re-flag ourselves; consumers
                    // still in the set stay tentative.
                    _deferredCNames.Remove(cn);
                    IrType newResult = nt2.Kind == NominalKind.Enum
                        ? LowerEnum(nt2, key, cn)
                        : LowerStruct(nt2, key, cn);
                    _cache[key] = newResult;
                }

                // Fan out: by-value consumers of size-changed types are stale.
                var changedCNames = new HashSet<string>();
                foreach (var (k, _, cn) in toRelower)
                {
                    if (oldSizes.TryGetValue(k, out var oldSize)
                        && _cache.TryGetValue(k, out var newT)
                        && IrTypeSize(newT) != oldSize)
                        changedCNames.Add(cn);
                }
                if (changedCNames.Count > 0)
                {
                    foreach (var kvp in _cache.ToList())
                    {
                        NominalType? consumerNt = null;
                        string? consumerCName = null;
                        if (kvp.Value is IrStruct s && AnyFieldReferencesCName(s, changedCNames))
                        {
                            consumerNt = _nominalTypes.LookupNominalType(s.Name);
                            consumerCName = s.CName;
                        }
                        else if (kvp.Value is IrEnum e && AnyVariantReferencesCName(e, changedCNames))
                        {
                            consumerNt = _nominalTypes.LookupNominalType(e.Name);
                            consumerCName = e.CName;
                        }
                        if (consumerNt != null && consumerCName != null)
                            QueueRelower(kvp.Key, consumerNt, consumerCName);
                    }
                }
            }
            _deferredCNames.Clear();
        }

        return result;
    }

    private IrStruct LowerStruct(NominalType nt, string cacheKey, string cName)
    {
        int registerSize = 8;

        if (nt.FieldsOrVariants.Count == 0)
            return new IrStruct(nt.Name, cName, [], 0, 1, registerSize, nt.IsForeign);

        var fields = new IrField[nt.FieldsOrVariants.Count];
        int offset = 0;
        int maxAlignment = 1;
        bool usedStub = false;

        for (int i = 0; i < nt.FieldsOrVariants.Count; i++)
        {
            var (name, fieldHmType) = nt.FieldsOrVariants[i];
            var fieldIrType = LowerResolved(_engine.Resolve(fieldHmType));
            // Stub (cycle-break) or already-queued tentative type: size is provisional.
            if (fieldIrType is IrStruct { Size: 0, Fields.Length: 0 }
                || fieldIrType is IrEnum { Variants.Length: 0 }
                || IsTentative(fieldIrType))
                usedStub = true;
            var alignment = fieldIrType.Alignment;
            maxAlignment = Math.Max(maxAlignment, alignment);
            offset = AlignUp(offset, alignment);
            fields[i] = new IrField(name, fieldIrType, offset);
            offset += fieldIrType.Size;
        }

        // If any field resolved to a stub, schedule this type for re-lowering
        if (usedStub)
            QueueRelower(cacheKey, nt, cName);

        if (nt.IsSimd)
        {
            var simdAlign = Math.Max(16, NextPowerOfTwo(offset));
            maxAlignment = Math.Max(maxAlignment, simdAlign);
            registerSize = simdAlign;
        }

        var totalSize = AlignUp(offset, maxAlignment);
        return new IrStruct(nt.Name, cName, fields, totalSize, maxAlignment, registerSize, nt.IsForeign);
    }

    private static int NextPowerOfTwo(int v)
    {
        v--;
        v |= v >> 1; v |= v >> 2; v |= v >> 4; v |= v >> 8; v |= v >> 16;
        return v + 1;
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
        bool usedStub = false;

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
                // Stub (cycle-break) or already-queued tentative type: size is provisional.
                if (payloadIrType is IrStruct { Size: 0, Fields.Length: 0 }
                    || payloadIrType is IrEnum { Variants.Length: 0 }
                    || IsTentative(payloadIrType))
                    usedStub = true;
                largestPayload = Math.Max(largestPayload, payloadIrType.Size);
                maxPayloadAlignment = Math.Max(maxPayloadAlignment, payloadIrType.Alignment);
                variants[i] = new IrVariant(variantName, tag, payloadIrType, tagSize);
            }
        }

        // If any payload resolved to a stub, schedule this type for re-lowering
        // once all dependencies have their final sizes.
        if (usedStub)
            QueueRelower(cacheKey, nt, cName);

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
            var payloadOffset = AlignUp(tagSize, maxPayloadAlignment);
            totalSize = payloadOffset + largestPayload;
            totalSize = AlignUp(totalSize, alignment);

            // Update PayloadOffset in variants if padding was added
            if (payloadOffset > tagSize)
            {
                for (int i = 0; i < variants.Length; i++)
                    variants[i] = variants[i] with { PayloadOffset = payloadOffset };
            }
        }

        return new IrEnum(nt.Name, cName, tagSize, variants, totalSize, alignment);
    }

    // Provisional size — consumers laying out next to this by value must
    // re-lower once the queued entry settles.
    private bool IsTentative(IrType t) => t switch
    {
        IrStruct s => _deferredCNames.Contains(s.CName),
        IrEnum e => _deferredCNames.Contains(e.CName),
        _ => false,
    };

    private void QueueRelower(string cacheKey, NominalType nt, string cName)
    {
        if (_deferredCNames.Add(cName))
            _deferredRelower.Add((cacheKey, nt, cName));
    }

    private static int IrTypeSize(IrType t) => t switch
    {
        IrStruct s => s.Size,
        IrEnum e => e.Size,
        IrPrimitive p => p.Size,
        IrPointer => 8,
        IrArray { Length: not null } a => (a.Length ?? 0) * IrTypeSize(a.Element),
        _ => 0,
    };

    private static bool AnyFieldReferencesCName(IrStruct s, HashSet<string> changedCNames)
    {
        foreach (var f in s.Fields)
        {
            if (f.Type is IrStruct fs && changedCNames.Contains(fs.CName)) return true;
            if (f.Type is IrEnum fe && changedCNames.Contains(fe.CName)) return true;
        }
        return false;
    }

    private static bool AnyVariantReferencesCName(IrEnum e, HashSet<string> changedCNames)
    {
        foreach (var v in e.Variants)
        {
            if (v.PayloadType is IrStruct ps && changedCNames.Contains(ps.CName)) return true;
            if (v.PayloadType is IrEnum pe && changedCNames.Contains(pe.CName)) return true;
        }
        return false;
    }

    private string BuildCacheKey(NominalType nt)
    {
        var sb = new StringBuilder();
        AppendTypeCacheKey(sb, nt);
        return sb.ToString();
    }

    /// <summary>
    /// Append a unique cache key for a type. For anonymous types (tuples),
    /// includes resolved field types to distinguish e.g. (i64, usize) from (u64, usize).
    /// </summary>
    private void AppendTypeCacheKey(StringBuilder sb, Type type)
    {
        if (type is NominalType nt)
        {
            sb.Append(nt.Name);
            if (nt.TypeArguments.Count > 0)
            {
                sb.Append('|');
                for (int i = 0; i < nt.TypeArguments.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    AppendTypeCacheKey(sb, _engine.Resolve(nt.TypeArguments[i]));
                }
            }
            else if (nt.Name.StartsWith("__anon_") && nt.FieldsOrVariants.Count > 0)
            {
                sb.Append('{');
                for (int i = 0; i < nt.FieldsOrVariants.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    AppendTypeCacheKey(sb, _engine.Resolve(nt.FieldsOrVariants[i].Type));
                }
                sb.Append('}');
            }
        }
        else
        {
            sb.Append(type);
        }
    }

    /// <summary>
    /// Replace TypeVars in a type according to the substitution map.
    /// </summary>
    public static Type SubstituteTypeArgs(Type type, Dictionary<int, Type>? subst)
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
            nt.FieldsOrVariants, nt.IsSimd, nt.IsForeign),
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
                    '.' or '[' or ']' or ',' or ' ' or '|' or '&' or '(' or ')' or '{' or '}' or '?' => '_',
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
