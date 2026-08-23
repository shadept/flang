using System.Text;
using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend;

/// <summary>
/// Result of template expansion: the generated text per origin file
/// (<c>origin.generated.f</c> path → text). Nothing reads these back; they exist
/// for <c>--emit-generated</c>, diagnostics and LSP virtual documents.
/// </summary>
public record TemplateExpansionResult(Dictionary<string, string> GeneratedFiles);

/// <summary>
/// Interface for the type information the template expander needs from the type checker.
/// Defined in Frontend so it doesn't create a circular dependency with Semantics.
/// </summary>
public interface ITemplateTypeProvider
{
    NominalType? LookupNominalType(string name);

    /// <summary>
    /// Look up a nominal type from the perspective of <paramref name="fromModule"/>.
    /// Honors the importing module's visibility set rather than the type checker's
    /// transient "current module" — required by TemplateExpander, which expands
    /// invocations across many modules in a single batch.
    /// </summary>
    NominalType? LookupNominalTypeFrom(string name, string fromModule);

    IReadOnlyDictionary<string, IReadOnlyList<(string Name, TypeNode TypeNode)>> FieldTypeNodes { get; }
    void CollectNominalTypes(ModuleNode module, string modulePath);
    void ResolveNominalTypes(ModuleNode module, string modulePath);
}

/// <summary>
/// Expands source generator invocations in one pass (RFC-021 §2): modules in
/// import-topological order, invocations in source order, each expansion's
/// declarations appended to the ORIGIN module and collected on the spot so
/// later invocations see them. No synthetic modules, no rounds.
/// Shared between the CLI compiler and the LSP workspace.
/// </summary>
public static class TemplateExpander
{
    /// <summary>
    /// Derive a module path from a file path and include paths.
    /// Duplicated from HmTypeChecker.DeriveModulePath to avoid the Semantics dependency.
    /// </summary>
    public static string DeriveModulePath(string filePath, Compilation compilation)
    {
        return DeriveModulePath(filePath, compilation.IncludePaths, compilation.WorkingDirectory,
            compilation.ProjectName, compilation.ProjectSourceRoot,
            compilation.DependencySourceRoots);
    }

    public static string DeriveModulePath(string filePath, IReadOnlyList<string> includePaths, string workingDirectory,
        string? projectName = null, string? projectSourceRoot = null,
        IReadOnlyDictionary<string, string>? dependencySourceRoots = null)
    {
        var normalizedFile = Path.GetFullPath(filePath);

        // If in project mode and file is under source root, prefix with project name
        if (projectName != null && projectSourceRoot != null)
        {
            var normalizedSourceRoot = Path.GetFullPath(projectSourceRoot);
            if (normalizedFile.StartsWith(normalizedSourceRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
                || normalizedFile.Equals(normalizedSourceRoot, StringComparison.OrdinalIgnoreCase))
            {
                var relativePath = Path.GetRelativePath(normalizedSourceRoot, normalizedFile);
                var withoutExtension = Path.ChangeExtension(relativePath, null);
                return projectName + "." + withoutExtension.Replace(Path.DirectorySeparatorChar, '.');
            }
        }

        // Dependency files: prefix with the dep's declared name (its import namespace).
        // Same shape as the project-mode branch above, one entry per direct dep.
        if (dependencySourceRoots != null)
        {
            foreach (var (depName, depRoot) in dependencySourceRoots)
            {
                var normalizedDepRoot = Path.GetFullPath(depRoot);
                if (normalizedFile.StartsWith(normalizedDepRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
                    || normalizedFile.Equals(normalizedDepRoot, StringComparison.OrdinalIgnoreCase))
                {
                    var relativePath = Path.GetRelativePath(normalizedDepRoot, normalizedFile);
                    var withoutExtension = Path.ChangeExtension(relativePath, null);
                    return depName + "." + withoutExtension.Replace(Path.DirectorySeparatorChar, '.');
                }
            }
        }

        foreach (var includePath in includePaths)
        {
            var normalizedInclude = Path.GetFullPath(includePath);
            if (normalizedFile.StartsWith(normalizedInclude, StringComparison.OrdinalIgnoreCase))
            {
                var relativePath = Path.GetRelativePath(normalizedInclude, normalizedFile);
                var withoutExtension = Path.ChangeExtension(relativePath, null);
                return withoutExtension.Replace(Path.DirectorySeparatorChar, '.');
            }
        }

        var normalizedWorking = Path.GetFullPath(workingDirectory);
        var relativeToWorking = Path.GetRelativePath(normalizedWorking, normalizedFile);
        var modulePathFromWorking = Path.ChangeExtension(relativeToWorking, null);
        return modulePathFromWorking.Replace(Path.DirectorySeparatorChar, '.');
    }

    /// <summary>
    /// Expand all source generator invocations. Runs between CollectNominalTypes
    /// and ResolveNominalTypes so generators can inspect declared types and
    /// generated types can be used as fields of original types.
    /// Mutates <paramref name="parsedModules"/>: each origin module is replaced
    /// by one with the generated declarations appended.
    /// </summary>
    public static TemplateExpansionResult ExpandAll(
        Dictionary<string, ModuleNode> parsedModules,
        Compilation compilation,
        ITemplateTypeProvider typeProvider,
        List<Diagnostic> diagnostics)
    {
        var generatedFiles = new Dictionary<string, string>();

        var allDefs = new Dictionary<string, SourceGeneratorDefinitionNode>();
        foreach (var mod in parsedModules.Values)
            foreach (var def in mod.GeneratorDefinitions)
                allDefs[def.Name] = def;

        if (allDefs.Count == 0 || parsedModules.Values.All(m => m.GeneratorInvocations.Count == 0))
            return new TemplateExpansionResult(generatedFiles);

        var modulePaths = parsedModules.Keys.ToDictionary(k => k, k => DeriveModulePath(k, compilation));
        var origins = new Dictionary<string, OriginState>();

        // One global worklist in import-topological + source order. An invocation
        // whose `Type` argument is not collected yet is parked and retried only
        // after some other expansion made progress (import cycles in the stdlib
        // make a pure ordering impossible); with no progress left it fails E2003.
        var work = new List<WorkItem>();
        foreach (var key in ImportTopologicalOrder(parsedModules.Keys, modulePaths, compilation))
        {
            var origin = parsedModules[key];
            if (origin.GeneratorInvocations.Count == 0) continue;
            origins[key] = new OriginState(key, origin);
            foreach (var inv in origin.GeneratorInvocations)
                work.Add(new WorkItem(key, inv, 0));
        }

        while (work.Count > 0)
        {
            var parked = new List<WorkItem>();
            var progress = false;
            foreach (var item in work)
            {
                var state = origins[item.OriginKey];
                if (item.Generation >= MaxGenerations)
                {
                    diagnostics.Add(Diagnostic.Error(
                        $"Template expansion depth exceeded ({MaxGenerations}) at `#{item.Inv.Name}`",
                        item.Inv.Span, code: "E2119"));
                    continue;
                }

                var outcome = ExpandOne(item.Inv, allDefs, modulePaths[item.OriginKey], typeProvider, compilation.CompileTimeContext, diagnostics, out var expanded);
                if (outcome == Outcome.UnknownType) { parked.Add(item); continue; }
                if (outcome == Outcome.Failed) continue;

                progress = true;
                var chunkModule = AppendChunk(state, item.Inv, expanded!, compilation, diagnostics);
                typeProvider.CollectNominalTypes(chunkModule, modulePaths[item.OriginKey]);
                foreach (var def in chunkModule.GeneratorDefinitions)
                    allDefs[def.Name] = def;
                // Nested invocations run after every pending one of this pass.
                foreach (var nested in chunkModule.GeneratorInvocations)
                    parked.Add(new WorkItem(item.OriginKey, nested, item.Generation + 1));
            }

            if (!progress)
            {
                foreach (var item in parked)
                    ReportUnknownTypes(item.Inv, allDefs, modulePaths[item.OriginKey], typeProvider, diagnostics);
                break;
            }
            work = parked;
        }

        foreach (var (key, state) in origins)
        {
            parsedModules[key] = state.Module;
            generatedFiles[state.GenFilePath] = state.Text.ToString();
        }

        return new TemplateExpansionResult(generatedFiles);
    }

    private sealed record WorkItem(string OriginKey, SourceGeneratorInvocationNode Inv, int Generation);

    private sealed class OriginState
    {
        public ModuleNode Module;
        public readonly StringBuilder Text = new();
        public int Lines;
        public readonly string GenFilePath;

        public OriginState(string key, ModuleNode module)
        {
            Module = module;
            GenFilePath = Path.ChangeExtension(key, ".generated.f");
            Text.AppendLine($"// Generated from {Path.GetFileName(key)}");
            Text.AppendLine();
            Lines = 2;
        }
    }

    /// <summary>
    /// Parse one invocation's output and append its declarations to the origin.
    /// The chunk is parsed against a Source padded with the lines already emitted
    /// for this origin, so spans line up with the combined generated text
    /// without re-parsing it.
    /// </summary>
    private static ModuleNode AppendChunk(
        OriginState state,
        SourceGeneratorInvocationNode inv,
        string expanded,
        Compilation compilation,
        List<Diagnostic> diagnostics)
    {
        var argsStr = string.Join(", ", inv.Arguments.Select(a =>
            a.Identifier ?? (a.TypeExpr != null ? CompileTimeEvaluator.TypeNodeToString(a.TypeExpr) : "?")));
        var chunk = $"// #{inv.Name}({argsStr})\n" + expanded + (expanded.EndsWith('\n') ? "" : "\n") + "\n";

        var source = new Source(new string('\n', state.Lines) + chunk, state.GenFilePath);
        var fileId = compilation.AddSource(source);
        var parser = new Parser(new Lexer(source, fileId));
        var chunkModule = parser.ParseModule();
        diagnostics.AddRange(parser.Diagnostics);
        chunkModule = IfDirectiveDeclarations.Flatten(chunkModule, compilation.CompileTimeContext, diagnostics);

        state.Text.Append(chunk);
        state.Lines += chunk.Count(c => c == '\n');
        state.Module = state.Module.Append(chunkModule);
        return chunkModule;
    }

    private const int MaxGenerations = 8;

    /// <summary>
    /// Modules ordered so that every module comes after the modules it imports
    /// (DFS post-order over <see cref="Compilation.ModuleImports"/>; cycles are
    /// cut at the first revisit). Unrelated modules keep their input order.
    /// </summary>
    private static List<string> ImportTopologicalOrder(
        IEnumerable<string> keys,
        Dictionary<string, string> modulePaths,
        Compilation compilation)
    {
        var keyByPath = modulePaths.ToDictionary(kv => kv.Value, kv => kv.Key);
        var visited = new HashSet<string>();
        var order = new List<string>();

        void Visit(string key)
        {
            if (!visited.Add(key)) return;
            if (compilation.ModuleImports.TryGetValue(modulePaths[key], out var imports))
                foreach (var imported in imports)
                    if (keyByPath.TryGetValue(imported, out var importedKey))
                        Visit(importedKey);
            order.Add(key);
        }

        foreach (var key in keys) Visit(key);
        return order;
    }

    private enum Outcome { Expanded, UnknownType, Failed }

    /// <summary>
    /// Bind one invocation's arguments and evaluate its template.
    /// <see cref="Outcome.UnknownType"/> means a `Type` argument is not collected
    /// yet — the caller parks the invocation; nothing is reported here.
    /// </summary>
    private static Outcome ExpandOne(
        SourceGeneratorInvocationNode inv,
        Dictionary<string, SourceGeneratorDefinitionNode> allDefs,
        string modulePath,
        ITemplateTypeProvider typeProvider,
        IReadOnlyDictionary<string, object> compileTimeContext,
        List<Diagnostic> diagnostics,
        out string? expanded)
    {
        expanded = null;
        if (!allDefs.TryGetValue(inv.Name, out var def))
        {
            diagnostics.Add(Diagnostic.Error($"Unknown source generator `{inv.Name}`", inv.Span, code: "E2070"));
            return Outcome.Failed;
        }

        var hasVariadic = def.Parameters.Count > 0 && def.Parameters[^1].IsVariadic;
        var requiredCount = hasVariadic ? def.Parameters.Count - 1 : def.Parameters.Count;
        if (hasVariadic ? inv.Arguments.Count < requiredCount : inv.Arguments.Count != def.Parameters.Count)
        {
            var expectMsg = hasVariadic ? $"at least {requiredCount}" : $"{def.Parameters.Count}";
            diagnostics.Add(Diagnostic.Error(
                $"Source generator `{inv.Name}` expects {expectMsg} arguments, got {inv.Arguments.Count}",
                inv.Span, code: "E2071"));
            return Outcome.Failed;
        }

        for (var p = 0; p < def.Parameters.Count; p++)
        {
            var param = def.Parameters[p];
            if (param.IsVariadic) break;

            var arg = inv.Arguments[p];
            if (param.Kind == GeneratorParamKind.Ident && arg.Identifier == null)
            {
                diagnostics.Add(Diagnostic.Error(
                    $"Source generator `{inv.Name}` parameter `{param.Name}` expects an identifier, got a type expression",
                    arg.Span, code: "E2072"));
                return Outcome.Failed;
            }

            if (param.Kind == GeneratorParamKind.Type && arg.Identifier != null
                && !TypeIsCollected(arg.Identifier, modulePath, typeProvider))
                return Outcome.UnknownType;
        }

        var lookup = DeclarationLookupFor(modulePath, typeProvider);
        var env = new Dictionary<string, object>();
        for (var p = 0; p < def.Parameters.Count; p++)
        {
            var param = def.Parameters[p];
            if (param.IsVariadic)
            {
                env[param.Name] = inv.Arguments.Skip(p).Select(a => BindArg(param, a, lookup)).ToList();
                break;
            }
            env[param.Name] = BindArg(param, inv.Arguments[p], lookup);
        }

        try
        {
            var evaluator = new CompileTimeEvaluator(compileTimeContext, env, lookup);
            expanded = new TemplateEngine(evaluator).Expand(def.Body);
            return Outcome.Expanded;
        }
        catch (CompileTimeError ex)
        {
            // Reported at the template expression; the invocation site is named in the message.
            diagnostics.Add(Diagnostic.Error(
                $"{ex.Message} (while expanding `#{inv.Name}`)", ex.Span, code: ex.Code));
            return Outcome.Failed;
        }
        catch (Exception ex)
        {
            diagnostics.Add(Diagnostic.Error(
                $"Template expansion error in `#{inv.Name}`: {ex.Message}", inv.Span, code: "E2073"));
            return Outcome.Failed;
        }
    }

    private static bool TypeIsCollected(string name, string modulePath, ITemplateTypeProvider typeProvider) =>
        TypeRegistry.GetTypeByName(name) != null
        || typeProvider.LookupNominalType($"{modulePath}.{name}") != null
        || typeProvider.LookupNominalTypeFrom(name, modulePath) != null;

    /// <summary>E2003 for every `Type` argument of a parked invocation that never became available.</summary>
    private static void ReportUnknownTypes(
        SourceGeneratorInvocationNode inv,
        Dictionary<string, SourceGeneratorDefinitionNode> allDefs,
        string modulePath,
        ITemplateTypeProvider typeProvider,
        List<Diagnostic> diagnostics)
    {
        var def = allDefs[inv.Name];
        for (var p = 0; p < def.Parameters.Count && p < inv.Arguments.Count; p++)
        {
            var param = def.Parameters[p];
            if (param.IsVariadic) break;
            var arg = inv.Arguments[p];
            if (param.Kind == GeneratorParamKind.Type && arg.Identifier != null
                && !TypeIsCollected(arg.Identifier, modulePath, typeProvider))
                diagnostics.Add(Diagnostic.Error($"Unknown type `{arg.Identifier}`", arg.Span, code: "E2003"));
        }
    }

    private static TypeInfoBuilder.DeclarationLookup DeclarationLookupFor(string modulePath, ITemplateTypeProvider typeProvider)
    {
        NominalType? Nominal(string name) =>
            typeProvider.LookupNominalType($"{modulePath}.{name}")
            ?? typeProvider.LookupNominalTypeFrom(name, modulePath)
            ?? typeProvider.LookupNominalType(name);

        IReadOnlyList<(string, TypeNode)>? FieldNodes(string fqn) =>
            typeProvider.FieldTypeNodes.TryGetValue(fqn, out var fields) ? fields : null;

        return new TypeInfoBuilder.DeclarationLookup(Nominal, FieldNodes);
    }

    /// <summary>`Ident` params bind an <see cref="CompileTimeEvaluator.Ident"/>; `Type` params bind the argument's `TypeInfo`.</summary>
    private static object BindArg(GeneratorParameter param, GeneratorArgument arg, TypeInfoBuilder.DeclarationLookup lookup)
    {
        if (param.Kind == GeneratorParamKind.Ident) return new CompileTimeEvaluator.Ident(arg.Identifier ?? "");
        TypeNode node = arg.TypeExpr ?? new NamedTypeNode(arg.Span, arg.Identifier ?? "");
        return TypeInfoBuilder.FromTypeNode(node, lookup);
    }
}
