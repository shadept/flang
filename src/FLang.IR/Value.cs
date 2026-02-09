using System.Numerics;
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
    public string Name { get; protected init; } = "";

    /// <summary>
    /// The type of this value, if known (old TypeBase pipeline).
    /// May be null during early IR construction before type inference completes.
    /// </summary>
    public TypeBase? Type { get; set; }

    /// <summary>
    /// The type of this value in the new IrType system (HM pipeline).
    /// Set by HmAstLowering; null when using old pipeline.
    /// </summary>
    public IrType? IrType { get; set; }

    // C keywords that must be escaped when used as identifiers.
    private static readonly HashSet<string> CKeywords =
    [
        "default", "switch", "case", "break", "continue", "return",
        "if", "else", "for", "while", "do", "struct", "enum",
        "union", "typedef", "void", "int", "char", "float",
        "double", "long", "short", "signed", "unsigned", "const",
        "static", "extern", "register", "volatile", "auto",
        "goto", "sizeof", "inline", "restrict"
    ];

    /// <summary>
    /// Sanitize a name for use as a C identifier. Replaces non-identifier chars in a
    /// single pass with no intermediate allocations, and escapes C keywords.
    /// </summary>
    public static string SanitizeCIdent(string name)
    {
        // Fast path: check if any char needs replacing
        bool needsSanitize = false;
        for (int i = 0; i < name.Length; i++)
        {
            char c = name[i];
            if (c == '.' || c == '[' || c == ']' || c == ',' || c == ' '
                || c == '-' || c == '|' || c == '&' || c == '(' || c == ')' || c == ';')
            {
                needsSanitize = true;
                break;
            }
        }
        if (!needsSanitize)
            return CKeywords.Contains(name) ? $"_{name}" : name;

        var result = string.Create(name.Length, name, static (span, src) =>
        {
            for (int i = 0; i < src.Length; i++)
            {
                span[i] = src[i] switch
                {
                    '.' or '[' or ']' or ',' or ' ' or '-' or '|' or '(' or ')' or ';' => '_',
                    '&' => 'R',
                    _ => src[i]
                };
            }
        });
        return CKeywords.Contains(result) ? $"_{result}" : result;
    }
}

/// <summary>
/// Represents a compile-time integer constant.
/// Used for literal values, array sizes, offsets, etc.
/// </summary>
public class ConstantValue : Value
{
    public ConstantValue(BigInteger intValue)
    {
        IntValue = intValue;
        Name = intValue.ToString();
        Type = TypeRegistry.USize;
    }

    public ConstantValue(BigInteger intValue, IrType irType)
    {
        IntValue = intValue;
        Name = intValue.ToString();
        IrType = irType;
    }

    /// <summary>
    /// The integer value of this constant.
    /// </summary>
    public BigInteger IntValue { get; }
}

/// <summary>
/// Represents a compile-time array constant (e.g., byte array for strings).
/// </summary>
public class ArrayConstantValue : Value
{
    public ArrayConstantValue(byte[] data, TypeBase elementType)
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

    /// <summary>
    /// HM pipeline: byte array constant (e.g., string data).
    /// </summary>
    public ArrayConstantValue(byte[] data, IrType elementIrType)
    {
        Data = data;
        IrType = new IrArray(elementIrType, data.Length);
        Elements = null;
    }

    /// <summary>
    /// HM pipeline: array of structured values (e.g., FieldInfo[]).
    /// </summary>
    public ArrayConstantValue(IrArray arrayIrType, Value[] elements)
    {
        IrType = arrayIrType;
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
    /// Constructor for HM pipeline (uses IrType instead of old StructType).
    /// </summary>
    public StructConstantValue(IrType irType, Dictionary<string, Value> fieldValues)
    {
        IrType = irType;
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
        Name = name; // e.g., "LC0", "LC1"
        Initializer = initializer;

        // Type is a pointer to the initializer's type (when available from old pipeline)
        if (initializer.Type != null)
            Type = new ReferenceType(initializer.Type, PointerWidth.Bits64);
    }

    /// <summary>
    /// Constructor for HM pipeline (uses IrType instead of old TypeBase).
    /// </summary>
    public GlobalValue(string name, Value initializer, IrType initializerIrType)
    {
        Name = SanitizeCIdent(name);
        Initializer = initializer;
        IrType = new IrPointer(initializerIrType);
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
    public LocalValue(string name, TypeBase type)
    {
        Name = name;
        Type = type;
    }

    public LocalValue(string name, IrType irType)
    {
        Name = SanitizeCIdent(name);
        IrType = irType;
    }
}

/// <summary>
/// Represents a reference to an entry in the module's string table.
/// Codegen emits this as __flang__string_table[Index].
/// </summary>
public class StringTableValue : Value
{
    public StringTableValue(int index, IrType stringIrType)
    {
        Index = index;
        Name = $"__flang__string_table[{index}]";
        IrType = stringIrType;
    }

    public int Index { get; }
}

/// <summary>
/// Represents a reference to a function (function pointer value).
/// Used when a function name is used as a value in expressions.
/// </summary>
public class FunctionReferenceValue : Value
{
    public FunctionReferenceValue(string functionName, TypeBase type)
    {
        FunctionName = functionName;
        Name = functionName;
        Type = type;
    }

    /// <summary>
    /// The name of the function being referenced.
    /// </summary>
    public string FunctionName { get; }
}
