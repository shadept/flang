namespace FLang.IR;

/// <summary>
/// Base for all types in the new IR type system.
/// Immutable records with pre-computed layout (Size, Alignment).
/// Clean firewall from both TypeBase (old) and HM Type.
/// </summary>
public abstract record IrType
{
    public abstract int Size { get; }
    public abstract int Alignment { get; }
}

/// <summary>
/// Built-in scalar type: i32, bool, u8, etc.
/// </summary>
public sealed record IrPrimitive : IrType
{
    public IrPrimitive(string name, int size, int alignment)
    {
        Name = name;
        Size = size;
        Alignment = alignment;
    }

    public string Name { get; }
    public override int Size { get; }
    public override int Alignment { get; }
    public override string ToString() => Name;
}

/// <summary>
/// Pointer to another type. Always 8 bytes on 64-bit.
/// </summary>
public sealed record IrPointer(IrType Pointee) : IrType
{
    public override int Size => 8;
    public override int Alignment => 8;
    public override string ToString() => $"&{Pointee}";
}

/// <summary>
/// Array type: [T; N] (fixed) or [T; _] (dynamic/VLA).
/// Length is null for dynamically-sized arrays (size determined at runtime).
/// </summary>
public sealed record IrArray(IrType Element, int? Length) : IrType
{
    public bool IsDynamic => Length is null;
    public override int Size => Length.HasValue ? Element.Size * Length.Value : 0;
    public override int Alignment => Element.Alignment;
    public override string ToString() => Length.HasValue ? $"[{Element}; {Length}]" : $"[{Element}; _]";
}

/// <summary>
/// A field within an IrStruct, with pre-computed byte offset.
/// </summary>
public readonly record struct IrField(string Name, IrType Type, int ByteOffset);

/// <summary>
/// Named struct type with pre-computed layout.
/// </summary>
public sealed record IrStruct : IrType
{
    public IrStruct(string name, string cName, IrField[] fields, int size, int alignment)
    {
        Name = name;
        CName = cName;
        Fields = fields;
        Size = size;
        Alignment = alignment;
    }

    public string Name { get; }
    public string CName { get; }
    public IrField[] Fields { get; }
    public override int Size { get; }
    public override int Alignment { get; }
    public override string ToString() => Name;
}

/// <summary>
/// A variant within an IrEnum.
/// </summary>
public readonly record struct IrVariant(string Name, int TagValue, IrType? PayloadType, int PayloadOffset);

/// <summary>
/// Named enum (tagged union) type with pre-computed layout.
/// Tag is always at offset 0.
/// </summary>
public sealed record IrEnum : IrType
{
    public IrEnum(string name, string cName, int tagSize, IrVariant[] variants, int size, int alignment)
    {
        Name = name;
        CName = cName;
        TagSize = tagSize;
        Variants = variants;
        Size = size;
        Alignment = alignment;
    }

    public string Name { get; }
    public string CName { get; }
    public int TagSize { get; }
    public IrVariant[] Variants { get; }
    public override int Size { get; }
    public override int Alignment { get; }
    public override string ToString() => Name;
}

/// <summary>
/// Function pointer type.
/// </summary>
public sealed record IrFunctionPtr(IrType[] Params, IrType Return) : IrType
{
    public override int Size => 8;
    public override int Alignment => 8;
    public override string ToString()
    {
        var ps = string.Join(", ", (IEnumerable<IrType>)Params);
        return $"fn({ps}) {Return}";
    }
}

