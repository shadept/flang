using FLang.Core;

namespace FLang.IR;

/// <summary>
/// Base class for all values in the FLang intermediate representation.
/// Values can be operands to instructions or results from instructions.
/// Each value has a name (for debugging/printing) and an optional type.
/// </summary>
public abstract class Value
{
    /// <summary>
    /// The name of this value, used for debugging and code generation.
    /// For constants, this is typically the string representation of the value.
    /// For locals, this is the SSA variable name (e.g., "t0", "x", "call_42").
    /// </summary>
    public string Name { get; set; } = "";

    /// <summary>
    /// The type of this value, if known.
    /// May be null during early IR construction before type inference completes.
    /// </summary>
    public FType? Type { get; set; }
}

/// <summary>
/// Represents a compile-time integer constant.
/// Used for literal values, array sizes, offsets, etc.
/// </summary>
public class ConstantValue : Value
{
    public ConstantValue(long intValue)
    {
        IntValue = intValue;
        Name = intValue.ToString();
        Type = TypeRegistry.USize;
    }

    /// <summary>
    /// The integer value of this constant.
    /// </summary>
    public long IntValue { get; }
}

/// <summary>
/// Represents a compile-time array constant (e.g., byte array for strings).
/// </summary>
public class ArrayConstantValue : Value
{
    public ArrayConstantValue(byte[] data, FType elementType)
    {
        Data = data;
        Type = new ArrayType(elementType, data.Length);
        Elements = null;
    }

    public ArrayConstantValue(ArrayType arrayType, Value[] elements)
    {
        Type = arrayType;
        Elements = elements;
        Data = null;
    }

    public byte[]? Data { get; }

    /// <summary>
    /// For general array literals, stores the element values.
    /// </summary>
    public Value[]? Elements { get; }

    /// <summary>
    /// For string literals, returns the UTF-8 string with null terminator.
    /// </summary>
    public string? StringRepresentation { get; set; }
}

/// <summary>
/// Represents a compile-time struct constant with field initializers.
/// Used for string literals represented as String struct constants.
/// </summary>
public class StructConstantValue : Value
{
    public StructConstantValue(StructType structType, Dictionary<string, Value> fieldValues)
    {
        Type = structType;
        FieldValues = fieldValues;
    }

    /// <summary>
    /// Field name -> initializer value mapping.
    /// </summary>
    public Dictionary<string, Value> FieldValues { get; }
}

/// <summary>
/// Represents a global symbol in memory (static variable, string literal, etc.).
/// CRITICAL: The Type of a GlobalValue is ALWAYS a pointer to its initializer's type.
/// This matches LLVM IR semantics where globals are pointer values.
/// </summary>
public class GlobalValue : Value
{
    public GlobalValue(string name, Value initializer)
    {
        Name = name;  // e.g., "LC0", "LC1"
        Initializer = initializer;

        // Type is a pointer to the initializer's type
        // Example: initializer is [5 x u8] → Type is &[u8; 5]
        Type = new ReferenceType(initializer.Type!);
    }

    /// <summary>
    /// The data stored at this global address.
    /// Used by backends to emit .data section.
    /// </summary>
    public Value Initializer { get; set; }
}

/// <summary>
/// Represents a local SSA value (variable or temporary).
/// This is the result of an instruction or a function parameter.
/// Each LocalValue has a unique name within its function scope.
/// </summary>
public class LocalValue : Value
{
    public LocalValue(string name)
    {
        Name = name;
    }
}