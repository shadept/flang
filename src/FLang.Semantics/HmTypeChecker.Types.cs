using FLang.Core.Types;
using FLang.Frontend.Ast.Types;
using Type = FLang.Core.Types.Type;

namespace FLang.Semantics;

public partial class HmTypeChecker
{
    /// <summary>
    /// Resolve a parser TypeNode to an inference Type.
    /// </summary>
    private Type ResolveTypeNode(TypeNode typeNode)
    {
        return typeNode switch
        {
            NamedTypeNode named => ResolveNamedType(named),
            ReferenceTypeNode refType => new ReferenceType(ResolveTypeNode(refType.InnerType)),
            NullableTypeNode nullable => new NominalType(WellKnown.Option,
                [ResolveTypeNode(nullable.InnerType)]),
            GenericTypeNode generic => ResolveGenericType(generic),
            ArrayTypeNode array => new ArrayType(ResolveTypeNode(array.ElementType), array.Length),
            SliceTypeNode slice => new NominalType(WellKnown.Slice,
                [ResolveTypeNode(slice.ElementType)]),
            GenericParameterTypeNode genParam => ResolveGenericParam(genParam),
            FunctionTypeNode fnType => new FunctionType(
                fnType.ParameterTypes.Select(ResolveTypeNode).ToArray(),
                ResolveTypeNode(fnType.ReturnType)),
            AnonymousStructTypeNode anonStruct => ResolveAnonymousStructType(anonStruct),
            _ => throw new NotSupportedException($"Unknown TypeNode: {typeNode.GetType().Name}")
        };
    }

    private Type ResolveNamedType(NamedTypeNode named)
    {
        // Built-in primitives
        var primitive = ResolvePrimitive(named.Name);
        if (primitive != null)
            return primitive;

        // Look up nominal type (struct/enum)
        var nominal = LookupNominalType(named.Name);
        if (nominal != null)
            return nominal;

        // Check scope for type parameters (bare T from generic context)
        var scheme = _scopes.Lookup(named.Name);
        if (scheme != null)
            return _engine.Specialize(scheme);

        ReportError($"Unknown type `{named.Name}`", named.Span, "E2003");
        return _engine.FreshVar();
    }

    private static PrimitiveType? ResolvePrimitive(string name)
    {
        return name switch
        {
            "never" => WellKnown.Never,
            "void" => WellKnown.Void,
            "i8" => WellKnown.I8,
            "i16" => WellKnown.I16,
            "i32" => WellKnown.I32,
            "i64" => WellKnown.I64,
            "isize" => WellKnown.ISize,
            "u8" => WellKnown.U8,
            "u16" => WellKnown.U16,
            "u32" => WellKnown.U32,
            "u64" => WellKnown.U64,
            "usize" => WellKnown.USize,
            "bool" => WellKnown.Bool,
            "char" => WellKnown.Char,
            _ => null
        };
    }

    private Type ResolveGenericType(GenericTypeNode generic)
    {
        var typeArgs = generic.TypeArguments.Select(ResolveTypeNode).ToArray();

        // Check for well-known generic types
        var name = generic.Name switch
        {
            "Option" => WellKnown.Option,
            "Slice" => WellKnown.Slice,
            "Range" => WellKnown.Range,
            "Type" => WellKnown.TypeInfo,
            _ => null
        };

        if (name != null)
            return new NominalType(name, typeArgs);

        // Look up user-defined generic nominal type
        var nominal = LookupNominalType(generic.Name);
        if (nominal != null)
            return new NominalType(nominal.Name, typeArgs, nominal.FieldsOrVariants);

        ReportError($"Unknown generic type `{generic.Name}`", generic.Span, "E2003");
        return _engine.FreshVar();
    }

    private Type ResolveGenericParam(GenericParameterTypeNode genParam)
    {
        // Generic parameters should be bound in scope as TypeVars during fn signature collection
        var scheme = _scopes.Lookup(genParam.Name);
        if (scheme != null)
            return scheme.Body;

        ReportError($"Unbound generic parameter `{genParam.Name}`", genParam.Span, "E2003");
        return _engine.FreshVar();
    }

    private Type ResolveAnonymousStructType(AnonymousStructTypeNode anonStruct)
    {
        var fields = anonStruct.Fields
            .Select(f => (f.FieldName, Type: ResolveTypeNode(f.FieldType)))
            .ToArray();

        // Anonymous structs get a synthetic name based on field structure
        var name = $"__anon_{string.Join("_", fields.Select(f => f.FieldName))}";
        return new NominalType(name, [], fields);
    }
}
