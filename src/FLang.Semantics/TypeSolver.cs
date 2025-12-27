using FLang.Core;

namespace FLang.Semantics;

public interface ICoercionRule
{
    // Try to coerce 'from' to 'to'. Returns true if successful
    bool TryApply(TypeBase from, TypeBase to, TypeSolver solver);
}

/// <summary>
/// Type unification and coercion solver with Core.Diagnostic reporting.
/// </summary>
public class TypeSolver
{
    private readonly List<Diagnostic> _diagnostics = [];
    private readonly List<ICoercionRule> _coercionRules = [];

    public IReadOnlyList<Diagnostic> Diagnostics => _diagnostics;

    public TypeSolver(PointerWidth pointerWidth = PointerWidth.Bits64)
    {
        // Add default coercion rules (pass pointer width to rules that need it)
        _coercionRules.Add(new IntegerWideningRule(pointerWidth));
        _coercionRules.Add(new OptionWrappingRule());
        _coercionRules.Add(new ArrayToSliceRule());
        _coercionRules.Add(new StringToByteSliceRule());
        _coercionRules.Add(new SliceToReferenceRule());
    }

    public void ClearDiagnostics() => _diagnostics.Clear();

    public TypeBase Unify(TypeBase t1, TypeBase t2, SourceSpan? span = null)
    {
        var result = UnifyInternal(t1, t2, span ?? new SourceSpan());
        return result ?? t1; // Return first type on failure (errors recorded)
    }

    private TypeBase? UnifyInternal(TypeBase t1, TypeBase t2, SourceSpan span)
    {
        var a = t1.Prune();
        var b = t2.Prune();

        // 1. Identity (Primitives & Rigid Generics)
        if (a.Equals(b)) return a;

        // 2. Variables (Flexible)
        if (a is TypeVar v1)
        {
            if (v1 != b)
                v1.Instance = b;
            return b;
        }
        if (b is TypeVar v2)
        {
            if (v2 != a)
                v2.Instance = a;
            return a;
        }

        // 3. Comptime Hardening (Soft Unification)
        if (a is ComptimeInt && b is PrimitiveType p1 && IsInteger(p1)) return p1;
        if (b is ComptimeInt && a is PrimitiveType p2 && IsInteger(p2)) return p2;

        // 4. Arrays (Recursion) - unify element types
        if (a is ArrayType arr1 && b is ArrayType arr2)
        {
            if (arr1.Length != arr2.Length)
            {
                ReportError($"Array length mismatch: expected {arr1.Length}, got {arr2.Length}", span, "E3001");
                return null;
            }
            var unifiedElem = UnifyInternal(arr1.ElementType, arr2.ElementType, span);
            if (unifiedElem == null)
                return null;
            return new ArrayType(unifiedElem, arr1.Length);
        }

        // 5. References (Recursion) - unify inner types
        if (a is ReferenceType ref1 && b is ReferenceType ref2)
        {
            var unifiedInner = UnifyInternal(ref1.InnerType, ref2.InnerType, span);
            if (unifiedInner == null)
                return null;
            return new ReferenceType(unifiedInner, ref1.PointerWidth);
        }

        // 6. Structs/Enums (Recursion) - Only if no coercion applied
        if (a is StructType s1 && b is StructType s2)
        {
            if (s1.Name != s2.Name)
            {
                ReportError($"Type mismatch: expected '{s1.Name}', got '{s2.Name}'", span, "E3001");
                return null;
            }
            if (s1.TypeArguments.Count != s2.TypeArguments.Count)
            {
                ReportError($"Generic arity mismatch for '{s1.Name}'", span, "E3002");
                return null;
            }

            for (int i = 0; i < s1.TypeArguments.Count; i++)
            {
                if (UnifyInternal(s1.TypeArguments[i], s2.TypeArguments[i], span) == null)
                    return null;
            }
            return a;
        }

        // 7. Coercion Extension (BEFORE structural checks to allow wrapping/conversions)
        // TODO either allow coersion rules to compound on each other or suficient to allow converting multiple M(T) -> &T
        // where M is Array, List, Slice or String
        foreach (var rule in _coercionRules)
        {
            if (rule.TryApply(a, b, this))
                return b;
        }

        // 8. Detailed Failure
        var hint = GenerateHint(t1, t2);
        if (IsSkolem(a) || IsSkolem(b))
            ReportError($"Cannot unify rigid generic parameter with concrete type", span, "E3003", hint);
        else
            ReportError($"Type mismatch: expected '{a}', got '{b}'", span, "E3001", hint);

        return null;
    }

    private void ReportError(string message, SourceSpan span, string code, string? hint = null)
    {
        _diagnostics.Add(Diagnostic.Error(message, span, hint, code));
    }

    private static bool IsSkolem(TypeBase t) => t is PrimitiveType p && p.Name.StartsWith('$');

    private static bool IsInteger(PrimitiveType p)
    {
        return p.Name is "i8" or "i16" or "i32" or "i64" or "isize" or "u8" or "u16" or "u32" or "u64" or "usize";
    }

    private static string? GenerateHint(TypeBase t1, TypeBase t2)
    {
        if (t1 is TypeVar v1 && v1.DeclarationSpan.HasValue)
            return $"variable '{v1.Id}' declared here";
        if (t2 is TypeVar v2 && v2.DeclarationSpan.HasValue)
            return $"variable '{v2.Id}' declared here";
        return null;
    }
}

// --- Coercion Rules ---

public class IntegerWideningRule : ICoercionRule
{
    private readonly Dictionary<string, int> _signedRank;
    private readonly Dictionary<string, int> _unsignedRank;

    public IntegerWideningRule(PointerWidth pointerWidth)
    {
        // Map isize/usize to platform-specific types
        int isizeRank = pointerWidth == PointerWidth.Bits64 ? 4 : 3;
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

    public bool TryApply(TypeBase from, TypeBase to, TypeSolver solver)
    {
        if (from is not PrimitiveType pFrom || to is not PrimitiveType pTo)
            return false;

        var (fromName, toName) = (pFrom.Name, pTo.Name);

        // Same-signedness widening (e.g., i8 → i32, u8 → u64, i64 → isize)
        if (_signedRank.TryGetValue(fromName, out var fromRank) &&
            _signedRank.TryGetValue(toName, out var toRank) &&
            fromRank <= toRank)
            return true;

        if (_unsignedRank.TryGetValue(fromName, out fromRank) &&
            _unsignedRank.TryGetValue(toName, out toRank) &&
            fromRank <= toRank)
            return true;

        // Cross-signedness widening: unsigned → signed with STRICTLY higher rank
        // Safe because unsigned range fits in larger signed type (e.g., u32 → i64)
        if (_unsignedRank.TryGetValue(fromName, out var unsignedFromRank) &&
            _signedRank.TryGetValue(toName, out var signedToRank) &&
            unsignedFromRank < signedToRank)
            return true;

        return false;
    }
}

public class OptionWrappingRule : ICoercionRule
{
    // T -> core.option.Option(T)
    public bool TryApply(TypeBase from, TypeBase to, TypeSolver solver)
    {
        if (to is StructType st && TypeRegistry.IsOption(st) && st.TypeArguments.Count == 1 && from.Equals(st.TypeArguments[0]))
            return true;
        return false;
    }
}

public class ArrayToSliceRule : ICoercionRule
{
    // [T; N] -> core.slice.Slice(T)
    public bool TryApply(TypeBase from, TypeBase to, TypeSolver solver)
    {
        if (to is StructType st && TypeRegistry.IsSlice(st) && st.TypeArguments.Count == 1)
        {
            if (from is ArrayType arr && arr.ElementType.Equals(st.TypeArguments[0]))
                return true;
            if (from is ReferenceType { InnerType: ArrayType refArr } && refArr.ElementType.Equals(st.TypeArguments[0]))
                return true;
        }
        return false;
    }
}

public class StringToByteSliceRule : ICoercionRule
{
    // core.string.String -> core.slice.Slice(u8)
    public bool TryApply(TypeBase from, TypeBase to, TypeSolver solver)
    {
        if (from is StructType fs && TypeRegistry.IsString(fs) &&
            to is StructType ts && TypeRegistry.IsSlice(ts) &&
            ts.TypeArguments.Count == 1 && ts.TypeArguments[0].Equals(TypeRegistry.U8))
            return true;
        return false;
    }
}

public class SliceToReferenceRule : ICoercionRule
{
    // core.slice.Slice(T) -> &T
    public bool TryApply(TypeBase from, TypeBase to, TypeSolver solver)
    {
        if (from is StructType fs && TypeRegistry.IsSlice(fs) &&
            to is ReferenceType tr && tr.InnerType.Equals(fs.TypeArguments[0]))
            return true;
        return false;
    }

}