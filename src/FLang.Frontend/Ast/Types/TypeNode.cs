using FLang.Core;

namespace FLang.Frontend.Ast.Types;

public abstract class TypeNode(SourceSpan span) : AstNode(span)
{

    public static bool ContainsGenericParam(TypeNode node) => node switch
    {
        GenericParameterTypeNode => true,
        ReferenceTypeNode rt => ContainsGenericParam(rt.InnerType),
        NullableTypeNode nt => ContainsGenericParam(nt.InnerType),
        ArrayTypeNode at => ContainsGenericParam(at.ElementType),
        SliceTypeNode st => ContainsGenericParam(st.ElementType),
        GenericTypeNode gt => gt.TypeArguments.Any(ContainsGenericParam),
        FunctionTypeNode ft => ft.ParameterTypes.Any(ContainsGenericParam) || ContainsGenericParam(ft.ReturnType),
        AnonymousStructTypeNode ast => ast.Fields.Any(f => ContainsGenericParam(f.FieldType)),
        AnonymousEnumTypeNode aet => aet.Variants.Any(v => v.PayloadTypes.Any(ContainsGenericParam)),
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
            case AnonymousStructTypeNode ast:
                foreach (var f in ast.Fields)
                    CollectGenericParamNames(f.FieldType, names);
                break;
            case AnonymousEnumTypeNode aet:
                foreach (var v in aet.Variants)
                    foreach (var pt in v.PayloadTypes)
                        CollectGenericParamNames(pt, names);
                break;
        }
    }
}

/// <summary>
/// Represents a named type like `i32`, `String`, `MyStruct`.
/// </summary>
public class NamedTypeNode(SourceSpan span, string name) : TypeNode(span)
{
    public string Name { get; } = name;
}

/// <summary>
/// Represents a reference type like `&amp;T`.
/// </summary>
public class ReferenceTypeNode(SourceSpan span, TypeNode innerType) : TypeNode(span)
{
    public TypeNode InnerType { get; } = innerType;
}

/// <summary>
/// Represents a nullable type like `T?` (sugar for `Option[T]`).
/// </summary>
public class NullableTypeNode(SourceSpan span, TypeNode innerType) : TypeNode(span)
{
    public TypeNode InnerType { get; } = innerType;
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
public class ArrayTypeNode(SourceSpan span, TypeNode elementType, int length) : TypeNode(span)
{
    public TypeNode ElementType { get; } = elementType;
    public int Length { get; } = length;
}

/// <summary>
/// Represents a slice type like `T[]`.
/// </summary>
public class SliceTypeNode(SourceSpan span, TypeNode elementType) : TypeNode(span)
{
    public TypeNode ElementType { get; } = elementType;
}

/// <summary>
/// Represents a generic parameter type like `$T`.
/// </summary>
public class GenericParameterTypeNode(SourceSpan span, string name) : TypeNode(span)
{
    public string Name { get; } = name;
}

/// <summary>
/// Represents a function type like `fn(T1, T2) R`.
/// </summary>
public class FunctionTypeNode(SourceSpan span, IReadOnlyList<TypeNode> parameterTypes, TypeNode returnType,
    IReadOnlyList<string?>? parameterNames = null) : TypeNode(span)
{
    public IReadOnlyList<TypeNode> ParameterTypes { get; } = parameterTypes;
    public TypeNode ReturnType { get; } = returnType;
    public IReadOnlyList<string?> ParameterNames { get; } = parameterNames ?? new string?[parameterTypes.Count];
}

/// <summary>
/// Represents an anonymous struct type like `{ _0: T1, _1: T2 }`.
/// Used for desugaring tuple types like `(T1, T2)`.
/// </summary>
public class AnonymousStructTypeNode(SourceSpan span, IReadOnlyList<(string FieldName, TypeNode FieldType)> fields) : TypeNode(span)
{

    public IReadOnlyList<(string FieldName, TypeNode FieldType)> Fields { get; } = fields;
}

/// <summary>
/// Represents an anonymous enum type like `enum { None, Some(T) }`.
/// Used as inline type expressions.
/// </summary>
public class AnonymousEnumTypeNode(SourceSpan span, IReadOnlyList<(string Name, IReadOnlyList<TypeNode> PayloadTypes)> variants) : TypeNode(span)
{
    public IReadOnlyList<(string Name, IReadOnlyList<TypeNode> PayloadTypes)> Variants { get; } = variants;
}
