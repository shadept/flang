using TypeBase = FLang.Core.TypeBase;

namespace FLang.Core;

/// <summary>
/// Provides name mangling utilities for generic functions and types to generate unique symbol names.
/// </summary>
public static class NameMangler
{
    /// <summary>
    /// Generates a mangled name for a generic function by combining the base name with type arguments.
    /// </summary>
    /// <param name="baseName">The base function name without type parameters.</param>
    /// <param name="typeArgs">The list of type arguments to encode in the mangled name.</param>
    /// <returns>A mangled name in the format "baseName__type1__type2" (e.g., "map__i32__bool").</returns>
    public static string GenericFunction(string baseName, IReadOnlyList<TypeBase> typeArgs)
    {
        // Example: name__i32__bool
        var parts = new List<string> { baseName };
        for (var i = 0; i < typeArgs.Count; i++)
        {
            var tname = SanitizeTypeForName(typeArgs[i]);
            parts.Add(tname);
        }

        return string.Join("__", parts);
    }

    /// <summary>
    /// Sanitizes a type into a safe identifier string for use in mangled names.
    /// Converts special characters and nested types into underscore-separated tokens.
    /// </summary>
    /// <param name="t">The type to sanitize.</param>
    /// <returns>A sanitized string representation safe for use in symbol names.</returns>
    private static string SanitizeTypeForName(TypeBase t)
    {
        // Map TypeBase to a C-like token and then sanitize
        var raw = t switch
        {
            PrimitiveType pt => pt.Name,
            StructType st when TypeRegistry.IsSlice(st) && st.TypeArguments.Count > 0 =>
                $"slice_{SanitizeTypeForName(st.TypeArguments[0])}",
            StructType st when TypeRegistry.IsOption(st) && st.TypeArguments.Count > 0 =>
                $"opt_{SanitizeTypeForName(st.TypeArguments[0])}",
            StructType st => GetStructName(st),
            ReferenceType rt => $"ref_{SanitizeTypeForName(rt.InnerType)}",
            ArrayType at => $"arr{at.Length}_{SanitizeTypeForName(at.ElementType)}",
            GenericType gt => $"{gt.BaseName}_{string.Join("_", gt.TypeArguments.Select(SanitizeTypeForName))}",
            GenericParameterType gp => $"gp_{gp.ParamName}",
            FunctionType ft => GetFunctionTypeName(ft),
            _ => t.Name
        };

        // Replace non-identifier characters (including dots from FQNs)
        var s = raw.Replace("*", "Ptr").Replace(" ", "_").Replace("[", "_").Replace("]", "_").Replace(";", "_")
            .Replace(",", "_").Replace(".", "_").Replace("(", "_").Replace(")", "_");
        return s;
    }

    /// <summary>
    /// Gets a mangled name for a function type.
    /// fn(i32, i32) i32 -> "fn_i32_i32_ret_i32"
    /// </summary>
    private static string GetFunctionTypeName(FunctionType ft)
    {
        var paramParts = ft.ParameterTypes.Select(SanitizeTypeForName);
        var returnPart = SanitizeTypeForName(ft.ReturnType);
        if (ft.ParameterTypes.Count == 0)
            return $"fn_ret_{returnPart}";
        return $"fn_{string.Join("_", paramParts)}_ret_{returnPart}";
    }

    /// <summary>
    /// Gets a mangled name for a struct type, including type arguments if present.
    /// </summary>
    /// <param name="st">The struct type to mangle.</param>
    /// <returns>A mangled struct name (e.g., "struct_MyType" or "struct_MyType_i32_bool" for generics).</returns>
    private static string GetStructName(StructType st)
    {
        // Generic structs: include type arguments
        if (st.TypeArguments.Count > 0)
        {
            var argSuffix = string.Join("_", st.TypeArguments.Select(SanitizeTypeForName));
            return $"struct_{st.StructName}_{argSuffix}";
        }

        return $"struct_{st.StructName}";
    }
}
