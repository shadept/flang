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
    public NamedTypeNode(SourceSpan span, string name) : base(span)
    {
        Name = name;
    }

    public string Name { get; }
}

/// <summary>
/// Represents a reference type like `&amp;T`.
/// </summary>
public class ReferenceTypeNode : TypeNode
{
    public ReferenceTypeNode(SourceSpan span, TypeNode innerType) : base(span)
    {
        InnerType = innerType;
    }

    public TypeNode InnerType { get; }
}

/// <summary>
/// Represents a nullable type like `T?` (sugar for `Option[T]`).
/// </summary>
public class NullableTypeNode : TypeNode
{
    public NullableTypeNode(SourceSpan span, TypeNode innerType) : base(span)
    {
        InnerType = innerType;
    }

    public TypeNode InnerType { get; }
}

/// <summary>
/// Represents a generic type like `List[T]`, `Dict[K, V]`, etc.
/// </summary>
public class GenericTypeNode : TypeNode
{
    public GenericTypeNode(SourceSpan span, string name, IReadOnlyList<TypeNode> typeArguments) : base(span)
    {
        if (typeArguments.Count == 0) throw new ArgumentException("Generic type must have at least one type argument.");
        Name = name;
        TypeArguments = typeArguments;
    }

    public string Name { get; }
    public IReadOnlyList<TypeNode> TypeArguments { get; }
}

/// <summary>
/// Represents a fixed-size array type like `[T; N]`.
/// </summary>
public class ArrayTypeNode : TypeNode
{
    public ArrayTypeNode(SourceSpan span, TypeNode elementType, int length) : base(span)
    {
        ElementType = elementType;
        Length = length;
    }

    public TypeNode ElementType { get; }
    public int Length { get; }
}

/// <summary>
/// Represents a slice type like `T[]`.
/// </summary>
public class SliceTypeNode : TypeNode
{
    public SliceTypeNode(SourceSpan span, TypeNode elementType) : base(span)
    {
        ElementType = elementType;
    }

    public TypeNode ElementType { get; }
}

/// <summary>
/// Represents a generic parameter type like `$T`.
/// </summary>
public class GenericParameterTypeNode : TypeNode
{
    public GenericParameterTypeNode(SourceSpan span, string name) : base(span)
    {
        Name = name;
    }

    public string Name { get; }
}