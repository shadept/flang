using System.Collections.Generic;

namespace FLang.Core.TypeSystem;

/// <summary>
/// Unified registry for primitive types and well-known composite types.
/// Replaces both the old TypeRegistry and WellKnownTypes.
/// </summary>
public static class TypeBaseRegistry
{
    // Primitive integer types
    public static readonly PrimitiveType I8 = new("i8", 1, 1);
    public static readonly PrimitiveType I16 = new("i16", 2, 2);
    public static readonly PrimitiveType I32 = new("i32", 4, 4);
    public static readonly PrimitiveType I64 = new("i64", 8, 8);
    public static readonly PrimitiveType U8 = new("u8", 1, 1);
    public static readonly PrimitiveType U16 = new("u16", 2, 2);
    public static readonly PrimitiveType U32 = new("u32", 4, 4);
    public static readonly PrimitiveType U64 = new("u64", 8, 8);

    // Platform-dependent integer types
    public static readonly PrimitiveType ISize = new("isize", 8, 8);
    public static readonly PrimitiveType USize = new("usize", 8, 8);

    // Other primitives
    public static readonly PrimitiveType Bool = new("bool", 1, 1);

    // Comptime types
    public static readonly ComptimeInt ComptimeInt = ComptimeInt.Instance;

    // Fully qualified names for well-known types
    private const string OptionFqn = "core.option.Option";
    private const string SliceFqn = "core.slice.Slice";
    private const string StringFqn = "core.string.String";

    // Cache for well-known types to ensure reference equality
    private static readonly Dictionary<string, StructType> _optionCache = new();
    private static readonly Dictionary<string, StructType> _sliceCache = new();
    private static StructType? _stringCache = null;

    /// <summary>
    /// Creates an Option&lt;T&gt; type with fully qualified name.
    /// </summary>
    public static StructType MakeOption(TypeBase innerType)
    {
        var key = innerType.ToString();
        if (_optionCache.TryGetValue(key, out var cached))
            return cached;

        var optionType = new StructType(OptionFqn, new List<TypeBase> { innerType });

        // Add fields: has_value: bool, value: T
        optionType.WithFields(new List<(string, TypeBase)>
        {
            ("has_value", Bool),
            ("value", innerType)
        });

        _optionCache[key] = optionType;
        return optionType;
    }

    /// <summary>
    /// Creates a Slice&lt;T&gt; type with fully qualified name.
    /// </summary>
    public static StructType MakeSlice(TypeBase elementType)
    {
        var key = elementType.ToString();
        if (_sliceCache.TryGetValue(key, out var cached))
            return cached;

        var sliceType = new StructType(SliceFqn, new List<TypeBase> { elementType });

        // Add fields: ptr: &T, len: usize
        sliceType.WithFields(new List<(string, TypeBase)>
        {
            ("ptr", new ReferenceType(elementType)),
            ("len", USize)
        });

        _sliceCache[key] = sliceType;
        return sliceType;
    }

    /// <summary>
    /// Creates a String type (equivalent to Slice&lt;u8&gt;).
    /// </summary>
    public static StructType MakeString()
    {
        if (_stringCache != null)
            return _stringCache;

        var stringType = new StructType(StringFqn);

        // String is basically a Slice<u8>
        stringType.WithFields(new List<(string, TypeBase)>
        {
            ("ptr", new ReferenceType(U8)),
            ("len", USize)
        });

        _stringCache = stringType;
        return _stringCache;
    }

    /// <summary>
    /// Checks if a StructType is Option&lt;T&gt; using fully qualified name.
    /// </summary>
    public static bool IsOption(StructType st)
    {
        // Check fully qualified name first, then short name for compatibility
        return st.Name == OptionFqn || st.Name == "Option";
    }

    /// <summary>
    /// Checks if a StructType is Slice&lt;T&gt; using fully qualified name.
    /// </summary>
    public static bool IsSlice(StructType st)
    {
        // Check fully qualified name first, then short name for compatibility
        return st.Name == SliceFqn || st.Name == "Slice";
    }

    /// <summary>
    /// Checks if a StructType is String using fully qualified name.
    /// </summary>
    public static bool IsString(StructType st)
    {
        // Check fully qualified name first, then short name for compatibility
        return st.Name == StringFqn || st.Name == "String";
    }
}
