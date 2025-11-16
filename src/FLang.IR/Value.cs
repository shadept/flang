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
/// Represents a compile-time string constant.
/// Used for string literals in the source code.
/// The backend will emit these as static global variables.
/// </summary>
public class StringConstantValue : Value
{
    public StringConstantValue(string stringValue, string name)
    {
        StringValue = stringValue;
        Name = name;
    }

    /// <summary>
    /// The string content of this constant.
    /// </summary>
    public string StringValue { get; }
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