using FLang.Core;
using FLang.Frontend.Ast.Declarations;

namespace FLang.Frontend;

/// <summary>
/// Resolves declaration-level #if directives immediately after parsing, before
/// any collection pass: the condition is evaluated once against the
/// compile-time context, the active branch's declarations are merged into the
/// module's lists, and inactive declarations are dropped (parsed but invisible
/// to name resolution). Nested #if directives resolve recursively.
/// </summary>
public static class IfDirectiveDeclarations
{
    /// <summary>
    /// Returns a module with all decl-level #if directives flattened away.
    /// Returns the same instance when the module has none (the common case).
    /// </summary>
    public static ModuleNode Flatten(
        ModuleNode module,
        IReadOnlyDictionary<string, object> context,
        List<Diagnostic> diagnostics)
    {
        if (module.IfDirectives.Count == 0)
            return module;

        var structs = new List<StructDeclarationNode>(module.Structs);
        var enums = new List<EnumDeclarationNode>(module.Enums);
        var typeAliases = new List<TypeAliasDeclarationNode>(module.TypeAliases);
        var functions = new List<FunctionDeclarationNode>(module.Functions);
        var tests = new List<TestDeclarationNode>(module.Tests);
        var globalConstants = new List<VariableDeclarationNode>(module.GlobalConstants);

        foreach (var directive in module.IfDirectives)
            FlattenDirective(directive, context, diagnostics,
                structs, enums, typeAliases, functions, tests, globalConstants);

        return new ModuleNode(module.Span, module.Imports, structs, enums, typeAliases,
            functions, tests, globalConstants, module.GeneratorDefinitions, module.GeneratorInvocations);
    }

    private static void FlattenDirective(
        IfDirectiveDeclarationNode directive,
        IReadOnlyDictionary<string, object> context,
        List<Diagnostic> diagnostics,
        List<StructDeclarationNode> structs,
        List<EnumDeclarationNode> enums,
        List<TypeAliasDeclarationNode> typeAliases,
        List<FunctionDeclarationNode> functions,
        List<TestDeclarationNode> tests,
        List<VariableDeclarationNode> globalConstants)
    {
        var result = CompileTimeEvaluator.Evaluate(directive.Condition, context);
        if (result.IsError)
        {
            diagnostics.Add(Diagnostic.Error(result.ErrorMessage!, result.ErrorSpan, code: result.ErrorCode!));
            return; // neither branch is collected
        }

        var branch = result.Value ? directive.ThenGroup : directive.ElseGroup;
        if (branch == null)
            return;

        structs.AddRange(branch.Structs);
        enums.AddRange(branch.Enums);
        typeAliases.AddRange(branch.TypeAliases);
        functions.AddRange(branch.Functions);
        tests.AddRange(branch.Tests);
        globalConstants.AddRange(branch.GlobalConstants);

        foreach (var nested in branch.IfDirectives)
            FlattenDirective(nested, context, diagnostics,
                structs, enums, typeAliases, functions, tests, globalConstants);
    }
}
