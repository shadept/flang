using System.Linq;

namespace FLang.Core;

/// <summary>
/// Base class for all types in the FLang type system.
/// </summary>
public abstract class FType
{
    public abstract string Name { get; }

    /// <summary>
    /// Gets the size of this type in bytes.
    /// Used by size_of intrinsic.
    /// </summary>
    public abstract int Size { get; }

    /// <summary>
    /// Gets the alignment requirement of this type in bytes.
    /// Used by align_of intrinsic.
    /// </summary>
    public abstract int Alignment { get; }

    public abstract bool Equals(FType other);

    public override bool Equals(object? obj)
    {
        return obj is FType other && Equals(other);
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
/// Represents a generic parameter type like $T used in generic function signatures.
/// </summary>
public class GenericParameterType : FType
{
    public GenericParameterType(string name)
    {
        ParamName = name;
    }

    public string ParamName { get; }

    public override string Name => "$" + ParamName;

    public override int Size =>
        throw new InvalidOperationException($"Cannot get size of generic parameter type ${ParamName}");

    public override int Alignment =>
        throw new InvalidOperationException($"Cannot get alignment of generic parameter type ${ParamName}");

    public override bool Equals(FType other)
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
public class PrimitiveType : FType
{
    public PrimitiveType(string name, int sizeInBytes, bool isSigned = true)
    {
        Name = name;
        SizeInBytes = sizeInBytes;
        IsSigned = isSigned;
    }

    public override string Name { get; }
    public int SizeInBytes { get; }
    public bool IsSigned { get; }

    public override int Size => SizeInBytes;

    public override int Alignment => SizeInBytes; // Primitives align to their size

    public override bool Equals(FType other)
    {
        return other is PrimitiveType pt && pt.Name == Name;
    }
}

/// <summary>
/// Represents compile-time integer type that must be resolved during type inference.
/// </summary>
public class ComptimeIntType : FType
{
    public static readonly ComptimeIntType Instance = new();

    private ComptimeIntType()
    {
    }

    public override string Name => "comptime_int";

    public override int Size => 8; // Assume isize (64-bit)

    public override int Alignment => 8;

    public override bool Equals(FType other)
    {
        return other is ComptimeIntType;
    }
}

/// <summary>
/// Represents compile-time float type that must be resolved during type inference.
/// </summary>
public class ComptimeFloatType : FType
{
    public static readonly ComptimeFloatType Instance = new();

    private ComptimeFloatType()
    {
    }

    public override string Name => "comptime_float";

    public override int Size => 8; // Assume f64

    public override int Alignment => 8;

    public override bool Equals(FType other)
    {
        return other is ComptimeFloatType;
    }
}

/// <summary>
/// Represents a reference type like &T.
/// </summary>
public class ReferenceType : FType
{
    public ReferenceType(FType innerType)
    {
        InnerType = innerType;
    }

    public FType InnerType { get; }

    public override string Name => $"&{InnerType.Name}";

    public override int Size => 8; // 64-bit pointer

    public override int Alignment => 8;

    public override bool Equals(FType other)
    {
        return other is ReferenceType rt && InnerType.Equals(rt.InnerType);
    }

    public override int GetHashCode()
    {
        return HashCode.Combine(Name, InnerType);
    }
}

/// <summary>
/// Represents an optional type (nullable) like T? or Option(T).
/// Placeholder for future milestones.
/// </summary>
public class OptionType : FType
{
    public OptionType(FType innerType)
    {
        InnerType = innerType;
    }

    public FType InnerType { get; }

    public override string Name => $"{InnerType.Name}?";

    public override int Size => InnerType.Size;

    public override int Alignment => InnerType.Alignment;

    public override bool Equals(FType other)
    {
        return other is OptionType ot && InnerType.Equals(ot.InnerType);
    }

    public override int GetHashCode()
    {
        return HashCode.Combine(Name, InnerType);
    }
}

public sealed class NullType : FType
{
    public static readonly NullType Instance = new();

    private NullType() { }

    public override string Name => "null";

    public override bool Equals(FType other) => ReferenceEquals(this, other);

    public override int GetHashCode() => Name.GetHashCode();

    public override int Size => 0;

    public override int Alignment => 1;
}

/// <summary>
/// Represents a generic type like List[T], Dict[K, V].
/// Placeholder for future milestones.
/// </summary>
public class GenericType : FType
{
    public GenericType(string baseName, IReadOnlyList<FType> typeArguments)
    {
        BaseName = baseName;
        TypeArguments = typeArguments;
    }

    public string BaseName { get; }
    public IReadOnlyList<FType> TypeArguments { get; }

    public override string Name => $"{BaseName}[{string.Join(", ", TypeArguments.Select(t => t.Name))}]";

    public override int Size =>
        throw new InvalidOperationException($"Cannot get size of uninstantiated generic type {Name}");

    public override int Alignment =>
        throw new InvalidOperationException($"Cannot get alignment of uninstantiated generic type {Name}");

    public override bool Equals(FType other)
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
/// Represents a struct type with fields.
/// </summary>
public class StructType : FType
{
    private readonly int _size;
    private readonly int _alignment;
    private readonly Dictionary<string, int> _fieldOffsets;

    public StructType(string structName, IReadOnlyList<string> typeParameters, IReadOnlyList<(string, FType)> fields)
    {
        StructName = structName;
        TypeParameters = typeParameters;
        Fields = fields;

        // Precompute layout
        _fieldOffsets = [];

        bool containsGeneric = fields.Any(field => ContainsGeneric(field.Item2));
        if (containsGeneric)
        {
            foreach (var (name, _) in fields)
                _fieldOffsets[name] = 0;
            _size = 0;
            _alignment = 1;
            return;
        }

        int offset = 0;
        int maxAlignment = 1;

        foreach (var (name, type) in fields)
        {
            var alignment = type.Alignment;
            maxAlignment = Math.Max(maxAlignment, alignment);

            // Align offset to field's alignment requirement
            offset = AlignOffset(offset, alignment);

            // Store field offset
            _fieldOffsets[name] = offset;

            // Advance offset by field size
            offset += type.Size;
        }

        // Add trailing padding to align to largest field
        _size = AlignOffset(offset, maxAlignment);
        _alignment = maxAlignment;
    }

    public string StructName { get; }
    public IReadOnlyList<string> TypeParameters { get; }
    public IReadOnlyList<(string Name, FType Type)> Fields { get; }

    public override string Name
    {
        get
        {
            if (TypeParameters.Count > 0) return $"{StructName}[{string.Join(", ", TypeParameters)}]";
            return StructName;
        }
    }

    public override bool Equals(FType other)
    {
        if (other is not StructType st) return false;
        if (StructName != st.StructName) return false;
        if (TypeParameters.Count != st.TypeParameters.Count) return false;
        for (var i = 0; i < TypeParameters.Count; i++)
            if (TypeParameters[i] != st.TypeParameters[i])
                return false;
        // Note: We don't compare fields for equality to allow structural typing
        return true;
    }

    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add(StructName);
        foreach (var param in TypeParameters) hash.Add(param);
        return hash.ToHashCode();
    }

    /// <summary>
    /// Looks up a field by name. Returns null if not found.
    /// </summary>
    public FType? GetFieldType(string fieldName)
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
        return _fieldOffsets.TryGetValue(fieldName, out var offset) ? offset : -1;
    }

    public override int Size => _size;

    public override int Alignment => _alignment;

    /// <summary>
    /// Aligns an offset to the specified alignment.
    /// </summary>
    private static int AlignOffset(int offset, int alignment)
    {
        return (offset + alignment - 1) / alignment * alignment;
    }

    private static bool ContainsGeneric(FType type) => type switch
    {
        GenericParameterType => true,
        ReferenceType rt => ContainsGeneric(rt.InnerType),
        OptionType ot => ContainsGeneric(ot.InnerType),
        ArrayType at => ContainsGeneric(at.ElementType),
        SliceType st => ContainsGeneric(st.ElementType),
        StructType st => st.Fields.Any(f => ContainsGeneric(f.Type)),
        GenericType => true,
        _ => false
    };
}

/// <summary>
/// Represents a fixed-size array type like [T; N].
/// Arrays are value types with compile-time known size.
/// </summary>
public class ArrayType : FType
{
    public ArrayType(FType elementType, int length)
    {
        ElementType = elementType;
        Length = length;
    }

    public FType ElementType { get; }
    public int Length { get; }

    public override string Name => $"[{ElementType.Name}; {Length}]";

    public override bool Equals(FType other)
    {
        return other is ArrayType at && ElementType.Equals(at.ElementType) && Length == at.Length;
    }

    public override int GetHashCode()
    {
        return HashCode.Combine(ElementType, Length);
    }

    public override int Size => ElementType.Size * Length;

    public override int Alignment => ElementType.Alignment;
}

/// <summary>
/// Represents a slice type T[] (fat pointer view).
/// Implemented as a struct { ptr: &T, len: usize } with guaranteed binary layout.
/// </summary>
public class SliceType : FType
{
    public SliceType(FType elementType)
    {
        ElementType = elementType;
    }

    public FType ElementType { get; }

    public override string Name => $"{ElementType.Name}[]";

    public override bool Equals(FType other)
    {
        return other is SliceType st && ElementType.Equals(st.ElementType);
    }

    public override int GetHashCode()
    {
        return HashCode.Combine("slice", ElementType);
    }

    public override int Size => 16; // ptr (8 bytes) + len (8 bytes) on 64-bit

    public override int Alignment => 8; // Pointer alignment on 64-bit
}

/// <summary>
/// Registry of all built-in types.
/// </summary>
public static class TypeRegistry
{
    // Void type (for functions with no return value)
    public static readonly PrimitiveType Void = new("void", 0);

    // Boolean type
    public static readonly PrimitiveType Bool = new("bool", 1);

    // Signed integer types
    public static readonly PrimitiveType I8 = new("i8", 1);
    public static readonly PrimitiveType I16 = new("i16", 2);
    public static readonly PrimitiveType I32 = new("i32", 4);
    public static readonly PrimitiveType I64 = new("i64", 8);

    // Unsigned integer types
    public static readonly PrimitiveType U8 = new("u8", 1, false);
    public static readonly PrimitiveType U16 = new("u16", 2, false);
    public static readonly PrimitiveType U32 = new("u32", 4, false);
    public static readonly PrimitiveType U64 = new("u64", 8, false);

    // Platform-dependent integer types
    public static readonly PrimitiveType ISize = new("isize", IntPtr.Size);
    public static readonly PrimitiveType USize = new("usize", IntPtr.Size, false);

    // Compile-time types
    public static readonly ComptimeIntType ComptimeInt = ComptimeIntType.Instance;
    public static readonly ComptimeFloatType ComptimeFloat = ComptimeFloatType.Instance;

    // Canonical struct representation for String (binary layout: ptr + len)
    public static readonly StructType StringStruct = new("String", [], [
        ("ptr", new ReferenceType(U8)),
        ("len", USize)
    ]);

    // Cache for Slice[$T] struct types - created on demand for each element type
    private static readonly Dictionary<FType, StructType> _sliceStructCache = new();
    private static readonly Dictionary<FType, StructType> _optionStructCache = new();

    /// <summary>
    /// Looks up a type by name. Returns null if not found.
    /// </summary>
    public static FType? GetTypeByName(string name)
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
    public static bool IsIntegerType(FType type)
    {
        return type is ComptimeIntType ||
               (type is PrimitiveType pt && pt != Bool);
    }

    /// <summary>
    /// Returns true if the given type is a numeric type (int or float).
    /// </summary>
    public static bool IsNumericType(FType type)
    {
        return IsIntegerType(type) || type is ComptimeFloatType;
    }

    /// <summary>
    /// Returns true if the given type is a compile-time type that needs resolution.
    /// </summary>
    public static bool IsComptimeType(FType type)
    {
        return type is ComptimeIntType or ComptimeFloatType;
    }

    /// <summary>
    /// Gets the canonical struct representation for a slice of the given element type.
    /// Returns a cached instance to ensure reference equality.
    /// </summary>
    public static StructType GetSliceStruct(FType elementType)
    {
        if (_sliceStructCache.TryGetValue(elementType, out var cached))
            return cached;

        // Create Slice[$T] struct with ptr and len fields
        var sliceStruct = new StructType("Slice", [elementType.Name], [
            ("ptr", new ReferenceType(elementType)),
            ("len", USize)
        ]);

        _sliceStructCache[elementType] = sliceStruct;
        return sliceStruct;
    }

    public static StructType GetOptionStruct(FType innerType)
    {
        if (_optionStructCache.TryGetValue(innerType, out var cached))
            return cached;

        var optionStruct = new StructType("Option", [innerType.Name], [
            ("has_value", Bool),
            ("value", innerType)
        ]);

        _optionStructCache[innerType] = optionStruct;
        return optionStruct;
    }

    /// <summary>
    /// Converts a FLang type to its C equivalent.
    /// </summary>
    public static string ToCType(FType type)
    {
        if (type is PrimitiveType pt)
            return pt.Name switch
            {
                "bool" => "int", // C99 bool (using int for simplicity)
                "i8" => "signed char",
                "i16" => "short",
                "i32" => "int",
                "i64" => "long long",
                "u8" => "unsigned char",
                "u16" => "unsigned short",
                "u32" => "unsigned int",
                "u64" => "unsigned long long",
                "isize" => "intptr_t",
                "usize" => "uintptr_t",
                _ => throw new Exception($"Unsupported primitive type: {pt.Name}")
            };

        // Handle reference types: &T becomes T*
        if (type is ReferenceType refType) return ToCType(refType.InnerType) + "*";

        // Handle optional types: T? (not fully implemented yet)
        if (type is OptionType optType)
            return ToCType(GetOptionStruct(optType.InnerType));

        // Handle struct types: use struct name
        if (type is StructType structType)
        {
            // Generic structs: include type parameters in C name to avoid collisions
            if (structType.TypeParameters.Count > 0)
            {
                var paramSuffix = string.Join("_", structType.TypeParameters.Select(p => p.Replace("*", "Ptr").Replace(" ", "_")));
                return $"struct {structType.StructName}_{paramSuffix}";
            }

            return $"struct {structType.StructName}";
        }

        // Handle array types: same struct representation as slices
        // Arrays and slices have identical binary layout: { ptr, len }
        // The only difference is ownership semantics (arrays own their data)
        if (type is ArrayType arrayType)
        {
            // For u8 arrays, use the same C struct name as String to guarantee ABI compatibility
            if (arrayType.ElementType.Equals(U8))
                return "struct String";

            // Generic array layout: same as slice - struct Slice_<Elem>
            return $"struct Slice_{ToCType(arrayType.ElementType).Replace(" ", "_").Replace("*", "Ptr")}";
        }

        // Handle slice types: struct with ptr and len
        if (type is SliceType sliceType)
        {
            // For u8[] specifically, use the same C struct name as String to guarantee ABI compatibility
            if (sliceType.ElementType.Equals(U8))
                return "struct String";

            // Generic slice layout: struct Slice_<Elem>
            return $"struct Slice_{ToCType(sliceType.ElementType).Replace(" ", "_").Replace("*", "Ptr")}";
        }

        throw new Exception($"Unsupported type: {type.Name}");
    }
}