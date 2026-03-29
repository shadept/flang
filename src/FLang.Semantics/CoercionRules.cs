using FLang.Core.Types;
using ArrayType = FLang.Core.Types.ArrayType;
using NominalType = FLang.Core.Types.NominalType;
using PrimitiveType = FLang.Core.Types.PrimitiveType;
using ReferenceType = FLang.Core.Types.ReferenceType;
using Type = FLang.Core.Types.Type;

namespace FLang.Semantics;

/// <summary>
/// Implicit widening of integer types (e.g., i8 -> i32).
/// Separate rank hierarchies for signed and unsigned.
/// </summary>
public class IntegerWideningCoercionRule : IInferenceCoercionRule
{
    private readonly Dictionary<string, int> _signedRank;
    private readonly Dictionary<string, int> _unsignedRank;

    public IntegerWideningCoercionRule(bool is64Bit)
    {
        var isizeRank = is64Bit ? 4 : 3;
        _signedRank = new Dictionary<string, int>
        {
            ["i8"] = 1,
            ["i16"] = 2,
            ["i32"] = 3,
            ["i64"] = 4,
            ["isize"] = isizeRank
        };
        _unsignedRank = new Dictionary<string, int>
        {
            ["u8"] = 1,
            ["u16"] = 2,
            ["u32"] = 3,
            ["u64"] = 4,
            ["usize"] = isizeRank
        };
    }

    public Type? TryApply(Type from, Type to, InferenceEngine engine)
    {
        if (from is not PrimitiveType pFrom || to is not PrimitiveType pTo)
            return null;

        var (fromName, toName) = (pFrom.Name, pTo.Name);

        // bool -> any integer
        if (fromName == "bool" && (_signedRank.ContainsKey(toName) || _unsignedRank.ContainsKey(toName)))
            return to;

        // Same-signedness widening
        if (_signedRank.TryGetValue(fromName, out var fromRank) &&
            _signedRank.TryGetValue(toName, out var toRank) &&
            fromRank <= toRank)
            return to;

        if (_unsignedRank.TryGetValue(fromName, out fromRank) &&
            _unsignedRank.TryGetValue(toName, out toRank) &&
            fromRank <= toRank)
            return to;

        // Cross-signedness: unsigned -> signed with strictly higher rank
        if (_unsignedRank.TryGetValue(fromName, out var uFromRank) &&
            _signedRank.TryGetValue(toName, out var sToRank) &&
            uFromRank < sToRank)
            return to;

        return null;
    }
}

/// <summary>
/// Implicit widening of floating-point types: f32 -> f64.
/// </summary>
public class FloatWideningCoercionRule : IInferenceCoercionRule
{
    public Type? TryApply(Type from, Type to, InferenceEngine engine)
    {
        if (from is not PrimitiveType { Name: "f32" } || to is not PrimitiveType { Name: "f64" })
            return null;
        return to;
    }
}

/// <summary>
/// Implicit wrapping: T -> Option(T).
/// </summary>
public class OptionWrappingCoercionRule : IInferenceCoercionRule
{
    public Type? TryApply(Type from, Type to, InferenceEngine engine)
    {
        // to is Option(T) and from equals T (resolving through union-find)
        if (to is NominalType { Name: WellKnown.Option } stTo && stTo.TypeArguments.Count > 0)
        {
            var innerType = engine.Resolve(stTo.TypeArguments[0]);
            if (from.Equals(innerType))
                return to;
        }

        return null;
    }
}

/// <summary>
/// String -> Slice(u8) (binary-compatible view cast).
/// </summary>
public class StringToByteSliceCoercionRule : IInferenceCoercionRule
{
    public Type? TryApply(Type from, Type to, InferenceEngine engine)
    {
        if (from is NominalType { Name: WellKnown.String } &&
            to is NominalType { Name: WellKnown.Slice } sliceTo &&
            sliceTo.TypeArguments.Count > 0 &&
            sliceTo.TypeArguments[0].Equals(WellKnown.U8))
            return to;

        return null;
    }
}

/// <summary>
/// Array decay: [T; N] -> &amp;T, [T; N] -> Slice(T), &amp;[T; N] -> Slice(T).
/// </summary>
public class ArrayDecayCoercionRule : IInferenceCoercionRule
{
    public Type? TryApply(Type from, Type to, InferenceEngine engine)
    {
        // [T; N] -> Slice(T)
        if (from is ArrayType arr && to is NominalType { Name: WellKnown.Slice } sliceTo &&
            sliceTo.TypeArguments.Count > 0)
        {
            if (engine.TryUnify(arr.ElementType, sliceTo.TypeArguments[0]) != null)
            {
                engine.Unify(arr.ElementType, sliceTo.TypeArguments[0], default);
                return to;
            }
        }

        // &[T; N] -> Slice(T)
        if (from is ReferenceType { InnerType: ArrayType refArr } &&
            to is NominalType { Name: WellKnown.Slice } sliceTo2 &&
            sliceTo2.TypeArguments.Count > 0)
        {
            if (engine.TryUnify(refArr.ElementType, sliceTo2.TypeArguments[0]) != null)
            {
                engine.Unify(refArr.ElementType, sliceTo2.TypeArguments[0], default);
                return to;
            }
        }

        // [T; N] -> &T
        if (from is ArrayType arrVal && to is ReferenceType refTarget)
        {
            if (engine.TryUnify(arrVal.ElementType, refTarget.InnerType) != null)
            {
                engine.Unify(arrVal.ElementType, refTarget.InnerType, default);
                return to;
            }
        }

        // &[T; N] -> &T
        if (from is ReferenceType { InnerType: ArrayType arrInRef } &&
            to is ReferenceType refTarget2)
        {
            if (engine.TryUnify(arrInRef.ElementType, refTarget2.InnerType) != null)
            {
                engine.Unify(arrInRef.ElementType, refTarget2.InnerType, default);
                return to;
            }
        }

        return null;
    }
}

/// <summary>
/// Anonymous struct -> named struct (structural compatibility).
/// When an __anon_* struct has the same fields as a named struct, coerce to the named type.
/// Uses a type lookup callback to properly substitute generic type arguments.
/// </summary>
public class AnonymousStructCoercionRule : IInferenceCoercionRule
{
    private readonly Func<string, NominalType?> _lookupNominalType;

    public AnonymousStructCoercionRule(Func<string, NominalType?> lookupNominalType)
    {
        _lookupNominalType = lookupNominalType;
    }

    public Type? TryApply(Type from, Type to, InferenceEngine engine)
    {
        if (from is not NominalType { Kind: NominalKind.Struct or NominalKind.Tuple } fromStruct) return null;
        if (to is not NominalType { Kind: NominalKind.Struct } toStruct) return null;

        // Only apply when the source is anonymous/tuple
        if (fromStruct.Kind != NominalKind.Tuple && !fromStruct.Name.StartsWith("__anon_")) return null;

        // Get the target's fields, substituting generic type args if needed
        var targetFields = GetSubstitutedFields(toStruct);

        // Source must not have more fields than target (extra fields = unknown)
        if (fromStruct.FieldsOrVariants.Count > targetFields.Count) return null;

        // Build field map for the target
        var targetFieldMap = new Dictionary<string, Type>();
        foreach (var (name, type) in targetFields)
            targetFieldMap[name] = type;

        // Check all source fields exist in target with compatible types
        foreach (var (name, type) in fromStruct.FieldsOrVariants)
        {
            if (!targetFieldMap.TryGetValue(name, out var targetType)) return null;
            if (engine.TryUnify(type, targetType) == null) return null;
        }

        // Commit field unification
        foreach (var (name, type) in fromStruct.FieldsOrVariants)
        {
            engine.Unify(type, targetFieldMap[name], default);
        }

        return to;
    }

    /// <summary>
    /// Get the fields of a NominalType with template TypeVars substituted by instance type args.
    /// </summary>
    private IReadOnlyList<(string Name, Type Type)> GetSubstitutedFields(NominalType instance)
    {
        if (instance.TypeArguments.Count == 0) return instance.FieldsOrVariants;

        var template = _lookupNominalType(instance.Name);
        if (template == null || template.TypeArguments.Count != instance.TypeArguments.Count)
        {
            return instance.FieldsOrVariants;
        }

        // Build substitution map: template TypeVar Id -> instance type arg
        var substMap = new Dictionary<int, Type>();
        for (int i = 0; i < template.TypeArguments.Count; i++)
        {
            if (template.TypeArguments[i] is TypeVar tv)
            {
                substMap[tv.Id] = instance.TypeArguments[i];
            }
        }
        if (substMap.Count == 0) return instance.FieldsOrVariants;

        // Apply substitution to field types (shallow — no recursion into NominalType fields)
        return [.. instance.FieldsOrVariants.Select(f => (f.Name, SubstShallow(f.Type, substMap)))];
    }

    private static Type SubstShallow(Type type, Dictionary<int, Type> substMap)
    {
        return type switch
        {
            TypeVar tv when substMap.TryGetValue(tv.Id, out var repl) => repl,
            ReferenceType refType => new ReferenceType(SubstShallow(refType.InnerType, substMap)),
            NominalType nominal => new NominalType(
                nominal.Name, nominal.Kind,
                nominal.TypeArguments.Select(a => SubstShallow(a, substMap)).ToArray(),
                nominal.FieldsOrVariants, nominal.IsSimd),
            _ => type
        };
    }
}

/// <summary>
/// Slice(T) -> &amp;T (extract pointer from slice).
/// </summary>
public class SliceToReferenceCoercionRule : IInferenceCoercionRule
{
    public Type? TryApply(Type from, Type to, InferenceEngine engine)
    {
        if (from is NominalType { Name: WellKnown.Slice } sliceFrom &&
            sliceFrom.TypeArguments.Count > 0 &&
            to is ReferenceType refTo)
        {
            var resolvedElem = engine.Resolve(sliceFrom.TypeArguments[0]);
            var resolvedInner = engine.Resolve(refTo.InnerType);
            if (resolvedElem.Equals(resolvedInner))
            {
                return to;
            }
        }

        return null;
    }
}
