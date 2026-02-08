using System.Runtime.CompilerServices;
using System.Text;

namespace FLang.Core.Types;

/// <summary>
/// Distinguishes struct vs enum nominal types in the HM type system.
/// </summary>
public enum NominalKind { Struct, Enum }

/// <summary>
/// Resolves and zonks inference type variables to their bound types.
/// Implemented by InferenceEngine, consumed by TypeLayoutService and other
/// downstream phases that need resolved types without depending on Semantics.
/// </summary>
public interface ITypeResolver
{
    Type Resolve(Type type);
    Type Zonk(Type type);
}

/// <summary>
/// Looks up registered NominalType definitions by fully-qualified name.
/// Implemented by HmTypeChecker, consumed by TypeLayoutService to resolve
/// bare NominalTypes (no fields) to their full definitions for layout computation.
/// </summary>
public interface INominalTypeRegistry
{
    NominalType? LookupNominalType(string name);
}

/// <summary>
/// Base for all types in the new inference type system.
/// Immutable — all binding state lives in the DisjointSet, not on the types.
/// </summary>
public abstract record Type;

/// <summary>
/// Built-in scalar types: i32, bool, u8, etc. Compared by name.
/// </summary>
public sealed record PrimitiveType(string Name) : Type
{
    public override string ToString() => Name;
}

/// <summary>
/// Unification variable. Identity-compared (not structural).
/// No mutable Instance — bindings live in the DisjointSet.
/// Level tracks binding depth for let-generalization.
/// </summary>
public sealed record TypeVar : Type
{
    private static int _nextId;

    public TypeVar(int level)
    {
        Id = Interlocked.Increment(ref _nextId);
        Level = level;
    }

    public int Id { get; }
    public int Level { get; }

    public bool Equals(TypeVar? other) => ReferenceEquals(this, other);
    public override int GetHashCode() => RuntimeHelpers.GetHashCode(this);
    public override string ToString() => $"?{Id}";
}

/// <summary>
/// Function type: fn(param1, param2, ...) return.
/// </summary>
public sealed record FunctionType(IReadOnlyList<Type> ParameterTypes, Type ReturnType) : Type
{
    public bool Equals(FunctionType? other)
    {
        if (other is null) return false;
        if (ReferenceEquals(this, other)) return true;
        if (other.ParameterTypes.Count != ParameterTypes.Count) return false;
        for (var i = 0; i < ParameterTypes.Count; i++)
            if (!ParameterTypes[i].Equals(other.ParameterTypes[i])) return false;
        return ReturnType.Equals(other.ReturnType);
    }

    public override int GetHashCode()
    {
        var hash = new HashCode();
        foreach (var p in ParameterTypes) hash.Add(p);
        hash.Add(ReturnType);
        return hash.ToHashCode();
    }

    public override string ToString()
    {
        var sb = new StringBuilder();
        sb.Append("fn(");
        for (var i = 0; i < ParameterTypes.Count; i++)
        {
            if (i > 0) sb.Append(", ");
            sb.Append(ParameterTypes[i]);
        }
        sb.Append(") ");
        sb.Append(ReturnType);
        return sb.ToString();
    }
}

/// <summary>
/// Reference type: &amp;T.
/// </summary>
public sealed record ReferenceType(Type InnerType) : Type
{
    public override string ToString() => $"&{InnerType}";
}

/// <summary>
/// Fixed-size array: [T; N].
/// </summary>
public sealed record ArrayType(Type ElementType, int Length) : Type
{
    public override string ToString() => $"[{ElementType}; {Length}]";
}

/// <summary>
/// Named type with optional type arguments. Covers structs, enums, slices, strings, options, etc.
///
/// FieldsOrVariants describes the structure of the type:
///   - For structs: field entries like ("x", i32), ("y", i32)
///   - For enums: variant entries where Type is the payload type, e.g. ("Some", T), ("Ok", T)
///     Payload-less variants use void as a sentinel: ("None", void), ("Equal", void)
///     This does NOT mean the variant "has type void" — void here means "no payload data."
///     The actual constructor types of variants (e.g. forall ?1. Option[?1] for None,
///     forall ?1. fn(?1) -> Option[?1] for Some) live in TypeScopes, not here.
///     Using the enum type itself would be cyclic (Option[T] contains None whose type is Option[T]).
///
/// Equality is by name + type arguments (not fields/variants).
/// </summary>
public sealed record NominalType(string Name, NominalKind Kind, IReadOnlyList<Type> TypeArguments,
    IReadOnlyList<(string Name, Type Type)> FieldsOrVariants) : Type
{
    public NominalType(string name, NominalKind kind, IReadOnlyList<Type> typeArguments)
        : this(name, kind, typeArguments, []) { }

    public NominalType(string name, NominalKind kind)
        : this(name, kind, [], []) { }

    public bool Equals(NominalType? other)
    {
        if (other is null) return false;
        if (ReferenceEquals(this, other)) return true;
        if (other.Name != Name) return false;
        if (other.TypeArguments.Count != TypeArguments.Count) return false;
        for (var i = 0; i < TypeArguments.Count; i++)
            if (!TypeArguments[i].Equals(other.TypeArguments[i])) return false;
        return true;
    }

    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add(Name);
        foreach (var ta in TypeArguments) hash.Add(ta);
        return hash.ToHashCode();
    }

    public override string ToString()
    {
        if (TypeArguments.Count == 0) return Name;
        var sb = new StringBuilder();
        sb.Append(Name);
        sb.Append('[');
        for (var i = 0; i < TypeArguments.Count; i++)
        {
            if (i > 0) sb.Append(", ");
            sb.Append(TypeArguments[i]);
        }
        sb.Append(']');
        return sb.ToString();
    }
}

/// <summary>
/// Polymorphic type: forall {quantified vars} . body.
/// Monomorphic types have an empty quantifier set.
/// QuantifiedVarIds stores TypeVar.Id values — globally unique auto-incremented integers
/// assigned at TypeVar construction. This relies on a single ID sequence across the
/// entire compilation (via Interlocked.Increment on TypeVar._nextId).
/// </summary>
public sealed record PolymorphicType(IReadOnlySet<int> QuantifiedVarIds, Type Body) : Type
{
    public PolymorphicType(Type body)
        : this(new HashSet<int>(), body) { }

    public bool IsMonomorphic => QuantifiedVarIds.Count == 0;

    public bool Equals(PolymorphicType? other)
    {
        if (other is null) return false;
        if (ReferenceEquals(this, other)) return true;
        if (!QuantifiedVarIds.SetEquals(other.QuantifiedVarIds)) return false;
        return Body.Equals(other.Body);
    }

    public override int GetHashCode() => HashCode.Combine(QuantifiedVarIds.Count, Body);

    public override string ToString()
    {
        if (IsMonomorphic) return Body.ToString();
        var sb = new StringBuilder();
        sb.Append("forall ");
        var first = true;
        foreach (var id in QuantifiedVarIds)
        {
            if (!first) sb.Append(", ");
            first = false;
            sb.Append('?');
            sb.Append(id);
        }
        sb.Append(" . ");
        sb.Append(Body);
        return sb.ToString();
    }
}
