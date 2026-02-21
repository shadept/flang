using System.Text;
using FLang.Frontend.Ast.Declarations;

namespace FLang.Frontend;

/// <summary>
/// Prints the parsed template AST for source generator definitions in a readable tree format.
/// </summary>
public static class TemplatePrinter
{
    public static string PrintDefinition(SourceGeneratorDefinitionNode def)
    {
        var sb = new StringBuilder();
        var paramsStr = string.Join(", ", def.Parameters.Select(p => $"{p.Name}: {p.Kind}"));
        sb.AppendLine($"#define({def.Name}, {paramsStr})");
        PrintBody(sb, def.Body, indent: 1);
        return sb.ToString();
    }

    public static string PrintAllDefinitions(IReadOnlyList<SourceGeneratorDefinitionNode> defs)
    {
        var sb = new StringBuilder();
        foreach (var def in defs)
            sb.Append(PrintDefinition(def));
        return sb.ToString();
    }

    private static void PrintBody(StringBuilder sb, IReadOnlyList<TemplateNode> body, int indent)
    {
        var prefix = new string(' ', indent * 2);
        foreach (var node in body)
        {
            switch (node)
            {
                case TemplateVerbatimNode v:
                    var escaped = v.Text.Replace("\r\n", "\\n").Replace("\n", "\\n");
                    sb.AppendLine($"{prefix}Verbatim: `{escaped}`");
                    break;

                case TemplateInterpolationNode interp:
                    sb.AppendLine($"{prefix}Interpolation: {PrintExpr(interp.Expression)}");
                    break;

                case TemplateForNode forNode:
                    sb.AppendLine($"{prefix}For {forNode.VariableName} in {PrintExpr(forNode.Iterable)}:");
                    PrintBody(sb, forNode.Body, indent + 1);
                    break;

                case TemplateIfNode ifNode:
                    sb.AppendLine($"{prefix}If {PrintExpr(ifNode.Condition)}:");
                    PrintBody(sb, ifNode.Body, indent + 1);
                    break;
            }
        }
    }

    private static string PrintExpr(TemplateExpr expr)
    {
        return expr switch
        {
            TemplateNameExpr name => name.Name,
            TemplateStringLiteral str => $"\"{str.Value}\"",
            TemplateIntLiteral num => num.Value.ToString(),
            TemplateMemberAccessExpr mem => $"{PrintExpr(mem.Object)}.{mem.Member}",
            TemplateBinaryExpr bin => $"{PrintExpr(bin.Left)} {bin.Operator} {PrintExpr(bin.Right)}",
            TemplateIndexExpr idx => $"{PrintExpr(idx.Object)}[{PrintExpr(idx.Index)}]",
            TemplateSliceExpr slice => $"{PrintExpr(slice.Object)}[{(slice.Start != null ? PrintExpr(slice.Start) : "")}" +
                                      $"..{(slice.End != null ? PrintExpr(slice.End) : "")}]",
            TemplateCallExpr call => $"{call.FunctionName}({string.Join(", ", call.Arguments.Select(PrintExpr))})",
            _ => expr.GetType().Name,
        };
    }
}
