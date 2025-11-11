using System.Collections.Generic;
using FLang.Core;

namespace FLang.Frontend.Ast.Types;

public abstract class TypeNode : AstNode
{
    protected TypeNode(SourceSpan span) : base(span)
    {
    }
}

/// <summary>
/// Represents a named type like `i32`, `String`, `MyStruct`.
/// </summary>
public class NamedTypeNode : TypeNode
{
    public string Name { get; }

    public NamedTypeNode(SourceSpan span, string name) : base(span)
    {
        Name = name;
    }
}

/// <summary>
/// Represents a reference type like `&amp;T`.
/// </summary>
public class ReferenceTypeNode : TypeNode
{
    public TypeNode InnerType { get; }

    public ReferenceTypeNode(SourceSpan span, TypeNode innerType) : base(span)
    {
        InnerType = innerType;
    }
}

/// <summary>
/// Represents a nullable type like `T?` (sugar for `Option[T]`).
/// </summary>
public class NullableTypeNode : TypeNode
{
    public TypeNode InnerType { get; }

    public NullableTypeNode(SourceSpan span, TypeNode innerType) : base(span)
    {
        InnerType = innerType;
    }
}

/// <summary>
/// Represents a generic type like `List[T]`, `Dict[K, V]`, etc.
/// </summary>
public class GenericTypeNode : TypeNode
{
    public string Name { get; }
    public IReadOnlyList<TypeNode> TypeArguments { get; }

    public GenericTypeNode(SourceSpan span, string name, IReadOnlyList<TypeNode> typeArguments) : base(span)
    {
        Name = name;
        TypeArguments = typeArguments;
    }
}

/// <summary>
/// Represents a fixed-size array type like `[T; N]`.
/// </summary>
public class ArrayTypeNode : TypeNode
{
    public TypeNode ElementType { get; }
    public int Length { get; }

    public ArrayTypeNode(SourceSpan span, TypeNode elementType, int length) : base(span)
    {
        ElementType = elementType;
        Length = length;
    }
}

/// <summary>
/// Represents a slice type like `T[]`.
/// </summary>
public class SliceTypeNode : TypeNode
{
    public TypeNode ElementType { get; }

    public SliceTypeNode(SourceSpan span, TypeNode elementType) : base(span)
    {
        ElementType = elementType;
    }
}
