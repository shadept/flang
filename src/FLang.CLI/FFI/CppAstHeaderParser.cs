using System.Diagnostics;
using System.Runtime.InteropServices;
using CppAst;

namespace FLang.CLI.FFI;

/// <summary>
/// Parses C headers using the CppAst library (libclang-based).
/// Maps C types to the intermediate CType model for FLang binding generation.
/// </summary>
public class CppAstHeaderParser : ICHeaderParser
{
    public CHeaderParseResult Parse(string headerPath)
    {
        var options = new CppParserOptions
        {
            ParseMacros = false,
            ParseComments = false,
        };

        // Add system include paths so libclang can find <stdarg.h> etc.
        foreach (var path in DiscoverSystemIncludePaths())
            options.SystemIncludeFolders.Add(path);

        var compilation = CppParser.ParseFile(headerPath, options);

        var functions = new List<CFunction>();
        var structs = new List<CStruct>();
        var enumConstants = new List<CEnumConstant>();
        var warnings = new List<string>();
        var errors = new List<string>();

        // Collect parse errors from CppAst
        foreach (var diag in compilation.Diagnostics.Messages)
        {
            if (diag.Type == CppLogMessageType.Error)
                errors.Add(diag.ToString());
        }

        if (errors.Count > 0)
            return new CHeaderParseResult(functions, structs, enumConstants, warnings, errors);

        // Track known struct names for type resolution
        var knownStructs = new HashSet<string>();

        // Parse structs
        foreach (var cppClass in compilation.Classes)
        {
            if (cppClass.ClassKind != CppClassKind.Struct) continue;
            if (cppClass.IsAnonymous) continue;
            if (string.IsNullOrEmpty(cppClass.Name)) continue;

            var fields = new List<CField>();
            var skip = false;

            foreach (var field in cppClass.Fields)
            {
                var fieldType = MapType(field.Type, knownStructs, warnings);
                if (fieldType.Kind == CTypeKind.Unknown)
                {
                    warnings.Add($"Skipping struct '{cppClass.Name}': unsupported field type for '{field.Name}'");
                    skip = true;
                    break;
                }
                fields.Add(new CField(field.Name, fieldType));
            }

            if (skip) continue;

            knownStructs.Add(cppClass.Name);
            structs.Add(new CStruct(cppClass.Name, fields));
        }

        // Parse enums as integer constants
        foreach (var cppEnum in compilation.Enums)
        {
            foreach (var item in cppEnum.Items)
            {
                enumConstants.Add(new CEnumConstant(item.Name, item.Value));
            }
        }

        // Parse functions
        foreach (var cppFunc in compilation.Functions)
        {
            // Skip variadic functions
            if (cppFunc.Parameters.Any(p => p.Type is CppPrimitiveType { Kind: CppPrimitiveKind.Void } && p.Name == "..."))
                continue;
            if (cppFunc.Flags.HasFlag(CppFunctionFlags.Variadic))
                continue;

            var returnType = MapType(cppFunc.ReturnType, knownStructs, warnings);
            if (returnType.Kind == CTypeKind.Unknown)
            {
                warnings.Add($"Skipping function '{cppFunc.Name}': unsupported return type");
                continue;
            }

            var parameters = new List<CParameter>();
            var skipFunc = false;

            foreach (var param in cppFunc.Parameters)
            {
                var paramType = MapType(param.Type, knownStructs, warnings);
                if (paramType.Kind == CTypeKind.Unknown)
                {
                    warnings.Add($"Skipping function '{cppFunc.Name}': unsupported parameter type for '{param.Name}'");
                    skipFunc = true;
                    break;
                }
                parameters.Add(new CParameter(param.Name, paramType));
            }

            if (skipFunc) continue;

            functions.Add(new CFunction(cppFunc.Name, returnType, parameters));
        }

        return new CHeaderParseResult(functions, structs, enumConstants, warnings, errors);
    }

    private static CType MapType(CppType cppType, HashSet<string> knownStructs, List<string> warnings)
    {
        // Unwrap qualifiers (const, volatile)
        if (cppType is CppQualifiedType qualified)
            return MapType(qualified.ElementType, knownStructs, warnings);

        // Unwrap typedefs recursively, but check if it's a known struct name first
        if (cppType is CppTypedef typedef)
        {
            // Check for well-known typedef names
            var mapped = MapWellKnownTypedef(typedef.Name);
            if (mapped != null) return mapped;

            // If the typedef name matches a known struct, treat as struct reference
            if (knownStructs.Contains(typedef.Name))
                return new CType(CTypeKind.Struct, typedef.Name);

            // Otherwise unwrap and recurse
            return MapType(typedef.ElementType, knownStructs, warnings);
        }

        if (cppType is CppPrimitiveType primitive)
            return MapPrimitive(primitive.Kind);

        if (cppType is CppPointerType pointer)
        {
            var pointee = MapType(pointer.ElementType, knownStructs, warnings);
            // void* maps to pointer to u8
            if (pointee.Kind == CTypeKind.Void)
                pointee = new CType(CTypeKind.U8);
            return new CType(CTypeKind.Pointer, PointeeType: pointee);
        }

        if (cppType is CppClass { ClassKind: CppClassKind.Struct } structType)
        {
            if (!string.IsNullOrEmpty(structType.Name) && knownStructs.Contains(structType.Name))
                return new CType(CTypeKind.Struct, structType.Name);
            // Anonymous or unknown struct
            warnings.Add($"Unsupported anonymous/unknown struct type");
            return new CType(CTypeKind.Unknown);
        }

        if (cppType is CppEnum)
            return new CType(CTypeKind.I32); // C enums are ints

        if (cppType is CppArrayType)
        {
            // Fixed-size arrays in struct fields — treat as pointer for FFI
            warnings.Add($"Array type encountered, treating as unsupported");
            return new CType(CTypeKind.Unknown);
        }

        if (cppType is CppFunctionType)
        {
            warnings.Add($"Function pointer type not supported");
            return new CType(CTypeKind.Unknown);
        }

        warnings.Add($"Unknown C type: {cppType.GetType().Name} '{cppType}'");
        return new CType(CTypeKind.Unknown);
    }

    private static CType MapPrimitive(CppPrimitiveKind kind) => kind switch
    {
        CppPrimitiveKind.Void => new CType(CTypeKind.Void),
        CppPrimitiveKind.Bool => new CType(CTypeKind.Bool),
        CppPrimitiveKind.Char => new CType(CTypeKind.U8),  // FLang strings are &u8
        CppPrimitiveKind.Short => new CType(CTypeKind.I16),
        CppPrimitiveKind.Int => new CType(CTypeKind.I32),
        CppPrimitiveKind.LongLong => new CType(CTypeKind.I64),
        CppPrimitiveKind.UnsignedChar => new CType(CTypeKind.U8),
        CppPrimitiveKind.UnsignedShort => new CType(CTypeKind.U16),
        CppPrimitiveKind.UnsignedInt => new CType(CTypeKind.U32),
        CppPrimitiveKind.UnsignedLongLong => new CType(CTypeKind.U64),
        CppPrimitiveKind.Float => new CType(CTypeKind.F32),
        CppPrimitiveKind.Double => new CType(CTypeKind.F64),
        CppPrimitiveKind.Long => new CType(CTypeKind.I64),          // 64-bit targets
        CppPrimitiveKind.UnsignedLong => new CType(CTypeKind.U64),  // 64-bit targets
        _ => new CType(CTypeKind.Unknown)
    };

    private static CType? MapWellKnownTypedef(string name) => name switch
    {
        "size_t" => new CType(CTypeKind.USize),
        "ssize_t" or "ptrdiff_t" => new CType(CTypeKind.ISize),
        "int8_t" => new CType(CTypeKind.I8),
        "int16_t" => new CType(CTypeKind.I16),
        "int32_t" => new CType(CTypeKind.I32),
        "int64_t" => new CType(CTypeKind.I64),
        "uint8_t" => new CType(CTypeKind.U8),
        "uint16_t" => new CType(CTypeKind.U16),
        "uint32_t" => new CType(CTypeKind.U32),
        "uint64_t" => new CType(CTypeKind.U64),
        "uintptr_t" => new CType(CTypeKind.USize),
        "intptr_t" => new CType(CTypeKind.ISize),
        _ => null
    };

    /// <summary>
    /// Discovers system C include paths by querying the system C compiler.
    /// These are needed so libclang can find &lt;stdarg.h&gt;, &lt;stdint.h&gt;, etc.
    /// </summary>
    private static List<string> DiscoverSystemIncludePaths()
    {
        var paths = new List<string>();
        try
        {
            // Use the same approach as CompilerDiscovery: query the C compiler for its search paths
            var compiler = RuntimeInformation.IsOSPlatform(OSPlatform.OSX) ? "xcrun" : "cc";
            var compilerArgs = RuntimeInformation.IsOSPlatform(OSPlatform.OSX)
                ? "clang -E -v -x c /dev/null"
                : "-E -v -x c /dev/null";

            var psi = new ProcessStartInfo(compiler, compilerArgs)
            {
                RedirectStandardError = true,
                RedirectStandardOutput = true,
                UseShellExecute = false,
            };
            using var proc = Process.Start(psi);
            if (proc == null) return paths;

            var stderr = proc.StandardError.ReadToEnd();
            proc.WaitForExit(5000);

            // Parse include paths from clang -v output (between "#include <...>" and "End of search list")
            var inSearchList = false;
            foreach (var line in stderr.Split('\n'))
            {
                if (line.Contains("#include <...> search starts here"))
                {
                    inSearchList = true;
                    continue;
                }
                if (line.Contains("End of search list"))
                    break;
                if (inSearchList)
                {
                    var trimmed = line.Trim();
                    // Strip " (framework directory)" suffix
                    var idx = trimmed.IndexOf(" (framework directory)");
                    if (idx >= 0) trimmed = trimmed[..idx];
                    if (Directory.Exists(trimmed))
                        paths.Add(trimmed);
                }
            }
        }
        catch
        {
            // Silently fall back to no system includes — errors will surface from CppAst
        }
        return paths;
    }
}
