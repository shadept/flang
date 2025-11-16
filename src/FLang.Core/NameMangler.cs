namespace FLang.Core;

public static class NameMangler
{
    public static string GenericFunction(string baseName, IReadOnlyList<FType> typeArgs)
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

    private static string SanitizeTypeForName(FType t)
    {
        // Map FType to a C-like token and then sanitize
        var raw = t switch
        {
            PrimitiveType pt => pt.Name,
            StructType st => GetStructName(st),
            ReferenceType rt => $"ref_{SanitizeTypeForName(rt.InnerType)}",
            OptionType ot => $"opt_{SanitizeTypeForName(ot.InnerType)}",
            ArrayType at => $"arr{at.Length}_{SanitizeTypeForName(at.ElementType)}",
            SliceType sl => $"slice_{SanitizeTypeForName(sl.ElementType)}",
            GenericType gt => $"{gt.BaseName}_{string.Join("_", gt.TypeArguments.Select(SanitizeTypeForName))}",
            GenericParameterType gp => $"gp_{gp.ParamName}",
            _ => t.Name
        };

        // Replace non-identifier characters
        var s = raw.Replace("*", "Ptr").Replace(" ", "_").Replace("[", "_").Replace("]", "_").Replace(";", "_")
            .Replace(",", "_");
        return s;
    }

    private static string GetStructName(StructType st)
    {
        // Generic structs: include type parameters
        if (st.TypeParameters.Count > 0)
        {
            var paramSuffix = string.Join("_", st.TypeParameters.Select(p => p.Replace("*", "Ptr").Replace(" ", "_")));
            return $"struct_{st.StructName}_{paramSuffix}";
        }

        return $"struct_{st.StructName}";
    }
}