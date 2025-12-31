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
/// Represents a generic parameter type like $T used in generic function signatures.
/// </summary>
public class GenericParameterType : TypeBase
{
    public GenericParameterType(string name)
    {
        ParamName = name;
    }

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
    public PrimitiveType(string name, int sizeInBytes, int alignmentInBytes)
    {
        Name = name;
        SizeInBytes = sizeInBytes;
        AlignmentInBytes = alignmentInBytes;
    }

    // Legacy constructor for compatibility (assumes alignment = size)
    public PrimitiveType(string name, int sizeInBytes, bool isSigned = true)
        : this(name, sizeInBytes, sizeInBytes)
    {
        IsSigned = isSigned;
    }

    public override string Name { get; }
    public int SizeInBytes { get; }
    public int AlignmentInBytes { get; }
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
    public ReferenceType(TypeBase innerType, PointerWidth pointerWidth = PointerWidth.Bits64)
    {
        InnerType = innerType;
        PointerWidth = pointerWidth;
    }

    public TypeBase InnerType { get; }
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
    public GenericType(string baseName, IReadOnlyList<TypeBase> typeArguments)
    {
        BaseName = baseName;
        TypeArguments = typeArguments;
    }

    public string BaseName { get; }
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

    // New constructor (takes TypeBase type arguments)
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

    public string StructName { get; }
    public override string Name { get; }
    public List<TypeBase> TypeArguments { get; }
    public IReadOnlyList<string> TypeParameters { get; } // Legacy
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

    private static int AlignUp(int offset, int alignment)
    {
        return (offset + alignment - 1) / alignment * alignment;
    }

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
/// Enum type (for tagged unions).
/// Memory layout is abstracted through query methods to enable future niche optimization.
/// </summary>
public class EnumType : TypeBase
{
    public EnumType(string name, List<TypeBase> typeArguments,
        List<(string VariantName, TypeBase? PayloadType)> variants)
    {
        Name = name;
        TypeArguments = typeArguments;
        Variants = variants;
    }

    public override string Name { get; }
    public List<TypeBase> TypeArguments { get; }
    public List<(string VariantName, TypeBase? PayloadType)> Variants { get; }

    /// <summary>
    /// Get the byte offset of the discriminant tag within the enum.
    /// Default implementation: tag at offset 0.
    /// Can be overridden for niche optimization (e.g., Option(&amp;T) has no tag).
    /// </summary>
    public virtual int GetTagOffset() => 0;

    /// <summary>
    /// Get the byte offset of the payload data for a specific variant.
    /// Default implementation: payload starts after 4-byte tag.
    /// Can be overridden for niche optimization.
    /// </summary>
    public virtual int GetPayloadOffset(int variantIndex) => 4;

    /// <summary>
    /// Get the size of the payload for a specific variant (in bytes).
    /// </summary>
    public virtual int GetVariantPayloadSize(int variantIndex)
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
    protected virtual int GetTagSize() => 4;

    /// <summary>
    /// Get the largest payload size among all variants.
    /// </summary>
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

/// <summary>
/// Registry of all built-in types and well-known composite types.
/// </summary>
public static class TypeRegistry
{
    // Fully qualified names for well-known types
    private const string OptionFqn = "core.option.Option";
    private const string RangeFqn = "core.range.Range";
    private const string SliceFqn = "core.slice.Slice";
    private const string StringFqn = "core.string.String";
    private const string TypeFqn = "core.rtti.Type";

    // Never type (the bottom type)
    public static readonly PrimitiveType Never = new("never", 0, 0);

    // Void type (for functions with no return value)
    public static readonly PrimitiveType Void = new("void", 0, 0);

    // Boolean type
    public static readonly PrimitiveType Bool = new("bool", 1, 1);

    // Signed integer types
    public static readonly PrimitiveType I8 = new("i8", 1, 1);
    public static readonly PrimitiveType I16 = new("i16", 2, 2);
    public static readonly PrimitiveType I32 = new("i32", 4, 4);
    public static readonly PrimitiveType I64 = new("i64", 8, 8);

    // Unsigned integer types
    public static readonly PrimitiveType U8 = new("u8", 1, 1) { IsSigned = false };
    public static readonly PrimitiveType U16 = new("u16", 2, 2) { IsSigned = false };
    public static readonly PrimitiveType U32 = new("u32", 4, 4) { IsSigned = false };
    public static readonly PrimitiveType U64 = new("u64", 8, 8) { IsSigned = false };

    // Platform-dependent integer types
    public static readonly PrimitiveType ISize = new("isize", IntPtr.Size, IntPtr.Size);
    public static readonly PrimitiveType USize = new("usize", IntPtr.Size, IntPtr.Size) { IsSigned = false };

    // Compile-time types
    public static readonly ComptimeInt ComptimeInt = ComptimeInt.Instance;
    public static readonly ComptimeFloat ComptimeFloat = ComptimeFloat.Instance;

    // Canonical struct representation for String (binary layout: ptr + len)
    public static readonly StructType StringStruct = new(StringFqn, [], [
        ("ptr", new ReferenceType(U8, PointerWidth.Bits64)),
        ("len", USize)
    ]);

    // Type struct template for runtime type information
    public static readonly StructType TypeStructTemplate = new(TypeFqn, [], [
        ("name", StringStruct),
        ("size", U8),
        ("align", U8)
    ]);


    // Cache for well-known types to ensure reference equality
    private static readonly Dictionary<TypeBase, StructType> _sliceStructCache = [];
    private static readonly Dictionary<TypeBase, StructType> _optionStructCache = [];
    private static readonly Dictionary<TypeBase, StructType> _typeStructCache = [];

    /// <summary>
    /// Looks up a type by name. Returns null if not found.
    /// </summary>
    public static TypeBase? GetTypeByName(string name)
    {
        return name switch
        {
            "bool" => Bool,
            "i8" => I8,
            "i16" => I16,
            "i32" => I32,
            "i64" => I64,
            "u8" => U8,
            "u16" => U16,
            "u32" => U32,
            "u64" => U64,
            "isize" => ISize,
            "usize" => USize,
            "comptime_int" => ComptimeInt,
            "comptime_float" => ComptimeFloat,
            _ => null
        };
    }

    /// <summary>
    /// Returns true if the given type is an integer type (including comptime_int).
    /// </summary>
    public static bool IsIntegerType(TypeBase type)
    {
        return type is ComptimeInt || (type is PrimitiveType pt && IsIntegerType(pt.Name));
    }

    public static bool IsIntegerType(string typeName)
    {
        return typeName is "i8" or "i16" or "i32" or "i64" or "isize" or "u8" or "u16" or "u32" or "u64" or "usize";
    }

    /// <summary>
    /// Returns true if the given type is a numeric type (int or float).
    /// </summary>
    public static bool IsNumericType(TypeBase type)
    {
        return IsIntegerType(type) || type is ComptimeFloat;
    }

    /// <summary>
    /// Returns true if the given type is a compile-time type that needs resolution.
    /// </summary>
    public static bool IsComptimeType(TypeBase type)
    {
        return type is ComptimeInt || type is ComptimeFloat;
    }

    /// <summary>
    /// Creates an Option&lt;T&gt; type with fully qualified name (Algorithm W style).
    /// </summary>
    public static StructType MakeOption(TypeBase innerType)
    {
        var key = innerType;
        if (_optionStructCache.TryGetValue(key, out var cached))
            return cached;

        var optionType = new StructType(OptionFqn, [innerType]);

        // Add fields: has_value: bool, value: T
        optionType.WithFields([
            ("has_value", Bool),
            ("value", innerType)
        ]);

        _optionStructCache[key] = optionType;
        return optionType;
    }

    /// <summary>
    /// Creates a Slice&lt;T&gt; type with fully qualified name (Algorithm W style).
    /// </summary>
    public static StructType MakeSlice(TypeBase elementType)
    {
        var key = elementType;
        if (_sliceStructCache.TryGetValue(key, out var cached))
            return cached;

        var sliceType = new StructType(SliceFqn, [elementType]);

        // Add fields: ptr: &T, len: usize
        sliceType.WithFields([
            ("ptr", new ReferenceType(elementType, PointerWidth.Bits64)),
            ("len", USize)
        ]);

        _sliceStructCache[key] = sliceType;
        return sliceType;
    }

    /// <summary>
    /// Creates a String type (equivalent to Slice&lt;u8&gt;).
    /// </summary>
    public static StructType MakeString()
    {
        return StringStruct; // Use existing canonical String struct
    }

    /// <summary>
    /// Gets or creates a Type(T) struct instance for the given type parameter.
    /// All instances have the same layout, differing only in the type parameter.
    /// </summary>
    public static StructType MakeType(TypeBase innerType)
    {
        if (_typeStructCache.TryGetValue(innerType, out var cached))
            return cached;

        var typeStruct = new StructType(TypeFqn, [innerType], [
            ("name", StringStruct),
            ("size", U8),
            ("align", U8)
        ]);

        _typeStructCache[innerType] = typeStruct;
        return typeStruct;
    }

    /// <summary>
    /// Checks if a TypeBase is Option&lt;T&gt; (convenience overload).
    /// </summary>
    public static bool IsOption(TypeBase type)
    {
        return type is StructType st && IsOption(st);
    }

    /// <summary>
    /// Checks if a StructType is Option&lt;T&gt; using fully qualified name.
    /// </summary>
    public static bool IsOption(StructType st)
    {
        return st.StructName == OptionFqn;
    }

    /// <summary>
    /// Checks if a TypeBase is Slice&lt;T&gt; (convenience overload).
    /// </summary>
    public static bool IsSlice(TypeBase type)
    {
        return type is StructType st && IsSlice(st);
    }

    /// <summary>
    /// Checks if a StructType is Slice&lt;T&gt; using fully qualified name.
    /// </summary>
    public static bool IsSlice(StructType st)
    {
        return st.StructName == SliceFqn;
    }

    /// <summary>
    /// Checks if a TypeBase is String (convenience overload).
    /// </summary>
    public static bool IsString(TypeBase type)
    {
        return type is StructType st && IsString(st);
    }

    /// <summary>
    /// Checks if a StructType is String using fully qualified name.
    /// </summary>
    public static bool IsString(StructType st)
    {
        return st.StructName == StringFqn;
    }

    /// <summary>
    /// Checks if a TypeBase is Range (convenience overload).
    /// </summary>
    public static bool IsRange(TypeBase type)
    {
        return type is StructType st && IsRange(st);
    }

    /// <summary>
    /// Checks if a StructType is Range using fully qualified name.
    /// </summary>
    public static bool IsRange(StructType st)
    {
        return st.StructName == RangeFqn;
    }

    /// <summary>
    /// Checks if a TypeBase is Type (convenience overload).
    /// </summary>
    public static bool IsType(TypeBase type)
    {
        return type is StructType st && IsType(st);
    }

    /// <summary>
    /// Checks if a StructType is Type using fully qualified name.
    /// </summary>
    public static bool IsType(StructType st)
    {
        return st.StructName == TypeFqn;
    }
}