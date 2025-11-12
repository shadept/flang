namespace FLang.Core;

/// <summary>
/// Base class for all types in the FLang type system.
/// </summary>
public abstract class Type
{
    public abstract string Name { get; }

    public abstract bool Equals(Type other);

    public override bool Equals(object? obj)
    {
        return obj is Type other && Equals(other);
    }

    public override int GetHashCode()
    {
        return Name.GetHashCode();
    }

    public override string ToString()
    {
        return Name;
    }

    /// <summary>
    /// Gets the size of a type in bytes.
    /// Used by size_of intrinsic.
    /// </summary>
    public static int GetSizeOf(Type type)
    {
        return type switch
        {
            PrimitiveType pt => pt.SizeInBytes,
            ReferenceType => IntPtr.Size, // Pointers are platform-dependent
            StructType st => st.GetSize(), // Recursive for nested structs
            ArrayType at => at.GetSize(), // Fixed-size array
            SliceType st => st.GetSize(), // Slice (fat pointer)
            _ => 4 // Default fallback (i32 size)
        };
    }

    /// <summary>
    /// Gets the alignment requirement of a type in bytes.
    /// Used by align_of intrinsic.
    /// </summary>
    public static int GetAlignmentOf(Type type)
    {
        return type switch
        {
            PrimitiveType pt => pt.SizeInBytes, // Primitives align to their size
            ReferenceType => IntPtr.Size, // Pointers align to pointer size
            StructType st => st.GetAlignment(), // Struct aligns to largest field
            ArrayType at => at.GetAlignment(), // Array aligns to element
            SliceType st => st.GetAlignment(), // Slice aligns to pointer
            _ => 4 // Default fallback
        };
    }
}

/// <summary>
/// Represents primitive types like i32, bool, etc.
/// </summary>
public class PrimitiveType : Type
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

    public override bool Equals(Type other)
    {
        return other is PrimitiveType pt && pt.Name == Name;
    }
}

/// <summary>
/// Represents compile-time integer type that must be resolved during type inference.
/// </summary>
public class ComptimeIntType : Type
{
    public static readonly ComptimeIntType Instance = new();

    private ComptimeIntType()
    {
    }

    public override string Name => "comptime_int";

    public override bool Equals(Type other)
    {
        return other is ComptimeIntType;
    }
}

/// <summary>
/// Represents compile-time float type that must be resolved during type inference.
/// </summary>
public class ComptimeFloatType : Type
{
    public static readonly ComptimeFloatType Instance = new();

    private ComptimeFloatType()
    {
    }

    public override string Name => "comptime_float";

    public override bool Equals(Type other)
    {
        return other is ComptimeFloatType;
    }
}

/// <summary>
/// Represents an unknown type during type inference.
/// </summary>
public class TypeVariable : Type
{
    private static int _nextId;

    public TypeVariable()
    {
        Id = _nextId++;
    }

    public int Id { get; }
    public override string Name => $"?T{Id}";

    public override bool Equals(Type other)
    {
        return other is TypeVariable tv && tv.Id == Id;
    }

    public override int GetHashCode()
    {
        return Id;
    }
}

/// <summary>
/// Represents a reference type like &T.
/// </summary>
public class ReferenceType : Type
{
    public ReferenceType(Type innerType)
    {
        InnerType = innerType;
    }

    public Type InnerType { get; }

    public override string Name => $"&{InnerType.Name}";

    public override bool Equals(Type other)
    {
        return other is ReferenceType rt && InnerType.Equals(rt.InnerType);
    }

    public override int GetHashCode()
    {
        return HashCode.Combine(Name, InnerType);
    }
}

/// <summary>
/// Represents an optional type (nullable) like T? or Option[T].
/// Placeholder for future milestones.
/// </summary>
public class OptionType : Type
{
    public OptionType(Type innerType)
    {
        InnerType = innerType;
    }

    public Type InnerType { get; }

    public override string Name => $"{InnerType.Name}?";

    public override bool Equals(Type other)
    {
        return other is OptionType ot && InnerType.Equals(ot.InnerType);
    }

    public override int GetHashCode()
    {
        return HashCode.Combine(Name, InnerType);
    }
}

/// <summary>
/// Represents a generic type like List[T], Dict[K, V].
/// Placeholder for future milestones.
/// </summary>
public class GenericType : Type
{
    public GenericType(string baseName, IReadOnlyList<Type> typeArguments)
    {
        BaseName = baseName;
        TypeArguments = typeArguments;
    }

    public string BaseName { get; }
    public IReadOnlyList<Type> TypeArguments { get; }

    public override string Name => $"{BaseName}[{string.Join(", ", TypeArguments.Select(t => t.Name))}]";

    public override bool Equals(Type other)
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
public class StructType : Type
{
    public StructType(string structName, IReadOnlyList<string> typeParameters, IReadOnlyList<(string, Type)> fields)
    {
        StructName = structName;
        TypeParameters = typeParameters;
        Fields = fields;
    }

    public string StructName { get; }
    public IReadOnlyList<string> TypeParameters { get; }
    public IReadOnlyList<(string Name, Type Type)> Fields { get; }

    public override string Name
    {
        get
        {
            if (TypeParameters.Count > 0) return $"{StructName}[{string.Join(", ", TypeParameters)}]";
            return StructName;
        }
    }

    public override bool Equals(Type other)
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
    public Type? GetFieldType(string fieldName)
    {
        foreach (var (name, type) in Fields)
            if (name == fieldName)
                return type;
        return null;
    }

    /// <summary>
    /// Calculates the byte offset of a field within the struct.
    /// Returns -1 if field not found.
    /// Uses optimized layout with proper alignment to reduce padding.
    /// </summary>
    public int GetFieldOffset(string fieldName)
    {
        var offset = 0;
        foreach (var (name, type) in Fields)
        {
            // Align offset to field's alignment requirement
            var alignment = GetTypeAlignment(type);
            offset = AlignOffset(offset, alignment);

            if (name == fieldName)
                return offset;

            // Advance offset by field size
            offset += GetTypeSize(type);
        }

        return -1; // Field not found
    }

    /// <summary>
    /// Returns the total size of the struct in bytes (including trailing padding).
    /// </summary>
    public int GetSize()
    {
        if (Fields.Count == 0)
            return 0;

        var size = 0;
        var maxAlignment = 1;

        foreach (var (_, type) in Fields)
        {
            var alignment = GetTypeAlignment(type);
            maxAlignment = Math.Max(maxAlignment, alignment);

            // Align current offset
            size = AlignOffset(size, alignment);

            // Add field size
            size += GetTypeSize(type);
        }

        // Add trailing padding to align to largest field
        size = AlignOffset(size, maxAlignment);

        return size;
    }

    /// <summary>
    /// Helper to get size of a type in bytes.
    /// </summary>
    private static int GetTypeSize(Type type)
    {
        return type switch
        {
            PrimitiveType pt => pt.SizeInBytes,
            ReferenceType => IntPtr.Size, // Pointers are platform-dependent
            StructType st => st.GetSize(), // Recursive for nested structs
            ArrayType at => at.GetSize(), // Fixed-size array
            SliceType st => st.GetSize(), // Slice (fat pointer)
            _ => 4 // Default fallback (i32 size)
        };
    }

    /// <summary>
    /// Helper to get alignment requirement of a type in bytes.
    /// </summary>
    private static int GetTypeAlignment(Type type)
    {
        return type switch
        {
            PrimitiveType pt => pt.SizeInBytes, // Primitives align to their size
            ReferenceType => IntPtr.Size, // Pointers align to pointer size
            StructType st => st.GetAlignment(), // Struct aligns to largest field
            ArrayType at => at.GetAlignment(), // Array aligns to element
            SliceType st => st.GetAlignment(), // Slice aligns to pointer
            _ => 4 // Default fallback
        };
    }

    /// <summary>
    /// Returns the alignment requirement of the struct (largest field alignment).
    /// </summary>
    public int GetAlignment()
    {
        var maxAlignment = 1;
        foreach (var (_, type) in Fields) maxAlignment = Math.Max(maxAlignment, GetTypeAlignment(type));
        return maxAlignment;
    }

    /// <summary>
    /// Aligns an offset to the specified alignment.
    /// </summary>
    private static int AlignOffset(int offset, int alignment)
    {
        return (offset + alignment - 1) / alignment * alignment;
    }
}

/// <summary>
/// Represents a fixed-size array type like [T; N].
/// Arrays are value types with compile-time known size.
/// </summary>
public class ArrayType : Type
{
    public ArrayType(Type elementType, int length)
    {
        ElementType = elementType;
        Length = length;
    }

    public Type ElementType { get; }
    public int Length { get; }

    public override string Name => $"[{ElementType.Name}; {Length}]";

    public override bool Equals(Type other)
    {
        return other is ArrayType at && ElementType.Equals(at.ElementType) && Length == at.Length;
    }

    public override int GetHashCode()
    {
        return HashCode.Combine(ElementType, Length);
    }

    /// <summary>
    /// Returns the total size of the array in bytes.
    /// </summary>
    public int GetSize()
    {
        return GetElementSize(ElementType) * Length;
    }

    /// <summary>
    /// Returns the alignment requirement of the array (same as element alignment).
    /// </summary>
    public int GetAlignment()
    {
        return GetElementAlignment(ElementType);
    }

    private static int GetElementSize(Type type)
    {
        return type switch
        {
            PrimitiveType pt => pt.SizeInBytes,
            ReferenceType => IntPtr.Size,
            StructType st => st.GetSize(),
            ArrayType at => at.GetSize(),
            _ => 4 // Default fallback
        };
    }

    private static int GetElementAlignment(Type type)
    {
        return type switch
        {
            PrimitiveType pt => pt.SizeInBytes,
            ReferenceType => IntPtr.Size,
            StructType st => st.GetAlignment(),
            ArrayType at => at.GetAlignment(),
            _ => 4 // Default fallback
        };
    }
}

/// <summary>
/// Represents a slice type T[] (fat pointer view).
/// Implemented as a struct { ptr: &T, len: usize } with guaranteed binary layout.
/// </summary>
public class SliceType : Type
{
    public SliceType(Type elementType)
    {
        ElementType = elementType;
    }

    public Type ElementType { get; }

    public override string Name => $"{ElementType.Name}[]";

    public override bool Equals(Type other)
    {
        return other is SliceType st && ElementType.Equals(st.ElementType);
    }

    public override int GetHashCode()
    {
        return HashCode.Combine("slice", ElementType);
    }

    /// <summary>
    /// Returns the size of the slice struct (pointer + length).
    /// </summary>
    public int GetSize()
    {
        return IntPtr.Size + IntPtr.Size; // ptr + len (both platform-dependent)
    }

    /// <summary>
    /// Returns the alignment requirement of the slice (pointer alignment).
    /// </summary>
    public int GetAlignment()
    {
        return IntPtr.Size;
    }
}

/// <summary>
/// Registry of all built-in types.
/// </summary>
public static class TypeRegistry
{
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

    /// <summary>
    /// Looks up a type by name. Returns null if not found.
    /// </summary>
    public static Type? GetTypeByName(string name)
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
    public static bool IsIntegerType(Type type)
    {
        return type is ComptimeIntType ||
               (type is PrimitiveType pt && pt != Bool);
    }

    /// <summary>
    /// Returns true if the given type is a numeric type (int or float).
    /// </summary>
    public static bool IsNumericType(Type type)
    {
        return IsIntegerType(type) || type is ComptimeFloatType;
    }

    /// <summary>
    /// Returns true if the given type is a compile-time type that needs resolution.
    /// </summary>
    public static bool IsComptimeType(Type type)
    {
        return type is ComptimeIntType or ComptimeFloatType;
    }

    /// <summary>
    /// Converts a FLang type to its C equivalent.
    /// </summary>
    public static string ToCType(Type type)
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
                _ => "int" // Fallback
            };

        // Handle reference types: &T becomes T*
        if (type is ReferenceType refType) return ToCType(refType.InnerType) + "*";

        // Handle optional types: T? (not fully implemented yet)
        if (type is OptionType optType)
            // For now, treat as the inner type
            return ToCType(optType.InnerType);

        // Handle struct types: use struct name
        if (type is StructType structType) return $"struct {structType.StructName}";

        // Handle array types: T[N] in C
        if (type is ArrayType arrayType) return $"{ToCType(arrayType.ElementType)}[{arrayType.Length}]";

        // Handle slice types: struct with ptr and len
        if (type is SliceType sliceType)
            // Slices are represented as fat pointers (struct with ptr and len)
            // We'll generate the struct definition in codegen
            return $"struct Slice_{ToCType(sliceType.ElementType).Replace(" ", "_").Replace("*", "Ptr")}";

        // Comptime types shouldn't reach codegen, but fallback to int
        return "int";
    }
}