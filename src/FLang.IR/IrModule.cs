using FLang.Core;

namespace FLang.IR;

/// <summary>
/// Top-level IR module that owns type definitions, globals, functions, and foreign declarations.
/// Replaces per-function globals with a module-level container.
/// </summary>
public class IrModule
{
    /// <summary>All struct/enum IrTypes used in this module.</summary>
    public List<IrType> TypeDefs { get; } = [];

    /// <summary>Global constants (allocator defaults, etc.).</summary>
    public List<IrGlobal> Globals { get; } = [];

    /// <summary>Global constant values (HM pipeline) — struct globals with field initializers.</summary>
    public List<GlobalValue> GlobalValues { get; } = [];

    /// <summary>
    /// String table — all string literals in the module.
    /// Emitted as a single C array: static const struct String __flang__string_table[N].
    /// </summary>
    public List<StringTableEntry> StringTable { get; } = [];

    /// <summary>Lowered functions.</summary>
    public List<IrFunction> Functions { get; } = [];

    /// <summary>Extern fn declarations (foreign functions).</summary>
    public List<IrForeignDecl> ForeignDecls { get; } = [];

    /// <summary>
    /// Source files indexed by FileId.
    /// Used by the C code generator to emit #line directives.
    /// </summary>
    public IReadOnlyList<Source> SourceFiles { get; set; } = [];
}

/// <summary>
/// A lowered function in the new IR pipeline.
/// </summary>
public class IrFunction
{
    public IrFunction(string name, IrType returnType)
    {
        Name = name;
        ReturnType = returnType;
    }

    public string Name { get; }
    public IrType ReturnType { get; }
    public List<IrParam> Params { get; } = [];
    public List<BasicBlock> BasicBlocks { get; } = [];
    public bool IsEntryPoint { get; set; }

}

/// <summary>
/// A global constant value in the module (e.g. allocator defaults).
/// </summary>
public class IrGlobal
{
    public IrGlobal(string name, IrType type)
    {
        Name = name;
        Type = type;
    }

    public string Name { get; }
    public IrType Type { get; }
    public byte[]? Data { get; set; }
}

/// <summary>
/// A foreign (extern) function declaration.
/// </summary>
public record IrForeignDecl(string Name, string CName, IrType ReturnType, IrType[] ParamTypes);

/// <summary>
/// A function parameter with name and type.
/// Name is sanitized for C at construction time.
/// </summary>
public record IrParam
{
    public string Name { get; }
    public IrType Type { get; }
    public IrParam(string name, IrType type)
    {
        Name = Value.SanitizeCIdent(name);
        Type = type;
    }
}

/// <summary>
/// An entry in the module's string table.
/// </summary>
public class StringTableEntry
{
    public StringTableEntry(string value, byte[] utf8Data)
    {
        Value = value;
        Utf8Data = utf8Data;
    }

    /// <summary>The original string value.</summary>
    public string Value { get; }

    /// <summary>UTF-8 encoded bytes with null terminator.</summary>
    public byte[] Utf8Data { get; }
}
