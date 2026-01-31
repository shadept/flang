namespace FLang.Core;

/// <summary>
/// Registry of all built-in types and well-known composite types.
/// Provides factory methods for creating type instances and type checking utilities.
/// </summary>
public static class TypeRegistry
{
    // Fully qualified names for well-known types
    private const string OptionFqn = "core.option.Option";
    private const string RangeFqn = "core.range.Range";
    private const string SliceFqn = "core.slice.Slice";
    private const string StringFqn = "core.string.String";
    private const string TypeFqn = "core.rtti.Type";
    private const string TypeInfoFqn = "core.rtti.TypeInfo";
    private const string FieldInfoFqn = "core.rtti.FieldInfo";

    /// <summary>
    /// The never type (bottom type) - represents computations that never return.
    /// </summary>
    public static readonly PrimitiveType Never = new("never", 0, 0);

    /// <summary>
    /// The void type - represents absence of a value (used for functions with no return value).
    /// </summary>
    public static readonly PrimitiveType Void = new("void", 0, 0);

    /// <summary>
    /// The boolean type (1 byte).
    /// </summary>
    public static readonly PrimitiveType Bool = new("bool", 1, 1);

    /// <summary>
    /// Signed 8-bit integer type.
    /// </summary>
    public static readonly PrimitiveType I8 = new("i8", 1, 1);

    /// <summary>
    /// Signed 16-bit integer type.
    /// </summary>
    public static readonly PrimitiveType I16 = new("i16", 2, 2);

    /// <summary>
    /// Signed 32-bit integer type.
    /// </summary>
    public static readonly PrimitiveType I32 = new("i32", 4, 4);

    /// <summary>
    /// Signed 64-bit integer type.
    /// </summary>
    public static readonly PrimitiveType I64 = new("i64", 8, 8);

    /// <summary>
    /// Unsigned 8-bit integer type.
    /// </summary>
    public static readonly PrimitiveType U8 = new("u8", 1, 1) { IsSigned = false };

    /// <summary>
    /// Unsigned 16-bit integer type.
    /// </summary>
    public static readonly PrimitiveType U16 = new("u16", 2, 2) { IsSigned = false };

    /// <summary>
    /// Unsigned 32-bit integer type.
    /// </summary>
    public static readonly PrimitiveType U32 = new("u32", 4, 4) { IsSigned = false };

    /// <summary>
    /// Unsigned 64-bit integer type.
    /// </summary>
    public static readonly PrimitiveType U64 = new("u64", 8, 8) { IsSigned = false };

    /// <summary>
    /// Platform-dependent signed integer type (32-bit on 32-bit platforms, 64-bit on 64-bit platforms).
    /// </summary>
    public static readonly PrimitiveType ISize = new("isize", IntPtr.Size, IntPtr.Size);

    /// <summary>
    /// Platform-dependent unsigned integer type (32-bit on 32-bit platforms, 64-bit on 64-bit platforms).
    /// </summary>
    public static readonly PrimitiveType USize = new("usize", IntPtr.Size, IntPtr.Size) { IsSigned = false };

    /// <summary>
    /// Compile-time integer type that must be resolved during type inference.
    /// </summary>
    public static readonly ComptimeInt ComptimeInt = ComptimeInt.Instance;

    /// <summary>
    /// Compile-time float type that must be resolved during type inference.
    /// </summary>
    public static readonly ComptimeFloat ComptimeFloat = ComptimeFloat.Instance;

    /// <summary>
    /// Canonical struct representation for String (binary layout: ptr + len).
    /// </summary>
    public static readonly StructType StringStruct = new(StringFqn, [], [
        ("ptr", new ReferenceType(U8, PointerWidth.Bits64)),
        ("len", USize)
    ]);

    /// <summary>
    /// Non-generic TypeInfo struct for the type table.
    /// This is the actual data layout emitted by the compiler.
    /// Type(T) has the same layout but is generic (used for type literal syntax).
    /// </summary>
    public static readonly StructType TypeInfoStruct;

    /// <summary>
    /// FieldInfo struct for runtime type information - describes a single field of a struct.
    /// Layout: name (String), offset (usize), type (&TypeInfo).
    /// </summary>
    public static readonly StructType FieldInfoStruct;

    /// <summary>
    /// Type struct template for runtime type information (generic wrapper).
    /// Has the same layout as TypeInfoStruct but carries a type parameter.
    /// </summary>
    public static readonly StructType TypeStructTemplate;

    static TypeRegistry()
    {
        // Forward-declare TypeInfoStruct so FieldInfoStruct can reference it
        TypeInfoStruct = new StructType(TypeInfoFqn, [], []);
        var typeInfoPtr = new ReferenceType(TypeInfoStruct, PointerWidth.Bits64);

        FieldInfoStruct = new StructType(FieldInfoFqn, [], [
            ("name", StringStruct),
            ("offset", USize),
            ("type", typeInfoPtr)
        ]);

        var fieldsSlice = new StructType(SliceFqn, [FieldInfoStruct], [
            ("ptr", new ReferenceType(FieldInfoStruct, PointerWidth.Bits64)),
            ("len", USize)
        ]);

        // Now set the actual fields on TypeInfoStruct
        TypeInfoStruct.SetFields([
            ("name", StringStruct),
            ("size", U8),
            ("align", U8),
            ("fields", fieldsSlice)
        ]);

        // TypeStructTemplate has the same layout as TypeInfoStruct
        TypeStructTemplate = new StructType(TypeFqn, [], [
            ("name", StringStruct),
            ("size", U8),
            ("align", U8),
            ("fields", new StructType(SliceFqn, [FieldInfoStruct], [
                ("ptr", new ReferenceType(FieldInfoStruct, PointerWidth.Bits64)),
                ("len", USize)
            ]))
        ]);
    }


    // Cache for well-known types to ensure reference equality
    private static readonly Dictionary<TypeBase, StructType> _sliceStructCache = [];
    private static readonly Dictionary<TypeBase, StructType> _optionStructCache = [];
    private static readonly Dictionary<TypeBase, StructType> _rangeStructCache = [];
    private static readonly Dictionary<TypeBase, StructType> _typeStructCache = [];

    /// <summary>
    /// Looks up a type by name. Returns null if not found.
    /// </summary>
    public static TypeBase? GetTypeByName(string name)
    {
        return name switch
        {
            "void" => Void,
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

    /// <summary>
    /// Returns true if the given type name represents an integer type.
    /// </summary>
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
        return type is Core.ComptimeInt or Core.ComptimeFloat;
    }

    /// <summary>
    /// Creates an Option&lt;T&gt; type with fully qualified name (Algorithm W style).
    /// Results are cached to ensure reference equality for the same inner type.
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
    /// Creates a Slice(T) type with fully qualified name (Algorithm W style).
    /// Results are cached to ensure reference equality for the same element type.
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
    /// Creates a Range(T) type with fully qualified name.
    /// Results are cached to ensure reference equality for the same element type.
    /// </summary>
    public static StructType MakeRange(TypeBase elementType)
    {
        var key = elementType;
        if (_rangeStructCache.TryGetValue(key, out var cached))
            return cached;

        var rangeType = new StructType(RangeFqn, [elementType]);

        rangeType.WithFields([
            ("start", elementType),
            ("end", elementType)
        ]);

        _rangeStructCache[key] = rangeType;
        return rangeType;
    }

    /// <summary>
    /// Creates a String type (equivalent to Slice&lt;u8&gt;).
    /// Returns the canonical String struct instance.
    /// </summary>
    public static StructType MakeString()
    {
        return StringStruct;
    }

    /// <summary>
    /// Gets or creates a Type(T) struct instance for the given type parameter.
    /// All instances have the same layout as TypeInfo, differing only in the type parameter.
    /// Results are cached to ensure reference equality.
    /// </summary>
    public static StructType MakeType(TypeBase innerType)
    {
        if (_typeStructCache.TryGetValue(innerType, out var cached))
            return cached;

        var fieldsSlice = new StructType(SliceFqn, [FieldInfoStruct], [
            ("ptr", new ReferenceType(FieldInfoStruct, PointerWidth.Bits64)),
            ("len", USize)
        ]);
        var typeStruct = new StructType(TypeFqn, [innerType], [
            ("name", StringStruct),
            ("size", U8),
            ("align", U8),
            ("fields", fieldsSlice)
        ]);

        _typeStructCache[innerType] = typeStruct;
        return typeStruct;
    }

    /// <summary>
    /// Checks if a TypeBase is Option(T) (convenience overload).
    /// </summary>
    public static bool IsOption(TypeBase type)
    {
        return type is StructType st && IsOption(st);
    }

    /// <summary>
    /// Checks if a StructType is Option(T) using fully qualified name.
    /// </summary>
    public static bool IsOption(StructType st)
    {
        return st.StructName == OptionFqn;
    }

    /// <summary>
    /// Checks if a TypeBase is Slice(T) (convenience overload).
    /// </summary>
    public static bool IsSlice(TypeBase type)
    {
        return type is StructType st && IsSlice(st);
    }

    /// <summary>
    /// Checks if a StructType is Slice(T) using fully qualified name.
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
    /// Checks if a TypeBase is FieldInfo.
    /// </summary>
    public static bool IsFieldInfo(TypeBase type)
    {
        return type is StructType st && IsFieldInfo(st);
    }

    /// <summary>
    /// Checks if a StructType is FieldInfo using fully qualified name.
    /// </summary>
    public static bool IsFieldInfo(StructType st)
    {
        return st.StructName == FieldInfoFqn;
    }

    /// <summary>
    /// Checks if a TypeBase is TypeInfo.
    /// </summary>
    public static bool IsTypeInfo(TypeBase type)
    {
        return type is StructType st && IsTypeInfo(st);
    }

    /// <summary>
    /// Checks if a StructType is TypeInfo using fully qualified name.
    /// </summary>
    public static bool IsTypeInfo(StructType st)
    {
        return st.StructName == TypeInfoFqn;
    }

    /// <summary>
    /// Checks if a TypeBase is Type(T) (convenience overload).
    /// </summary>
    public static bool IsType(TypeBase type)
    {
        return type is StructType st && IsType(st);
    }

    /// <summary>
    /// Checks if a StructType is Type(T) using fully qualified name.
    /// </summary>
    public static bool IsType(StructType st)
    {
        return st.StructName == TypeFqn;
    }
}
