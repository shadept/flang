using FLang.Core;

namespace FLang.Frontend.Ast.Types;

public abstract class TypeNode : AstNode
{
    protected TypeNode(SourceSpan span) : base(span)
    {
    }

    public static bool ContainsGenericParam(TypeNode node) => node switch
    {
        GenericParameterTypeNode => true,
        ReferenceTypeNode rt => ContainsGenericParam(rt.InnerType),
        NullableTypeNode nt => ContainsGenericParam(nt.InnerType),
        ArrayTypeNode at => ContainsGenericParam(at.ElementType),
        SliceTypeNode st => ContainsGenericParam(st.ElementType),
        GenericTypeNode gt => gt.TypeArguments.Any(ContainsGenericParam),
        FunctionTypeNode ft => ft.ParameterTypes.Any(ContainsGenericParam) || ContainsGenericParam(ft.ReturnType),
        _ => false
    };

    public static void CollectGenericParamNames(TypeNode node, HashSet<string> names)
    {
        switch (node)
        {
            case GenericParameterTypeNode gp:
                names.Add(gp.Name);
                break;
            case ReferenceTypeNode rt:
                CollectGenericParamNames(rt.InnerType, names);
                break;
            case NullableTypeNode nt:
                CollectGenericParamNames(nt.InnerType, names);
                break;
            case ArrayTypeNode at:
                CollectGenericParamNames(at.ElementType, names);
                break;
            case SliceTypeNode st:
                CollectGenericParamNames(st.ElementType, names);
                break;
            case GenericTypeNode gt:
                foreach (var ta in gt.TypeArguments)
                    CollectGenericParamNames(ta, names);
                break;
            case FunctionTypeNode ft:
                foreach (var pt in ft.ParameterTypes)
                    CollectGenericParamNames(pt, names);
                CollectGenericParamNames(ft.ReturnType, names);
                break;
        }
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

/// <summary>
/// Represents a function type like `fn(T1, T2) R`.
/// </summary>
public class FunctionTypeNode : TypeNode
{
    public FunctionTypeNode(SourceSpan span, IReadOnlyList<TypeNode> parameterTypes, TypeNode returnType) : base(span)
    {
        ParameterTypes = parameterTypes;
        ReturnType = returnType;
    }

    public IReadOnlyList<TypeNode> ParameterTypes { get; }
    public TypeNode ReturnType { get; }
}

/// <summary>
/// Represents an anonymous struct type like `{ _0: T1, _1: T2 }`.
/// Used for desugaring tuple types like `(T1, T2)`.
/// </summary>
public class AnonymousStructTypeNode : TypeNode
{
    public AnonymousStructTypeNode(SourceSpan span, IReadOnlyList<(string FieldName, TypeNode FieldType)> fields) : base(span)
    {
        Fields = fields;
    }

    public IReadOnlyList<(string FieldName, TypeNode FieldType)> Fields { get; }
}