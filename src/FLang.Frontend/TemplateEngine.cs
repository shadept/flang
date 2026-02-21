using System.Text;
using FLang.Core.Types;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend;

/// <summary>
/// Expands source generator templates by evaluating template expressions and producing source text.
/// Template values are plain C# objects; member access dispatches via pattern matching.
/// </summary>
public class TemplateEngine
{
    public record TemplateFieldInfo(string Name, TypeNode TypeNode);
    public record TemplateParamInfo(string Name, TypeNode TypeNode);

    private readonly Dictionary<string, object> _env;
    private readonly Func<string, NominalType?> _typeOfLookup;
    private readonly Func<string, IReadOnlyList<(string Name, TypeNode TypeNode)>?> _fieldNodeLookup;

    public TemplateEngine(
        Dictionary<string, object> env,
        Func<string, NominalType?> typeOfLookup,
        Func<string, IReadOnlyList<(string Name, TypeNode TypeNode)>?> fieldNodeLookup)
    {
        _env = env;
        _typeOfLookup = typeOfLookup;
        _fieldNodeLookup = fieldNodeLookup;
    }

    public string Expand(IReadOnlyList<TemplateNode> body)
    {
        var sb = new StringBuilder();
        foreach (var node in body)
            ExpandNode(sb, node);
        var result = Dedent(sb.ToString());
        var trimmed = result.Trim('\n', '\r');
        return trimmed.Length > 0 ? trimmed + "\n" : "";
    }

    private void ExpandNode(StringBuilder sb, TemplateNode node)
    {
        switch (node)
        {
            case TemplateVerbatimNode v:
                sb.Append(v.Text);
                break;

            case TemplateInterpolationNode interp:
                sb.Append(Stringify(EvalExpr(interp.Expression)));
                break;

            case TemplateForNode forNode:
                var iterable = EvalExpr(forNode.Iterable);
                if (iterable is List<object> list)
                {
                    var bodySb = new StringBuilder();
                    foreach (var item in list)
                    {
                        _env[forNode.VariableName] = item;
                        foreach (var child in forNode.Body)
                            ExpandNode(bodySb, child);
                    }
                    _env.Remove(forNode.VariableName);
                    AppendDedented(sb, bodySb.ToString());
                }
                break;

            case TemplateIfNode ifNode:
                var cond = EvalExpr(ifNode.Condition);
                if (IsTruthy(cond))
                {
                    var ifSb = new StringBuilder();
                    foreach (var child in ifNode.Body)
                        ExpandNode(ifSb, child);
                    AppendDedented(sb, ifSb.ToString());
                }
                else if (ifNode.ElseBranch != null)
                {
                    var elseSb = new StringBuilder();
                    foreach (var child in ifNode.ElseBranch)
                        ExpandNode(elseSb, child);
                    AppendDedented(sb, elseSb.ToString());
                }
                break;
        }
    }

    private object EvalExpr(TemplateExpr expr)
    {
        switch (expr)
        {
            case TemplateStringLiteral str:
                return str.Value;

            case TemplateIntLiteral num:
                return num.Value;

            case TemplateNameExpr name:
                if (_env.TryGetValue(name.Name, out var val))
                    return val;
                // Return as string identity (bare identifier)
                return name.Name;

            case TemplateMemberAccessExpr mem:
                var obj = EvalExpr(mem.Object);
                return GetMember(obj, mem.Member);

            case TemplateBinaryExpr bin:
                var left = EvalExpr(bin.Left);
                var right = EvalExpr(bin.Right);
                return EvalBinary(left, bin.Operator, right);

            case TemplateIndexExpr idx:
                var indexObj = EvalExpr(idx.Object);
                var indexVal = EvalExpr(idx.Index);
                if (indexObj is List<object> indexList && indexVal is long i)
                    return indexList[(int)i];
                throw new InvalidOperationException($"Cannot index {indexObj?.GetType().Name} with {indexVal}");

            case TemplateSliceExpr slice:
                var sliceObj = EvalExpr(slice.Object);
                if (sliceObj is List<object> sliceList)
                {
                    var start = slice.Start != null ? (int)(long)EvalExpr(slice.Start) : 0;
                    var end = slice.End != null ? (int)(long)EvalExpr(slice.End) : sliceList.Count;
                    return sliceList.GetRange(start, end - start);
                }
                throw new InvalidOperationException($"Cannot slice {sliceObj?.GetType().Name}");

            case TemplateCallExpr call:
                return EvalCall(call);

            default:
                throw new InvalidOperationException($"Unknown template expression: {expr.GetType().Name}");
        }
    }

    private object EvalCall(TemplateCallExpr call)
    {
        switch (call.FunctionName)
        {
            case "type_of":
            {
                var arg = EvalExpr(call.Arguments[0]);
                var name = Stringify(arg);
                var nominal = _typeOfLookup(name);
                if (nominal == null)
                    throw new InvalidOperationException($"type_of: type '{name}' not found");
                return nominal;
            }

            case "lower":
            {
                var arg = EvalExpr(call.Arguments[0]);
                return Stringify(arg).ToLowerInvariant();
            }

            default:
                throw new InvalidOperationException($"Unknown template function: {call.FunctionName}");
        }
    }

    private object GetMember(object value, string member)
    {
        switch (value)
        {
            // NamedTypeNode — T.name → the type name
            case NamedTypeNode named when member == "name":
                return named.Name;

            // AnonymousStructTypeNode — Spec.fields → list of TemplateFieldInfo
            case AnonymousStructTypeNode anon when member == "fields":
                return anon.Fields.Select(f =>
                    (object)new TemplateFieldInfo(f.FieldName, f.FieldType)).ToList();

            // NominalType — type_of(...).fields → look up field TypeNodes from side-table
            case NominalType nominal when member == "fields":
            {
                var fieldNodes = _fieldNodeLookup(nominal.Name);
                if (fieldNodes != null)
                    return fieldNodes.Select(f =>
                        (object)new TemplateFieldInfo(f.Name, f.TypeNode)).ToList();
                // Fallback: build from NominalType's FieldsOrVariants (no TypeNode info)
                return nominal.FieldsOrVariants.Select(f =>
                    (object)new TemplateFieldInfo(f.Name, new NamedTypeNode(default, f.Type.ToString()!))).ToList();
            }

            // NominalType — .name
            case NominalType nominal when member == "name":
            {
                // Return the short name (last segment after '.')
                var name = nominal.Name;
                var dot = name.LastIndexOf('.');
                return dot >= 0 ? name[(dot + 1)..] : name;
            }

            // TemplateFieldInfo — field.name, field.type_info
            case TemplateFieldInfo field when member == "name":
                return field.Name;
            case TemplateFieldInfo field when member == "type_info":
                return field.TypeNode;

            // TemplateParamInfo — param.name, param.type_info
            case TemplateParamInfo param when member == "name":
                return param.Name;
            case TemplateParamInfo param when member == "type_info":
                return param.TypeNode;

            // FunctionTypeNode — .params, .return_type
            case FunctionTypeNode fn when member == "params":
                return fn.ParameterTypes.Select((pt, i) =>
                {
                    var paramName = fn.ParameterNames.Count > i ? fn.ParameterNames[i] : null;
                    return (object)new TemplateParamInfo(paramName ?? $"_{i}", pt);
                }).ToList();
            case FunctionTypeNode fn when member == "return_type":
                return fn.ReturnType;
            case FunctionTypeNode fn when member == "name":
                return TypeNodeToString(fn);

            // TypeNode — .name (generic fallback for any TypeNode)
            case TypeNode typeNode when member == "name":
                return TypeNodeToString(typeNode);

            // string — .len
            case string s when member == "len":
                return (long)s.Length;

            // List — .len
            case List<object> list when member == "len":
                return (long)list.Count;

            default:
                throw new InvalidOperationException(
                    $"Cannot access member '{member}' on {value?.GetType().Name ?? "null"} (value: {value})");
        }
    }

    private object EvalBinary(object left, string op, object right)
    {
        // String concatenation
        if (op == "+")
        {
            if (left is string ls && right is string rs)
                return ls + rs;
            if (left is string || right is string)
                return Stringify(left) + Stringify(right);
        }

        // Integer arithmetic
        if (left is long li && right is long ri)
        {
            return op switch
            {
                "+" => li + ri,
                "-" => li - ri,
                "*" => li * ri,
                "/" => li / ri,
                "%" => li % ri,
                "==" => li == ri ? 1L : 0L,
                "!=" => li != ri ? 1L : 0L,
                "<" => li < ri ? 1L : 0L,
                ">" => li > ri ? 1L : 0L,
                "<=" => li <= ri ? 1L : 0L,
                ">=" => li >= ri ? 1L : 0L,
                _ => throw new InvalidOperationException($"Unknown operator: {op}")
            };
        }

        // String comparison
        if (left is string lStr && right is string rStr)
        {
            return op switch
            {
                "==" => lStr == rStr ? 1L : 0L,
                "!=" => lStr != rStr ? 1L : 0L,
                _ => throw new InvalidOperationException($"Cannot apply '{op}' to strings")
            };
        }

        throw new InvalidOperationException($"Cannot apply '{op}' to {left?.GetType().Name} and {right?.GetType().Name}");
    }

    public string Stringify(object value)
    {
        return value switch
        {
            string s => s,
            long l => l.ToString(),
            NamedTypeNode named => named.Name,
            TypeNode tn => TypeNodeToString(tn),
            NominalType nominal => nominal.Name.Contains('.')
                ? nominal.Name[(nominal.Name.LastIndexOf('.') + 1)..]
                : nominal.Name,
            TemplateFieldInfo f => f.Name,
            TemplateParamInfo p => p.Name,
            _ => value?.ToString() ?? ""
        };
    }

    public static string TypeNodeToString(TypeNode node)
    {
        return node switch
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
            _ => node.GetType().Name
        };
    }

    private static bool IsTruthy(object value)
    {
        return value switch
        {
            bool b => b,
            long l => l != 0,
            string s => s.Length > 0,
            List<object> list => list.Count > 0,
            null => false,
            _ => true
        };
    }

    /// <summary>
    /// Dedent, clean, and re-indent a #for/#if body before appending to the output buffer.
    /// The context indentation is taken from the current line in the output buffer.
    /// </summary>
    private static void AppendDedented(StringBuilder sb, string bodyText)
    {
        var dedented = Dedent(bodyText);

        // Clean: remove leading/trailing blank lines, collapse consecutive blanks
        var lines = dedented.Split('\n');
        var cleaned = new List<string>();
        var lastWasBlank = true;
        foreach (var line in lines)
        {
            var isBlank = line.TrimEnd().Length == 0;
            if (isBlank)
            {
                if (!lastWasBlank) cleaned.Add("");
                lastWasBlank = true;
            }
            else
            {
                cleaned.Add(line);
                lastWasBlank = false;
            }
        }
        while (cleaned.Count > 0 && cleaned[^1].TrimEnd().Length == 0)
            cleaned.RemoveAt(cleaned.Count - 1);

        if (cleaned.Count == 0) return;

        var contextIndent = GetContextIndent(sb);

        for (var i = 0; i < cleaned.Count; i++)
        {
            if (i > 0)
            {
                sb.Append('\n');
                if (cleaned[i].Length > 0)
                    sb.Append(contextIndent);
            }
            sb.Append(cleaned[i]);
        }
    }

    /// <summary>
    /// Returns the leading whitespace of the current line in the buffer
    /// (spaces between the last newline and the first non-space character).
    /// </summary>
    private static string GetContextIndent(StringBuilder sb)
    {
        for (var i = sb.Length - 1; i >= 0; i--)
        {
            if (sb[i] == '\n')
            {
                var start = i + 1;
                var end = start;
                while (end < sb.Length && sb[end] == ' ')
                    end++;
                return new string(' ', end - start);
            }
        }
        return "";
    }

    /// <summary>
    /// Remove common leading whitespace from all non-blank lines.
    /// Whitespace-only lines become empty.
    /// </summary>
    private static string Dedent(string text)
    {
        var lines = text.Split('\n');
        var minIndent = int.MaxValue;

        foreach (var line in lines)
        {
            if (line.TrimEnd().Length == 0) continue;
            var indent = 0;
            while (indent < line.Length && line[indent] == ' ')
                indent++;
            if (indent < minIndent)
                minIndent = indent;
        }

        if (minIndent == int.MaxValue || minIndent == 0)
            return text;

        var sb = new StringBuilder();
        for (var i = 0; i < lines.Length; i++)
        {
            if (i > 0) sb.Append('\n');
            if (lines[i].TrimEnd().Length == 0)
                continue; // blank line: just the \n
            sb.Append(lines[i][minIndent..]);
        }
        return sb.ToString();
    }
}
