using FLang.Core.Types;
using ArrayType = FLang.Core.Types.ArrayType;
using NominalType = FLang.Core.Types.NominalType;
using PrimitiveType = FLang.Core.Types.PrimitiveType;
using ReferenceType = FLang.Core.Types.ReferenceType;
using Type = FLang.Core.Types.Type;

namespace FLang.Semantics;

/// <summary>
/// Implicit widening of integer types (e.g., i8 → i32).
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

        // bool → any integer
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

        // Cross-signedness: unsigned → signed with strictly higher rank
        if (_unsignedRank.TryGetValue(fromName, out var uFromRank) &&
            _signedRank.TryGetValue(toName, out var sToRank) &&
            uFromRank < sToRank)
            return to;

        return null;
    }
}

/// <summary>
/// Implicit wrapping: T → Option(T).
/// </summary>
public class OptionWrappingCoercionRule : IInferenceCoercionRule
{
    public Type? TryApply(Type from, Type to, InferenceEngine engine)
    {
        // to is Option[T] and from equals T
        if (to is NominalType { Name: WellKnown.Option } stTo && stTo.TypeArguments.Count > 0)
        {
            if (from.Equals(stTo.TypeArguments[0]))
                return to;
        }

        return null;
    }
}

/// <summary>
/// String → Slice[u8] (binary-compatible view cast).
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
/// Array decay: [T; N] → &amp;T, [T; N] → Slice[T], &amp;[T; N] → Slice[T].
/// </summary>
public class ArrayDecayCoercionRule : IInferenceCoercionRule
{
    public Type? TryApply(Type from, Type to, InferenceEngine engine)
    {
        // [T; N] → Slice[T]
        if (from is ArrayType arr && to is NominalType { Name: WellKnown.Slice } sliceTo &&
            sliceTo.TypeArguments.Count > 0)
        {
            var resolvedElem = engine.Resolve(arr.ElementType);
            var resolvedSliceElem = engine.Resolve(sliceTo.TypeArguments[0]);
            if (resolvedElem.Equals(resolvedSliceElem))
                return to;
        }

        // &[T; N] → Slice[T]
        if (from is ReferenceType { InnerType: ArrayType refArr } &&
            to is NominalType { Name: WellKnown.Slice } sliceTo2 &&
            sliceTo2.TypeArguments.Count > 0)
        {
            var resolvedElem = engine.Resolve(refArr.ElementType);
            var resolvedSliceElem = engine.Resolve(sliceTo2.TypeArguments[0]);
            if (resolvedElem.Equals(resolvedSliceElem))
                return to;
        }

        // [T; N] → &T
        if (from is ArrayType arrVal && to is ReferenceType refTarget)
        {
            var resolvedElem = engine.Resolve(arrVal.ElementType);
            var resolvedInner = engine.Resolve(refTarget.InnerType);
            if (resolvedElem.Equals(resolvedInner))
                return to;
        }

        // &[T; N] → &T
        if (from is ReferenceType { InnerType: ArrayType arrInRef } &&
            to is ReferenceType refTarget2)
        {
            var resolvedElem = engine.Resolve(arrInRef.ElementType);
            var resolvedInner = engine.Resolve(refTarget2.InnerType);
            if (resolvedElem.Equals(resolvedInner))
                return to;
        }

        return null;
    }
}

/// <summary>
/// Slice[T] → &amp;T (extract pointer from slice).
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
                return to;
        }

        return null;
    }
}
