using System.Text;
using FLang.Frontend.Ast.Declarations;

namespace FLang.Frontend;

/// <summary>
/// Assembles source text from a template body. Every expression — `#(expr)`,
/// `#for` iterables, `#if` conditions — is evaluated by the one
/// <see cref="CompileTimeEvaluator"/> the `#if` directive uses, with the
/// template's bindings layered over the closed compile-time context.
/// </summary>
public class TemplateEngine(CompileTimeEvaluator evaluator)
{
    private readonly Dictionary<string, object> _env = evaluator.Bindings;

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
                var text = CompileTimeEvaluator.Stringify(evaluator.Eval(interp.Expression));
                sb.Append(interp.InsideStringLiteral ? EscapeForStringLiteral(text) : text);
                break;

            case TemplateForNode forNode:
                var iterable = evaluator.Eval(forNode.Iterable);
                if (iterable is not List<object> list)
                    throw new CompileTimeError("E2118", "`#for` requires a list to iterate", forNode.Iterable.Span);
                var bodySb = new StringBuilder();
                foreach (var item in list)
                {
                    _env[forNode.VariableName] = item;
                    foreach (var child in forNode.Body)
                        ExpandNode(bodySb, child);
                }
                _env.Remove(forNode.VariableName);
                AppendDedented(sb, bodySb.ToString());
                break;

            case TemplateIfNode ifNode:
                if (evaluator.EvalCondition(ifNode.Condition))
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

    private static string EscapeForStringLiteral(string text) =>
        text.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n");

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
