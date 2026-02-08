namespace FLang.IR;

/// <summary>
/// IrType-based name mangling for C code generation.
/// Uses CName from IrStruct/IrEnum when available.
/// </summary>
public static class IrNameMangling
{
    /// <summary>
    /// Mangle a function name with its parameter types: "name__type1__type2".
    /// </summary>
    public static string MangleFunctionName(string baseName, IReadOnlyList<IrType> paramTypes)
    {
        if (paramTypes.Count == 0) return baseName;
        var parts = new List<string>(paramTypes.Count + 1) { baseName };
        foreach (var pt in paramTypes)
            parts.Add(MangleIrType(pt));
        return string.Join("__", parts);
    }

    /// <summary>
    /// Convert an IrType to its mangled name token.
    /// </summary>
    public static string MangleIrType(IrType type)
    {
        return type switch
        {
            IrPrimitive p => p.Name,
            IrPointer ptr => $"ref_{MangleIrType(ptr.Pointee)}",
            IrStruct s => $"struct_{s.CName}",
            IrEnum e => $"struct_{e.CName}",
            IrArray a when a.Length.HasValue => $"arr{a.Length}_{MangleIrType(a.Element)}",
            IrArray a => $"arr_{MangleIrType(a.Element)}",
            IrFunctionPtr fp => MangleFunctionPtr(fp),
            _ => "void"
        };
    }

    private static string MangleFunctionPtr(IrFunctionPtr fp)
    {
        var paramParts = fp.Params.Select(MangleIrType);
        var retPart = MangleIrType(fp.Return);
        return fp.Params.Length == 0
            ? $"fn_ret_{retPart}"
            : $"fn_{string.Join("_", paramParts)}_ret_{retPart}";
    }
}
