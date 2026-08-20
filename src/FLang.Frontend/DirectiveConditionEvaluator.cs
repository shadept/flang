using FLang.Core;
using FLang.Frontend.Ast.Declarations;

namespace FLang.Frontend;

/// <summary>
/// Strict evaluator for #if directive conditions, following FLang semantics:
/// conditions must evaluate to bool (E2117), unknown compile-time names are
/// errors (E2116), and dict lookups (`runtime.env["KEY"]`) yield optionals
/// that must be unwrapped with `??` before use (E2118) — mirroring FLang's
/// `Dict.op_index` returning `V?`.
///
/// Deliberately separate from the template engine's loose evaluator: #if is
/// spec'd as a self-contained feature (spec §7.7) and its conditions reject
/// what FLang itself would reject.
/// </summary>
public static class DirectiveConditionEvaluator
{
    /// <summary>Outcome of evaluating a directive condition. On error, Value is false.</summary>
    public sealed record Result(bool Value, string? ErrorCode, string? ErrorMessage, SourceSpan ErrorSpan)
    {
        public bool IsError => ErrorCode != null;
    }

    /// <summary>An optional compile-time value, as produced by dict indexing.</summary>
    private sealed record Optional(object? Value);

    private sealed class DirectiveError(string code, string message, SourceSpan span) : Exception(message)
    {
        public string Code { get; } = code;
        public SourceSpan Span { get; } = span;
    }

    public static Result Evaluate(TemplateExpr condition, IReadOnlyDictionary<string, object> context)
    {
        try
        {
            var value = Eval(condition, context);
            if (value is bool b)
                return new Result(b, null, null, default);
            if (value is Optional)
                return new Result(false, "E2118",
                    "optional value must be unwrapped with `??` before use as a condition", condition.Span);
            return new Result(false, "E2117",
                $"#if condition must be a bool, got {Describe(value)}", condition.Span);
        }
        catch (DirectiveError e)
        {
            return new Result(false, e.Code, e.Message, e.Span);
        }
    }

    private static object Eval(TemplateExpr expr, IReadOnlyDictionary<string, object> context)
    {
        switch (expr)
        {
            case TemplateBoolLiteral b:
                return b.Value;

            case TemplateStringLiteral s:
                return s.Value;

            case TemplateNameExpr name:
                if (context.TryGetValue(name.Name, out var rootVal))
                    return rootVal;
                throw new DirectiveError("E2116",
                    $"unknown compile-time name `{name.Name}`", name.Span);

            case TemplateMemberAccessExpr mem:
            {
                var obj = Eval(mem.Object, context);
                if (obj is IReadOnlyDictionary<string, object> rd)
                    return rd.TryGetValue(mem.Member, out var mv)
                        ? mv
                        : throw new DirectiveError("E2116",
                            $"unknown compile-time member `{mem.Member}`", mem.Span);
                throw new DirectiveError("E2118",
                    $"cannot access member `{mem.Member}` on {Describe(obj)}", mem.Span);
            }

            case TemplateIndexExpr idx:
            {
                var obj = Eval(idx.Object, context);
                var key = Eval(idx.Index, context);
                if (obj is Dictionary<string, object> dict && key is string sk)
                    // FLang Dict semantics: indexing yields an optional (V?)
                    return new Optional(dict.TryGetValue(sk, out var v) ? v : null);
                throw new DirectiveError("E2118",
                    $"cannot index {Describe(obj)} with {Describe(key)} in #if condition", idx.Span);
            }

            case TemplateUnaryExpr un:
            {
                var operand = Eval(un.Operand, context);
                if (un.Operator == "!" && operand is bool ob)
                    return !ob;
                throw new DirectiveError("E2118",
                    $"`!` requires a bool operand, got {Describe(operand)}", un.Span);
            }

            case TemplateBinaryExpr bin:
                return EvalBinary(bin, context);

            default:
                throw new DirectiveError("E2118",
                    $"expression form not allowed in #if condition", expr.Span);
        }
    }

    private static object EvalBinary(TemplateBinaryExpr bin, IReadOnlyDictionary<string, object> context)
    {
        var left = Eval(bin.Left, context);

        if (bin.Operator == "??")
        {
            if (left is Optional opt)
                return opt.Value ?? Eval(bin.Right, context);
            throw new DirectiveError("E2118",
                $"left operand of `??` must be an optional (a dict lookup), got {Describe(left)}", bin.Span);
        }

        var right = Eval(bin.Right, context);

        if (left is Optional || right is Optional)
            throw new DirectiveError("E2118",
                "optional value must be unwrapped with `??` before comparison", bin.Span);

        switch (bin.Operator)
        {
            case "or" or "and":
                if (left is bool lb && right is bool rb)
                    return bin.Operator == "or" ? lb || rb : lb && rb;
                throw new DirectiveError("E2118",
                    $"`{bin.Operator}` requires bool operands, got {Describe(left)} and {Describe(right)}", bin.Span);

            case "==" or "!=":
            {
                bool? eq = (left, right) switch
                {
                    (string a, string b) => a == b,
                    (bool a, bool b) => a == b,
                    _ => null
                };
                if (eq is bool e)
                    return bin.Operator == "==" ? e : !e;
                throw new DirectiveError("E2118",
                    $"cannot compare {Describe(left)} with {Describe(right)}", bin.Span);
            }

            default:
                throw new DirectiveError("E2118",
                    $"operator `{bin.Operator}` not allowed in #if condition", bin.Span);
        }
    }

    private static string Describe(object? value) => value switch
    {
        null => "nothing",
        bool => "a bool",
        string s => $"a string (\"{s}\")",
        Optional => "an optional",
        Dictionary<string, object> => "a compile-time namespace",
        IReadOnlyDictionary<string, object> => "a compile-time namespace",
        _ => value.GetType().Name,
    };
}
