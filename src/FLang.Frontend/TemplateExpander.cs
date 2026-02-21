using System.Text;
using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Types;

namespace FLang.Frontend;

/// <summary>
/// Result of template expansion: synthetic module paths and generated source files.
/// </summary>
public record TemplateExpansionResult(
    Dictionary<string, string> SyntheticModulePaths,
    Dictionary<string, string> GeneratedFiles);

/// <summary>
/// Interface for the type information the template expander needs from the type checker.
/// Defined in Frontend so it doesn't create a circular dependency with Semantics.
/// </summary>
public interface ITemplateTypeProvider
{
    NominalType? LookupNominalType(string name);
    IReadOnlyDictionary<string, IReadOnlyList<(string Name, TypeNode TypeNode)>> FieldTypeNodes { get; }
    void CollectNominalTypes(ModuleNode module, string modulePath);
    void ResolveNominalTypes(ModuleNode module, string modulePath);
}

/// <summary>
/// Expands source generator invocations into synthetic modules.
/// Shared between the CLI compiler and the LSP workspace.
/// </summary>
public static class TemplateExpander
{
    /// <summary>
    /// Derive a module path from a file path and include paths.
    /// Duplicated from HmTypeChecker.DeriveModulePath to avoid the Semantics dependency.
    /// </summary>
    public static string DeriveModulePath(string filePath, IReadOnlyList<string> includePaths, string workingDirectory)
    {
        var normalizedFile = Path.GetFullPath(filePath);

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
    /// Expand all source generator invocations in the parsed modules.
    /// Runs between ResolveNominalTypes and CollectFunctionSignatures so generated
    /// code can reference already-collected types.
    /// Mutates <paramref name="parsedModules"/> by adding synthetic module entries.
    /// </summary>
    public static TemplateExpansionResult ExpandAll(
        Dictionary<string, ModuleNode> parsedModules,
        Compilation compilation,
        ITemplateTypeProvider typeProvider,
        List<Diagnostic> diagnostics)
    {
        var syntheticModulePaths = new Dictionary<string, string>();
        var generatedFiles = new Dictionary<string, string>();

        // Collect all generator definitions across all modules
        var allDefs = new Dictionary<string, SourceGeneratorDefinitionNode>();
        foreach (var kvp in parsedModules)
        {
            foreach (var def in kvp.Value.GeneratorDefinitions)
                allDefs[def.Name] = def;
        }

        if (allDefs.Count == 0)
            return new TemplateExpansionResult(syntheticModulePaths, generatedFiles);

        var expandedInvocations = new HashSet<string>();
        var generatedSources = new Dictionary<string, StringBuilder>();

        const int maxRounds = 8;
        for (var round = 0; round < maxRounds; round++)
        {
            var newModules = new List<(string key, ModuleNode module)>();

            foreach (var kvp in parsedModules.ToList())
            {
                var mod = kvp.Value;
                if (mod.GeneratorInvocations.Count == 0) continue;

                string modulePath;
                if (syntheticModulePaths.TryGetValue(kvp.Key, out var storedPath))
                    modulePath = storedPath;
                else
                    modulePath = DeriveModulePath(kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);

                for (var i = 0; i < mod.GeneratorInvocations.Count; i++)
                {
                    var inv = mod.GeneratorInvocations[i];
                    var invocationKey = $"{kvp.Key}_{inv.Name}_{i}";
                    if (!expandedInvocations.Add(invocationKey)) continue;

                    if (!allDefs.TryGetValue(inv.Name, out var def))
                    {
                        diagnostics.Add(Diagnostic.Error(
                            $"Unknown source generator `{inv.Name}`", inv.Span, "E2070"));
                        continue;
                    }

                    if (inv.Arguments.Count != def.Parameters.Count)
                    {
                        diagnostics.Add(Diagnostic.Error(
                            $"Source generator `{inv.Name}` expects {def.Parameters.Count} arguments, got {inv.Arguments.Count}",
                            inv.Span, "E2071"));
                        continue;
                    }

                    // Bind parameters
                    var env = new Dictionary<string, object>();
                    var bindingError = false;
                    for (var p = 0; p < def.Parameters.Count; p++)
                    {
                        var param = def.Parameters[p];
                        var arg = inv.Arguments[p];

                        if (param.Kind == GeneratorParamKind.Ident)
                        {
                            if (arg.Identifier == null)
                            {
                                diagnostics.Add(Diagnostic.Error(
                                    $"Source generator `{inv.Name}` parameter `{param.Name}` expects an identifier, got a type expression",
                                    arg.Span, "E2072"));
                                bindingError = true;
                                break;
                            }
                            env[param.Name] = arg.Identifier;
                        }
                        else
                        {
                            if (arg.TypeExpr != null)
                                env[param.Name] = arg.TypeExpr;
                            else if (arg.Identifier != null)
                                env[param.Name] = new NamedTypeNode(arg.Span, arg.Identifier);
                            else
                                env[param.Name] = new NamedTypeNode(arg.Span, "");
                        }
                    }

                    if (bindingError) continue;

                    // Create lookups
                    NominalType? TypeOfLookup(string name)
                    {
                        var fqn = $"{modulePath}.{name}";
                        var result = typeProvider.LookupNominalType(fqn);
                        if (result != null) return result;
                        return typeProvider.LookupNominalType(name);
                    }

                    IReadOnlyList<(string, TypeNode)>? FieldNodeLookup(string fqn)
                    {
                        if (typeProvider.FieldTypeNodes.TryGetValue(fqn, out var fields))
                            return fields;
                        var qualified = $"{modulePath}.{fqn}";
                        if (typeProvider.FieldTypeNodes.TryGetValue(qualified, out fields))
                            return fields;
                        foreach (var (key, val) in typeProvider.FieldTypeNodes)
                        {
                            if (key.EndsWith($".{fqn}"))
                                return val;
                        }
                        return null;
                    }

                    string expandedSource;
                    try
                    {
                        var engine = new TemplateEngine(env, TypeOfLookup, FieldNodeLookup);
                        expandedSource = engine.Expand(def.Body);
                    }
                    catch (Exception ex)
                    {
                        expandedInvocations.Remove(invocationKey);
                        if (round == maxRounds - 1)
                        {
                            diagnostics.Add(Diagnostic.Error(
                                $"Template expansion error in `#{inv.Name}`: {ex.Message}",
                                inv.Span, "E2073"));
                        }
                        continue;
                    }

                    var originFile = ResolveOriginFile(kvp.Key, syntheticModulePaths);
                    var genFilePath = Path.ChangeExtension(originFile, ".generated.f");

                    if (!generatedSources.TryGetValue(genFilePath, out var genSb))
                    {
                        genSb = new StringBuilder();
                        genSb.AppendLine($"// Generated from {Path.GetFileName(originFile)}");
                        genSb.AppendLine();
                        generatedSources[genFilePath] = genSb;
                    }

                    var argsStr = string.Join(", ", inv.Arguments.Select(a =>
                        a.Identifier ?? (a.TypeExpr != null ? TemplateEngine.TypeNodeToString(a.TypeExpr) : "?")));
                    genSb.AppendLine($"// #{inv.Name}({argsStr})");
                    genSb.Append(expandedSource);
                    if (!expandedSource.EndsWith('\n'))
                        genSb.AppendLine();
                    genSb.AppendLine();

                    var syntheticKey = $"__gen_{kvp.Key}_{inv.Name}_{i}";
                    var source = new Source(expandedSource, genFilePath);
                    var fileId = compilation.AddSource(source);
                    compilation.RegisterModule(syntheticKey, fileId);

                    var lexer = new Lexer(source, fileId);
                    var parser = new Parser(lexer);
                    var syntheticModule = parser.ParseModule();

                    foreach (var d in parser.Diagnostics)
                        diagnostics.Add(d);

                    syntheticModulePaths[syntheticKey] = modulePath;
                    newModules.Add((syntheticKey, syntheticModule));
                }
            }

            if (newModules.Count == 0) break;

            foreach (var (key, module) in newModules)
            {
                parsedModules[key] = module;
                var synModulePath = syntheticModulePaths[key];
                typeProvider.CollectNominalTypes(module, synModulePath);
            }

            foreach (var (key, module) in newModules)
            {
                var synModulePath = syntheticModulePaths[key];
                typeProvider.ResolveNominalTypes(module, synModulePath);
            }

            foreach (var (_, module) in newModules)
            {
                foreach (var def in module.GeneratorDefinitions)
                    allDefs[def.Name] = def;
            }
        }

        foreach (var (path, sb) in generatedSources)
            generatedFiles[path] = sb.ToString();

        // Replace per-invocation synthetic modules with a single combined module
        // per .generated.f file so that source spans are consistent with the file.
        foreach (var (genFilePath, genContent) in generatedFiles)
        {
            // Find all per-invocation synthetic keys for this .generated.f
            var keysForGen = new List<string>();
            string? modulePath = null;
            foreach (var kvp in syntheticModulePaths)
            {
                if (!parsedModules.ContainsKey(kvp.Key)) continue;
                var originFile = ResolveOriginFile(kvp.Key, syntheticModulePaths);
                var expectedGenPath = Path.ChangeExtension(originFile, ".generated.f");
                if (expectedGenPath == genFilePath)
                {
                    keysForGen.Add(kvp.Key);
                    modulePath ??= kvp.Value;
                }
            }

            if (keysForGen.Count == 0 || modulePath == null) continue;

            // Remove per-invocation modules
            foreach (var key in keysForGen)
            {
                parsedModules.Remove(key);
                syntheticModulePaths.Remove(key);
            }

            // Parse the combined .generated.f content as a single module
            var combinedSource = new Source(genContent, genFilePath);
            var combinedFileId = compilation.AddSource(combinedSource);
            var combinedKey = $"__combined_{genFilePath}";
            compilation.RegisterModule(combinedKey, combinedFileId);

            var lexer = new Lexer(combinedSource, combinedFileId);
            var parser = new Parser(lexer);
            var combinedModule = parser.ParseModule();

            foreach (var d in parser.Diagnostics)
                diagnostics.Add(d);

            parsedModules[combinedKey] = combinedModule;
            syntheticModulePaths[combinedKey] = modulePath;

            // Nominals were already collected from per-invocation modules during rounds.
            // Don't re-collect — the type checker would flag them as duplicates.
            // Downstream phases (CollectFunctionSignatures, CheckModuleBodies, Lowering)
            // will use the combined module's AST nodes which have correct spans.
        }

        return new TemplateExpansionResult(syntheticModulePaths, generatedFiles);
    }

    private static string ResolveOriginFile(string key, Dictionary<string, string> syntheticModulePaths)
    {
        var originFile = key;
        while (syntheticModulePaths.ContainsKey(originFile))
        {
            const string prefix = "__gen_";
            if (!originFile.StartsWith(prefix)) break;
            var rest = originFile[prefix.Length..];
            var lastUnderscore = rest.LastIndexOf('_');
            if (lastUnderscore <= 0) break;
            var secondLast = rest.LastIndexOf('_', lastUnderscore - 1);
            if (secondLast <= 0) break;
            originFile = rest[..secondLast];
        }
        return originFile;
    }
}
