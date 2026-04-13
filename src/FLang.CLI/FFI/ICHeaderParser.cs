namespace FLang.CLI.FFI;

/// <summary>
/// Abstraction for parsing C headers into an intermediate representation.
/// Implementations are swappable (e.g. CppAst today, custom parser tomorrow).
/// </summary>
public interface ICHeaderParser
{
    CHeaderParseResult Parse(string headerPath);
}

public record CHeaderParseResult(
    List<CFunction> Functions,
    List<CStruct> Structs,
    List<CEnumConstant> EnumConstants,
    List<string> Warnings,
    List<string> Errors);

public record CFunction(string Name, CType ReturnType, List<CParameter> Parameters);
public record CParameter(string Name, CType Type);
public record CStruct(string Name, List<CField> Fields);
public record CField(string Name, CType Type);
public record CEnumConstant(string Name, long Value);

public record CType(CTypeKind Kind, string? Name = null, CType? PointeeType = null);

public enum CTypeKind
{
    Void,
    Bool,
    I8,
    U8,
    I16,
    U16,
    I32,
    U32,
    I64,
    U64,
    F32,
    F64,
    USize,
    ISize,
    Pointer,
    Struct,
    Unknown
}
