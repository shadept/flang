using System.Text;
using FLang.Core;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend;

/// <summary>
/// Error raised by compile-time evaluation: an error code, a message and the
/// span of the offending expression.
/// </summary>
public sealed class CompileTimeError(string code, string message, SourceSpan span) : Exception(message)
{
    public string Code { get; } = code;
    public SourceSpan Span { get; } = span;
}

/// <summary>
/// THE compile-time evaluator (RFC-021 §3). Declaration- and statement-level
/// `#if` directives and the template engine (`#if`, `#for`, `#(expr)`) all run
/// through this one class. Semantics follow FLang: conditions must be bool
/// (E2117), unknown names and members are errors (E2116), dict lookups
/// (`runtime.env["KEY"]`) yield optionals that must be unwrapped with `??`
/// before use (E2118), operators require matching operand types (E2118).
///
/// The environment is two layers: the closed compile-time <c>context</c>
/// (`platform.*`, `runtime.*`, honoring target overrides) and, inside a
/// template, the <c>bindings</c> (parameters and `#for` variables) layered
/// on top. Directives pass no bindings.
/// </summary>
public sealed class CompileTimeEvaluator
{
    /// <summary>A bare identifier bound to an `Ident` template parameter.</summary>
    public sealed record Ident(string Text);

    /// <summary>The `TypeKind` namespace: `TypeKind.Struct` etc. evaluate to <see cref="TypeInfoKind"/> values.</summary>
    private static readonly IReadOnlyDictionary<string, object> TypeKindNamespace =
        Enum.GetValues<TypeInfoKind>().ToDictionary(k => k.ToString(), k => (object)k);

    /// <summary>An optional compile-time value, as produced by dict indexing.</summary>
    private sealed record Optional(object? Value);

    /// <summary>Outcome of evaluating a directive condition. On error, Value is false.</summary>
    public sealed record Result(bool Value, string? ErrorCode, string? ErrorMessage, SourceSpan ErrorSpan)
    {
        public bool IsError => ErrorCode != null;
    }

    private readonly IReadOnlyDictionary<string, object> _context;
    private readonly Dictionary<string, object> _bindings;
    private readonly TypeInfoBuilder.DeclarationLookup _lookup;

    public CompileTimeEvaluator(
        IReadOnlyDictionary<string, object> context,
        Dictionary<string, object>? bindings = null,
        TypeInfoBuilder.DeclarationLookup? lookup = null)
    {
        _context = context;
        _bindings = bindings ?? [];
        _lookup = lookup ?? new TypeInfoBuilder.DeclarationLookup(_ => null, _ => null);
    }

    /// <summary>Template bindings (parameters, `#for` variables); mutated by the template engine.</summary>
    public Dictionary<string, object> Bindings => _bindings;

    /// <summary>Evaluate a directive `#if` condition over the closed context only.</summary>
    public static Result Evaluate(TemplateExpr condition, IReadOnlyDictionary<string, object> context)
    {
        try
        {
            return new Result(new CompileTimeEvaluator(context).EvalCondition(condition), null, null, default);
        }
        catch (CompileTimeError e)
        {
            return new Result(false, e.Code, e.Message, e.Span);
        }
    }

    /// <summary>Evaluate a condition; throws <see cref="CompileTimeError"/> unless it is a bool.</summary>
    public bool EvalCondition(TemplateExpr condition)
    {
        var value = Eval(condition);
        if (value is bool b) return b;
        if (value is Optional)
            throw new CompileTimeError("E2118",
                "optional value must be unwrapped with `??` before use as a condition", condition.Span);
        throw new CompileTimeError("E2117", $"#if condition must be a bool, got {Describe(value)}", condition.Span);
    }

    public object Eval(TemplateExpr expr)
    {
        switch (expr)
        {
            case TemplateBoolLiteral b: return b.Value;
            case TemplateStringLiteral s: return s.Value;
            case TemplateIntLiteral n: return n.Value;

            case TemplateNameExpr name:
                if (_bindings.TryGetValue(name.Name, out var bound)) return bound;
                if (_context.TryGetValue(name.Name, out var ctx)) return ctx;
                if (name.Name == "TypeKind") return TypeKindNamespace;
                throw new CompileTimeError("E2116", $"unknown compile-time name `{name.Name}`", name.Span);

            case TemplateMemberAccessExpr mem:
                return GetMember(Eval(mem.Object), mem.Member, mem.Span);

            case TemplateIndexExpr idx:
            {
                var obj = Eval(idx.Object);
                var key = Eval(idx.Index);
                if (obj is IReadOnlyDictionary<string, object> dict && key is string sk)
                    return new Optional(dict.TryGetValue(sk, out var v) ? v : null); // Dict.op_index → V?
                if (obj is List<object> list && key is long i)
                    return i >= 0 && i < list.Count
                        ? list[(int)i]
                        : throw new CompileTimeError("E2118", $"index {i} out of range (len {list.Count})", idx.Span);
                throw new CompileTimeError("E2118", $"cannot index {Describe(obj)} with {Describe(key)}", idx.Span);
            }

            case TemplateSliceExpr slice:
            {
                var obj = Eval(slice.Object);
                if (obj is not List<object> list)
                    throw new CompileTimeError("E2118", $"cannot slice {Describe(obj)}", slice.Span);
                var start = slice.Start != null ? ExpectInt(Eval(slice.Start), slice.Start.Span) : 0;
                var end = slice.End != null ? ExpectInt(Eval(slice.End), slice.End.Span) : list.Count;
                if (start < 0 || end > list.Count || start > end)
                    throw new CompileTimeError("E2118", $"slice {start}..{end} out of range (len {list.Count})", slice.Span);
                return list.GetRange(start, end - start);
            }

            case TemplateUnaryExpr un:
            {
                var operand = Eval(un.Operand);
                if (un.Operator == "!" && operand is bool ob) return !ob;
                if (un.Operator == "-" && operand is long ol) return -ol;
                throw new CompileTimeError("E2118", $"`{un.Operator}` cannot be applied to {Describe(operand)}", un.Span);
            }

            case TemplateBinaryExpr bin:
                return EvalBinary(bin);

            case TemplateCallExpr call:
                return EvalCall(call);

            default:
                throw new CompileTimeError("E2118", "expression form not allowed at compile time", expr.Span);
        }
    }

    private object EvalBinary(TemplateBinaryExpr bin)
    {
        var left = Eval(bin.Left);

        if (bin.Operator == "??")
        {
            if (left is Optional opt) return opt.Value ?? Eval(bin.Right);
            throw new CompileTimeError("E2118",
                $"left operand of `??` must be an optional (a dict lookup), got {Describe(left)}", bin.Span);
        }

        var right = Eval(bin.Right);
        if (left is Optional || right is Optional)
            throw new CompileTimeError("E2118", "optional value must be unwrapped with `??` before use", bin.Span);

        object? result = (bin.Operator, left, right) switch
        {
            ("and", bool a, bool b) => a && b,
            ("or", bool a, bool b) => a || b,
            ("==", bool a, bool b) => a == b,
            ("!=", bool a, bool b) => a != b,
            ("==", TypeInfoKind a, TypeInfoKind b) => a == b,
            ("!=", TypeInfoKind a, TypeInfoKind b) => a != b,
            ("==", Ident a, Ident b) => a.Text == b.Text,
            ("!=", Ident a, Ident b) => a.Text != b.Text,
            ("==", string a, string b) => a == b,
            ("!=", string a, string b) => a != b,
            ("+", string a, string b) => a + b,
            ("==", long a, long b) => a == b,
            ("!=", long a, long b) => a != b,
            ("<", long a, long b) => a < b,
            (">", long a, long b) => a > b,
            ("<=", long a, long b) => a <= b,
            (">=", long a, long b) => a >= b,
            ("+", long a, long b) => a + b,
            ("-", long a, long b) => a - b,
            ("*", long a, long b) => a * b,
            ("/", long a, long b) => b != 0 ? a / b : throw new CompileTimeError("E2118", "division by zero", bin.Span),
            ("%", long a, long b) => b != 0 ? a % b : throw new CompileTimeError("E2118", "division by zero", bin.Span),
            _ => null,
        };
        return result ?? throw new CompileTimeError("E2118",
            $"`{bin.Operator}` cannot be applied to {Describe(left)} and {Describe(right)}", bin.Span);
    }

    private object EvalCall(TemplateCallExpr call)
    {
        if (call.Arguments.Count != 1)
            throw new CompileTimeError("E2118", $"`{call.FunctionName}` takes one argument", call.Span);
        var arg = Eval(call.Arguments[0]);
        var argSpan = call.Arguments[0].Span;

        switch (call.FunctionName)
        {
            case "type_of":
                return arg is TypeInfoModel
                    ? arg
                    : throw new CompileTimeError("E2118", $"`type_of` expects a type, got {Describe(arg)}", argSpan);
            case "type_named":
            {
                var name = arg as string
                    ?? throw new CompileTimeError("E2118", $"`type_named` expects a string, got {Describe(arg)}", argSpan);
                var nominal = _lookup.Nominal(name)
                    ?? throw new CompileTimeError("E2003", $"Unknown type `{name}`", call.Span);
                return TypeInfoBuilder.FromNominalDeclaration(nominal, _lookup);
            }
            case "lower": return ExpectText(arg, argSpan).ToLowerInvariant();
            case "snake_case": return SnakeCase(ExpectText(arg, argSpan));
            case "pascal_case": return PascalCase(ExpectText(arg, argSpan));
            default:
                throw new CompileTimeError("E2116", $"unknown compile-time function `{call.FunctionName}`", call.Span);
        }
    }

    private static string ExpectText(object value, SourceSpan span) => value switch
    {
        string s => s,
        Ident i => i.Text,
        _ => throw new CompileTimeError("E2118", $"expected a string or identifier, got {Describe(value)}", span),
    };

    private object GetMember(object value, string member, SourceSpan span)
    {
        switch (value)
        {
            case IReadOnlyDictionary<string, object> ns:
                return ns.TryGetValue(member, out var v)
                    ? v
                    : throw new CompileTimeError("E2116", $"unknown compile-time member `{member}`", span);

            // core.rtti.TypeInfo
            case TypeInfoModel t when member == "name": return t.Name;
            case TypeInfoModel t when member == "kind":
                return t.Kind ?? throw new CompileTimeError("E2118",
                    $"`{t.Name}` has no TypeKind at template time", span);
            case TypeInfoModel t when member == "fields": return t.Fields.Cast<object>().ToList();
            case TypeInfoModel t when member == "variants": return t.Variants.Cast<object>().ToList();
            case TypeInfoModel t when member == "params": return t.Params.Cast<object>().ToList();
            case TypeInfoModel t when member == "return_type":
                return t.ReturnType ?? throw new CompileTimeError("E2118", $"`{t.Name}` is not a function type", span);
            case TypeInfoModel when member is "type_params" or "type_args": return new List<object>();
            case TypeInfoModel when member is "size" or "align":
            case FieldInfoModel when member == "offset":
                throw new CompileTimeError("E2120", $"`{member}` is not available at template time (layout is computed after expansion)", span);

            // core.rtti.FieldInfo / VariantInfo / ParamInfo
            case FieldInfoModel f when member == "name": return f.Name;
            case FieldInfoModel f when member == "type_info": return f.TypeInfo;
            case VariantInfoModel vi when member == "name": return vi.Name;
            case ParamInfoModel p when member == "name": return p.Name;
            case ParamInfoModel p when member == "type_info": return p.TypeInfo;

            case Ident id when member == "text": return id.Text;
            case string s when member == "len": return (long)s.Length;
            case List<object> list when member == "len": return (long)list.Count;

            default:
                throw new CompileTimeError("E2116", $"cannot access member `{member}` on {Describe(value)}", span);
        }
    }

    private static int ExpectInt(object value, SourceSpan span) =>
        value is long l ? (int)l : throw new CompileTimeError("E2118", $"expected an integer, got {Describe(value)}", span);

    public static string Stringify(object value) => value switch
    {
        string s => s,
        long l => l.ToString(),
        bool b => b ? "true" : "false",
        Ident i => i.Text,
        TypeInfoModel t => t.Name,
        TypeInfoKind k => k.ToString(),
        FieldInfoModel f => f.Name,
        VariantInfoModel v => v.Name,
        ParamInfoModel p => p.Name,
        _ => value?.ToString() ?? "",
    };

    private static string Describe(object? value) => value switch
    {
        null => "nothing",
        bool => "a bool",
        long => "an integer",
        string s => $"a string (\"{s}\")",
        Optional => "an optional",
        IReadOnlyDictionary<string, object> => "a compile-time namespace",
        List<object> => "a list",
        Ident i => $"an identifier (`{i.Text}`)",
        TypeInfoModel t => $"a type (`{t.Name}`)",
        TypeInfoKind => "a TypeKind",
        FieldInfoModel => "a field",
        VariantInfoModel => "a variant",
        ParamInfoModel => "a parameter",
        _ => value.GetType().Name,
    };

    private static string SnakeCase(string input)
    {
        var sb = new StringBuilder(input.Length + 4);
        for (var i = 0; i < input.Length; i++)
        {
            if (char.IsUpper(input[i]) && i > 0) sb.Append('_');
            sb.Append(char.ToLowerInvariant(input[i]));
        }
        return sb.ToString();
    }

    private static string PascalCase(string input)
    {
        var sb = new StringBuilder(input.Length);
        var capitalizeNext = true;
        foreach (var c in input)
        {
            if (c == '_') { capitalizeNext = true; continue; }
            sb.Append(capitalizeNext ? char.ToUpperInvariant(c) : c);
            capitalizeNext = false;
        }
        return sb.ToString();
    }

    public static string TypeNodeToString(TypeNode node) => node switch
    {
        NamedTypeNode named => named.Name,
        ReferenceTypeNode refType => $"&{TypeNodeToString(refType.InnerType)}",
        NullableTypeNode nullable => $"{TypeNodeToString(nullable.InnerType)}?",
        ArrayTypeNode array => $"[{TypeNodeToString(array.ElementType)}; {array.Length}]",
        SliceTypeNode slice => $"{TypeNodeToString(slice.ElementType)}[]",
        GenericParameterTypeNode gp => $"${gp.Name}",
        GenericTypeNode generic => $"{generic.Name}[{string.Join(", ", generic.TypeArguments.Select(TypeNodeToString))}]",
        FunctionTypeNode fn =>
            $"fn({string.Join(", ", fn.ParameterTypes.Select((pt, i) =>
            {
                var name = fn.ParameterNames.Count > i ? fn.ParameterNames[i] : null;
                return name != null ? $"{name}: {TypeNodeToString(pt)}" : TypeNodeToString(pt);
            }))}) {TypeNodeToString(fn.ReturnType)}",
        AnonymousStructTypeNode anon =>
            $"struct {{ {string.Join(", ", anon.Fields.Select(f => $"{f.FieldName}: {TypeNodeToString(f.FieldType)}"))} }}",
        _ => node.GetType().Name,
    };
}
