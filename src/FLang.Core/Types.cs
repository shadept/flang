using System.Runtime.CompilerServices;

namespace FLang.Core;

/// <summary>
/// Base class for all types in the FLang type system (Algorithm W-style).
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
    /// <summary>
    /// Initializes a new instance of the <see cref="TypeVar"/> class.
    /// </summary>
    /// <param name="id">The identifier for this type variable.</param>
    /// <param name="declarationSpan">Optional source span where this type variable was declared.</param>
    public TypeVar(string id, SourceSpan? declarationSpan = null)
    {
        Id = id;
        DeclarationSpan = declarationSpan;
    }

    /// <summary>
    /// Gets the identifier of this type variable.
    /// </summary>
    public string Id { get; }

    /// <summary>
    /// Gets the source location where this type variable was declared, if available.
    /// </summary>
    public SourceSpan? DeclarationSpan { get; }

    /// <summary>
    /// The type this variable is bound to (null if unbound).
    /// </summary>
    public TypeBase? Instance { get; set; }

    public override string Name => Instance?.Name ?? $"?TV_{Id}";

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
        if (Instance == null) return this;
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
/// Represents a generic parameter type like $T used in generic function signatures.
/// </summary>
public class GenericParameterType : TypeBase
{
    /// <summary>
    /// Initializes a new instance of the <see cref="GenericParameterType"/> class.
    /// </summary>
    /// <param name="name">The name of the generic parameter (e.g., "T").</param>
    public GenericParameterType(string name)
    {
        ParamName = name;
    }

    /// <summary>
    /// Gets the name of this generic parameter.
    /// </summary>
    public string ParamName { get; }

    public override string Name => ParamName;

    public override int Size =>
        throw new InvalidOperationException($"Cannot get size of generic parameter type ${ParamName}");

    public override int Alignment =>
        throw new InvalidOperationException($"Cannot get alignment of generic parameter type ${ParamName}");

    public override bool Equals(TypeBase other)
    {
        return other is GenericParameterType g && g.ParamName == ParamName;
    }

    public override int GetHashCode()
    {
        return ParamName.GetHashCode();
    }
}

/// <summary>
/// Represents primitive types like i32, bool, etc.
/// </summary>
public class PrimitiveType : TypeBase
{
    /// <summary>
    /// Initializes a new instance of the <see cref="PrimitiveType"/> class with explicit size and alignment.
    /// </summary>
    /// <param name="name">The name of the primitive type (e.g., "i32", "bool").</param>
    /// <param name="sizeInBytes">The size of the type in bytes.</param>
    /// <param name="alignmentInBytes">The alignment requirement in bytes.</param>
    public PrimitiveType(string name, int sizeInBytes, int alignmentInBytes)
    {
        Name = name;
        SizeInBytes = sizeInBytes;
        AlignmentInBytes = alignmentInBytes;
    }

    /// <summary>
    /// Initializes a new instance of the <see cref="PrimitiveType"/> class (legacy constructor).
    /// Assumes alignment equals size.
    /// </summary>
    /// <param name="name">The name of the primitive type.</param>
    /// <param name="sizeInBytes">The size of the type in bytes.</param>
    /// <param name="isSigned">Whether this is a signed integer type.</param>
    public PrimitiveType(string name, int sizeInBytes, bool isSigned = true)
        : this(name, sizeInBytes, sizeInBytes)
    {
        IsSigned = isSigned;
    }

    /// <summary>
    /// Gets the name of this primitive type.
    /// </summary>
    public override string Name { get; }

    /// <summary>
    /// Gets the size of this type in bytes.
    /// </summary>
    public int SizeInBytes { get; }

    /// <summary>
    /// Gets the alignment requirement of this type in bytes.
    /// </summary>
    public int AlignmentInBytes { get; }

    /// <summary>
    /// Gets or sets whether this is a signed integer type.
    /// </summary>
    public bool IsSigned { get; init; } = true;

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
    public static readonly ComptimeInt Instance = new();

    private ComptimeInt()
    {
    }

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
/// Represents compile-time float type that must be resolved during type inference.
/// </summary>
public class ComptimeFloat : TypeBase
{
    public static readonly ComptimeFloat Instance = new();

    private ComptimeFloat()
    {
    }

    public override string Name => "comptime_float";

    public override int Size =>
        throw new InvalidOperationException("Cannot get size of comptime_float (not a concrete type)");

    public override int Alignment =>
        throw new InvalidOperationException("Cannot get alignment of comptime_float (not a concrete type)");

    public override bool IsConcrete => false;

    public override bool Equals(TypeBase other)
    {
        return other is ComptimeFloat;
    }
}

/// <summary>
/// Represents a reference type like &amp;T.
/// </summary>
public class ReferenceType : TypeBase
{
    /// <summary>
    /// Initializes a new instance of the <see cref="ReferenceType"/> class.
    /// </summary>
    /// <param name="innerType">The type being referenced.</param>
    /// <param name="pointerWidth">The platform pointer width (32 or 64 bits).</param>
    public ReferenceType(TypeBase innerType, PointerWidth pointerWidth = PointerWidth.Bits64)
    {
        InnerType = innerType;
        PointerWidth = pointerWidth;
    }

    /// <summary>
    /// Gets the type being referenced.
    /// </summary>
    public TypeBase InnerType { get; }

    /// <summary>
    /// Gets the platform pointer width.
    /// </summary>
    public PointerWidth PointerWidth { get; }

    public override string Name => $"&{InnerType}";

    public override int Size => PointerWidth.Size;

    public override int Alignment => PointerWidth.Size;

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
/// Represents a generic type like List(T), Dict(K, V).
/// </summary>
public class GenericType : TypeBase
{
    /// <summary>
    /// Initializes a new instance of the <see cref="GenericType"/> class.
    /// </summary>
    /// <param name="baseName">The base name of the generic type (e.g., "List", "Dict").</param>
    /// <param name="typeArguments">The type arguments for this generic instantiation.</param>
    public GenericType(string baseName, IReadOnlyList<TypeBase> typeArguments)
    {
        BaseName = baseName;
        TypeArguments = typeArguments;
    }

    /// <summary>
    /// Gets the base name of this generic type.
    /// </summary>
    public string BaseName { get; }

    /// <summary>
    /// Gets the type arguments for this generic instantiation.
    /// </summary>
    public IReadOnlyList<TypeBase> TypeArguments { get; }

    public override string Name => $"{BaseName}[{string.Join(", ", TypeArguments.Select(t => t.Name))}]";

    public override int Size =>
        throw new InvalidOperationException($"Cannot get size of uninstantiated generic type {Name}");

    public override int Alignment =>
        throw new InvalidOperationException($"Cannot get alignment of uninstantiated generic type {Name}");

    public override bool Equals(TypeBase other)
    {
        if (other is not GenericType gt) return false;
        if (BaseName != gt.BaseName) return false;
        if (TypeArguments.Count != gt.TypeArguments.Count) return false;
        for (var i = 0; i < TypeArguments.Count; i++)
            if (!TypeArguments[i].Equals(gt.TypeArguments[i]))
                return false;
        return true;
    }

    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add(BaseName);
        foreach (var arg in TypeArguments) hash.Add(arg);
        return hash.ToHashCode();
    }
}

/// <summary>
/// Represents a struct type with fields and optional type arguments.
/// </summary>
public class StructType : TypeBase
{
    private int? _cachedSize;
    private int? _cachedAlignment;
    private readonly Dictionary<string, int> _fieldOffsets = [];

    /// <summary>
    /// Initializes a new instance of the <see cref="StructType"/> class.
    /// </summary>
    /// <param name="name">The fully qualified name of the struct.</param>
    /// <param name="typeArguments">Optional type arguments for generic structs.</param>
    /// <param name="fields">Optional list of field names and types.</param>
    public StructType(string name, List<TypeBase>? typeArguments = null,
        List<(string Name, TypeBase Type)>? fields = null)
    {
        StructName = name;
        Name = name; // Fully qualified name
        TypeArguments = typeArguments ?? [];
        TypeParameters = new List<string>(); // Empty for new style
        Fields = fields ?? [];
        ComputeLayout();
    }

    /// <summary>
    /// Gets the struct's base name (same as Name for new-style structs).
    /// </summary>
    public string StructName { get; }

    /// <summary>
    /// Gets the fully qualified name of this struct type.
    /// </summary>
    public override string Name { get; }

    /// <summary>
    /// Gets the type arguments for this generic struct instantiation.
    /// </summary>
    public List<TypeBase> TypeArguments { get; }

    /// <summary>
    /// Gets the legacy type parameter names (deprecated, use TypeArguments instead).
    /// </summary>
    public IReadOnlyList<string> TypeParameters { get; } // Legacy

    /// <summary>
    /// Gets the list of fields in this struct.
    /// </summary>
    public List<(string Name, TypeBase Type)> Fields { get; }

    public override int Size
    {
        get
        {
            if (_cachedSize.HasValue)
                return _cachedSize.Value;

            // Recompute if needed
            ComputeLayout();
            return _cachedSize ?? 0;
        }
    }

    public override int Alignment
    {
        get
        {
            if (_cachedAlignment.HasValue)
                return _cachedAlignment.Value;

            // Recompute if needed
            ComputeLayout();
            return _cachedAlignment ?? 1;
        }
    }

    /// <summary>
    /// Computes the memory layout of this struct, calculating field offsets, total size, and alignment.
    /// </summary>
    private void ComputeLayout()
    {
        // Check if contains generic parameters
        bool containsGeneric = Fields.Any(field => ContainsGeneric(field.Type)) ||
                               TypeArguments.Any(t => !t.IsConcrete);

        if (containsGeneric)
        {
            foreach (var (name, _) in Fields)
                _fieldOffsets[name] = 0;
            _cachedSize = 0;
            _cachedAlignment = 1;
            return;
        }

        if (Fields.Count == 0)
        {
            _cachedSize = 0;
            _cachedAlignment = 1;
            return;
        }

        int offset = 0;
        int maxAlignment = 1;

        foreach (var (name, type) in Fields)
        {
            var alignment = type.Alignment;
            maxAlignment = Math.Max(maxAlignment, alignment);

            // Align offset to field's alignment requirement
            offset = AlignUp(offset, alignment);

            // Store field offset
            _fieldOffsets[name] = offset;

            // Advance offset by field size
            offset += type.Size;
        }

        // Add trailing padding to align to largest field
        _cachedSize = AlignUp(offset, maxAlignment);
        _cachedAlignment = maxAlignment;
    }

    /// <summary>
    /// Aligns an offset up to the next multiple of the specified alignment.
    /// </summary>
    /// <param name="offset">The offset to align.</param>
    /// <param name="alignment">The alignment requirement in bytes.</param>
    /// <returns>The aligned offset.</returns>
    private static int AlignUp(int offset, int alignment)
    {
        if (alignment <= 0) return offset;
        return (offset + alignment - 1) / alignment * alignment;
    }

    /// <summary>
    /// Checks whether a type contains generic parameters or type variables.
    /// </summary>
    /// <param name="type">The type to check.</param>
    /// <returns>True if the type contains generic parameters; otherwise, false.</returns>
    private static bool ContainsGeneric(TypeBase type) => type switch
    {
        GenericParameterType => true,
        TypeVar => true,
        ReferenceType rt => ContainsGeneric(rt.InnerType),
        ArrayType at => ContainsGeneric(at.ElementType),
        StructType st => st.Fields.Any(f => ContainsGeneric(f.Type)) || st.TypeArguments.Any(t => ContainsGeneric(t)),
        GenericType => true,
        _ => false
    };

    public override bool Equals(TypeBase other)
    {
        if (other is not StructType st) return false;
        if (StructName != st.StructName) return false;

        // Compare type arguments (new style)
        if (TypeArguments.Count != st.TypeArguments.Count) return false;
        for (int i = 0; i < TypeArguments.Count; i++)
        {
            if (!TypeArguments[i].Equals(st.TypeArguments[i]))
                return false;
        }

        // Compare type parameters (legacy style)
        if (TypeParameters.Count != st.TypeParameters.Count) return false;
        for (var i = 0; i < TypeParameters.Count; i++)
            if (TypeParameters[i] != st.TypeParameters[i])
                return false;

        return true;
    }

    public override int GetHashCode()
    {
        var hash = StructName.GetHashCode();
        foreach (var arg in TypeArguments)
            hash = HashCode.Combine(hash, arg.GetHashCode());
        foreach (var param in TypeParameters)
            hash = HashCode.Combine(hash, param);
        return hash;
    }

    public override string ToString()
    {
        // Extract simple name from FQN for display (e.g., "core.string.String" -> "String")
        var displayName = GetSimpleName(StructName);

        if (TypeArguments.Count > 0)
        {
            var typeArgs = string.Join(", ", TypeArguments.Select(t => t.ToString()));
            return $"{displayName}({typeArgs})";
        }

        if (TypeParameters.Count > 0)
        {
            return $"{displayName}[{string.Join(", ", TypeParameters)}]";
        }

        return displayName;
    }

    /// <summary>
    /// Extracts the simple name from a fully qualified name (e.g., "core.string.String" becomes "String").
    /// </summary>
    /// <param name="fqn">The fully qualified name.</param>
    /// <returns>The simple name without namespace qualifiers.</returns>
    private static string GetSimpleName(string fqn)
    {
        var lastDot = fqn.LastIndexOf('.');
        return lastDot >= 0 ? fqn.Substring(lastDot + 1) : fqn;
    }

    /// <summary>
    /// Looks up a field by name. Returns null if not found.
    /// </summary>
    public TypeBase? GetFieldType(string fieldName)
    {
        foreach (var (name, type) in Fields)
            if (name == fieldName)
                return type;
        return null;
    }

    /// <summary>
    /// Returns the byte offset of a field within the struct.
    /// Returns -1 if field not found.
    /// </summary>
    public int GetFieldOffset(string fieldName)
    {
        // Ensure layout is computed
        if (_fieldOffsets.Count == 0 && Fields.Count > 0)
            ComputeLayout();

        return _fieldOffsets.GetValueOrDefault(fieldName, -1);
    }
}

/// <summary>
/// Extension methods for StructType (builder pattern used in tests).
/// </summary>
public static class StructTypeExtensions
{
    /// <summary>
    /// Replaces the fields of a struct type and invalidates the cached layout.
    /// Used in tests and internal type construction.
    /// </summary>
    /// <param name="structType">The struct type to modify.</param>
    /// <param name="fields">The new list of fields.</param>
    /// <returns>The modified struct type for method chaining.</returns>
    public static StructType WithFields(this StructType structType, List<(string Name, TypeBase Type)> fields)
    {
        // TODO make this part of a StructTypeBuilder
        structType.Fields.Clear();
        structType.Fields.AddRange(fields);
        // Invalidate cached layout
        typeof(StructType)
            .GetField("_cachedSize", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)
            ?.SetValue(structType, null);
        typeof(StructType)
            .GetField("_cachedAlignment",
                System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)
            ?.SetValue(structType, null);
        return structType;
    }
}

/// <summary>
/// Represents a fixed-size array type like [T; N].
/// </summary>
public class ArrayType : TypeBase
{
    /// <summary>
    /// Initializes a new instance of the <see cref="ArrayType"/> class.
    /// </summary>
    /// <param name="elementType">The type of elements in the array.</param>
    /// <param name="length">The fixed length of the array.</param>
    public ArrayType(TypeBase elementType, int length)
    {
        ElementType = elementType;
        Length = length;
    }

    /// <summary>
    /// Gets the type of elements in this array.
    /// </summary>
    public TypeBase ElementType { get; }

    /// <summary>
    /// Gets the fixed length of this array.
    /// </summary>
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
/// Represents a first-class function type like fn(T1, T2) R.
/// Used for passing functions as arguments and storing them in variables.
/// </summary>
public class FunctionType : TypeBase
{
    /// <summary>
    /// Initializes a new instance of the <see cref="FunctionType"/> class.
    /// </summary>
    /// <param name="parameterTypes">The types of the function parameters.</param>
    /// <param name="returnType">The return type of the function.</param>
    /// <param name="pointerWidth">The platform pointer width (32 or 64 bits).</param>
    public FunctionType(IReadOnlyList<TypeBase> parameterTypes, TypeBase returnType, PointerWidth pointerWidth = PointerWidth.Bits64)
    {
        ParameterTypes = parameterTypes;
        ReturnType = returnType;
        PointerWidth = pointerWidth;
    }

    /// <summary>
    /// Gets the parameter types of this function type.
    /// </summary>
    public IReadOnlyList<TypeBase> ParameterTypes { get; }

    /// <summary>
    /// Gets the return type of this function type.
    /// </summary>
    public TypeBase ReturnType { get; }

    /// <summary>
    /// Gets the platform pointer width.
    /// </summary>
    public PointerWidth PointerWidth { get; }

    public override string Name
    {
        get
        {
            var paramList = string.Join(", ", ParameterTypes.Select(t => t.Name));
            return $"fn({paramList}) {ReturnType.Name}";
        }
    }

    /// <summary>
    /// Function types are pointer-sized (function pointer).
    /// </summary>
    public override int Size => PointerWidth.Size;

    /// <summary>
    /// Function types are pointer-aligned.
    /// </summary>
    public override int Alignment => PointerWidth.Size;

    public override bool IsConcrete => ParameterTypes.All(p => p.IsConcrete) && ReturnType.IsConcrete;

    public override bool Equals(TypeBase other)
    {
        if (other is not FunctionType ft) return false;
        if (ParameterTypes.Count != ft.ParameterTypes.Count) return false;
        for (var i = 0; i < ParameterTypes.Count; i++)
        {
            if (!ParameterTypes[i].Equals(ft.ParameterTypes[i]))
                return false;
        }
        return ReturnType.Equals(ft.ReturnType);
    }

    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add("fn");
        foreach (var param in ParameterTypes)
            hash.Add(param.GetHashCode());
        hash.Add(ReturnType.GetHashCode());
        return hash.ToHashCode();
    }
}

/// <summary>
/// Enum type (for tagged unions).
/// Memory layout is abstracted through query methods to enable future niche optimization.
/// </summary>
public class EnumType : TypeBase
{
    /// <summary>
    /// Initializes a new instance of the <see cref="EnumType"/> class.
    /// </summary>
    /// <param name="name">The fully qualified name of the enum type.</param>
    /// <param name="typeArguments">The type arguments for generic enums.</param>
    /// <param name="variants">The list of variants with their optional payload types.</param>
    public EnumType(string name, List<TypeBase> typeArguments,
        List<(string VariantName, TypeBase? PayloadType)> variants)
    {
        Name = name;
        TypeArguments = typeArguments;
        Variants = variants;
    }

    /// <summary>
    /// Gets the fully qualified name of this enum type.
    /// </summary>
    public override string Name { get; }

    /// <summary>
    /// Gets the type arguments for this generic enum instantiation.
    /// </summary>
    public List<TypeBase> TypeArguments { get; }

    /// <summary>
    /// Gets the list of variants in this enum, each with an optional payload type.
    /// </summary>
    public List<(string VariantName, TypeBase? PayloadType)> Variants { get; }

    /// <summary>
    /// Get the byte offset of the discriminant tag within the enum.
    /// Default implementation: tag at offset 0.
    /// Can be overridden for niche optimization (e.g., Option(&amp;T) has no tag).
    /// </summary>
    public int GetTagOffset() => 0;

    /// <summary>
    /// Get the byte offset of the payload data for a specific variant.
    /// Default implementation: payload starts after 4-byte tag.
    /// Can be overridden for niche optimization.
    /// </summary>
    public int GetPayloadOffset(int variantIndex) => 4;

    /// <summary>
    /// Get the size of the payload for a specific variant (in bytes).
    /// </summary>
    public int GetVariantPayloadSize(int variantIndex)
    {
        if (variantIndex < 0 || variantIndex >= Variants.Count)
            return 0;

        var payloadType = Variants[variantIndex].PayloadType;
        return payloadType?.Size ?? 0;
    }

    /// <summary>
    /// Get the size of the discriminant tag (in bytes).
    /// Default: 4 bytes (i32).
    /// </summary>
    protected int GetTagSize() => 4;

    /// <summary>
    /// Gets the largest payload size among all variants.
    /// </summary>
    /// <returns>The size in bytes of the largest variant payload.</returns>
    protected int GetLargestPayloadSize()
    {
        return Variants
            .Where(v => v.PayloadType != null)
            .Select(v => v.PayloadType!.Size)
            .DefaultIfEmpty(0)
            .Max();
    }

    public override int Size
    {
        get
        {
            if (Variants.Count == 0)
                return GetTagSize();

            // Default implementation: tag + largest variant payload
            // Future niche optimizations can override this
            return GetTagSize() + GetLargestPayloadSize();
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