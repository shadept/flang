using FLang.Core;

namespace FLang.Semantics;

/// <summary>
/// Interface for type coercion rules that convert one type to another.
/// </summary>
public interface ICoercionRule
{
    /// <summary>
    /// Attempts to coerce a value from one type to another.
    /// </summary>
    /// <param name="from">The source type to coerce from.</param>
    /// <param name="to">The target type to coerce to.</param>
    /// <param name="solver">The type solver for unified error reporting.</param>
    /// <returns>True if coercion is possible, false otherwise.</returns>
    bool TryApply(TypeBase from, TypeBase to, TypeSolver solver);
}

/// <summary>
/// Type unification and coercion solver with <see cref="Diagnostic"/> reporting.
/// </summary>
public class TypeSolver
{
    private readonly List<Diagnostic> _diagnostics = [];
    private readonly List<ICoercionRule> _coercionRules = [];

    /// <summary>
    /// Gets the list of diagnostics generated during type unification.
    /// </summary>
    public IReadOnlyList<Diagnostic> Diagnostics => _diagnostics;

    /// <summary>
    /// Initializes a new instance of the <see cref="TypeSolver"/> class with the specified pointer width.
    /// </summary>
    /// <param name="pointerWidth">The target platform pointer width (32 or 64 bits).</param>
    public TypeSolver(PointerWidth pointerWidth = PointerWidth.Bits64)
    {
        // Add default coercion rules (pass pointer width to rules that need it)
        // Note: Explicit rules like ArrayDecayRule are optimizations to avoid multi-step coercion chains
        _coercionRules.Add(new IntegerWideningRule(pointerWidth));
        _coercionRules.Add(new OptionWrappingRule());
        _coercionRules.Add(new StringToByteSliceRule());
        _coercionRules.Add(new ArrayDecayRule());
        _coercionRules.Add(new SliceToReferenceRule());
    }

    /// <summary>
    /// Clears all diagnostics recorded by the type solver.
    /// </summary>
    public void ClearDiagnostics() => _diagnostics.Clear();

    /// <summary>
    /// Unifies two types, applying coercion rules if necessary, and records diagnostics on failure.
    /// </summary>
    /// <param name="t1">The first type to unify.</param>
    /// <param name="t2">The second type to unify.</param>
    /// <param name="span">Optional source span for error reporting.</param>
    /// <returns>The unified type, or Never type if unification fails.</returns>
    public TypeBase Unify(TypeBase t1, TypeBase t2, SourceSpan? span = null)
    {
        var result = UnifyInternal(t1, t2, span ?? SourceSpan.None);
        return result ?? TypeRegistry.Never;
    }

    /// <summary>
    /// Checks if two types can unify without recording diagnostics.
    /// Used for speculative type checking (e.g., overload resolution, checking coercion possibility).
    /// </summary>
    public bool CanUnify(TypeBase t1, TypeBase t2)
    {
        var diagCountBefore = _diagnostics.Count;
        var result = UnifyInternal(t1, t2, SourceSpan.None);

        // Remove any diagnostics that were added during speculative unification
        if (_diagnostics.Count > diagCountBefore)
        {
            _diagnostics.RemoveRange(diagCountBefore, _diagnostics.Count - diagCountBefore);
        }

        return result != null;
    }

    /// <summary>
    /// Internal implementation of type unification with coercion support.
    /// Attempts to unify two types, applying coercion rules if direct unification fails.
    /// </summary>
    /// <param name="t1">The first type to unify.</param>
    /// <param name="t2">The second type to unify.</param>
    /// <param name="span">Source span for error reporting.</param>
    /// <returns>The unified type if successful, null otherwise.</returns>
    private TypeBase? UnifyInternal(TypeBase t1, TypeBase t2, SourceSpan span)
    {
        // 2. Variables (Flexible) - Check BEFORE pruning to preserve TypeVar references
        // Special case: when both are TypeVars, link them to create a chain
        if (t1 is TypeVar v1 && t2 is TypeVar v2)
        {
            if (!Equals(v1, v2))
                v1.Instance = v2;  // Create chain: v1 -> v2
            return v2;
        }

        if (t1 is TypeVar v1a)
        {
            var pruned1 = v1a.Prune();  // Get current binding of the TypeVar
            var pruned2 = t2.Prune();

            // If the TypeVar is already bound to a concrete type (not itself, not comptime type, not another TypeVar),
            // unify the existing binding with the new type to detect conflicts
            if (!Equals(v1a, pruned1) && !TypeRegistry.IsComptimeType(pruned1) && pruned1 is not TypeVar)
            {
                return UnifyInternal(pruned1, pruned2, span);
            }

            // Otherwise, bind the TypeVar to the new type (soft binding, unbound, or TypeVar chain)
            if (!Equals(v1a, pruned2))
                v1a.Instance = pruned2;
            return pruned2;
        }

        if (t2 is TypeVar v2a)
        {
            var pruned2 = v2a.Prune();  // Get current binding of the TypeVar
            var pruned1 = t1.Prune();

            // If the TypeVar is already bound to a concrete type (not itself, not comptime type, not another TypeVar),
            // unify the existing binding with the new type to detect conflicts
            if (!Equals(v2a, pruned2) && !TypeRegistry.IsComptimeType(pruned2) && pruned2 is not TypeVar)
            {
                return UnifyInternal(pruned1, pruned2, span);
            }

            // Otherwise, bind the TypeVar to the new type (soft binding, unbound, or TypeVar chain)
            if (!Equals(v2a, pruned1))
                v2a.Instance = pruned1;
            return pruned1;
        }

        // Now prune for remaining checks
        var a = t1.Prune();
        var b = t2.Prune();

        // 0. Never, always fails
        if (a.Equals(TypeRegistry.Never) || b.Equals(TypeRegistry.Never))
        {
            // TODO proper error message
            ReportError("Cannot unify with `never` type", span, "E2002");
            return null;
        }

        // 1. Identity (Primitives & Rigid Generics)
        if (a.Equals(b)) return a;

        // 3. Comptime Hardening (Soft Unification)
        if (a is ComptimeInt && b is PrimitiveType p1 && TypeRegistry.IsIntegerType(p1)) return p1;
        if (b is ComptimeInt && a is PrimitiveType p2 && TypeRegistry.IsIntegerType(p2)) return p2;

        // 4. Coercion Extension
        // Must come before structural recursion to allow cross-type coercions
        // (e.g., Array→Slice, &[T;N]→&T, String→Slice<u8>)
        foreach (var rule in _coercionRules)
        {
            if (rule.TryApply(a, b, this))
                return b;
        }

        // 5. Arrays (Structural Recursion) - unify element types
        if (a is ArrayType arr1 && b is ArrayType arr2)
        {
            if (arr1.Length != arr2.Length)
            {
                ReportError($"Array length mismatch: expected {arr1.Length}, got {arr2.Length}", span, "E2002");
                return null;
            }

            var unifiedElem = UnifyInternal(arr1.ElementType, arr2.ElementType, span);
            if (unifiedElem == null)
                return null;
            return new ArrayType(unifiedElem, arr1.Length);
        }

        // 6. References (Structural Recursion) - unify inner types
        if (a is ReferenceType ref1 && b is ReferenceType ref2)
        {
            var unifiedInner = UnifyInternal(ref1.InnerType, ref2.InnerType, span);
            if (unifiedInner == null)
                return null;
            return new ReferenceType(unifiedInner, ref1.PointerWidth);
        }

        // 7. Structs (Structural Recursion)
        if (a is StructType s1 && b is StructType s2)
        {
            if (s1.Name != s2.Name)
            {
                ReportError($"Type mismatch: expected `{s1.Name}`, got `{s2.Name}`", span, "E2002");
                return null;
            }

            if (s1.TypeArguments.Count != s2.TypeArguments.Count)
            {
                ReportError($"Generic arity mismatch for `{s1.Name}`", span, "E2002");
                return null;
            }

            for (var i = 0; i < s1.TypeArguments.Count; i++)
            {
                if (UnifyInternal(s1.TypeArguments[i], s2.TypeArguments[i], span) == null)
                    return null;
            }

            return a;
        }

        // 8. Enums (Structural Recursion)
        if (a is EnumType e1 && b is EnumType e2)
        {
            if (e1.Name != e2.Name)
            {
                ReportError($"Type mismatch: expected `{e1.Name}`, got `{e2.Name}`", span, "E2002");
                return null;
            }

            if (e1.TypeArguments.Count != e2.TypeArguments.Count)
            {
                ReportError($"Generic arity mismatch for `{e1.Name}`", span, "E2002");
                return null;
            }

            for (var i = 0; i < e1.TypeArguments.Count; i++)
            {
                if (UnifyInternal(e1.TypeArguments[i], e2.TypeArguments[i], span) == null)
                    return null;
            }

            return a;
        }

        // 9. Detailed Failure
        var hint = GenerateHint(t1, t2);
        if (IsSkolem(a) || IsSkolem(b))
            ReportError($"Cannot unify rigid generic parameter with concrete type", span, "E2002", hint);
        else
            ReportError($"Type mismatch: expected `{a}`, got `{b}`", span, "E2002", hint);

        return null;
    }

    /// <summary>
    /// Reports a type error diagnostic.
    /// </summary>
    /// <param name="message">The error message.</param>
    /// <param name="span">The source location of the error.</param>
    /// <param name="code">The error code.</param>
    /// <param name="hint">Optional hint for resolving the error.</param>
    private void ReportError(string message, SourceSpan span, string code, string? hint = null)
    {
        _diagnostics.Add(Diagnostic.Error(message, span, hint, code));
    }

    /// <summary>
    /// Checks if a type is a skolem (rigid generic parameter).
    /// Skolem types start with '$' and represent generic parameters that cannot be unified with concrete types.
    /// </summary>
    /// <param name="t">The type to check.</param>
    /// <returns>True if the type is a skolem, false otherwise.</returns>
    private static bool IsSkolem(TypeBase t) => t is PrimitiveType p && p.Name.StartsWith('$');

    /// <summary>
    /// Generates a hint message for type mismatch errors based on common patterns.
    /// </summary>
    /// <param name="t1">The expected type.</param>
    /// <param name="t2">The actual type.</param>
    /// <returns>A hint string if applicable, null otherwise.</returns>
    private static string? GenerateHint(TypeBase t1, TypeBase t2)
    {
        if (t1 is TypeVar { DeclarationSpan: not null } v1)
            return $"variable '{v1.Id}' declared here";
        if (t2 is TypeVar { DeclarationSpan: not null } v2)
            return $"variable '{v2.Id}' declared here";
        return null;
    }
}

// --- Coercion Rules ---

/// <summary>
/// Coercion rule that allows implicit widening of integer types (e.g., i8 to i32).
/// Maintains separate rank hierarchies for signed and unsigned integers.
/// </summary>
public class IntegerWideningRule : ICoercionRule
{
    private readonly Dictionary<string, int> _signedRank;
    private readonly Dictionary<string, int> _unsignedRank;

    /// <summary>
    /// Initializes a new instance of the <see cref="IntegerWideningRule"/> class.
    /// </summary>
    /// <param name="pointerWidth">The platform pointer width, used to determine isize/usize rank.</param>
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

    /// <summary>
    /// Attempts to widen an integer type to a larger integer type of the same signedness.
    /// </summary>
    /// <param name="from">The source integer type.</param>
    /// <param name="to">The target integer type.</param>
    /// <param name="solver">The type solver (unused by this rule).</param>
    /// <returns>True if widening is valid, false otherwise.</returns>
    public bool TryApply(TypeBase from, TypeBase to, TypeSolver solver)
    {
        if (from is not PrimitiveType pFrom || to is not PrimitiveType pTo)
            return false;

        var (fromName, toName) = (pFrom.Name, pTo.Name);

        // bool → any integer: treat bool as b1/u8 (rank 1 unsigned)
        if (fromName == "bool" && (TypeRegistry.IsIntegerType(toName) || toName == "bool"))
            return true;

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

/// <summary>
/// Coercion rule that allows implicit wrapping of a value into an Option type.
/// </summary>
public class OptionWrappingRule : ICoercionRule
{
    /// <summary>
    /// Attempts to coerce a value of type T into Option(T).
    /// </summary>
    /// <param name="from">The source type T.</param>
    /// <param name="to">The target type, expected to be Option(T).</param>
    /// <param name="solver">The type solver (unused by this rule).</param>
    /// <returns>True if the target is Option and the inner type matches the source type.</returns>
    public bool TryApply(TypeBase from, TypeBase to, TypeSolver solver)
    {
        if (to is StructType st && TypeRegistry.IsOption(st))
            return from.Equals(st.TypeArguments[0]);
        return false;
    }
}

/// <summary>
/// Coercion rule that allows implicit conversion from String to Slice(u8).
/// </summary>
public class StringToByteSliceRule : ICoercionRule
{
    /// <summary>
    /// Attempts to coerce a String to a Slice of bytes (u8).
    /// </summary>
    /// <param name="from">The source type, expected to be core.string.String.</param>
    /// <param name="to">The target type, expected to be core.slice.Slice(u8).</param>
    /// <param name="solver">The type solver (unused by this rule).</param>
    /// <returns>True if conversion from String to Slice(u8) is requested.</returns>
    public bool TryApply(TypeBase from, TypeBase to, TypeSolver solver)
    {
        if (from is StructType fs && TypeRegistry.IsString(fs) &&
            to is StructType ts && TypeRegistry.IsSlice(ts))
            return ts.TypeArguments[0].Equals(TypeRegistry.U8);
        return false;
    }
}

/// <summary>
/// Coercion rule for array decay: converts arrays to pointers or slices.
/// Supports: [T; N] → &amp;T, &[T; N] → &amp;T, [T; N] → Slice(T), &[T; N] → Slice(T).
/// </summary>
public class ArrayDecayRule : ICoercionRule
{
    /// <summary>
    /// Attempts to decay an array to a pointer or slice.
    /// </summary>
    /// <param name="from">The source array type or reference to array.</param>
    /// <param name="to">The target type (pointer or slice).</param>
    /// <param name="solver">The type solver (unused by this rule).</param>
    /// <returns>True if array decay is valid for the given types.</returns>
    public bool TryApply(TypeBase from, TypeBase to, TypeSolver solver)
    {
        // Array-to-slice coercions
        if (to is StructType st && TypeRegistry.IsSlice(st))
        {
            // [T; N] → Slice(T)
            if (from is ArrayType arr)
                return arr.ElementType.Equals(st.TypeArguments[0]);
            // &[T; N] → Slice(T)
            if (from is ReferenceType { InnerType: ArrayType refArr })
                return refArr.ElementType.Equals(st.TypeArguments[0]);
        }

        // Array-to-pointer coercions
        // [T; N] → &T
        if (from is ArrayType arrValue && to is ReferenceType refTarget)
            return arrValue.ElementType.Equals(refTarget.InnerType);

        // &[T; N] → &T
        if (from is ReferenceType { InnerType: ArrayType arrInRef } &&
            to is ReferenceType { InnerType: var targetInner })
            return arrInRef.ElementType.Equals(targetInner);

        return false;
    }
}

/// <summary>
/// Coercion rule that allows implicit conversion from Slice(T) to &amp;T.
/// </summary>
public class SliceToReferenceRule : ICoercionRule
{
    /// <summary>
    /// Attempts to coerce a Slice to a reference to its element type.
    /// </summary>
    /// <param name="from">The source type, expected to be core.slice.Slice(T).</param>
    /// <param name="to">The target type, expected to be &amp;T.</param>
    /// <param name="solver">The type solver (unused by this rule).</param>
    /// <returns>True if conversion from Slice(T) to &amp;T is requested.</returns>
    public bool TryApply(TypeBase from, TypeBase to, TypeSolver solver)
    {
        if (from is StructType fs && TypeRegistry.IsSlice(fs) &&
            to is ReferenceType tr && tr.InnerType.Equals(fs.TypeArguments[0]))
            return true;
        return false;
    }
}