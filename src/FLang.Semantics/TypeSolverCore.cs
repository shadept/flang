using System;
using System.Collections.Generic;
using FLang.Core.TypeSystem;

namespace FLang.Semantics.TypeSystem;

/// <summary>
/// Target architecture pointer width for isize/usize coercion rules.
/// </summary>
public enum PointerWidth
{
    Bits32, // isize=i32, usize=u32
    Bits64  // isize=i64, usize=u64
}

public interface ICoercionRule
{
    // Try to coerce 'from' to 'to'. Returns true if successful
    bool TryApply(TypeBase from, TypeBase to, TypeSolverCore solver);
}

/// <summary>
/// Type unification and coercion solver with Core.Diagnostic reporting.
/// </summary>
public class TypeSolverCore
{
    public List<ICoercionRule> CoercionRules { get; } = new();
    private readonly List<Core.Diagnostic> _diagnostics = new();

    public IReadOnlyList<Core.Diagnostic> Diagnostics => _diagnostics;

    public TypeSolverCore(PointerWidth pointerWidth = PointerWidth.Bits64)
    {
        // Add default coercion rules (pass pointer width to rules that need it)
        CoercionRules.Add(new IntegerWideningRule(pointerWidth));
        CoercionRules.Add(new OptionWrappingRule());
        CoercionRules.Add(new ArrayToSliceRule());
        CoercionRules.Add(new StringToByteSliceRule());
    }

    public TypeBase Unify(TypeBase t1, TypeBase t2, Core.SourceSpan? span = null)
    {
        var result = UnifyInternal(t1, t2, span);
        return result ?? t1; // Return first type on failure (errors recorded)
    }

    private TypeBase? UnifyInternal(TypeBase t1, TypeBase t2, Core.SourceSpan? span)
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

        // 4. Coercion Extension (BEFORE structural checks to allow wrapping/conversions)
        foreach (var rule in CoercionRules)
        {
            if (rule.TryApply(a, b, this))
                return b;
        }

        // 5. Structs/Enums (Recursion) - Only if no coercion applied
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

        // 6. Detailed Failure
        var hint = GenerateHint(t1, t2);
        if (IsSkolem(a) || IsSkolem(b))
            ReportError($"Cannot unify rigid generic parameter with concrete type", span, "E3003", hint);
        else
            ReportError($"Type mismatch: expected '{a}', got '{b}'", span, "E3001", hint);

        return null;
    }

    private void ReportError(string message, Core.SourceSpan? span, string code, string? hint = null)
    {
        _diagnostics.Add(Core.Diagnostic.Error(message, span ?? new Core.SourceSpan(0, 0, 0), hint, code));
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

    public bool TryApply(TypeBase from, TypeBase to, TypeSolverCore solver)
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
    // T -> core.option.Option<T>
    public bool TryApply(TypeBase from, TypeBase to, TypeSolverCore solver)
    {
        if (to is StructType st && TypeBaseRegistry.IsOption(st) &&
            st.TypeArguments.Count == 1 && from.Equals(st.TypeArguments[0]))
            return true;
        return false;
    }
}

public class ArrayToSliceRule : ICoercionRule
{
    // [T; N] -> core.slice.Slice<T>
    public bool TryApply(TypeBase from, TypeBase to, TypeSolverCore solver)
    {
        if (to is StructType st && TypeBaseRegistry.IsSlice(st) && st.TypeArguments.Count == 1)
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
    // core.string.String -> core.slice.Slice<u8>
    public bool TryApply(TypeBase from, TypeBase to, TypeSolverCore solver)
    {
        if (from is StructType fs && TypeBaseRegistry.IsString(fs) &&
            to is StructType ts && TypeBaseRegistry.IsSlice(ts) &&
            ts.TypeArguments.Count == 1 && ts.TypeArguments[0].Equals(TypeBaseRegistry.U8))
            return true;
        return false;
    }
}
