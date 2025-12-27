using System.Runtime.CompilerServices;

namespace FLang.Core.TypeSystem;

/// <summary>
/// Base class for all types in the new type system (Algorithm W-style).
/// </summary>
public abstract class TypeBase
{
    public abstract string Name { get; }

    /// <summary>
    /// Gets the size of this type in bytes. Used by size_of intrinsic.
    /// </summary>
    public abstract int Size { get; }

    /// <summary>
    /// Gets the alignment requirement of this type in bytes. Used by align_of intrinsic.
    /// </summary>
    public abstract int Alignment { get; }

    /// <summary>
    /// Follow type variable Instance chains to find the concrete type.
    /// </summary>
    public virtual TypeBase Prune() => this;

    /// <summary>
    /// Returns true if this type is fully concrete (no unbound type variables).
    /// </summary>
    public virtual bool IsConcrete => true;

    public abstract bool Equals(TypeBase other);

    public override bool Equals(object? obj)
    {
        return obj is TypeBase other && Equals(other);
    }

    public override int GetHashCode()
    {
        return Name.GetHashCode();
    }

    public override string ToString()
    {
        return Name;
    }
}

/// <summary>
/// Unification variable with mutable Instance property.
/// Used for Algorithm W-style type inference.
/// </summary>
public class TypeVar : TypeBase
{
    public TypeVar(string id, SourceSpan? declarationSpan = null)
    {
        Id = id;
        DeclarationSpan = declarationSpan;
    }

    public string Id { get; }
    public SourceSpan? DeclarationSpan { get; }

    /// <summary>
    /// The type this variable is bound to (null if unbound).
    /// </summary>
    public TypeBase? Instance { get; set; }

    public override string Name => Instance?.Name ?? $"'{Id}";

    public override int Size
    {
        get
        {
            if (Instance == null)
                throw new InvalidOperationException($"Cannot get size of unbound type variable '{Id}'");
            return Instance.Size;
        }
    }

    public override int Alignment
    {
        get
        {
            if (Instance == null)
                throw new InvalidOperationException($"Cannot get alignment of unbound type variable '{Id}'");
            return Instance.Alignment;
        }
    }

    public override TypeBase Prune()
    {
        if (Instance == null)
            return this;

        // Follow the chain and compress the path
        Instance = Instance.Prune();
        return Instance;
    }

    public override bool IsConcrete => Instance != null && Instance.IsConcrete;

    public override bool Equals(TypeBase other)
    {
        // Type variables are compared by identity
        return ReferenceEquals(this, other);
    }

    public override int GetHashCode()
    {
        return RuntimeHelpers.GetHashCode(this);
    }
}

/// <summary>
/// Primitive types like i8, i16, i32, i64, u8, u16, u32, u64, bool, isize, usize.
/// </summary>
public class PrimitiveType : TypeBase
{
    public PrimitiveType(string name, int size, int alignment)
    {
        Name = name;
        SizeInBytes = size;
        AlignmentInBytes = alignment;
    }

    public override string Name { get; }
    public int SizeInBytes { get; }
    public int AlignmentInBytes { get; }

    public override int Size => SizeInBytes;
    public override int Alignment => AlignmentInBytes;

    public override bool Equals(TypeBase other)
    {
        return other is PrimitiveType pt && pt.Name == Name;
    }

    /// <summary>
    /// Creates a skolem (rigid generic parameter) for use in generic function signatures.
    /// These cannot be unified with concrete types.
    /// </summary>
    public static PrimitiveType CreateSkolem(string name)
    {
        // Skolems have $ prefix and throw on Size/Alignment access
        return new SkolemType(name);
    }

    private class SkolemType : PrimitiveType
    {
        public SkolemType(string name) : base($"${name}", 0, 0)
        {
        }

        public override int Size =>
            throw new InvalidOperationException($"Cannot get size of skolem type {Name}");

        public override int Alignment =>
            throw new InvalidOperationException($"Cannot get alignment of skolem type {Name}");
    }
}

/// <summary>
/// Compile-time integer type that must be resolved during type inference.
/// </summary>
public class ComptimeInt : TypeBase
{
    private ComptimeInt() { }

    public static readonly ComptimeInt Instance = new();

    public override string Name => "comptime_int";

    public override int Size =>
        throw new InvalidOperationException("Cannot get size of comptime_int (not a concrete type)");

    public override int Alignment =>
        throw new InvalidOperationException("Cannot get alignment of comptime_int (not a concrete type)");

    public override bool IsConcrete => false;

    public override bool Equals(TypeBase other)
    {
        return other is ComptimeInt;
    }
}

/// <summary>
/// User-defined struct type with fields and optional type arguments.
/// </summary>
public class StructType : TypeBase
{
    public StructType(string name, List<TypeBase>? typeArguments = null, List<(string Name, TypeBase Type)>? fields = null)
    {
        Name = name;
        TypeArguments = typeArguments ?? [];
        Fields = fields ?? [];
    }

    public override string Name { get; }
    public List<TypeBase> TypeArguments { get; }
    public List<(string Name, TypeBase Type)> Fields { get; }

    public override int Size
    {
        get
        {
            // Generic structs with uninstantiated type parameters return 0
            if (TypeArguments.Any(t => !t.IsConcrete))
                return 0;

            // Calculate struct layout size
            if (Fields.Count == 0)
                return 0;

            int totalSize = 0;
            int maxAlignment = 1;

            foreach (var (_, fieldType) in Fields)
            {
                var fieldAlignment = fieldType.Alignment;
                maxAlignment = Math.Max(maxAlignment, fieldAlignment);

                // Align current offset to field alignment
                totalSize = AlignUp(totalSize, fieldAlignment);
                totalSize += fieldType.Size;
            }

            // Pad to struct alignment
            totalSize = AlignUp(totalSize, maxAlignment);

            return totalSize;
        }
    }

    public override int Alignment
    {
        get
        {
            // Generic structs with uninstantiated type parameters return 1
            if (TypeArguments.Any(t => !t.IsConcrete))
                return 1;

            if (Fields.Count == 0)
                return 1;

            // Struct alignment is the maximum field alignment
            return Fields.Max(f => f.Type.Alignment);
        }
    }

    private static int AlignUp(int offset, int alignment)
    {
        return (offset + alignment - 1) / alignment * alignment;
    }

    public override bool Equals(TypeBase other)
    {
        if (other is not StructType st)
            return false;

        if (Name != st.Name)
            return false;

        if (TypeArguments.Count != st.TypeArguments.Count)
            return false;

        for (int i = 0; i < TypeArguments.Count; i++)
        {
            if (!TypeArguments[i].Equals(st.TypeArguments[i]))
                return false;
        }

        return true;
    }

    public override string ToString()
    {
        if (TypeArguments.Count == 0)
            return Name;

        var typeArgs = string.Join(", ", TypeArguments.Select(t => t.ToString()));
        return $"{Name}<{typeArgs}>";
    }

    public override int GetHashCode()
    {
        var hash = Name.GetHashCode();
        foreach (var arg in TypeArguments)
            hash = HashCode.Combine(hash, arg.GetHashCode());
        return hash;
    }
}

/// <summary>
/// Extension methods for StructType (builder pattern used in tests).
/// </summary>
public static class StructTypeExtensions
{
    public static StructType WithFields(this StructType structType, List<(string Name, TypeBase Type)> fields)
    {
        structType.Fields.Clear();
        structType.Fields.AddRange(fields);
        return structType;
    }
}

/// <summary>
/// Fixed-size array type [T; N].
/// </summary>
public class ArrayType : TypeBase
{
    public ArrayType(TypeBase elementType, int length)
    {
        ElementType = elementType;
        Length = length;
    }

    public TypeBase ElementType { get; }
    public int Length { get; }

    public override string Name => $"[{ElementType}; {Length}]";

    public override int Size => ElementType.Size * Length;

    public override int Alignment => ElementType.Alignment;

    public override bool IsConcrete => ElementType.IsConcrete;

    public override bool Equals(TypeBase other)
    {
        return other is ArrayType at &&
               at.Length == Length &&
               ElementType.Equals(at.ElementType);
    }

    public override int GetHashCode()
    {
        return HashCode.Combine(ElementType.GetHashCode(), Length);
    }
}

/// <summary>
/// Reference type &T.
/// </summary>
public class ReferenceType : TypeBase
{
    private const int PointerSize = 8; // 64-bit pointer

    public ReferenceType(TypeBase innerType)
    {
        InnerType = innerType;
    }

    public TypeBase InnerType { get; }

    public override string Name => $"&{InnerType}";

    public override int Size => PointerSize;

    public override int Alignment => PointerSize;

    public override bool IsConcrete => InnerType.IsConcrete;

    public override bool Equals(TypeBase other)
    {
        return other is ReferenceType rt && InnerType.Equals(rt.InnerType);
    }

    public override int GetHashCode()
    {
        return HashCode.Combine("&", InnerType.GetHashCode());
    }
}

/// <summary>
/// Enum type (if needed for tests).
/// </summary>
public class EnumType : TypeBase
{
    public EnumType(string name, List<(string VariantName, TypeBase? PayloadType)>? variants = null)
    {
        Name = name;
        Variants = variants ?? new List<(string, TypeBase?)>();
    }

    public override string Name { get; }
    public List<(string VariantName, TypeBase? PayloadType)> Variants { get; }

    public override int Size
    {
        get
        {
            if (Variants.Count == 0)
                return 4; // Tag only (i32)

            // Tag (4 bytes) + largest variant payload
            int maxPayloadSize = Variants
                .Where(v => v.PayloadType != null)
                .Select(v => v.PayloadType!.Size)
                .DefaultIfEmpty(0)
                .Max();

            return 4 + maxPayloadSize;
        }
    }

    public override int Alignment
    {
        get
        {
            if (Variants.Count == 0)
                return 4; // Tag alignment

            // Max of tag alignment (4) and variant payload alignments
            int maxPayloadAlignment = Variants
                .Where(v => v.PayloadType != null)
                .Select(v => v.PayloadType!.Alignment)
                .DefaultIfEmpty(1)
                .Max();

            return Math.Max(4, maxPayloadAlignment);
        }
    }

    public override bool Equals(TypeBase other)
    {
        return other is EnumType et && et.Name == Name;
    }
}
