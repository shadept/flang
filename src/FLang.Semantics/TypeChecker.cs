using FLang.Core;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;
using FLang.Frontend.Ast.Types;
using Microsoft.Extensions.Logging;

namespace FLang.Semantics;

/// <summary>
/// Performs type checking and inference on the AST.
/// </summary>
public class TypeChecker
{
    private readonly ILogger<TypeChecker> _logger;
    private readonly Compilation _compilation;
    private readonly List<Diagnostic> _diagnostics = [];
    private readonly TypeSolver _unificationEngine;

    // Variable scopes (local to type checking phase)
    // Each entry tracks both the type and whether the variable is const (immutable)
    private readonly record struct VariableInfo(TypeBase Type, bool IsConst);
    private readonly Stack<Dictionary<string, VariableInfo>> _scopes = new();

    // Function registry (stays in TypeChecker - contains AST nodes)
    private readonly Dictionary<string, List<FunctionEntry>> _functions = [];
    private readonly List<FunctionDeclarationNode> _specializations = [];
    private readonly HashSet<string> _emittedSpecs = [];

    // Private functions per module - needed for generic specialization
    // When a generic function from module X is specialized, private functions from X must be visible
    private readonly Dictionary<string, List<(string Name, FunctionEntry Entry)>> _privateEntriesByModule = [];

    // Private global constants per module - needed for generic specialization
    // When a generic function from module X is specialized, private constants from X must be visible
    private readonly Dictionary<string, List<(string Name, TypeBase Type)>> _privateConstantsByModule = [];

    // Module-aware state (local to type checking phase)
    private string? _currentModulePath = null;

    // Generic binding state (local to type checking phase)
    private Dictionary<string, TypeBase>? _currentBindings;

    private readonly Stack<HashSet<string>> _genericScopes = new();
    private readonly Stack<FunctionDeclarationNode> _functionStack = new();

    // Track binding recursion depth for indented logging
    private int _bindingDepth = 0;

    // Literal TypeVar tracking for inference (with value for range validation)
    private int _nextLiteralTypeVarId = 0;
    private readonly List<(TypeVar Tv, long Value)> _literalTypeVars = [];

    /// <summary>
    /// Creates a new TypeVar for a literal, soft-bound to the given comptime type.
    /// Tracks the TypeVar and its value for later verification.
    /// </summary>
    private TypeVar CreateLiteralTypeVar(string id, SourceSpan span, TypeBase comptimeType, long value)
    {
        var tv = new TypeVar(id, span);
        tv.Instance = comptimeType;
        _literalTypeVars.Add((tv, value));
        return tv;
    }

    private static string BuildSpecKey(string name, IReadOnlyList<TypeBase> paramTypes)
    {
        var sb = new System.Text.StringBuilder();
        sb.Append(name);
        sb.Append('|');
        for (var i = 0; i < paramTypes.Count; i++)
        {
            if (i > 0) sb.Append(',');
            // Use ToString() to include full type with type arguments (e.g., "Option(&u8)" vs "Option(Slice(u8))")
            sb.Append(paramTypes[i].ToString());
        }

        return sb.ToString();
    }

    private static string BuildStructSpecKey(string name, IReadOnlyList<TypeBase> typeArgs)
    {
        var sb = new System.Text.StringBuilder();
        sb.Append(name);
        sb.Append('<');
        for (var i = 0; i < typeArgs.Count; i++)
        {
            if (i > 0) sb.Append(',');
            sb.Append(typeArgs[i].Name);
        }

        sb.Append('>');
        return sb.ToString();
    }

    // ResolvedCall struct removed - call resolution info now stored on CallExpressionNode.ResolvedTarget

    public TypeChecker(Compilation compilation, ILogger<TypeChecker> logger)
    {
        _compilation = compilation;
        _logger = logger;
        _unificationEngine = new TypeSolver(PointerWidth.Bits64);
        PushScope(); // Global scope
    }

    public IReadOnlyList<Diagnostic> Diagnostics => _diagnostics;

    // Accessor methods removed - semantic data is now directly on AST nodes

    public IReadOnlySet<TypeBase> InstantiatedTypes => _compilation.InstantiatedTypes;

    public string GetStructFqn(StructType structType) => structType.StructName;

    /// <summary>
    /// Formats a type name for display in error messages.
    /// Returns the short name if available, otherwise the full name.
    /// TODO: Check for ambiguities and use FQN when multiple types with same short name exist in scope.
    /// </summary>
    private string FormatTypeNameForDisplay(TypeBase type)
    {
        // If we have active generic bindings, resolve GenericParameterType to its bound type
        if (type is GenericParameterType gpt && _currentBindings != null)
        {
            if (_currentBindings.TryGetValue(gpt.ParamName, out var boundType))
            {
                return FormatTypeNameForDisplay(boundType);
            }
        }

        return type switch
        {
            StructType st => GetSimpleName(st.StructName),
            EnumType et => GetSimpleName(et.Name),
            _ => type.Name
        };
    }

    private static string GetSimpleName(string fqn)
    {
        var lastDot = fqn.LastIndexOf('.');
        return lastDot >= 0 ? fqn.Substring(lastDot + 1) : fqn;
    }

    /// <summary>
    /// Formats a pair of types for error display, simplifying when the difference is only in wrappers.
    /// For example, if expected is Option(Slice(u8)) and actual is &Option(Slice(u8)),
    /// returns ("Option(T)", "&Option(T)") instead of the full instantiation.
    /// </summary>
    private (string Expected, string Actual) FormatTypePairForDisplay(TypeBase expected, TypeBase actual)
    {
        var expectedPruned = expected.Prune();
        var actualPruned = actual.Prune();

        // Check if one is a reference to the other
        if (actualPruned is ReferenceType actualRef)
        {
            var innerActual = actualRef.InnerType.Prune();
            if (AreStructurallyEquivalent(expectedPruned, innerActual))
            {
                // Difference is just the & wrapper - simplify display
                var simpleName = GetSimplifiedTypeName(expectedPruned);
                return (simpleName, $"&{simpleName}");
            }
        }
        else if (expectedPruned is ReferenceType expectedRef)
        {
            var innerExpected = expectedRef.InnerType.Prune();
            if (AreStructurallyEquivalent(innerExpected, actualPruned))
            {
                // Difference is just the & wrapper - simplify display
                var simpleName = GetSimplifiedTypeName(actualPruned);
                return ($"&{simpleName}", simpleName);
            }
        }

        // Default: show full types
        return (FormatTypeNameForDisplay(expectedPruned), FormatTypeNameForDisplay(actualPruned));
    }

    /// <summary>
    /// Checks if two types are structurally equivalent (same base type, ignoring generic instantiation details).
    /// </summary>
    private static bool AreStructurallyEquivalent(TypeBase a, TypeBase b)
    {
        if (a.GetType() != b.GetType()) return false;

        return (a, b) switch
        {
            (StructType sa, StructType sb) => sa.StructName == sb.StructName,
            (EnumType ea, EnumType eb) => ea.Name == eb.Name,
            (ReferenceType ra, ReferenceType rb) => AreStructurallyEquivalent(ra.InnerType.Prune(), rb.InnerType.Prune()),
            (ArrayType aa, ArrayType ab) => aa.Length == ab.Length && AreStructurallyEquivalent(aa.ElementType.Prune(), ab.ElementType.Prune()),
            _ => a.Equals(b)
        };
    }

    /// <summary>
    /// Gets a simplified type name, replacing generic arguments with T, U, etc.
    /// </summary>
    private static string GetSimplifiedTypeName(TypeBase type)
    {
        return type switch
        {
            StructType st when TypeRegistry.IsSlice(st) && st.TypeArguments.Count > 0 =>
                $"{GetGenericPlaceholders(1).First()}[]",
            StructType st when st.TypeArguments.Count > 0 =>
                $"{GetSimpleName(st.StructName)}({string.Join(", ", GetGenericPlaceholders(st.TypeArguments.Count))})",
            StructType st => GetSimpleName(st.StructName),
            EnumType et when et.TypeArguments.Count > 0 =>
                $"{GetSimpleName(et.Name)}({string.Join(", ", GetGenericPlaceholders(et.TypeArguments.Count))})",
            EnumType et => GetSimpleName(et.Name),
            ReferenceType rt => $"&{GetSimplifiedTypeName(rt.InnerType.Prune())}",
            ArrayType at => $"[{at.Length}]{GetSimplifiedTypeName(at.ElementType.Prune())}",
            _ => type.Name
        };
    }

    private static IEnumerable<string> GetGenericPlaceholders(int count)
    {
        var names = new[] { "T", "U", "V", "W", "X", "Y", "Z" };
        for (var i = 0; i < count; i++)
            yield return i < names.Length ? names[i] : $"T{i}";
    }

    public TypeBase? ResolveTypeName(string typeName)
    {
        // Check built-in primitives first
        var builtInType = TypeRegistry.GetTypeByName(typeName);
        if (builtInType != null) return builtInType;

        // Determine if FQN or short name
        if (typeName.Contains('.'))
            return ResolveFqnTypeName(typeName);
        else
            return ResolveShortTypeName(typeName);
    }

    private TypeBase? ResolveFqnTypeName(string fqn)
    {
        // Try direct FQN lookup for structs
        if (_compilation.StructsByFqn.TryGetValue(fqn, out var type))
            return type;

        // Try direct FQN lookup for enums
        if (_compilation.EnumsByFqn.TryGetValue(fqn, out var enumType))
            return enumType;

        // Parse FQN: "core.string.String" → "core.string" + "String"
        var lastDot = fqn.LastIndexOf('.');
        if (lastDot == -1) return null;

        var modulePath = fqn.Substring(0, lastDot);
        var typeName = fqn.Substring(lastDot + 1);

        // Allow current module to reference its own types via FQN
        if (_currentModulePath == modulePath)
        {
            if (_compilation.StructsByModule.TryGetValue(modulePath, out var moduleTypes))
            {
                var result = moduleTypes.GetValueOrDefault(typeName);
                if (result != null) return result;
            }

            if (_compilation.EnumsByModule.TryGetValue(modulePath, out var moduleEnums))
            {
                var result = moduleEnums.GetValueOrDefault(typeName);
                if (result != null) return result;
            }
        }

        // Check if module is imported
        if (_currentModulePath != null &&
            _compilation.ModuleImports.TryGetValue(_currentModulePath, out var imports) &&
            imports.Contains(modulePath))
        {
            if (_compilation.StructsByModule.TryGetValue(modulePath, out var moduleTypes))
            {
                var result = moduleTypes.GetValueOrDefault(typeName);
                if (result != null) return result;
            }

            if (_compilation.EnumsByModule.TryGetValue(modulePath, out var moduleEnums))
            {
                var result = moduleEnums.GetValueOrDefault(typeName);
                if (result != null) return result;
            }
        }

        return null;
    }

    private TypeBase? ResolveShortTypeName(string typeName)
    {
        if (_currentModulePath == null)
        {
            // Fallback: try legacy lookup
            var legacyStruct = _compilation.Structs.GetValueOrDefault(typeName);
            if (legacyStruct != null) return legacyStruct;
            return _compilation.Enums.GetValueOrDefault(typeName);
        }

        // 1. Check local module first (highest priority)
        if (_compilation.StructsByModule.TryGetValue(_currentModulePath, out var localTypes) &&
            localTypes.TryGetValue(typeName, out var localType))
        {
            return localType;
        }

        if (_compilation.EnumsByModule.TryGetValue(_currentModulePath, out var localEnums) &&
            localEnums.TryGetValue(typeName, out var localEnum))
        {
            return localEnum;
        }

        // 2. Check imported modules
        TypeBase? foundType = null;

        if (_compilation.ModuleImports.TryGetValue(_currentModulePath, out var imports))
        {
            foreach (var importedModulePath in imports)
            {
                // Check structs
                if (_compilation.StructsByModule.TryGetValue(importedModulePath, out var importedTypes) &&
                    importedTypes.TryGetValue(typeName, out var importedType))
                {
                    if (foundType != null)
                    {
                        // Ambiguous reference - multiple imports define this type
                        // Return null and let caller report E2003
                        return null;
                    }

                    foundType = importedType;
                }

                // Check enums
                if (_compilation.EnumsByModule.TryGetValue(importedModulePath, out var importedEnums) &&
                    importedEnums.TryGetValue(typeName, out var importedEnum))
                {
                    if (foundType != null)
                    {
                        // Ambiguous reference - multiple imports define this type
                        // Return null and let caller report E2003
                        return null;
                    }

                    foundType = importedEnum;
                }
            }
        }

        if (foundType != null)
            return foundType;

        // 3. Fallback: search all modules for unambiguous match by simple name
        // This allows finding types like Option even if core.option isn't directly imported
        StructType? globalFoundType = null;
        foreach (var moduleTypes in _compilation.StructsByModule.Values)
        {
            if (moduleTypes.TryGetValue(typeName, out var globalType))
            {
                if (globalFoundType != null)
                {
                    // Ambiguous - multiple modules define this simple name
                    return null;
                }

                globalFoundType = globalType;
            }
        }

        return globalFoundType;
    }

    public static string DeriveModulePath(string filePath, IReadOnlyList<string> includePaths, string workingDirectory)
    {
        var normalizedFile = Path.GetFullPath(filePath);

        // Try to find which include path this file is under
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

        // If not under any include path, treat as relative to working directory
        var normalizedWorking = Path.GetFullPath(workingDirectory);
        var relativeToWorking = Path.GetRelativePath(normalizedWorking, normalizedFile);
        var modulePathFromWorking = Path.ChangeExtension(relativeToWorking, null);
        return modulePathFromWorking.Replace(Path.DirectorySeparatorChar, '.');
    }

    private void PushGenericScope(FunctionDeclarationNode function)
    {
        _genericScopes.Push(CollectGenericParamNames(function));
    }

    private void PopGenericScope()
    {
        if (_genericScopes.Count > 0)
            _genericScopes.Pop();
    }

    private bool IsGenericNameInScope(string name, HashSet<string>? explicitScope = null)
    {
        if (explicitScope != null && explicitScope.Contains(name))
            return true;

        foreach (var scope in _genericScopes)
            if (scope.Contains(name))
                return true;

        return false;
    }

    public void CollectFunctionSignatures(ModuleNode module, string modulePath)
    {
        _currentModulePath = modulePath;

        // Collect private function entries for later use in generic specialization
        // Private functions from a module must be visible when specializing generic functions from that module
        var privateEntries = new List<(string, FunctionEntry)>();

        foreach (var function in module.Functions)
        {
            var mods = function.Modifiers;
            var isPublic = (mods & FunctionModifiers.Public) != 0;
            var isForeign = (mods & FunctionModifiers.Foreign) != 0;

            PushGenericScope(function);
            try
            {
                var returnType = ResolveTypeNode(function.ReturnType) ?? TypeRegistry.Void;

                var parameterTypes = new List<TypeBase>();
                foreach (var param in function.Parameters)
                {
                    var pt = ResolveTypeNode(param.Type);
                    if (pt == null)
                    {
                        ReportError(
                            $"cannot find type `{(param.Type as NamedTypeNode)?.Name ?? "unknown"}` in this scope",
                            param.Type.Span,
                            "not found in this scope",
                            "E2003");
                        pt = TypeRegistry.Never;
                    }

                    // Store resolved type on parameter for AstLowering
                    param.ResolvedType = pt;
                    parameterTypes.Add(pt);
                }

                // Store resolved types on function for AstLowering
                function.ResolvedReturnType = returnType;
                function.ResolvedParameterTypes = parameterTypes;

                var entry = new FunctionEntry(function.Name, parameterTypes, returnType, function, isForeign,
                    IsGenericSignature(parameterTypes, returnType), modulePath);

                if (isPublic || isForeign)
                {
                    // Public/foreign functions go into global registry
                    if (!_functions.TryGetValue(function.Name, out var list))
                    {
                        list = [];
                        _functions[function.Name] = list;
                    }
                    list.Add(entry);
                }
                else
                {
                    // Private functions: store for later use during generic specialization
                    privateEntries.Add((function.Name, entry));
                }
            }
            finally
            {
                PopGenericScope();
            }
        }

        // Store private entries for this module (needed when specializing generics from this module)
        _privateEntriesByModule[modulePath] = privateEntries;

        // Temporarily register private functions so constant initializers can reference them
        foreach (var (name, entry) in privateEntries)
        {
            if (!_functions.TryGetValue(name, out var list))
            {
                list = [];
                _functions[name] = list;
            }
            list.Add(entry);
        }

        // Collect global constants early so they're available during generic specialization
        // Note: Constants are fully type-checked here (including initializers) so they can be used
        // when generic functions from this module are specialized before CheckModuleBodies runs
        var privateConstants = new List<(string Name, TypeBase Type)>();
        foreach (var globalConst in module.GlobalConstants)
        {
            CollectGlobalConstant(globalConst, privateConstants);
        }
        _privateConstantsByModule[modulePath] = privateConstants;

        // Remove private functions again (they'll be re-registered in CheckModuleBodies)
        foreach (var (name, entry) in privateEntries)
        {
            if (_functions.TryGetValue(name, out var list))
            {
                list.Remove(entry);
                if (list.Count == 0) _functions.Remove(name);
            }
        }

        // Remove private constants again (they'll be re-registered in CheckModuleBodies)
        foreach (var (name, _) in privateConstants)
        {
            _compilation.GlobalConstants.Remove(name);
        }

        _currentModulePath = null;
    }

    /// <summary>
    /// Collects a global constant during signature collection phase.
    /// This is needed so constants are available when generic functions are specialized.
    /// </summary>
    private void CollectGlobalConstant(VariableDeclarationNode v, List<(string Name, TypeBase Type)> privateConstants)
    {
        // Global constants must have an initializer
        if (v.Initializer == null)
        {
            ReportError(
                "global const declaration must have an initializer",
                v.Span,
                "global const variables must be initialized at declaration",
                "E2039");
            v.ResolvedType = TypeRegistry.Never;
            if (v.IsPublic)
                _compilation.GlobalConstants[v.Name] = TypeRegistry.Never;
            return;
        }

        // Check for duplicate global constant names
        if (_compilation.GlobalConstants.ContainsKey(v.Name))
        {
            ReportError(
                $"global constant `{v.Name}` is already declared",
                v.Span,
                "duplicate global constant declaration",
                "E2005");
            v.ResolvedType = TypeRegistry.Never;
            return;
        }

        var dt = ResolveTypeNode(v.Type);
        var it = CheckExpression(v.Initializer, dt);

        TypeBase finalType;
        if (it != null && dt != null)
        {
            var originalInitType = it.Prune();
            UnifyTypes(it, dt, v.Initializer.Span);
            v.Initializer = WrapWithCoercionIfNeeded(v.Initializer, originalInitType, dt.Prune());
            v.ResolvedType = dt;
            finalType = dt;
        }
        else
        {
            var varType = dt ?? it;
            if (varType == null)
            {
                ReportError(
                    "cannot infer type",
                    v.Span,
                    "type annotations needed: global const declaration requires either a type annotation or an initializer",
                    "E2001");
                v.ResolvedType = TypeRegistry.Never;
                finalType = TypeRegistry.Never;
            }
            else
            {
                v.ResolvedType = varType;
                finalType = varType;
            }
        }

        // Register based on visibility
        // Also register all constants temporarily so later constants in the same module can reference them
        _compilation.GlobalConstants[v.Name] = finalType;
        if (!v.IsPublic)
        {
            // Private constants: also store for module-local access during generic specialization
            privateConstants.Add((v.Name, finalType));
        }
    }

    /// <summary>
    /// Phase 1: Register struct names without resolving field types.
    /// This enables order-independent struct declarations.
    /// </summary>
    public void CollectStructNames(ModuleNode module, string modulePath)
    {
        if (!_compilation.StructsByModule.ContainsKey(modulePath))
            _compilation.StructsByModule[modulePath] = new Dictionary<string, StructType>();

        foreach (var structDecl in module.Structs)
        {
            // Convert string type parameters to GenericParameterType instances
            var typeArgs = new List<TypeBase>();
            foreach (var param in structDecl.TypeParameters)
                typeArgs.Add(new GenericParameterType(param));

            // Compute FQN for this struct
            var fqn = $"{modulePath}.{structDecl.Name}";

            // Create struct type with EMPTY fields (placeholder)
            StructType stype = new(fqn, typeArgs, []);

            // Register the struct name immediately (fields will be resolved later)
            _compilation.StructsByModule[modulePath][structDecl.Name] = stype;
            _compilation.StructsByFqn[fqn] = stype;
            _compilation.Structs[structDecl.Name] = stype;
        }
    }

    /// <summary>
    /// Phase 2: Resolve struct field types after all struct names are registered.
    /// This must run after CollectStructNames has processed ALL modules.
    /// </summary>
    public void ResolveStructFields(ModuleNode module, string modulePath)
    {
        _currentModulePath = modulePath;

        foreach (var structDecl in module.Structs)
        {
            var fields = new List<(string, TypeBase)>();
            foreach (var field in structDecl.Fields)
            {
                var ft = ResolveTypeNode(field.Type);
                if (ft == null)
                {
                    ReportError(
                        $"cannot find type `{(field.Type as NamedTypeNode)?.Name ?? "unknown"}` in this scope",
                        field.Type.Span,
                        "not found in this scope",
                        "E2003");
                    ft = TypeRegistry.Never;
                }

                fields.Add((field.Name, ft));
            }

            // Compute FQN for this struct
            var fqn = $"{modulePath}.{structDecl.Name}";

            // Update the existing placeholder struct in-place so all references
            // (including those captured during Phase 1) get the resolved fields.
            var existing = _compilation.StructsByFqn[fqn];
            existing.SetFields(fields);
        }

        _currentModulePath = null;
    }

    /// <summary>
    /// Phase 1: Register enum names without resolving variant payload types.
    /// This enables order-independent enum declarations.
    /// </summary>
    public void CollectEnumNames(ModuleNode module, string modulePath)
    {
        if (!_compilation.EnumsByModule.ContainsKey(modulePath))
            _compilation.EnumsByModule[modulePath] = new Dictionary<string, EnumType>();

        foreach (var enumDecl in module.Enums)
        {
            // Convert string type parameters to GenericParameterType instances
            var typeArgs = new List<TypeBase>();
            foreach (var param in enumDecl.TypeParameters)
                typeArgs.Add(new GenericParameterType(param));

            // Compute FQN for this enum
            var fqn = $"{modulePath}.{enumDecl.Name}";

            // Create enum type with type parameters and EMPTY variants (placeholder)
            EnumType etype = new(fqn, typeArgs, []);

            // Register the enum name immediately (variants will be resolved later)
            _compilation.EnumsByModule[modulePath][enumDecl.Name] = etype;
            _compilation.EnumsByFqn[fqn] = etype;
            _compilation.Enums[enumDecl.Name] = etype;
        }
    }

    /// <summary>
    /// Phase 2: Resolve enum variant payload types after all type names are registered.
    /// This must run after CollectEnumNames and CollectStructNames have processed ALL modules.
    /// </summary>
    public void ResolveEnumVariants(ModuleNode module, string modulePath)
    {
        _currentModulePath = modulePath;

        foreach (var enumDecl in module.Enums)
        {
            var variants = new List<(string VariantName, TypeBase? PayloadType)>();
            var fqn = $"{modulePath}.{enumDecl.Name}";

            foreach (var variant in enumDecl.Variants)
            {
                TypeBase? payloadType = null;

                // Resolve payload type if variant has fields
                if (variant.PayloadTypes.Count > 0)
                {
                    // Multiple payload types → create anonymous struct
                    if (variant.PayloadTypes.Count == 1)
                    {
                        // Single payload - use that type directly
                        payloadType = ResolveTypeNode(variant.PayloadTypes[0]);
                        if (payloadType == null)
                        {
                            ReportError(
                                $"cannot find type `{(variant.PayloadTypes[0] as NamedTypeNode)?.Name ?? "unknown"}` in this scope",
                                variant.PayloadTypes[0].Span,
                                "not found in this scope",
                                "E2003");
                            payloadType = TypeRegistry.Never;
                        }
                        else
                        {
                            // Check for direct recursion (enum containing itself)
                            if (ContainsTypeDirectly(payloadType, fqn))
                            {
                                ReportError(
                                    $"enum `{enumDecl.Name}` cannot contain itself directly",
                                    variant.PayloadTypes[0].Span,
                                    "recursive types must use references (e.g., &EnumName)",
                                    "E2035");
                                payloadType = TypeRegistry.Never; // Fallback
                            }
                        }
                    }
                    else
                    {
                        // Multiple payloads - create anonymous struct to hold them
                        var payloadFields = new List<(string, TypeBase)>();
                        for (int i = 0; i < variant.PayloadTypes.Count; i++)
                        {
                            var fieldType = ResolveTypeNode(variant.PayloadTypes[i]);
                            if (fieldType == null)
                            {
                                ReportError(
                                    $"cannot find type `{(variant.PayloadTypes[i] as NamedTypeNode)?.Name ?? "unknown"}` in this scope",
                                    variant.PayloadTypes[i].Span,
                                    "not found in this scope",
                                    "E2003");
                                fieldType = TypeRegistry.Never;
                            }
                            else
                            {
                                // Check for direct recursion
                                if (ContainsTypeDirectly(fieldType, fqn))
                                {
                                    ReportError(
                                        $"enum `{enumDecl.Name}` cannot contain itself directly",
                                        variant.PayloadTypes[i].Span,
                                        "recursive types must use references (e.g., &EnumName)",
                                        "E2035");
                                    fieldType = TypeRegistry.Never; // Fallback
                                }
                            }

                            payloadFields.Add(($"field{i}", fieldType));
                        }

                        // Create anonymous struct for multiple payloads
                        var anonStructName = $"{modulePath}.{enumDecl.Name}.{variant.Name}_payload";
                        payloadType = new StructType(anonStructName, [], payloadFields);
                    }
                }

                variants.Add((variant.Name, payloadType));
            }

            // Check for duplicate variant names
            var variantNames = new HashSet<string>();
            foreach (var (variantName, _) in variants)
            {
                if (!variantNames.Add(variantName))
                {
                    ReportError(
                        $"duplicate variant name `{variantName}` in enum `{enumDecl.Name}`",
                        enumDecl.Span,
                        "variant names must be unique within an enum",
                        "E2034");
                }
            }

            // Compute FQN for this enum
            fqn = $"{modulePath}.{enumDecl.Name}";

            // Convert string type parameters to GenericParameterType instances
            var typeArgs = new List<TypeBase>();
            foreach (var param in enumDecl.TypeParameters)
                typeArgs.Add(new GenericParameterType(param));

            // Create final enum type with type parameters and resolved variants
            EnumType etype = new(fqn, typeArgs, variants);

            // Check for naked enum (C-style enum with explicit tag values)
            bool hasExplicitTag = enumDecl.Variants.Any(v => v.ExplicitTagValue != null);
            if (hasExplicitTag)
            {
                // Naked enums cannot have payload variants
                foreach (var variant in enumDecl.Variants)
                {
                    if (variant.PayloadTypes.Count > 0)
                    {
                        ReportError(
                            $"variant `{variant.Name}` in naked enum `{enumDecl.Name}` cannot have payload",
                            variant.Span,
                            "naked enums (with explicit tag values) cannot have variant payloads",
                            "E2047");
                    }
                }

                // Resolve tag values with auto-increment
                var tagValues = new Dictionary<string, long>();
                var usedTags = new Dictionary<long, string>();
                long nextTag = 0;

                foreach (var variant in enumDecl.Variants)
                {
                    long tagValue = variant.ExplicitTagValue ?? nextTag;

                    if (usedTags.TryGetValue(tagValue, out var existingVariant))
                    {
                        ReportError(
                            $"duplicate tag value `{tagValue}` in enum `{enumDecl.Name}`: variant `{variant.Name}` conflicts with `{existingVariant}`",
                            variant.Span,
                            "each variant must have a unique tag value",
                            "E2048");
                    }
                    else
                    {
                        usedTags[tagValue] = variant.Name;
                    }

                    tagValues[variant.Name] = tagValue;
                    nextTag = tagValue + 1;
                }

                etype.TagValues = tagValues;
            }

            // Replace placeholder with complete enum type
            _compilation.EnumsByModule[modulePath][enumDecl.Name] = etype;
            _compilation.EnumsByFqn[fqn] = etype;
            _compilation.Enums[enumDecl.Name] = etype;

            // Register each variant as a symbol in the current scope
            // Each variant has type = enum type, allowing natural usage like `let c = Red`
            foreach (var (variantName, _) in variants)
            {
                DeclareVariable(variantName, etype, enumDecl.Span);
            }
        }

        _currentModulePath = null;
    }

    /// <summary>
    /// Check if a type contains another type directly (not through a reference).
    /// This prevents recursive types with infinite size.
    /// </summary>
    private bool ContainsTypeDirectly(TypeBase type, string targetFqn)
    {
        // Unwrap the type
        type = type.Prune();

        // References are OK - they add indirection
        if (type is ReferenceType)
            return false;

        // Direct match with target enum
        if (type is EnumType et && et.Name == targetFqn)
            return true;

        // Check struct fields recursively
        if (type is StructType st)
        {
            foreach (var (_, fieldType) in st.Fields)
            {
                if (ContainsTypeDirectly(fieldType, targetFqn))
                    return true;
            }
        }

        // Arrays contain elements directly
        if (type is ArrayType at)
        {
            return ContainsTypeDirectly(at.ElementType, targetFqn);
        }

        // Slices are references (fat pointers), so they're OK
        // Other types (primitives, etc.) are fine
        return false;
    }

    public void RegisterImports(ModuleNode module, string modulePath)
    {
        if (!_compilation.ModuleImports.ContainsKey(modulePath))
            _compilation.ModuleImports[modulePath] = new HashSet<string>();

        foreach (var import in module.Imports)
        {
            // Convert ["core", "string"] → "core.string"
            var importedModulePath = string.Join(".", import.Path);
            _compilation.ModuleImports[modulePath].Add(importedModulePath);
        }
    }

    public void CheckModuleBodies(ModuleNode module, string modulePath)
    {
        _currentModulePath = modulePath;
        _literalTypeVars.Clear();  // Clear TypeVars from previous module

        // Get private function entries (collected earlier in CollectFunctionSignatures)
        var privateEntries = _privateEntriesByModule.TryGetValue(modulePath, out var entries) ? entries : [];

        // Temporarily add private functions to global registry (must happen before global const checking
        // so that function references can be resolved in global constant initializers)
        foreach (var (name, entry) in privateEntries)
        {
            if (!_functions.TryGetValue(name, out var list))
            {
                list = [];
                _functions[name] = list;
            }
            list.Add(entry);
        }

        // Get private constants (already collected in CollectFunctionSignatures)
        var privateConstants = _privateConstantsByModule.TryGetValue(modulePath, out var pc) ? pc : [];

        // Temporarily register private constants for use within this module
        foreach (var (name, type) in privateConstants)
        {
            _compilation.GlobalConstants[name] = type;
        }

        // Check non-generic bodies
        foreach (var function in module.Functions)
        {
            if ((function.Modifiers & FunctionModifiers.Foreign) != 0) continue;
            if (IsGenericFunctionDecl(function)) continue;
            CheckFunction(function);
        }

        // Check test block bodies
        foreach (var test in module.Tests)
        {
            CheckTest(test);
        }

        // Remove private entries from global registry
        // They remain in _privateEntriesByModule for use during generic specialization
        foreach (var (name, entry) in privateEntries)
        {
            if (_functions.TryGetValue(name, out var list))
            {
                list.Remove(entry);
                if (list.Count == 0) _functions.Remove(name);
            }
        }

        // Remove private constants from global registry
        // They remain in _privateConstantsByModule for use during generic specialization
        foreach (var (name, _) in privateConstants)
        {
            _compilation.GlobalConstants.Remove(name);
        }

        // Verify all literal TypeVars have been resolved to concrete types
        VerifyAllTypesResolved();

        _currentModulePath = null;
    }

    private void CheckFunction(FunctionDeclarationNode function)
    {
        PushGenericScope(function);
        PushScope();
        _functionStack.Push(function);
        try
        {
            // Resolve and store parameter types
            var resolvedParamTypes = new List<TypeBase>();
            foreach (var p in function.Parameters)
            {
                var t = ResolveTypeNode(p.Type) ?? TypeRegistry.Never;
                p.ResolvedType = t;
                resolvedParamTypes.Add(t);
                if (t != TypeRegistry.Never) DeclareVariable(p.Name, t, p.Span);
            }
            function.ResolvedParameterTypes = resolvedParamTypes;

            // Resolve and store return type
            var expectedReturn = ResolveTypeNode(function.ReturnType) ?? TypeRegistry.Void;
            function.ResolvedReturnType = expectedReturn;

            _logger.LogDebug(
                "[TypeChecker] CheckFunctionBody '{FunctionName}': ReturnType node type={ReturnTypeNodeType}, expectedReturn={ExpectedReturn}",
                function.Name,
                function.ReturnType?.GetType().Name ?? "null",
                expectedReturn.Name);

            foreach (var stmt in function.Body) CheckStatement(stmt);
        }
        finally
        {
            PopScope();
            PopGenericScope();
            _functionStack.Pop();
        }
    }

    /// <summary>
    /// Type check a test block body (no parameters, void return).
    /// </summary>
    private void CheckTest(TestDeclarationNode test)
    {
        PushScope();
        try
        {
            // Test blocks have no parameters and implicitly return void
            foreach (var stmt in test.Body)
            {
                CheckStatement(stmt);
            }
        }
        finally
        {
            PopScope();
        }
    }

    private void CheckStatement(StatementNode statement)
    {
        switch (statement)
        {
            case ReturnStatementNode ret:
                CheckReturnStatement(ret);
                break;
            case VariableDeclarationNode v:
                CheckVariableDeclaration(v);
                break;
            case ExpressionStatementNode es:
                CheckExpressionStatement(es);
                break;
            case ForLoopNode fl:
                CheckForLoop(fl);
                break;
            case BreakStatementNode:
            case ContinueStatementNode:
                // No-op: these statements don't require type checking
                break;
            case DeferStatementNode ds:
                CheckDeferStatement(ds);
                break;
            default:
                throw new Exception($"Unknown statement type: {statement.GetType().Name}");
        }
    }

    private void CheckReturnStatement(ReturnStatementNode ret)
    {
        // Get expected return type from current function
        TypeBase? expectedReturnType = null;
        if (_functionStack.Count > 0)
        {
            var currentFunction = _functionStack.Peek();
            expectedReturnType = currentFunction.ReturnType != null ? ResolveTypeNode(currentFunction.ReturnType) : TypeRegistry.Void;
        }

        // Handle bare `return` for void functions
        if (ret.Expression == null)
        {
            if (expectedReturnType != null && !expectedReturnType.Equals(TypeRegistry.Void))
            {
                ReportError(
                    "bare `return` in non-void function",
                    ret.Span,
                    $"expected `{expectedReturnType.Name}`, use `return <expr>`",
                    "E2027");
            }
            return;
        }

        var et = CheckExpression(ret.Expression, expectedReturnType);
        _logger.LogDebug(
            "[TypeChecker] CheckReturnStatement: expectedReturnType={ExpectedType}, expressionType={ExprType}",
            expectedReturnType?.Name ?? "null", et.Name);

        // Early exit if expression failed type checking to prevent cascading unification errors
        if (IsNever(et)) return;

        if (expectedReturnType != null)
        {
            // Always unify to propagate type info (e.g., comptime_int → i32)
            var unified = UnifyTypes(expectedReturnType, et, ret.Expression.Span);

            // Wrap return expression with coercion node if needed
            ret.Expression = WrapWithCoercionIfNeeded(ret.Expression, et.Prune(), expectedReturnType.Prune());

            _logger.LogDebug(
                "[TypeChecker] After unification: unified={UnifiedType}",
                unified.Name);
        }
    }

    private void CheckVariableDeclaration(VariableDeclarationNode v)
    {
        // const declarations require an initializer
        if (v.IsConst && v.Initializer == null)
        {
            ReportError(
                "const declaration must have an initializer",
                v.Span,
                "const variables must be initialized at declaration",
                "E2039");
            v.ResolvedType = TypeRegistry.Never;
            DeclareVariable(v.Name, TypeRegistry.Never, v.Span, isConst: true);
            return;
        }

        var dt = ResolveTypeNode(v.Type);
        var it = v.Initializer != null ? CheckExpression(v.Initializer, dt) : null;

        // Early exit if initializer failed type checking to prevent cascading unification errors
        if (it != null && IsNever(it))
        {
            v.ResolvedType = TypeRegistry.Never;
            DeclareVariable(v.Name, TypeRegistry.Never, v.Span, v.IsConst);
            return;
        }

        if (it != null && dt != null)
        {
            // Capture the original initializer type BEFORE unification (for coercion detection)
            var originalInitType = it.Prune();

            // Unify initializer type with declared type - TypeVar.Prune() handles propagation
            var unified = UnifyTypes(it, dt, v.Initializer!.Span);

            // Wrap initializer with coercion node if needed
            // Use originalInitType (before unification) to correctly detect coercions like comptime_int -> Option
            v.Initializer = WrapWithCoercionIfNeeded(v.Initializer!, originalInitType, dt.Prune());

            v.ResolvedType = dt;
            DeclareVariable(v.Name, dt, v.Span, v.IsConst);
        }
        else
        {
            // Use declared type if available, otherwise inferred type from initializer
            var varType = dt ?? it;

            if (varType == null)
            {
                // Neither type annotation nor initializer present
                ReportError(
                    "cannot infer type",
                    v.Span,
                    "type annotations needed: variable declaration requires either a type annotation or an initializer",
                    "E2001");
                v.ResolvedType = TypeRegistry.Never;
                DeclareVariable(v.Name, TypeRegistry.Never, v.Span, v.IsConst);
            }
            else
            {
                // No immediate check for IsComptimeType - validation happens in VerifyAllTypesResolved
                v.ResolvedType = varType;
                DeclareVariable(v.Name, varType, v.Span, v.IsConst);
            }
        }
    }

    private void CheckExpressionStatement(ExpressionStatementNode es)
    {
        CheckExpression(es.Expression);
    }

    private void CheckForLoop(ForLoopNode fl)
    {
        PushScope();

        // 1. Resolve iterable expression type
        var iterableType = CheckExpression(fl.IterableExpression);

        // Track if we encountered any errors - if so, skip body checking
        var hadIteratorError = false;

        // 2. Resolve iter(&T) for the iterable type using a synthetic in-memory call
        //    This leverages the normal overload resolution and generic binding machinery.
        if (_functions.TryGetValue("iter", out _))
        {
            // Use a nested scope so the synthetic variable does not leak into the loop body
            PushScope();
            var iterableTempName = "__flang_for_iterable_tmp";
            DeclareVariable(iterableTempName, iterableType, fl.IterableExpression.Span);
            var iterableId = new IdentifierExpressionNode(fl.IterableExpression.Span, iterableTempName);
            var iterableAddr = new AddressOfExpressionNode(fl.IterableExpression.Span, iterableId);
            var iterCall = new CallExpressionNode(fl.Span, "iter", [iterableAddr]);

            // Track diagnostics before the call to detect failures
            var diagnosticsBefore = _diagnostics.Count;
            var iteratorType = CheckExpression(iterCall);
            var diagnosticsAfter = _diagnostics.Count;
            var hadError = diagnosticsAfter > diagnosticsBefore;

            // If iter(&T) failed, type is not iterable
            if (hadError)
            {
                // Check if the error is a resolution failure (E2004/E2011) or a body
                // specialization error. Only replace with E2021 for resolution failures.
                var lastDiagnostic = _diagnostics[^1];
                if (lastDiagnostic.Code == "E2004" || lastDiagnostic.Code == "E2011")
                {
                    _diagnostics.RemoveAt(_diagnostics.Count - 1);

                    var iterableTypeName = FormatTypeNameForDisplay(iterableType);
                    ReportError(
                        $"type `{iterableTypeName}` is not iterable",
                        fl.IterableExpression.Span,
                        $"define `fn iter(&{iterableTypeName})` that returns an iterator state struct type",
                        "E2021");
                }
                PopScope();
                hadIteratorError = true;
            }
            else if (iteratorType is StructType iteratorStruct)
            {
                // 3. Resolve next(&IteratorType) using another synthetic call
                PushScope();
                var iterTempName = "__flang_for_iterator_tmp";
                DeclareVariable(iterTempName, iteratorStruct, fl.Span);
                var iterId = new IdentifierExpressionNode(fl.Span, iterTempName);
                var iterAddr = new AddressOfExpressionNode(fl.Span, iterId);
                var nextCall = new CallExpressionNode(fl.Span, "next", [iterAddr]);

                var diagnosticsBeforeNext = _diagnostics.Count;
                var nextResultType = CheckExpression(nextCall);
                var diagnosticsAfterNext = _diagnostics.Count;
                var hadNextError = diagnosticsAfterNext > diagnosticsBeforeNext;

                // If next(&IteratorType) failed, check what kind of failure:
                // - Resolution failure (no matching function): replace with E2023
                // - Body specialization error (function found but body has type errors):
                //   keep the original errors as they are more informative
                if (hadNextError)
                {
                    // Only replace with E2023 if the function wasn't found at all.
                    // If nextCall.ResolvedTarget is set, the function was resolved but
                    // body specialization had errors - keep those errors as they are
                    // more informative than a generic "no next function" message.
                    var nextWasResolved = nextCall.ResolvedTarget != null;
                    if (!nextWasResolved)
                    {
                        _diagnostics.RemoveAt(_diagnostics.Count - 1);
                        var iteratorStructName = FormatTypeNameForDisplay(iteratorStruct);
                        ReportError(
                            $"iterator state type `{iteratorStructName}` has no `next` function",
                            fl.IterableExpression.Span,
                            $"define `fn next(&{iteratorStructName})` that returns an option type",
                            "E2023");
                    }
                    // else: body errors are already in _diagnostics, keep them
                    PopScope();
                    PopScope();
                    hadIteratorError = true;
                }
                // 4. Validate that next returns an Option[E] and extract element type
                else if (nextResultType is StructType optionStruct && TypeRegistry.IsOption(optionStruct)
                                                                   && optionStruct.TypeArguments.Count > 0)
                {
                    var elementType = optionStruct.TypeArguments[0];
                    // Write iterator protocol types to node
                    fl.IteratorType = iteratorStruct;
                    fl.ElementType = elementType;
                    fl.NextResultOptionType = optionStruct;
                    PopScope();
                    PopScope();
                    // Declare the loop variable with the inferred element type
                    // This must be done AFTER popping the nested scopes so the variable is in the outer for loop scope
                    DeclareVariable(fl.IteratorVariable, elementType, fl.Span);
                }
                else
                {
                    // E2025: next must return an Option type
                    var actualReturnType = FormatTypeNameForDisplay(nextResultType);

                    // Find the next function that was called to get its return type span for the hint
                    SourceSpan? nextReturnTypeSpan = null;
                    if (_functions.TryGetValue("next", out var nextCandidates))
                    {
                        // Find a next function that takes &iteratorStruct
                        foreach (var candidate in nextCandidates)
                        {
                            if (candidate.ParameterTypes.Count == 1 &&
                                candidate.ParameterTypes[0] is ReferenceType reTypeBase &&
                                reTypeBase.InnerType.Equals(iteratorStruct))
                            {
                                // Found the matching next function - get its return type span
                                if (candidate.AstNode.ReturnType != null)
                                {
                                    nextReturnTypeSpan = candidate.AstNode.ReturnType.Span;
                                }

                                break;
                            }
                        }
                    }

                    ReportError(
                        $"`next` function must return an option type, but it returns `{actualReturnType}`",
                        fl.IterableExpression.Span,
                        null, // No inline hint - we'll create a separate hint diagnostic
                        "E2025");

                    // Create a hint diagnostic pointing to the return type if we found it
                    if (nextReturnTypeSpan.HasValue)
                    {
                        _diagnostics.Add(Diagnostic.Hint(
                            $"change return type of `next` to `{actualReturnType}?` or `Option({actualReturnType})`",
                            nextReturnTypeSpan.Value, $"change to `{actualReturnType}?`"));
                    }

                    PopScope();
                    PopScope();
                    hadIteratorError = true;
                }
            }
            else
            {
                // iter was called successfully but returned a non-struct
                // This means iter exists and signature matched, but return type is wrong
                // This is similar to E2023 (missing next), but the issue is that iter returned wrong type
                // Use E2023 as it's the closest match (iterator state issue)
                var actualReturnType = FormatTypeNameForDisplay(iteratorType);

                // Find the iter function that was called to get its return type span for the hint
                SourceSpan? iterReturnTypeSpan = null;
                if (_functions.TryGetValue("iter", out var iterCandidates))
                {
                    // Find an iter function that takes &iterableType
                    foreach (var candidate in iterCandidates)
                    {
                        if (candidate.ParameterTypes.Count == 1 &&
                            candidate.ParameterTypes[0] is ReferenceType reTypeBase &&
                            reTypeBase.InnerType.Equals(iterableType))
                        {
                            // Found the matching iter function - get its return type span
                            if (candidate.AstNode.ReturnType != null)
                            {
                                iterReturnTypeSpan = candidate.AstNode.ReturnType.Span;
                            }

                            break;
                        }
                    }
                }

                ReportError(
                    $"`iter` function must return a struct, but it returns `{actualReturnType}`",
                    fl.Span,
                    null,
                    "E2023");

                // Create a hint diagnostic pointing to the return type if we found it
                if (iterReturnTypeSpan.HasValue)
                {
                    _diagnostics.Add(Diagnostic.Hint(
                        "change to a struct type",
                        iterReturnTypeSpan.Value));
                }

                PopScope();
                hadIteratorError = true;
            }
        }
        else
        {
            // No `iter` function at all; the specific error for this loop is that T is not iterable.
            // E2021: type T is not iterable
            var iterableTypeName = FormatTypeNameForDisplay(iterableType);
            ReportError(
                $"type `{iterableTypeName}` cannot be iterated",
                fl.IterableExpression.Span,
                $"implement the iterator protocol by defining `fn iter(&{iterableTypeName})`",
                "E2021");
            hadIteratorError = true;
        }

        // 5. Type-check loop body with the loop variable in scope (only if iterator setup succeeded)
        if (!hadIteratorError)
        {
            CheckExpression(fl.Body);
        }

        PopScope();
    }

    private void CheckDeferStatement(DeferStatementNode ds)
    {
        CheckExpression(ds.Expression);
    }

    private TypeBase CheckStringLiteral(StringLiteralNode strLit)
    {
        if (_compilation.Structs.TryGetValue("String", out var st))
            return st;

        ReportError(
            "String type not found",
            strLit.Span,
            "make sure to import core.string",
            "E2013");
        return TypeRegistry.Never;
    }

    /// <summary>
    /// Attempts to build a dotted path string from a member access chain.
    /// Returns null if the chain contains non-identifier/member-access nodes.
    /// Example: a.b.c → "a.b.c"
    /// </summary>
    private string? TryBuildMemberAccessPath(MemberAccessExpressionNode ma)
    {
        var parts = new List<string>();
        ExpressionNode current = ma;

        // Walk the chain backwards, collecting parts
        while (current is MemberAccessExpressionNode memberAccess)
        {
            parts.Insert(0, memberAccess.FieldName);
            current = memberAccess.Target;
        }

        // Base must be an identifier
        if (current is IdentifierExpressionNode identifier)
        {
            parts.Insert(0, identifier.Name);
            return string.Join(".", parts);
        }

        return null; // Complex expression, can't build simple path
    }

    private TypeBase CheckIdentifierExpression(IdentifierExpressionNode id)
    {
        // First try variable lookup
        if (TryLookupVariable(id.Name, out var t))
        {
            // If the variable has an enum type and its name is a variant of that enum,
            // this is an unqualified variant reference (e.g., `Red` for `Color.Red`)
            if (t is EnumType enumType && enumType.Variants.Any(v => v.VariantName == id.Name))
            {
                // This is a unit variant - construct it with no payload
                return CheckEnumVariantConstruction(enumType, id.Name, new List<ExpressionNode>(), id.Span);
            }

            return t;
        }

        // Check if this identifier is a function name (function reference)
        if (_functions.TryGetValue(id.Name, out var candidates))
        {
            // For now, only support non-overloaded, non-generic functions as values
            var nonGenericCandidates = candidates.Where(c => !c.IsGeneric).ToList();
            if (nonGenericCandidates.Count == 1)
            {
                var entry = nonGenericCandidates[0];
                // Set the resolved target for IR lowering
                id.ResolvedFunctionTarget = entry.AstNode;
                return new FunctionType(entry.ParameterTypes, entry.ReturnType);
            }
            else if (nonGenericCandidates.Count > 1)
            {
                ReportError(
                    $"cannot take address of overloaded function `{id.Name}`",
                    id.Span,
                    "function has multiple overloads",
                    "E2004");
                return TypeRegistry.Never;
            }
            else if (candidates.Count > 0)
            {
                ReportError(
                    $"cannot take address of generic function `{id.Name}`",
                    id.Span,
                    "generic functions cannot be used as values directly",
                    "E2004");
                return TypeRegistry.Never;
            }
        }

        // Check if this identifier is a type name used as a value (type literal)
        var resolvedType = ResolveTypeName(id.Name);
        if (resolvedType != null)
        {
            // This is a type literal: i32, Point, etc. used as a value
            // It has type Type(T) where T is the referenced type
            var typeStruct = TypeRegistry.MakeType(resolvedType);

            // Track that this type is used as a literal
            _compilation.InstantiatedTypes.Add(resolvedType);
            return typeStruct;
        }

        // Check if identifier is a generic type parameter in scope (e.g., T in List(T))
        // This handles cases like size_of(T) where T is a generic parameter
        if (IsGenericNameInScope(id.Name))
        {
            // Create generic parameter type and substitute with bound type if available
            TypeBase genericType = new GenericParameterType(id.Name);
            if (_currentBindings != null && _currentBindings.TryGetValue(id.Name, out var boundType))
            {
                genericType = boundType;
            }
            // Return as type literal: T → Type(T) or Type(i32) if bound
            var typeStruct = TypeRegistry.MakeType(genericType);
            _compilation.InstantiatedTypes.Add(genericType);
            return typeStruct;
        }

        // Not found as variable or type
        ReportError(
            $"cannot find value or type `{id.Name}` in this scope",
            id.Span,
            "not found in this scope",
            "E2004");
        return TypeRegistry.Never;
    }

    private TypeBase CheckMemberAccessExpression(MemberAccessExpressionNode ma, TypeBase? expectedType = null)
    {
        // Try to resolve as full type FQN first (e.g., std.result.Result)
        var pathString = TryBuildMemberAccessPath(ma);
        if (pathString != null)
        {
            var resolvedType = ResolveTypeName(pathString);
            if (resolvedType != null)
            {
                // This entire chain resolves to a type - return Type(T)
                var typeLiteral = TypeRegistry.MakeType(resolvedType);
                _compilation.InstantiatedTypes.Add(resolvedType);
                return typeLiteral;
            }
        }

        // Evaluate target expression
        var obj = CheckExpression(ma.Target);
        if (IsNever(obj)) return TypeRegistry.Never;
        var prunedObj = obj.Prune();

        // Check if target is an enum type (accessing variant): EnumType.Variant
        if (prunedObj is StructType typeStruct && TypeRegistry.IsType(typeStruct))
        {
            // Extract the referenced type from Type(T)
            if (typeStruct.TypeArguments.Count > 0 && typeStruct.TypeArguments[0] is EnumType enumType)
            {
                // Check if field name matches a variant
                if (enumType.Variants.Any(v => v.VariantName == ma.FieldName))
                {
                    // If the enum has type parameters and we have an expected type, use it
                    // This handles cases like: let nil: List(i32) = List.Nil
                    var enumToUse = enumType;
                    if (enumType.TypeArguments.Any(t => t is GenericParameterType) && expectedType is EnumType expectedEnum)
                    {
                        // Expected type has concrete type arguments - use that
                        if (expectedEnum.Name == enumType.Name)
                            enumToUse = expectedEnum;
                    }

                    // This is enum variant construction: EnumType.Variant
                    return CheckEnumVariantConstruction(enumToUse, ma.FieldName, new List<ExpressionNode>(),
                        ma.Span);
                }

                // Not a valid variant
                ReportError(
                    $"enum `{enumType.Name}` has no variant `{ma.FieldName}`",
                    ma.Span,
                    null,
                    "E2037");
                return enumType;
            }
        }

        // Runtime field access on struct values
        // Convert arrays and slices to their canonical struct representations
        // Auto-dereference references recursively to allow field access on &T, &&T, etc.
        var currentType = prunedObj;
        int autoDerefCount = 0;

        // Unwrap references recursively until we find a struct or non-reference type
        while (currentType is ReferenceType refType)
        {
            autoDerefCount++;
            currentType = refType.InnerType.Prune();
        }

        // Convert arrays to slice representation for field access (.ptr, .len)
        var structType = currentType switch
        {
            StructType st => st,
            ArrayType array => MakeSliceType(array.ElementType, ma.Span),
            _ => null
        };

        if (structType != null)
        {
            var ft = structType.GetFieldType(ma.FieldName);
            if (ft == null)
            {
                ReportError(
                    $"no field `{ma.FieldName}` on type `{prunedObj.Name}`",
                    ma.Span,
                    $"type `{prunedObj.Name}` does not have a field named `{ma.FieldName}`",
                    "E2014");
                return TypeRegistry.Never;
            }

            // Store the auto-deref count for lowering
            ma.AutoDerefCount = autoDerefCount;

            return ft;
        }
        else
        {
            ReportError(
                "cannot access field on non-struct type",
                ma.Span,
                $"expected struct type, found `{obj}`",
                "E2014");
            return TypeRegistry.Never;
        }
    }

    private TypeBase CheckBinaryExpression(BinaryExpressionNode be)
    {
        var lt = CheckExpression(be.Left);
        if (IsNever(lt)) return TypeRegistry.Never;
        var rt = CheckExpression(be.Right, lt);
        if (IsNever(rt)) return TypeRegistry.Never;

        // Logical operators: both operands must be bool, no operator overloading
        if (be.Operator is BinaryOperatorKind.And or BinaryOperatorKind.Or)
        {
            var opSymbol = OperatorFunctions.GetOperatorSymbol(be.Operator);
            var leftPruned = lt.Prune();
            var rightPruned = rt.Prune();
            if (!leftPruned.Equals(TypeRegistry.Bool))
            {
                ReportError(
                    $"cannot apply `{opSymbol}` to non-bool type `{FormatTypeNameForDisplay(leftPruned)}`",
                    be.Left.Span,
                    $"expected `bool`, found `{FormatTypeNameForDisplay(leftPruned)}`",
                    "E2046");
                return TypeRegistry.Never;
            }
            if (!rightPruned.Equals(TypeRegistry.Bool))
            {
                ReportError(
                    $"cannot apply `{opSymbol}` to non-bool type `{FormatTypeNameForDisplay(rightPruned)}`",
                    be.Right.Span,
                    $"expected `bool`, found `{FormatTypeNameForDisplay(rightPruned)}`",
                    "E2046");
                return TypeRegistry.Never;
            }
            return TypeRegistry.Bool;
        }

        // Try to find an operator function for this operation
        var opFuncName = OperatorFunctions.GetFunctionName(be.Operator);
        var operatorFuncResult = TryResolveOperatorFunction(opFuncName, lt, rt, be.Span);

        if (operatorFuncResult != null)
        {
            // Use operator function
            be.ResolvedOperatorFunction = operatorFuncResult.Value.Function;
            return operatorFuncResult.Value.ReturnType;
        }

        // Auto-derive op_eq from op_ne or vice versa by negating the complement
        if (be.Operator is BinaryOperatorKind.Equal or BinaryOperatorKind.NotEqual)
        {
            var complementName = be.Operator == BinaryOperatorKind.Equal ? "op_ne" : "op_eq";
            var complementResult = TryResolveOperatorFunction(complementName, lt, rt, be.Span);
            if (complementResult != null)
            {
                be.ResolvedOperatorFunction = complementResult.Value.Function;
                be.NegateOperatorResult = true;
                return complementResult.Value.ReturnType;
            }
        }

        // Auto-derive comparison operators from op_cmp
        // op_cmp returns Ord (naked enum: Less=-1, Equal=0, Greater=1)
        // So op_cmp(a,b) < 0 means a < b, etc.
        if (be.Operator is BinaryOperatorKind.LessThan or BinaryOperatorKind.GreaterThan
            or BinaryOperatorKind.LessThanOrEqual or BinaryOperatorKind.GreaterThanOrEqual
            or BinaryOperatorKind.Equal or BinaryOperatorKind.NotEqual)
        {
            var cmpResult = TryResolveOperatorFunction("op_cmp", lt, rt, be.Span);
            if (cmpResult != null)
            {
                be.ResolvedOperatorFunction = cmpResult.Value.Function;
                be.CmpDerivedOperator = be.Operator;
                return TypeRegistry.Bool;
            }
        }

        // Fall back to built-in handling for primitive types
        var prunedLt = lt.Prune();
        var prunedRt = rt.Prune();

        // Built-in operators only work on numeric primitives
        if (!IsBuiltinOperatorApplicable(prunedLt, prunedRt, be.Operator))
        {
            var opSymbol = OperatorFunctions.GetOperatorSymbol(be.Operator);
            ReportError(
                $"cannot apply binary operator `{opSymbol}` to types `{FormatTypeNameForDisplay(prunedLt)}` and `{FormatTypeNameForDisplay(prunedRt)}`",
                be.Span,
                $"no implementation for `{FormatTypeNameForDisplay(prunedLt)} {opSymbol} {FormatTypeNameForDisplay(prunedRt)}`",
                "E2017");
            return TypeRegistry.Never;
        }

        // Handle pointer arithmetic specially - result type is the pointer type
        if (prunedLt is ReferenceType refType && TypeRegistry.IsNumericType(prunedRt))
        {
            // Ensure the index is resolved to a concrete integer type
            if (prunedRt is ComptimeInt)
            {
                UnifyTypes(rt, TypeRegistry.ISize, be.Span);
            }
            return refType;
        }

        // Unify operand types - TypeVar.Prune() handles propagation automatically
        var unified = UnifyTypes(lt, rt, be.Span);

        if (be.Operator >= BinaryOperatorKind.Equal && be.Operator <= BinaryOperatorKind.GreaterThanOrEqual)
        {
            return TypeRegistry.Bool;
        }
        else
        {
            return unified;
        }
    }

    private TypeBase CheckUnaryExpression(UnaryExpressionNode ue)
    {
        var operandType = CheckExpression(ue.Operand);
        if (IsNever(operandType)) return TypeRegistry.Never;

        // Try to find an operator function for this operation
        var opFuncName = OperatorFunctions.GetFunctionName(ue.Operator);
        var operatorFuncResult = TryResolveUnaryOperatorFunction(opFuncName, operandType, ue.Span);

        if (operatorFuncResult != null)
        {
            ue.ResolvedOperatorFunction = operatorFuncResult.Value.Function;
            return operatorFuncResult.Value.ReturnType;
        }

        // Fall back to built-in handling for primitive types
        var pruned = operandType.Prune();

        switch (ue.Operator)
        {
            case UnaryOperatorKind.Negate:
                if (TypeRegistry.IsNumericType(pruned) || pruned is ComptimeInt)
                    return operandType;
                break;

            case UnaryOperatorKind.Not:
                if (pruned.Equals(TypeRegistry.Bool))
                    return TypeRegistry.Bool;
                break;
        }

        var opSymbol = OperatorFunctions.GetOperatorSymbol(ue.Operator);
        ReportError(
            $"cannot apply unary operator `{opSymbol}` to type `{FormatTypeNameForDisplay(pruned)}`",
            ue.Span,
            $"no implementation for `{opSymbol}{FormatTypeNameForDisplay(pruned)}`",
            "E2017");
        return TypeRegistry.Never;
    }

    private OperatorFunctionResult? TryResolveUnaryOperatorFunction(string opFuncName, TypeBase operandType, SourceSpan span)
    {
        if (!_functions.TryGetValue(opFuncName, out var candidates))
            return null;

        var argTypes = new List<TypeBase> { operandType.Prune() };

        FunctionEntry? bestNonGeneric = null;
        var bestNonGenericCost = int.MaxValue;

        foreach (var cand in candidates)
        {
            if (cand.IsGeneric) continue;
            if (cand.ParameterTypes.Count != 1) continue;
            if (!TryComputeCoercionCost(argTypes, cand.ParameterTypes, out var cost))
                continue;

            if (cost < bestNonGenericCost)
            {
                bestNonGeneric = cand;
                bestNonGenericCost = cost;
            }
        }

        FunctionEntry? bestGeneric = null;
        Dictionary<string, TypeBase>? bestBindings = null;
        var bestGenericCost = int.MaxValue;

        foreach (var cand in candidates)
        {
            if (!cand.IsGeneric) continue;
            if (cand.ParameterTypes.Count != 1) continue;

            var bindings = new Dictionary<string, TypeBase>();
            if (!TryBindGeneric(cand.ParameterTypes[0], argTypes[0], bindings, out _, out _))
                continue;

            var concreteParams = cand.ParameterTypes
                .Select(pt => SubstituteGenerics(pt, bindings))
                .ToList();

            if (!TryComputeCoercionCost(argTypes, concreteParams, out var genCost))
                continue;

            if (genCost < bestGenericCost)
            {
                bestGeneric = cand;
                bestBindings = bindings;
                bestGenericCost = genCost;
            }
        }

        FunctionEntry? chosen;
        Dictionary<string, TypeBase>? chosenBindings = null;

        if (bestNonGeneric != null && (bestGeneric == null || bestNonGenericCost <= bestGenericCost))
        {
            chosen = bestNonGeneric;
        }
        else
        {
            chosen = bestGeneric;
            chosenBindings = bestBindings;
        }

        if (chosen == null)
            return null;

        FunctionDeclarationNode resolvedFunction;
        TypeBase returnType;

        if (chosen.IsGeneric && chosenBindings != null)
        {
            resolvedFunction = EnsureSpecialization(chosen, chosenBindings, argTypes);
            returnType = SubstituteGenerics(chosen.ReturnType, chosenBindings);
        }
        else
        {
            resolvedFunction = chosen.AstNode;
            returnType = chosen.ReturnType;
        }

        return new OperatorFunctionResult
        {
            Function = resolvedFunction,
            ReturnType = returnType
        };
    }

    /// <summary>
    /// Type checks a null-coalescing expression (a ?? b).
    /// Resolves to op_coalesce(a, b) function call.
    /// </summary>
    private TypeBase CheckCoalesceExpression(CoalesceExpressionNode coalesce)
    {
        var lt = CheckExpression(coalesce.Left);
        if (IsNever(lt)) return TypeRegistry.Never;

        // For op_coalesce, we need to determine the expected type for the right side
        // based on the available overloads. If left is Option(T), the right could be T or Option(T).
        // We check the right side without an expected type and let overload resolution pick.
        var rt = CheckExpression(coalesce.Right);
        if (IsNever(rt)) return TypeRegistry.Never;

        // Try to find op_coalesce function for this operation
        const string opFuncName = "op_coalesce";
        var operatorFuncResult = TryResolveOperatorFunction(opFuncName, lt, rt, coalesce.Span);

        if (operatorFuncResult != null)
        {
            coalesce.ResolvedCoalesceFunction = operatorFuncResult.Value.Function;
            return operatorFuncResult.Value.ReturnType;
        }

        // No op_coalesce function found - report error
        var prunedLt = lt.Prune();
        var prunedRt = rt.Prune();
        ReportError(
            $"cannot apply `??` operator to types `{FormatTypeNameForDisplay(prunedLt)}` and `{FormatTypeNameForDisplay(prunedRt)}`",
            coalesce.Span,
            $"no `op_coalesce` implementation for `{FormatTypeNameForDisplay(prunedLt)} ?? {FormatTypeNameForDisplay(prunedRt)}`",
            "E2017");
        return TypeRegistry.Never;
    }

    /// <summary>
    /// Type checks a null-propagation expression (target?.field).
    /// If target is Option(T), unwraps T, accesses field, and wraps result in Option.
    /// </summary>
    private TypeBase CheckNullPropagationExpression(NullPropagationExpressionNode nullProp)
    {
        var targetType = CheckExpression(nullProp.Target);
        if (IsNever(targetType)) return TypeRegistry.Never;
        var prunedTarget = targetType.Prune();

        // Target must be Option(T)
        if (prunedTarget is not StructType optionType || !TypeRegistry.IsOption(optionType))
        {
            ReportError(
                $"cannot use `?.` on non-optional type `{FormatTypeNameForDisplay(prunedTarget)}`",
                nullProp.Target.Span,
                "expected `Option(T)` or `T?`",
                "E2002");
            return TypeRegistry.Never;
        }

        // Get the inner type T from Option(T)
        if (optionType.TypeArguments.Count == 0)
        {
            ReportError(
                "Option type has no inner type",
                nullProp.Target.Span,
                null,
                "E2002");
            return TypeRegistry.Never;
        }

        var innerType = optionType.TypeArguments[0];

        // Inner type must be a struct with the requested field
        if (innerType is not StructType innerStruct)
        {
            ReportError(
                $"cannot access field `{nullProp.MemberName}` on non-struct type `{FormatTypeNameForDisplay(innerType)}`",
                nullProp.Span,
                null,
                "E2014");
            return TypeRegistry.Never;
        }

        // Look up the field
        var fieldType = innerStruct.GetFieldType(nullProp.MemberName);
        if (fieldType == null)
        {
            ReportError(
                $"struct `{innerStruct.Name}` does not have a field named `{nullProp.MemberName}`",
                nullProp.Span,
                "unknown field",
                "E2014");
            return TypeRegistry.Never;
        }

        // Result is Option(fieldType)
        return TypeRegistry.MakeOption(fieldType);
    }

    /// <summary>
    /// Checks if built-in operator handling is applicable for the given operand types.
    /// Built-in operators only work on numeric primitives, booleans (for equality),
    /// and pointer arithmetic (&T + integer, &T - integer).
    /// </summary>
    private bool IsBuiltinOperatorApplicable(TypeBase left, TypeBase right, BinaryOperatorKind op)
    {
        // Both must be primitive or comptime types
        var leftIsNumeric = TypeRegistry.IsNumericType(left);
        var rightIsNumeric = TypeRegistry.IsNumericType(right);
        var leftIsBool = left.Equals(TypeRegistry.Bool);
        var rightIsBool = right.Equals(TypeRegistry.Bool);
        var leftIsPointer = left is ReferenceType;
        var rightIsPointer = right is ReferenceType;

        // Arithmetic operators require numeric types
        if (op >= BinaryOperatorKind.Add && op <= BinaryOperatorKind.Modulo)
        {
            // Pointer arithmetic: &T + integer or &T - integer
            if (op == BinaryOperatorKind.Add || op == BinaryOperatorKind.Subtract)
            {
                if (leftIsPointer && rightIsNumeric) return true;
            }
            return leftIsNumeric && rightIsNumeric;
        }

        // Comparison operators work on numeric types
        if (op >= BinaryOperatorKind.LessThan && op <= BinaryOperatorKind.GreaterThanOrEqual)
        {
            return leftIsNumeric && rightIsNumeric;
        }

        // Equality operators work on numeric types, booleans, and pointers
        if (op == BinaryOperatorKind.Equal || op == BinaryOperatorKind.NotEqual)
        {
            if (leftIsPointer && rightIsPointer) return true;
            return (leftIsNumeric && rightIsNumeric) || (leftIsBool && rightIsBool);
        }

        return false;
    }

    /// <summary>
    /// Result of operator function resolution.
    /// </summary>
    private readonly struct OperatorFunctionResult
    {
        public FunctionDeclarationNode Function { get; init; }
        public TypeBase ReturnType { get; init; }
    }

    /// <summary>
    /// Attempts to resolve an operator function for the given operand types.
    /// Returns null if no matching operator function is found.
    /// </summary>
    private OperatorFunctionResult? TryResolveOperatorFunction(string opFuncName, TypeBase leftType, TypeBase rightType, SourceSpan span)
    {
        if (!_functions.TryGetValue(opFuncName, out var candidates))
            return null;

        // Prune types to ensure we're comparing concrete types
        var argTypes = new List<TypeBase> { leftType.Prune(), rightType.Prune() };

        FunctionEntry? bestNonGeneric = null;
        var bestNonGenericCost = int.MaxValue;

        foreach (var cand in candidates)
        {
            if (cand.IsGeneric) continue;
            if (cand.ParameterTypes.Count != 2) continue;
            if (!TryComputeCoercionCost(argTypes, cand.ParameterTypes, out var cost))
                continue;

            if (cost < bestNonGenericCost)
            {
                bestNonGeneric = cand;
                bestNonGenericCost = cost;
            }
        }

        FunctionEntry? bestGeneric = null;
        Dictionary<string, TypeBase>? bestBindings = null;
        var bestGenericCost = int.MaxValue;

        foreach (var cand in candidates)
        {
            if (!cand.IsGeneric) continue;
            if (cand.ParameterTypes.Count != 2) continue;

            var bindings = new Dictionary<string, TypeBase>();
            var okGen = true;
            for (var i = 0; i < 2; i++)
            {
                if (!TryBindGeneric(cand.ParameterTypes[i], argTypes[i], bindings, out _, out _))
                {
                    okGen = false;
                    break;
                }
            }

            if (!okGen) continue;

            var concreteParams = cand.ParameterTypes
                .Select(pt => SubstituteGenerics(pt, bindings))
                .ToList();

            if (!TryComputeCoercionCost(argTypes, concreteParams, out var genCost))
                continue;

            if (genCost < bestGenericCost)
            {
                bestGeneric = cand;
                bestBindings = bindings;
                bestGenericCost = genCost;
            }
        }

        FunctionEntry? chosen;
        Dictionary<string, TypeBase>? chosenBindings = null;

        if (bestNonGeneric != null && (bestGeneric == null || bestNonGenericCost <= bestGenericCost))
        {
            chosen = bestNonGeneric;
        }
        else
        {
            chosen = bestGeneric;
            chosenBindings = bestBindings;
        }

        if (chosen == null)
            return null;

        // Get the actual function to call (specialized if generic)
        FunctionDeclarationNode resolvedFunction;
        TypeBase returnType;

        if (chosen.IsGeneric && chosenBindings != null)
        {
            resolvedFunction = EnsureSpecialization(chosen, chosenBindings, argTypes);
            returnType = SubstituteGenerics(chosen.ReturnType, chosenBindings);
        }
        else
        {
            resolvedFunction = chosen.AstNode;
            returnType = chosen.ReturnType;
        }

        return new OperatorFunctionResult
        {
            Function = resolvedFunction,
            ReturnType = returnType
        };
    }

    private TypeBase CheckAssignmentExpression(AssignmentExpressionNode ae)
    {
        // Check for const reassignment
        if (ae.Target is IdentifierExpressionNode id)
        {
            if (TryLookupVariableInfo(id.Name, out var varInfo) && varInfo.IsConst)
            {
                ReportError(
                    $"cannot assign to const variable `{id.Name}`",
                    ae.Target.Span,
                    "const variables cannot be reassigned after initialization",
                    "E2038");
                // Continue type checking for better error recovery
            }
        }

        // Handle indexed assignment: expr[index] = value
        if (ae.Target is IndexExpressionNode ix)
        {
            return CheckIndexedAssignment(ae, ix);
        }

        // Get the type of the assignment target (lvalue)
        TypeBase targetType = ae.Target switch
        {
            IdentifierExpressionNode idExpr => LookupVariable(idExpr.Name, ae.Target.Span),
            MemberAccessExpressionNode fa => CheckExpression(fa),
            DereferenceExpressionNode dr => CheckExpression(dr),
            _ => throw new Exception($"Invalid assignment target: {ae.Target.GetType().Name}")
        };
        if (IsNever(targetType)) return TypeRegistry.Never;

        // Check the value expression against the target type
        var val = CheckExpression(ae.Value, targetType);
        if (IsNever(val)) return TypeRegistry.Never;

        // Unify value with target type - TypeVar.Prune() handles propagation
        var unified = UnifyTypes(val, targetType, ae.Value.Span);

        return targetType;
    }

    /// <summary>
    /// Handles indexed assignment: expr[index] = value
    /// For slices/custom types, resolves op_set_index(&amp;base, index, value)
    /// For arrays, validates element type and uses native store
    /// </summary>
    private TypeBase CheckIndexedAssignment(AssignmentExpressionNode ae, IndexExpressionNode ix)
    {
        var bt = CheckExpression(ix.Base);
        if (IsNever(bt)) return TypeRegistry.Never;

        var it = CheckExpression(ix.Index);
        if (IsNever(it)) return TypeRegistry.Never;

        // For struct types (slices, custom types), look up op_set_index function
        var prunedBtForSet = bt.Prune();
        if (prunedBtForSet is StructType structTypeForSetIndex)
        {
            var refBaseType = new ReferenceType(structTypeForSetIndex);

            // Check value type
            var val = CheckExpression(ae.Value);
            if (IsNever(val)) return TypeRegistry.Never;

            // Try with &T first: op_set_index(&T, index, value)
            var opSetIndexResult = TryResolveSetIndexFunction("op_set_index", refBaseType, it, val, ae.Span);

            // Also try with value T: op_set_index(T, index, value)
            if (opSetIndexResult == null)
                opSetIndexResult = TryResolveSetIndexFunction("op_set_index", prunedBtForSet, it, val, ae.Span);

            if (opSetIndexResult != null)
            {
                ix.ResolvedSetIndexFunction = opSetIndexResult.Value.Function;

                // Resolve comptime_int index and value to the parameter's concrete types
                var resolvedSetFunc = opSetIndexResult.Value.Function;
                if (resolvedSetFunc.Parameters.Count >= 2)
                {
                    var indexParamType = resolvedSetFunc.Parameters[1].ResolvedType;
                    if (indexParamType != null)
                        UnifyTypes(it, indexParamType, ix.Index.Span);
                }
                if (resolvedSetFunc.Parameters.Count >= 3)
                {
                    var valueParamType = resolvedSetFunc.Parameters[2].ResolvedType;
                    if (valueParamType != null)
                        UnifyTypes(val, valueParamType, ae.Value.Span);
                }

                return opSetIndexResult.Value.ReturnType;
            }

            // op_set_index not found — check WHY
            if (_functions.TryGetValue("op_set_index", out var setIndexCandidates))
            {
                var matchingBaseCandidates = setIndexCandidates
                    .Where(c => c.ParameterTypes.Count == 3 &&
                           (_unificationEngine.CanUnify(c.ParameterTypes[0], structTypeForSetIndex) ||
                            _unificationEngine.CanUnify(c.ParameterTypes[0], new ReferenceType(structTypeForSetIndex))))
                    .ToList();

                if (matchingBaseCandidates.Count > 0)
                {
                    // Type IS indexable for assignment, but not with this index type
                    var indexTypeName = FormatTypeNameForDisplay(it.Prune());
                    var baseTypeName = FormatTypeNameForDisplay(structTypeForSetIndex);

                    var acceptedTypes = matchingBaseCandidates
                        .Select(c => FormatTypeNameForDisplay(c.ParameterTypes[1]))
                        .Distinct().ToList();
                    var typeList = acceptedTypes.Count <= 3
                        ? string.Join(", ", acceptedTypes.Select(t => $"`{t}`"))
                        : string.Join(", ", acceptedTypes.Take(3).Select(t => $"`{t}`")) + ", ...";

                    ReportError(
                        $"type `{baseTypeName}` cannot be indexed by value of type `{indexTypeName}`",
                        ix.Index.Span,
                        $"expected {typeList}",
                        "E2028");
                    return TypeRegistry.Never;
                }
            }

            // No op_set_index for this type at all — fall through to array/slice check
        }

        // Built-in array indexing
        var prunedIt = it.Prune();
        if (!TypeRegistry.IsIntegerType(prunedIt))
        {
            ReportError(
                "array index must be an integer",
                ix.Index.Span,
                $"found `{prunedIt}`",
                "E2027");
        }
        else if (prunedIt is ComptimeInt)
        {
            UnifyTypes(it, TypeRegistry.USize, ix.Index.Span);
        }

        TypeBase elementType2;
        if (bt is ArrayType at)
        {
            elementType2 = at.ElementType;
        }
        else if (bt is StructType st && TypeRegistry.IsSlice(st))
        {
            elementType2 = st.TypeArguments[0];
        }
        else
        {
            ReportError(
                $"type `{bt}` does not support indexed assignment",
                ix.Base.Span,
                "define `op_set_index` to enable indexed assignment",
                "E2028");
            return TypeRegistry.Never;
        }

        // Check value against element type
        var valType = CheckExpression(ae.Value, elementType2);
        if (IsNever(valType)) return TypeRegistry.Never;

        UnifyTypes(valType, elementType2, ae.Value.Span);
        return elementType2;
    }

    /// <summary>
    /// Attempts to resolve an op_set_index function for indexed assignment.
    /// op_set_index takes 3 arguments: (&amp;base, index, value)
    /// </summary>
    private OperatorFunctionResult? TryResolveSetIndexFunction(
        string opFuncName, TypeBase baseRefType, TypeBase indexType, TypeBase valueType, SourceSpan span)
    {
        if (!_functions.TryGetValue(opFuncName, out var candidates))
            return null;

        var argTypes = new List<TypeBase> { baseRefType.Prune(), indexType.Prune(), valueType.Prune() };

        FunctionEntry? bestNonGeneric = null;
        var bestNonGenericCost = int.MaxValue;

        foreach (var cand in candidates)
        {
            if (cand.IsGeneric) continue;
            if (cand.ParameterTypes.Count != 3) continue;
            if (!TryComputeCoercionCost(argTypes, cand.ParameterTypes, out var cost))
                continue;

            if (cost < bestNonGenericCost)
            {
                bestNonGeneric = cand;
                bestNonGenericCost = cost;
            }
        }

        FunctionEntry? bestGeneric = null;
        Dictionary<string, TypeBase>? bestBindings = null;
        var bestGenericCost = int.MaxValue;

        foreach (var cand in candidates)
        {
            if (!cand.IsGeneric) continue;
            if (cand.ParameterTypes.Count != 3) continue;

            var bindings = new Dictionary<string, TypeBase>();
            var okGen = true;
            for (var i = 0; i < 3; i++)
            {
                if (!TryBindGeneric(cand.ParameterTypes[i], argTypes[i], bindings, out _, out _))
                {
                    okGen = false;
                    break;
                }
            }

            if (!okGen) continue;

            var concreteParams = cand.ParameterTypes
                .Select(pt => SubstituteGenerics(pt, bindings))
                .ToList();

            if (!TryComputeCoercionCost(argTypes, concreteParams, out var genCost))
                continue;

            if (genCost < bestGenericCost)
            {
                bestGeneric = cand;
                bestBindings = bindings;
                bestGenericCost = genCost;
            }
        }

        FunctionEntry? chosen;
        Dictionary<string, TypeBase>? chosenBindings = null;

        if (bestNonGeneric != null && (bestGeneric == null || bestNonGenericCost <= bestGenericCost))
        {
            chosen = bestNonGeneric;
        }
        else
        {
            chosen = bestGeneric;
            chosenBindings = bestBindings;
        }

        if (chosen == null)
            return null;

        FunctionDeclarationNode resolvedFunction;
        TypeBase returnType;

        if (chosen.IsGeneric && chosenBindings != null)
        {
            resolvedFunction = EnsureSpecialization(chosen, chosenBindings, argTypes);
            returnType = SubstituteGenerics(chosen.ReturnType, chosenBindings);
        }
        else
        {
            resolvedFunction = chosen.AstNode;
            returnType = chosen.ReturnType;
        }

        return new OperatorFunctionResult
        {
            Function = resolvedFunction,
            ReturnType = returnType
        };
    }

    private TypeBase CheckCallExpression(CallExpressionNode call, TypeBase? expectedType)
    {
        // First check if this is enum variant construction (short form)
        // Syntax: Variant(args) when type can be inferred
        var enumConstructionType =
            TryResolveEnumVariantConstruction(call.FunctionName, call.Arguments, expectedType, call.Span);
        if (enumConstructionType != null)
        {
            return enumConstructionType;
        }

        // UFCS calls (obj.method(args)) are semantically equivalent to method(&obj, args).
        // We don't mutate the AST - instead we build the effective argument list for resolution
        // and let lowering handle the actual transformation.
        TypeBase? ufcsReceiverType = null;
        if (call.UfcsReceiver != null && call.MethodName != null)
        {
            // Type-check the receiver expression first
            ufcsReceiverType = CheckExpression(call.UfcsReceiver);
            if (IsNever(ufcsReceiverType)) return TypeRegistry.Never;
            var prunedReceiverType = ufcsReceiverType.Prune();

            // Check if receiver is a struct with a function-typed field matching the method name.
            // This enables vtable-style patterns: ops.add(5, 3) calls the function in ops.add field.
            StructType? structType = prunedReceiverType switch
            {
                StructType st => st,
                ReferenceType { InnerType: StructType refSt } => refSt,
                _ => null
            };

            if (structType != null)
            {
                var fieldType = structType.GetFieldType(call.MethodName);
                if (fieldType?.Prune() is FunctionType funcType)
                {
                    // Field-call pattern: type-check arguments and mark as indirect call
                    return CheckFieldCall(call, funcType);
                }

                // Check if field exists but is not callable (for better error message)
                if (fieldType != null)
                {
                    var receiverTypeName = FormatTypeNameForDisplay(prunedReceiverType);
                    var fieldTypeName = FormatTypeNameForDisplay(fieldType.Prune());
                    ReportError(
                        $"`{call.MethodName}` is a field of `{receiverTypeName}`, not a method",
                        call.Span,
                        $"has type `{fieldTypeName}` which is not callable",
                        "E2011");
                    return TypeRegistry.Never;
                }
            }

            // UFCS: receiver.method(args) -> method(receiver, a, b) or method(&receiver, a, b)
            // The actual transformation depends on what the resolved function expects.
            // We keep the original receiver type here; overload resolution will try both forms.
        }

        // For UFCS calls, use MethodName (the actual function name) rather than FunctionName
        // (which is a synthetic name like "obj.method" for error messages)
        var functionName = call.MethodName ?? call.FunctionName;

        if (_functions.TryGetValue(functionName, out var candidates))
        {
            _logger.LogDebug("{Indent}Considering {CandidateCount} candidates for '{FunctionName}'", Indent(),
                candidates.Count, functionName);

            // Build effective argument types: for UFCS, prepend receiver type
            // Defer anonymous struct arguments - they need expected type from generic bindings
            var explicitArgTypes = new List<TypeBase>(call.Arguments.Count);
            var deferredAnonStructIndices = new List<int>();
            for (var i = 0; i < call.Arguments.Count; i++)
            {
                var arg = call.Arguments[i];
                if (arg is AnonymousStructExpressionNode)
                {
                    // Defer - use TypeVar placeholder until we have concrete expected type
                    explicitArgTypes.Add(new TypeVar($"__deferred_anon_{i}"));
                    deferredAnonStructIndices.Add(i);
                }
                else
                {
                    var argType = CheckExpression(arg);
                    if (IsNever(argType)) return TypeRegistry.Never;
                    explicitArgTypes.Add(argType);
                }
            }
            var argTypes = ufcsReceiverType != null
                ? new List<TypeBase> { ufcsReceiverType }.Concat(explicitArgTypes).ToList()
                : explicitArgTypes;

            FunctionEntry? bestNonGeneric = null;
            var bestNonGenericCost = int.MaxValue;

            // Track candidates that matched arg count but failed type check (for better error messages)
            FunctionEntry? closestTypeMismatch = null;
            int closestMismatchIndex = -1;
            TypeBase? closestExpectedType = null;
            TypeBase? closestActualType = null;

            foreach (var cand in candidates)
            {
                if (cand.IsGeneric) continue;
                if (cand.ParameterTypes.Count != argTypes.Count) continue;

                // For UFCS calls, adapt receiver type to match what the function expects
                var effectiveArgTypes = argTypes;
                if (ufcsReceiverType != null && argTypes.Count > 0 && cand.ParameterTypes.Count > 0)
                {
                    effectiveArgTypes = TryAdaptUfcsReceiverType(argTypes, cand.ParameterTypes[0]);
                }

                if (!TryComputeCoercionCost(effectiveArgTypes, cand.ParameterTypes, out var cost))
                {
                    // Track which argument failed for error reporting
                    if (closestTypeMismatch == null)
                    {
                        closestTypeMismatch = cand;
                        for (var i = 0; i < effectiveArgTypes.Count; i++)
                        {
                            var argPruned = effectiveArgTypes[i].Prune();
                            var paramPruned = cand.ParameterTypes[i].Prune();
                            if (!argPruned.Equals(paramPruned) && !_unificationEngine.CanUnify(effectiveArgTypes[i], cand.ParameterTypes[i]))
                            {
                                closestMismatchIndex = i;
                                closestExpectedType = paramPruned;
                                closestActualType = argPruned;
                                break;
                            }
                        }
                    }
                    continue;
                }

                if (cost < bestNonGenericCost)
                {
                    bestNonGeneric = cand;
                    bestNonGenericCost = cost;
                }
            }

            FunctionEntry? bestGeneric = null;
            Dictionary<string, TypeBase>? bestBindings = null;
            var bestGenericCost = int.MaxValue;
            string? conflictName = null;
            (TypeBase Existing, TypeBase Incoming)? conflictPair = null;

            foreach (var cand in candidates)
            {
                using var _ = new BindingDepthScope(this);
                _logger.LogDebug(
                    "{Indent}Candidate '{Name}': IsGeneric={IsGeneric}, ParamCount={ParamCount}, ArgCount={ArgCount}",
                    Indent(), cand.Name, cand.IsGeneric, cand.ParameterTypes.Count, argTypes.Count);
                if (!cand.IsGeneric) continue;
                if (cand.ParameterTypes.Count != argTypes.Count) continue;

                // For UFCS calls, adapt receiver type to match what the function expects
                var effectiveArgTypes = argTypes;
                if (ufcsReceiverType != null && argTypes.Count > 0 && cand.ParameterTypes.Count > 0)
                {
                    effectiveArgTypes = TryAdaptUfcsReceiverType(argTypes, cand.ParameterTypes[0]);
                }

                _logger.LogDebug("{Indent}Attempting generic binding for '{Name}'", Indent(), cand.Name);
                var bindings = new Dictionary<string, TypeBase>();
                var okGen = true;
                var failedBindingIndex = -1;
                for (var i = 0; i < effectiveArgTypes.Count; i++)
                {
                    var argType = effectiveArgTypes[i] ?? throw new NullReferenceException();
                    using var __ = new BindingDepthScope(this);
                    _logger.LogDebug("{Indent}Binding param[{Index}] '{ParamName}' with arg '{ArgType}'", Indent(), i,
                        cand.ParameterTypes[i].Name, argType.Name);
                    if (!TryBindGeneric(cand.ParameterTypes[i], argType, bindings, out var cn, out var ct))
                    {
                        okGen = false;
                        failedBindingIndex = i;
                        if (cn != null)
                        {
                            conflictName = cn;
                            conflictPair = ct;
                        }

                        break;
                    }
                }

                if (!okGen)
                {
                    // Track this as a type mismatch if we don't have one yet
                    // For generic candidates, we report the argument that failed binding
                    if (closestTypeMismatch == null && failedBindingIndex >= 0)
                    {
                        closestTypeMismatch = cand;
                        closestMismatchIndex = failedBindingIndex;
                        closestExpectedType = cand.ParameterTypes[failedBindingIndex].Prune();
                        closestActualType = effectiveArgTypes[failedBindingIndex].Prune();
                    }
                    continue;
                }

                var concreteParams = new List<TypeBase>();
                for (var i = 0; i < cand.ParameterTypes.Count; i++)
                    concreteParams.Add(SubstituteGenerics(cand.ParameterTypes[i], bindings));

                // Re-adapt for coercion cost check using concrete params (not generic params)
                var costCheckArgTypes = ufcsReceiverType != null && effectiveArgTypes.Count > 0 && concreteParams.Count > 0
                    ? TryAdaptUfcsReceiverType(argTypes, concreteParams[0])
                    : effectiveArgTypes;

                if (!TryComputeCoercionCost(costCheckArgTypes, concreteParams, out var genCost))
                {
                    _logger.LogDebug("{Indent}  Coercion cost failed: costCheckArgTypes[0]={Arg}, concreteParams[0]={Param}",
                        Indent(), costCheckArgTypes[0].Prune().Name, concreteParams[0].Prune().Name);
                    continue;
                }

                if (genCost < bestGenericCost)
                {
                    _logger.LogDebug("{Indent}  Setting bestGeneric to '{Name}' with cost {Cost}", Indent(), cand.Name, genCost);
                    bestGeneric = cand;
                    bestBindings = bindings;
                    bestGenericCost = genCost;
                }
            }

            FunctionEntry? chosen;
            Dictionary<string, TypeBase>? chosenBindings = null;

            if (bestNonGeneric != null && (bestGeneric == null || bestNonGenericCost <= bestGenericCost))
            {
                chosen = bestNonGeneric;
            }
            else
            {
                chosen = bestGeneric;
                chosenBindings = bestBindings;
            }

            if (chosen == null)
            {
                if (conflictName != null && conflictPair.HasValue)
                {
                    ReportError(
                        $"conflicting bindings for `{conflictName}`",
                        call.Span,
                        $"`{conflictName}` mapped to `{conflictPair.Value.Existing}` and `{conflictPair.Value.Incoming}`",
                        "E2102");
                }
                else
                {
                    // Build argument type list for error message
                    var argTypeNames = string.Join(", ", argTypes.Select(t => FormatTypeNameForDisplay(t.Prune())));

                    // Check if we have a candidate with matching arg count but type mismatch
                    if (closestTypeMismatch != null && closestMismatchIndex >= 0)
                    {
                        // For UFCS, index 0 is the receiver, explicit args start at 1
                        var argOffset = ufcsReceiverType != null ? 1 : 0;
                        SourceSpan errorSpan;
                        var isReceiverMismatch = ufcsReceiverType != null && closestMismatchIndex == 0;
                        if (isReceiverMismatch)
                        {
                            // Receiver type mismatch
                            errorSpan = call.UfcsReceiver!.Span;
                        }
                        else
                        {
                            // Explicit argument mismatch
                            errorSpan = call.Arguments[closestMismatchIndex - argOffset].Span;
                        }

                        var (expectedDisplay, actualDisplay) = FormatTypePairForDisplay(closestExpectedType!, closestActualType!);

                        if (isReceiverMismatch)
                        {
                            ReportError(
                                $"`{call.MethodName}` expects receiver of type `{expectedDisplay}`",
                                errorSpan,
                                $"expected `{expectedDisplay}`, found `{actualDisplay}`",
                                "E2011");
                        }
                        else
                        {
                            ReportError(
                                $"mismatched types",
                                errorSpan,
                                $"expected `{expectedDisplay}`, found `{actualDisplay}`",
                                "E2011");
                        }
                    }
                    else
                    {
                        // No candidate with matching arg count - report on the call with arg types
                        ReportError(
                            $"no function `{call.FunctionName}` found for arguments `({argTypeNames})`",
                            call.Span,
                            "no matching function signature",
                            "E2011");
                    }
                }

                return TypeRegistry.Never;
            }
            else if (!chosen.IsGeneric)
            {
                // Return actual function return type, not unified type,
                // so that coercion (e.g., T → Option<T>) can be applied by the caller
                var type = chosen.ReturnType;
                if (expectedType != null)
                    UnifyTypes(type, expectedType, call.Span);

                // For UFCS, receiver is at argTypes[0]/paramTypes[0], explicit args start at index 1
                var argOffset = ufcsReceiverType != null ? 1 : 0;

                // Unify receiver type if UFCS (using adapted type for proper value/ref matching)
                if (ufcsReceiverType != null)
                {
                    var adaptedArgTypes = TryAdaptUfcsReceiverType(argTypes, chosen.ParameterTypes[0]);
                    UnifyTypes(adaptedArgTypes[0], chosen.ParameterTypes[0], call.UfcsReceiver!.Span);
                }

                // Unify and wrap explicit arguments
                for (var i = 0; i < call.Arguments.Count; i++)
                {
                    var argIdx = i + argOffset;
                    var unified = UnifyTypes(argTypes[argIdx], chosen.ParameterTypes[argIdx], call.Arguments[i].Span);
                    call.Arguments[i] = WrapWithCoercionIfNeeded(call.Arguments[i], argTypes[argIdx].Prune(), chosen.ParameterTypes[argIdx].Prune());
                }

                call.ResolvedTarget = chosen.AstNode;
                return type;
            }
            else
            {
                var bindings = chosenBindings!;
                if (expectedType != null)
                    RefineBindingsWithExpectedReturn(chosen.ReturnType, expectedType, bindings, call.Span);
                var ret = SubstituteGenerics(chosen.ReturnType, bindings);
                // Unify to check compatibility, but return the actual function return type
                // so that coercion (e.g., T → Option<T>) can be applied by the caller
                if (expectedType != null) UnifyTypes(ret, expectedType, call.Span);
                var type = ret;

                var concreteParams = new List<TypeBase>();
                for (var i = 0; i < chosen.ParameterTypes.Count; i++)
                    concreteParams.Add(SubstituteGenerics(chosen.ParameterTypes[i], bindings));

                // For UFCS, receiver is at index 0, explicit args start at index 1
                var argOffset = ufcsReceiverType != null ? 1 : 0;

                // Re-check deferred anonymous struct arguments with concrete expected types
                foreach (var idx in deferredAnonStructIndices)
                {
                    var argIdx = idx + argOffset;
                    var concreteExpected = concreteParams[argIdx];
                    var argType = CheckExpression(call.Arguments[idx], concreteExpected);
                    if (IsNever(argType)) return TypeRegistry.Never;
                    argTypes[argIdx] = argType;
                    explicitArgTypes[idx] = argType;
                }

                // Unify receiver type if UFCS (using adapted type for proper value/ref matching)
                if (ufcsReceiverType != null)
                {
                    var adaptedArgTypes = TryAdaptUfcsReceiverType(argTypes, concreteParams[0]);
                    UnifyTypes(adaptedArgTypes[0], concreteParams[0], call.UfcsReceiver!.Span);
                }

                // Unify and wrap explicit arguments
                for (var i = 0; i < call.Arguments.Count; i++)
                {
                    var argIdx = i + argOffset;
                    var unified = UnifyTypes(concreteParams[argIdx], argTypes[argIdx], call.Arguments[i].Span);
                    call.Arguments[i] = WrapWithCoercionIfNeeded(call.Arguments[i], argTypes[argIdx].Prune(), concreteParams[argIdx].Prune());
                }

                var specializedNode = EnsureSpecialization(chosen, bindings, concreteParams);
                call.ResolvedTarget = specializedNode;
                _logger.LogDebug("{Indent}  Set ResolvedTarget for '{FuncName}' to '{Target}'",
                    Indent(), call.FunctionName, specializedNode?.Name ?? "null");
                return type;
            }
        }
        else
        {
            // Temporary built-in fallback for C printf without explicit import
            if (functionName == "printf")
            {
                // Check arguments and resolve comptime_int to i32 for variadic args
                var argTypes = new List<TypeBase>();
                for (var i = 0; i < call.Arguments.Count; i++)
                {
                    var argType = CheckExpression(call.Arguments[i]);
                    if (argType.Prune() is ComptimeInt)
                    {
                        // Resolve comptime_int to i32 for variadic functions - unify handles TypeVar propagation
                        var unified = UnifyTypes(argType, TypeRegistry.I32, call.Arguments[i].Span);
                        argTypes.Add(unified);

                        // Wrap argument with coercion node
                        call.Arguments[i] = WrapWithCoercionIfNeeded(call.Arguments[i], argType.Prune(), TypeRegistry.I32);
                    }
                    else
                    {
                        argTypes.Add(argType);
                    }
                }

                call.ResolvedTarget = null;  // printf is a special builtin, no FunctionDeclarationNode
                return TypeRegistry.I32;
            }

            // Check if function name is a variable with function type (indirect call)
            if (TryLookupVariable(functionName, out var varType) && varType.Prune() is FunctionType funcType)
            {
                // Type-check the arguments
                var argTypes = call.Arguments.Select(arg => CheckExpression(arg)).ToList();

                // Check argument count
                if (argTypes.Count != funcType.ParameterTypes.Count)
                {
                    ReportError(
                        $"function expects {funcType.ParameterTypes.Count} argument(s), but {argTypes.Count} were provided",
                        call.Span,
                        $"expected {funcType.ParameterTypes.Count}, got {argTypes.Count}",
                        "E2011");
                    return TypeRegistry.Never;
                }

                // Check argument types - C semantics: exact match required except comptime_int
                // comptime_int can coerce to the expected integer type (handled by UnifyTypes)
                for (var i = 0; i < argTypes.Count; i++)
                {
                    var argTypePruned = argTypes[i].Prune();
                    var paramType = funcType.ParameterTypes[i].Prune();

                    // Allow comptime_int to coerce to the expected integer type
                    // and TypeVar unification for generic contexts
                    if (argTypePruned is ComptimeInt || argTypePruned is TypeVar ||
                        paramType is TypeVar || argTypePruned is GenericParameterType ||
                        paramType is GenericParameterType)
                    {
                        UnifyTypes(argTypes[i], funcType.ParameterTypes[i], call.Arguments[i].Span);
                        // Wrap argument with coercion node if needed
                        call.Arguments[i] = WrapWithCoercionIfNeeded(call.Arguments[i], argTypePruned, paramType);
                    }
                    else if (!argTypePruned.Equals(paramType))
                    {
                        // Exact match required for non-comptime types (C semantics - no integer widening)
                        ReportError(
                            $"mismatched types: expected `{paramType}`, got `{argTypePruned}`",
                            call.Arguments[i].Span,
                            $"expected `{paramType}`",
                            "E2002");
                        return TypeRegistry.Never;
                    }
                }

                // Mark this as an indirect call (ResolvedTarget remains null for indirect calls)
                call.ResolvedTarget = null;
                call.IsIndirectCall = true;
                return funcType.ReturnType;
            }

            ReportError(
                $"cannot find function `{call.MethodName ?? call.FunctionName}` in this scope",
                call.Span,
                "not found in this scope",
                "E2004");
            return TypeRegistry.Never;
        }
    }

    /// <summary>
    /// Handles field-call pattern: receiver.field(args) where field is a function type.
    /// Used for vtable-style patterns.
    /// </summary>
    private TypeBase CheckFieldCall(CallExpressionNode call, FunctionType funcType)
    {
        var fieldArgTypes = call.Arguments.Select(arg => CheckExpression(arg)).ToList();

        if (fieldArgTypes.Count != funcType.ParameterTypes.Count)
        {
            ReportError(
                $"function expects {funcType.ParameterTypes.Count} argument(s), but {fieldArgTypes.Count} were provided",
                call.Span,
                $"expected {funcType.ParameterTypes.Count}, got {fieldArgTypes.Count}",
                "E2011");
            return TypeRegistry.Never;
        }

        for (var i = 0; i < fieldArgTypes.Count; i++)
        {
            var argTypePruned = fieldArgTypes[i].Prune();
            var paramType = funcType.ParameterTypes[i].Prune();

            if (argTypePruned is ComptimeInt || argTypePruned is TypeVar ||
                paramType is TypeVar || argTypePruned is GenericParameterType ||
                paramType is GenericParameterType)
            {
                UnifyTypes(fieldArgTypes[i], funcType.ParameterTypes[i], call.Arguments[i].Span);
                call.Arguments[i] = WrapWithCoercionIfNeeded(call.Arguments[i], argTypePruned, paramType);
            }
            else if (!argTypePruned.Equals(paramType))
            {
                ReportError(
                    $"mismatched types",
                    call.Arguments[i].Span,
                    $"expected `{FormatTypeNameForDisplay(paramType)}`, found `{FormatTypeNameForDisplay(argTypePruned)}`",
                    "E2011");
                return TypeRegistry.Never;
            }
        }

        // Mark as indirect call (UfcsReceiver + MethodName indicate field-call in lowering)
        call.ResolvedTarget = null;
        call.IsIndirectCall = true;
        return funcType.ReturnType;
    }

    private TypeBase CheckExpression(ExpressionNode expression, TypeBase? expectedType = null)
    {
        TypeBase type;
        switch (expression)
        {
            case IntegerLiteralNode lit:
                var tvId = $"lit_{lit.Span.Index}_{_nextLiteralTypeVarId++}";
                type = CreateLiteralTypeVar(tvId, lit.Span, TypeRegistry.ComptimeInt, lit.Value);
                break;
            case BooleanLiteralNode:
                type = TypeRegistry.Bool;
                break;
            case StringLiteralNode strLit:
                type = CheckStringLiteral(strLit);
                break;
            case IdentifierExpressionNode id:
                type = CheckIdentifierExpression(id);
                break;
            case BinaryExpressionNode be:
                type = CheckBinaryExpression(be);
                break;
            case UnaryExpressionNode ue:
                type = CheckUnaryExpression(ue);
                break;
            case AssignmentExpressionNode ae:
                type = CheckAssignmentExpression(ae);
                break;
            case CallExpressionNode call:
                type = CheckCallExpression(call, expectedType);
                break;
            case IfExpressionNode ie:
                {
                    var ct = CheckExpression(ie.Condition);
                    if (IsNever(ct))
                    {
                        type = TypeRegistry.Never;
                        break;
                    }
                    var prunedCt = ct.Prune();
                    if (!prunedCt.Equals(TypeRegistry.Bool))
                        ReportError(
                            "mismatched types",
                            ie.Condition.Span,
                            $"expected `bool`, found `{prunedCt}`",
                            "E2002");
                    var tt = CheckExpression(ie.ThenBranch, expectedType);
                    if (ie.ElseBranch != null)
                    {
                        var et = CheckExpression(ie.ElseBranch, expectedType);
                        type = UnifyTypes(tt, et, ie.Span);
                    }
                    else
                    {
                        type = TypeRegistry.Never;
                    }

                    // Propagate expected type to resolve comptime literals in branches
                    if (expectedType != null && !IsNever(type))
                        type = UnifyTypes(type, expectedType, ie.Span);

                    break;
                }
            case BlockExpressionNode bex:
                {
                    PushScope();
                    TypeBase? last = null;
                    foreach (var s in bex.Statements)
                    {
                        if (s is ExpressionStatementNode es) last = CheckExpression(es.Expression);
                        else
                        {
                            CheckStatement(s);
                            last = null;
                        }
                    }

                    if (bex.TrailingExpression != null) last = CheckExpression(bex.TrailingExpression);
                    PopScope();
                    type = last ?? TypeRegistry.Never;
                    break;
                }
            case RangeExpressionNode re:
                {
                    var st = CheckExpression(re.Start);
                    if (IsNever(st))
                    {
                        type = TypeRegistry.Never;
                        break;
                    }
                    var en = CheckExpression(re.End);
                    if (IsNever(en))
                    {
                        type = TypeRegistry.Never;
                        break;
                    }
                    var prunedSt = st.Prune();
                    var prunedEn = en.Prune();

                    // Validate range bounds are integers
                    if (!TypeRegistry.IsIntegerType(prunedSt) || !TypeRegistry.IsIntegerType(prunedEn))
                    {
                        ReportError("range bounds must be integers", re.Span, $"found `{prunedSt}..{prunedEn}`",
                            "E2002");
                        type = TypeRegistry.Never;
                        break;
                    }

                    // Unify start and end types so they agree
                    UnifyTypes(st, en, re.Span);

                    // Determine the element type for Range(T)
                    var elementType = st.Prune();

                    // Coerce comptime_int to isize as default
                    if (elementType is ComptimeInt)
                    {
                        elementType = TypeRegistry.ISize;
                        UnifyTypes(st, TypeRegistry.ISize, re.Start.Span);
                        UnifyTypes(en, TypeRegistry.ISize, re.End.Span);
                    }

                    type = MakeRangeType(elementType, re.Span);
                    break;
                }
            case MatchExpressionNode match:
                type = CheckMatchExpression(match, expectedType);
                break;
            case AddressOfExpressionNode adr:
                {
                    // Propagate expected type through &: if context expects &T, pass T as expected type
                    TypeBase? innerExpected = expectedType is ReferenceType refExpected ? refExpected.InnerType : null;
                    var tt = CheckExpression(adr.Target, innerExpected);
                    if (IsNever(tt))
                    {
                        type = TypeRegistry.Never;
                        break;
                    }

                    // Check that the target is not a temporary (e.g. anonymous struct literal)
                    if (adr.Target is AnonymousStructExpressionNode)
                    {
                        ReportError(
                            "cannot take address of temporary value",
                            adr.Span,
                            "consider assigning to a variable first",
                            "E2040");
                        type = TypeRegistry.Never;
                        break;
                    }

                    type = new ReferenceType(tt);
                    break;
                }
            case DereferenceExpressionNode dr:
                {
                    var pt = CheckExpression(dr.Target);
                    if (IsNever(pt))
                    {
                        type = TypeRegistry.Never;
                        break;
                    }
                    var prunedPt = pt.Prune();
                    if (prunedPt is ReferenceType rft) type = rft.InnerType;
                    else if (prunedPt is StructType opt && TypeRegistry.IsOption(opt) && opt.TypeArguments.Count > 0 &&
                             opt.TypeArguments[0] is ReferenceType rf2) type = rf2.InnerType;
                    else
                    {
                        ReportError(
                            "cannot dereference non-reference type",
                            dr.Span,
                            $"expected `&T` or `&T?`, found `{prunedPt}`",
                            "E2012");
                        type = TypeRegistry.Never;
                    }

                    break;
                }
            case MemberAccessExpressionNode ma:
                type = CheckMemberAccessExpression(ma, expectedType);
                break;
            case StructConstructionExpressionNode sc:
                {
                    var resolvedType = ResolveTypeNode(sc.TypeName);
                    StructType? optionLiteral = null;
                    if (resolvedType is StructType optStruct && TypeRegistry.IsOption(optStruct))
                    {
                        optionLiteral = optStruct;
                        resolvedType = optStruct; // Already a StructType
                    }

                    if (resolvedType == null)
                    {
                        ReportError(
                            $"cannot find type `{(sc.TypeName as NamedTypeNode)?.Name ?? "unknown"}`",
                            sc.TypeName.Span,
                            "not found in this scope",
                            "E2003");
                        type = TypeRegistry.Never;
                        break;
                    }

                    if (resolvedType is GenericType genericType)
                        resolvedType = InstantiateStruct(genericType, sc.Span);

                    if (resolvedType is StructType optFromGeneric && TypeRegistry.IsOption(optFromGeneric))
                    {
                        optionLiteral = optFromGeneric;
                        resolvedType = optFromGeneric; // Already a StructType
                    }

                    if (resolvedType is not StructType st)
                    {
                        ReportError(
                            $"type `{resolvedType.Name}` is not a struct",
                            sc.TypeName.Span,
                            "cannot construct non-struct type",
                            "E2018");
                        type = TypeRegistry.I32;
                        break;
                    }

                    ValidateStructLiteralFields(st, sc.Fields, sc.Span);

                    // Ensure no missing fields
                    var provided = new HashSet<string>();
                    foreach (var (fieldName, fieldExpr) in sc.Fields)
                    {
                        provided.Add(fieldName);
                        var fieldType = st.GetFieldType(fieldName);
                        if (fieldType == null)
                        {
                            ReportError(
                                $"struct `{st.Name}` does not have a field named `{fieldName}`",
                                fieldExpr.Span,
                                "unknown field",
                                "E2014");
                            continue;
                        }

                        var valueType = CheckExpression(fieldExpr, fieldType);
                        // Unify field value with field type - TypeVar.Prune() handles propagation
                        var unified = UnifyTypes(valueType, fieldType, fieldExpr.Span);
                    }

                    foreach (var (fieldName, _) in st.Fields)
                        if (!provided.Contains(fieldName))
                            ReportError(
                                $"missing field `{fieldName}` in struct construction",
                                sc.Span,
                                $"struct `{st.Name}` requires field `{fieldName}`",
                                "E2019");
                    type = optionLiteral ?? st;
                    break;
                }
            case AnonymousStructExpressionNode anon:
                {
                    // Unwrap ReferenceType to find the underlying struct type
                    var unwrappedExpected = expectedType is ReferenceType refType ? refType.InnerType : expectedType;
                    StructType? structType = unwrappedExpected switch
                    {
                        StructType st => st,
                        GenericType gt => InstantiateStruct(gt, anon.Span),
                        _ => null
                    };

                    if (structType == null)
                    {
                        // No expected type - infer field types from values (tuple case)
                        // This enables tuples like (10, 20) without type annotation
                        var inferredFields = new List<(string Name, TypeBase Type)>();
                        bool inferenceSucceeded = true;

                        foreach (var (fieldName, fieldValue) in anon.Fields)
                        {
                            var fieldType = CheckExpression(fieldValue);

                            // Handle comptime types: default comptime_int to i32 for tuples
                            var prunedType = fieldType is TypeVar tv ? tv.Prune() : fieldType;
                            if (prunedType is ComptimeInt)
                            {
                                // Unify the TypeVar with i32 to resolve the comptime_int
                                fieldType = UnifyTypes(fieldType, TypeRegistry.I32, fieldValue.Span) ?? TypeRegistry.I32;
                            }
                            else if (fieldType == TypeRegistry.Never)
                            {
                                inferenceSucceeded = false;
                            }

                            inferredFields.Add((fieldName, fieldType));
                        }

                        if (!inferenceSucceeded)
                        {
                            ReportError(
                                "cannot infer type of anonymous struct/tuple literal",
                                anon.Span,
                                "add a type annotation",
                                "E2018");
                            type = TypeRegistry.Never;
                            break;
                        }

                        // Create an anonymous struct type from inferred fields
                        structType = new StructType("", typeArguments: null, fields: inferredFields);
                        _compilation.InstantiatedTypes.Add(structType);
                    }
                    else
                    {
                        ValidateStructLiteralFields(structType, anon.Fields, anon.Span);
                    }

                    anon.Type = structType;

                    if (TypeRegistry.IsOption(expectedType))
                        type = expectedType;
                    else
                        type = structType;

                    break;
                }

            case NullLiteralNode nullLiteral:
                {
                    // Infer Option type from context
                    var innerType = expectedType switch
                    {
                        StructType st when TypeRegistry.IsOption(st) => st.TypeArguments[0],
                        _ => null
                    };

                    if (innerType == null)
                    {
                        ReportError(
                            "cannot infer type of null literal",
                            nullLiteral.Span,
                            "add an option type annotation or use an explicit constructor",
                            "E2001");
                        type = TypeRegistry.Never; // Fallback
                    }
                    else
                    {
                        type = TypeRegistry.MakeOption(innerType);
                    }

                    break;
                }
            case ArrayLiteralExpressionNode al:
                {
                    if (al.IsRepeatSyntax)
                    {
                        var rv = CheckExpression(al.RepeatValue!);
                        type = new ArrayType(rv, al.RepeatCount!.Value);
                    }
                    else if (al.Elements!.Count == 0)
                    {
                        ReportError(
                            "cannot infer type of empty array literal",
                            al.Span,
                            "consider adding type annotation",
                            "E2026");
                        type = new ArrayType(TypeRegistry.Never, 0);
                    }
                    else
                    {
                        var first = CheckExpression(al.Elements[0]);
                        var unified = first;
                        for (var i = 1; i < al.Elements.Count; i++)
                        {
                            var et = CheckExpression(al.Elements[i]);
                            unified = UnifyTypes(unified, et, al.Elements[i].Span);
                        }

                        type = new ArrayType(unified, al.Elements.Count);
                    }

                    break;
                }
            case IndexExpressionNode ix:
                {
                    var bt = CheckExpression(ix.Base);
                    if (IsNever(bt))
                    {
                        type = TypeRegistry.Never;
                        break;
                    }
                    var it = CheckExpression(ix.Index);
                    if (IsNever(it))
                    {
                        type = TypeRegistry.Never;
                        break;
                    }

                    // For struct types (slices, custom types), look up op_index function
                    // Arrays use built-in indexing (no op_index lookup)
                    var prunedBt = bt.Prune();
                    if (prunedBt is StructType structTypeForIndex)
                    {
                        // Try with &T first (op_index(base: &T, index: I) R)
                        var refBaseType = new ReferenceType(structTypeForIndex);
                        var opIndexResult = TryResolveOperatorFunction("op_index", refBaseType, it, ix.Span);

                        // Also try with value T (op_index(base: T, index: I) R)
                        if (opIndexResult == null)
                            opIndexResult = TryResolveOperatorFunction("op_index", prunedBt, it, ix.Span);

                        if (opIndexResult != null)
                        {
                            // Use op_index function
                            ix.ResolvedIndexFunction = opIndexResult.Value.Function;
                            type = opIndexResult.Value.ReturnType;

                            // Resolve comptime_int index to the parameter's concrete type
                            var resolvedFunc = opIndexResult.Value.Function;
                            if (resolvedFunc.Parameters.Count >= 2)
                            {
                                var indexParamType = resolvedFunc.Parameters[1].ResolvedType;
                                if (indexParamType != null)
                                    UnifyTypes(it, indexParamType, ix.Index.Span);
                            }

                            break;
                        }

                        // op_index not found — check WHY
                        if (_functions.TryGetValue("op_index", out var indexCandidates))
                        {
                            var matchingBaseCandidates = indexCandidates
                                .Where(c => c.ParameterTypes.Count == 2 &&
                                       (_unificationEngine.CanUnify(c.ParameterTypes[0], structTypeForIndex) ||
                                        _unificationEngine.CanUnify(c.ParameterTypes[0], new ReferenceType(structTypeForIndex))))
                                .ToList();

                            if (matchingBaseCandidates.Count > 0)
                            {
                                // Type IS indexable, but not with this index type
                                var indexTypeName = FormatTypeNameForDisplay(it.Prune());
                                var baseTypeName = FormatTypeNameForDisplay(structTypeForIndex);

                                var acceptedTypes = matchingBaseCandidates
                                    .Select(c => FormatTypeNameForDisplay(c.ParameterTypes[1]))
                                    .Distinct().ToList();
                                var typeList = acceptedTypes.Count <= 3
                                    ? string.Join(", ", acceptedTypes.Select(t => $"`{t}`"))
                                    : string.Join(", ", acceptedTypes.Take(3).Select(t => $"`{t}`")) + ", ...";

                                ReportError(
                                    $"type `{baseTypeName}` cannot be indexed by value of type `{indexTypeName}`",
                                    ix.Index.Span,
                                    $"expected {typeList}",
                                    "E2028");
                                type = TypeRegistry.Never;
                                break;
                            }
                        }

                        // No op_index for this type at all — fall through to array/slice check
                    }

                    // Built-in array/slice indexing with usize
                    var prunedIt = it.Prune();

                    if (!TypeRegistry.IsIntegerType(prunedIt))
                    {
                        ReportError(
                            "array index must be an integer",
                            ix.Index.Span,
                            $"found `{prunedIt}`",
                            "E2027");
                    }
                    else if (prunedIt is ComptimeInt)
                    {
                        // Resolve comptime_int indices to usize for built-in indexing
                        UnifyTypes(it, TypeRegistry.USize, ix.Index.Span);
                    }

                    if (bt is ArrayType at) type = at.ElementType;
                    else if (bt is StructType st && TypeRegistry.IsSlice(st)) type = st.TypeArguments[0];
                    else
                    {
                        ReportError(
                            $"type `{bt}` does not support indexing",
                            ix.Base.Span,
                            "define `op_index` to enable indexing",
                            "E2028");
                        type = TypeRegistry.Never;
                    }

                    break;
                }
            case CastExpressionNode c:
                {
                    var src = CheckExpression(c.Expression);
                    var dst = ResolveTypeNode(c.TargetType) ?? TypeRegistry.Never;
                    if (!CanExplicitCast(src, dst))
                        ReportError(
                            "invalid cast",
                            c.Span,
                            $"cannot cast `{src}` to `{dst}`",
                            "E2020");

                    // When casting comptime_int to a concrete integer type, update the TypeVar
                    // so the literal gets properly resolved
                    if (src is TypeVar srcTv && srcTv.Prune() is ComptimeInt && TypeRegistry.IsIntegerType(dst))
                        srcTv.Instance = dst;

                    type = dst;
                    break;
                }
            case CoalesceExpressionNode coalesce:
                type = CheckCoalesceExpression(coalesce);
                break;
            case NullPropagationExpressionNode nullProp:
                type = CheckNullPropagationExpression(nullProp);
                break;
            default:
                throw new Exception($"Unknown expression type: {expression.GetType().Name}");
        }

        type = ApplyOptionExpectation(expression, type, expectedType);
        expression.Type = type;
        return type;
    }

    private TypeBase ApplyOptionExpectation(ExpressionNode expression, TypeBase type, TypeBase? expectedType)
    {
        if (expectedType is StructType expectedOption && TypeRegistry.IsOption(expectedOption))
        {
            if (type is StructType actualOption && TypeRegistry.IsOption(actualOption))
            {
                if (actualOption.TypeArguments.Count > 0 && expectedOption.TypeArguments.Count > 0 &&
                    !actualOption.TypeArguments[0].Equals(expectedOption.TypeArguments[0]))
                {
                    ReportError(
                        "mismatched option types",
                        expression.Span,
                        $"expected `{expectedOption}`, found `{actualOption}`",
                        "E2002");
                }

                return expectedOption;
            }

            // NOTE: Do NOT change type from T to Option<T> here!
            // The actual coercion (wrapping T in Option) must be done via WrapWithCoercionIfNeeded
            // which creates an ImplicitCoercionNode. If we change the type here without a coercion node,
            // the lowering phase will emit code that assigns T to Option<T> directly, causing C errors.
            // Just return the actual type and let the caller handle coercion.
        }

        return type;
    }

    /// <summary>
    /// Wraps an expression in an ImplicitCoercionNode if a coercion from sourceType to targetType is needed.
    /// Returns the original expression if no coercion is needed, or a new ImplicitCoercionNode wrapping it.
    /// </summary>
    private ExpressionNode WrapWithCoercionIfNeeded(ExpressionNode expr, TypeBase sourceType, TypeBase targetType)
    {
        // No coercion needed if types are equal
        if (sourceType.Equals(targetType))
            return expr;

        // Determine the coercion kind
        CoercionKind? kind = DetermineCoercionKind(sourceType, targetType);
        if (kind == null)
            return expr; // No coercion applicable

        // Create and return the coercion node
        var coercionNode = new ImplicitCoercionNode(expr.Span, expr, targetType, kind.Value);
        return coercionNode;
    }

    /// <summary>
    /// Determines the coercion kind for converting from sourceType to targetType.
    /// Returns null if no coercion is applicable.
    /// The type system has already validated these coercions are valid.
    /// </summary>
    private static CoercionKind? DetermineCoercionKind(TypeBase sourceType, TypeBase targetType)
    {
        // Option wrapping: T → Option(T)
        if (targetType is StructType optionTarget && TypeRegistry.IsOption(optionTarget))
        {
            if (optionTarget.TypeArguments.Count > 0 && sourceType.Equals(optionTarget.TypeArguments[0]))
                return CoercionKind.Wrap;

            // Also handle comptime_int → Option(intType): this is Wrap (will harden inside)
            if (optionTarget.TypeArguments.Count > 0 &&
                sourceType is ComptimeInt &&
                TypeRegistry.IsIntegerType(optionTarget.TypeArguments[0]))
                return CoercionKind.Wrap;
        }

        // Integer widening (includes comptime_int hardening)
        if (sourceType is ComptimeInt && TypeRegistry.IsIntegerType(targetType))
            return CoercionKind.IntegerWidening;

        if (TypeRegistry.IsIntegerType(sourceType) && TypeRegistry.IsIntegerType(targetType))
            return CoercionKind.IntegerWidening;

        // Binary-compatible reinterpret casts:
        // - String ↔ Slice(u8)
        // - [T; N] → Slice(T) or &T
        // - &[T; N] → Slice(T) or &T
        // - Slice(T) → &T

        // String to byte slice (binary compatible)
        if (sourceType is StructType ss && TypeRegistry.IsString(ss) &&
            targetType is StructType ts && TypeRegistry.IsSlice(ts) &&
            ts.TypeArguments.Count > 0 && ts.TypeArguments[0].Equals(TypeRegistry.U8))
            return CoercionKind.ReinterpretCast;

        // Array decay: [T; N] → &T or [T; N] → Slice(T)
        if (sourceType is ArrayType)
        {
            if (targetType is ReferenceType)
                return CoercionKind.ReinterpretCast;
            if (targetType is StructType sliceTarget && TypeRegistry.IsSlice(sliceTarget))
                return CoercionKind.ReinterpretCast;
        }

        // Reference to array decay: &[T; N] → Slice(T) or &[T; N] → &T
        if (sourceType is ReferenceType { InnerType: ArrayType })
        {
            if (targetType is StructType sliceTarget && TypeRegistry.IsSlice(sliceTarget))
                return CoercionKind.ReinterpretCast;
            if (targetType is ReferenceType)
                return CoercionKind.ReinterpretCast;
        }

        // Slice to reference
        if (sourceType is StructType sliceSource && TypeRegistry.IsSlice(sliceSource) &&
            targetType is ReferenceType refTarget &&
            sliceSource.TypeArguments.Count > 0 &&
            sliceSource.TypeArguments[0].Equals(refTarget.InnerType))
            return CoercionKind.ReinterpretCast;

        return null;
    }

    private bool CanExplicitCast(TypeBase source, TypeBase target)
    {
        // Prune TypeVars to get their actual types (e.g., TypeVar bound to comptime_int)
        source = source.Prune();
        target = target.Prune();

        if (source.Equals(target)) return true;
        if (TypeRegistry.IsIntegerType(source) && TypeRegistry.IsIntegerType(target)) return true;
        // XXX get rest seems like Unification
        if (source is ReferenceType && target is ReferenceType) return true;
        if (source is StructType opt && TypeRegistry.IsOption(opt) && opt.TypeArguments.Count > 0 &&
            opt.TypeArguments[0] is ReferenceType && target is ReferenceType) return true;
        if (source is ReferenceType &&
            (target.Equals(TypeRegistry.USize) || target.Equals(TypeRegistry.ISize))) return true;
        if ((source.Equals(TypeRegistry.USize) || source.Equals(TypeRegistry.ISize)) &&
            target is ReferenceType) return true;

        // String is the canonical u8[] struct type, bidirectionally compatible
        bool IsU8Slice(TypeBase t) =>
            (t is StructType strt && TypeRegistry.IsString(strt)) ||
            (t is StructType strt2 && TypeRegistry.IsSlice(strt2) && strt2.TypeArguments.Count > 0 &&
             strt2.TypeArguments[0].Equals(TypeRegistry.U8));

        if (source is StructType ss && TypeRegistry.IsString(ss) && IsU8Slice(target)) return true;
        if (target is StructType ts && TypeRegistry.IsString(ts) && IsU8Slice(source)) return true;

        // Array -> Slice casts (view cast)
        if (source is ArrayType arr)
        {
            if (target is StructType slice && TypeRegistry.IsSlice(slice) &&
                _unificationEngine.CanUnify(arr.ElementType, slice.TypeArguments[0]))
                return true;
            // Check if target is a Slice struct (canonical representation)
            if (target is StructType sliceStruct && TypeRegistry.IsSlice(sliceStruct))
                return true; // Can cast array to any slice struct

            // Unsafe cast: [T; N] → &u8 for low-level memory operations (e.g., memcpy)
            if (target is ReferenceType { InnerType: PrimitiveType { Name: "u8" } })
                return true;
        }

        return false;
    }

    public TypeBase? ResolveTypeNode(TypeNode? typeNode)
    {
        if (typeNode == null) return null;
        var type = ResolveTypeNodeInternal(typeNode);
        if (type != null && _currentBindings != null)
        {
            return SubstituteGenerics(type, _currentBindings);
        }

        return type;
    }

    private TypeBase? ResolveTypeNodeInternal(TypeNode? typeNode)
    {
        if (typeNode == null) return null;
        switch (typeNode)
        {
            case NamedTypeNode named:
                {
                    if (IsGenericNameInScope(named.Name))
                        return new GenericParameterType(named.Name);

                    var bt = TypeRegistry.GetTypeByName(named.Name);
                    if (bt != null)
                    {
                        // Track primitive type usage (but not Type itself)
                        if (bt is not StructType { StructName: "Type" })
                        {
                            _compilation.InstantiatedTypes.Add(bt);
                        }

                        return bt;
                    }

                    // Use ResolveTypeName to handle both FQN and short names
                    var resolvedType = ResolveTypeName(named.Name);
                    if (resolvedType != null)
                    {
                        // Track non-Type struct usage
                        if (!TypeRegistry.IsType(resolvedType))
                        {
                            _compilation.InstantiatedTypes.Add(resolvedType);
                        }

                        return resolvedType;
                    }

                    if (named.Name.Length == 1 && char.IsUpper(named.Name[0]))
                        return new GenericParameterType(named.Name);
                    ReportError(
                        $"cannot find type `{named.Name}` in this scope",
                        named.Span,
                        "not found in this scope",
                        "E2003");
                    return null;
                }
            case GenericParameterTypeNode gp:
                return new GenericParameterType(gp.Name);
            case ReferenceTypeNode rt:
                {
                    var inner = ResolveTypeNode(rt.InnerType);
                    if (inner == null) return null;
                    // Disallow &fn(...) - function types are already pointer-sized
                    if (inner is FunctionType)
                    {
                        ReportError(
                            "cannot create reference to function type",
                            rt.Span,
                            "function types are already pointer-sized; use `fn(...)` directly",
                            "E2006");
                        return null;
                    }
                    return new ReferenceType(inner);
                }
            case NullableTypeNode nt:
                {
                    var inner = ResolveTypeNode(nt.InnerType);
                    if (inner == null) return null;
                    return TypeRegistry.MakeOption(inner);
                }
            case GenericTypeNode gt:
                {
                    var args = new List<TypeBase>();
                    foreach (var a in gt.TypeArguments)
                    {
                        var at = ResolveTypeNode(a);
                        if (at == null) return null;
                        args.Add(at);
                    }

                    // Resolve the base type name (might be short name or FQN)
                    var baseType = ResolveTypeName(gt.Name);

                    // Special case for Type(T) - check using TypeRegistry
                    if (baseType is StructType st && TypeRegistry.IsType(st))
                    {
                        if (args.Count != 1)
                        {
                            ReportError(
                                "`Type` expects exactly one type argument",
                                gt.Span,
                                "usage: Type(T)",
                                "E2006");
                            return null;
                        }

                        // Do NOT track Type(T) instantiations!
                        return TypeRegistry.MakeType(args[0]);
                    }

                    // Special case for Option(T)
                    if (baseType is StructType st2 && TypeRegistry.IsOption(st2))
                    {
                        if (args.Count != 1)
                        {
                            ReportError(
                                "`Option` expects exactly one type argument",
                                gt.Span,
                                "usage: Option(T)",
                                "E2006");
                            return null;
                        }

                        return TypeRegistry.MakeOption(args[0]);
                    }

                    // General generic struct/enum instantiation
                    if (baseType is StructType structTemplate)
                    {
                        // Track generic struct instantiation
                        var instantiated = InstantiateStruct(structTemplate, args, gt.Span);
                        _compilation.InstantiatedTypes.Add(instantiated);
                        return instantiated;
                    }
                    else if (baseType is EnumType enumTemplate)
                    {
                        // Track generic enum instantiation
                        var instantiated = InstantiateEnum(enumTemplate, args, gt.Span);
                        _compilation.InstantiatedTypes.Add(instantiated);
                        return instantiated;
                    }
                    else
                    {
                        ReportError(
                            $"cannot find generic type `{gt.Name}`",
                            gt.Span,
                            "not found in this scope",
                            "E2003");
                        return null;
                    }
                }
            case ArrayTypeNode arr:
                {
                    var et = ResolveTypeNode(arr.ElementType);
                    if (et == null) return null;
                    return new ArrayType(et, arr.Length);
                }
            case SliceTypeNode sl:
                {
                    var et = ResolveTypeNode(sl.ElementType);
                    if (et == null) return null;
                    return MakeSliceType(et, sl.Span);
                }
            case FunctionTypeNode ft:
                {
                    var paramTypes = new List<TypeBase>();
                    foreach (var pt in ft.ParameterTypes)
                    {
                        var resolved = ResolveTypeNode(pt);
                        if (resolved == null) return null;
                        paramTypes.Add(resolved);
                    }
                    var returnType = ResolveTypeNode(ft.ReturnType);
                    if (returnType == null) return null;
                    return new FunctionType(paramTypes, returnType);
                }
            case AnonymousStructTypeNode ast:
                {
                    // Anonymous struct type (used for tuple types like (T1, T2) -> { _0: T1, _1: T2 })
                    var fields = new List<(string Name, TypeBase Type)>();
                    foreach (var (fieldName, fieldTypeNode) in ast.Fields)
                    {
                        var fieldType = ResolveTypeNode(fieldTypeNode);
                        if (fieldType == null) return null;
                        fields.Add((fieldName, fieldType));
                    }
                    // Create an anonymous struct type (empty name for anonymous struct)
                    var anonStruct = new StructType("", typeArguments: null, fields: fields);
                    _compilation.InstantiatedTypes.Add(anonStruct);
                    return anonStruct;
                }
            default:
                return null;
        }
    }

    public StructType? InstantiateStruct(GenericType genericType, SourceSpan span)
    {
        if (!_compilation.Structs.TryGetValue(genericType.BaseName, out var template))
            return null;
        return InstantiateStruct(template, genericType.TypeArguments, span);
    }

    private StructType InstantiateStruct(StructType template, IReadOnlyList<TypeBase> typeArgs, SourceSpan span)
    {
        if (template.TypeArguments.Count != typeArgs.Count)
        {
            ReportError(
                $"struct `{template.StructName}` expects {template.TypeArguments.Count} type parameter(s)",
                span,
                $"provided {typeArgs.Count}",
                "E2006");
            return template;
        }

        var key = BuildStructSpecKey(template.StructName, typeArgs);
        if (_compilation.StructSpecializations.TryGetValue(key, out var cached))
            return cached;

        // Build bindings from GenericParameterType names to concrete types
        var bindings = new Dictionary<string, TypeBase>();
        for (var i = 0; i < template.TypeArguments.Count; i++)
        {
            if (template.TypeArguments[i] is GenericParameterType gp)
                bindings[gp.ParamName] = typeArgs[i];
        }

        var specializedFields = new List<(string Name, TypeBase Type)>();
        foreach (var (fieldName, fieldType) in template.Fields)
        {
            var specializedType = SubstituteGenerics(fieldType, bindings);
            specializedFields.Add((fieldName, specializedType));
        }

        // Create specialized struct with concrete type arguments
        var specialized = new StructType(template.StructName, typeArgs.ToList(), specializedFields);
        _compilation.StructSpecializations[key] = specialized;
        return specialized;
    }

    /// <summary>
    /// Creates a Slice(T) type using the stdlib Slice struct template.
    /// Uses the normal generic instantiation infrastructure instead of hardcoded fields.
    /// </summary>
    public StructType MakeSliceType(TypeBase elementType, SourceSpan span)
    {
        // Look up the Slice template from core.slice
        if (!_compilation.StructsByFqn.TryGetValue("core.slice.Slice", out var sliceTemplate))
        {
            // Fallback to TypeRegistry if stdlib not loaded (e.g., during early bootstrap)
            return TypeRegistry.MakeSlice(elementType);
        }

        var instantiated = InstantiateStruct(sliceTemplate, [elementType], span);
        _compilation.InstantiatedTypes.Add(instantiated);
        return instantiated;
    }

    /// <summary>
    /// Creates a Range(T) type using the stdlib Range struct template.
    /// Uses the normal generic instantiation infrastructure instead of hardcoded fields.
    /// </summary>
    public StructType MakeRangeType(TypeBase elementType, SourceSpan span)
    {
        // Look up the Range template from core.range
        if (!_compilation.StructsByFqn.TryGetValue("core.range.Range", out var rangeTemplate))
        {
            // Fallback to TypeRegistry if stdlib not loaded (e.g., during early bootstrap)
            return TypeRegistry.MakeRange(elementType);
        }

        var instantiated = InstantiateStruct(rangeTemplate, [elementType], span);
        _compilation.InstantiatedTypes.Add(instantiated);
        return instantiated;
    }

    private EnumType InstantiateEnum(EnumType template, IReadOnlyList<TypeBase> typeArgs, SourceSpan span)
    {
        if (template.TypeArguments.Count != typeArgs.Count)
        {
            ReportError(
                $"enum `{template.Name}` expects {template.TypeArguments.Count} type parameter(s)",
                span,
                $"provided {typeArgs.Count}",
                "E2006");
            return template;
        }

        var key = BuildStructSpecKey(template.Name, typeArgs);
        if (_compilation.EnumSpecializations.TryGetValue(key, out var cached))
            return cached;

        // Build bindings from GenericParameterType names to concrete types
        var bindings = new Dictionary<string, TypeBase>();
        for (var i = 0; i < template.TypeArguments.Count; i++)
        {
            if (template.TypeArguments[i] is GenericParameterType gp)
                bindings[gp.ParamName] = typeArgs[i];
        }

        var specializedVariants = new List<(string VariantName, TypeBase? PayloadType)>();
        foreach (var (variantName, payloadType) in template.Variants)
        {
            var specializedPayload = payloadType != null
                ? SubstituteGenerics(payloadType, bindings)
                : null;
            specializedVariants.Add((variantName, specializedPayload));
        }

        // Create specialized enum with concrete type arguments
        var specialized = new EnumType(template.Name, typeArgs.ToList(), specializedVariants);
        _compilation.EnumSpecializations[key] = specialized;
        return specialized;
    }

    private void ValidateStructLiteralFields(StructType structType,
        IReadOnlyList<(string FieldName, ExpressionNode Value)> fields, SourceSpan span)
    {
        var provided = new HashSet<string>();
        foreach (var (fieldName, expr) in fields)
        {
            provided.Add(fieldName);
            var fieldType = structType.GetFieldType(fieldName);
            if (fieldType == null)
            {
                ReportError(
                    $"struct `{structType.Name}` does not have a field named `{fieldName}`",
                    expr.Span,
                    "unknown field",
                    "E2014");
                continue;
            }

            var valueType = CheckExpression(expr, fieldType);
            // Unify field value with field type - TypeVar.Prune() handles propagation
            var unified = UnifyTypes(valueType, fieldType, expr.Span);
        }

        foreach (var (fieldName, _) in structType.Fields)
            if (!provided.Contains(fieldName))
                ReportError(
                    $"missing field `{fieldName}` in struct construction",
                    span,
                    $"struct `{structType.Name}` requires field `{fieldName}`",
                    "E2015");
    }

    private static HashSet<string> CollectGenericParamNames(FunctionDeclarationNode fn)
    {
        var set = new HashSet<string>();

        foreach (var p in fn.Parameters) Visit(p.Type);
        Visit(fn.ReturnType);
        return set;

        void Visit(TypeNode? n)
        {
            if (n == null) return;
            switch (n)
            {
                case GenericParameterTypeNode gp:
                    set.Add(gp.Name); break;
                case ReferenceTypeNode r:
                    Visit(r.InnerType); break;
                case NullableTypeNode nn:
                    Visit(nn.InnerType); break;
                case ArrayTypeNode a:
                    Visit(a.ElementType); break;
                case SliceTypeNode s:
                    Visit(s.ElementType); break;
                case GenericTypeNode g:
                    foreach (var t in g.TypeArguments) Visit(t);
                    break;
                case FunctionTypeNode ft:
                    foreach (var pt in ft.ParameterTypes) Visit(pt);
                    Visit(ft.ReturnType);
                    break;
            }
        }
    }

    private TypeBase UnifyTypes(TypeBase a, TypeBase b, SourceSpan span)
    {
        var result = _unificationEngine.Unify(a, b, span);

        // Copy diagnostics from unification engine to type checker
        foreach (var diag in _unificationEngine.Diagnostics)
            _diagnostics.Add(diag);

        // Clear diagnostics in unification engine to avoid duplication
        _unificationEngine.ClearDiagnostics();

        return result;
    }

    private void RefineBindingsWithExpectedReturn(TypeBase template, TypeBase expected,
        Dictionary<string, TypeBase> bindings, SourceSpan span)
    {
        if (template is GenericParameterType gp)
        {
            if (bindings.TryGetValue(gp.ParamName, out var existing))
                bindings[gp.ParamName] = UnifyTypes(existing, expected, span);
            else
                bindings[gp.ParamName] = expected;
            return;
        }

        switch (template)
        {
            case ReferenceType rt when expected is ReferenceType expectedRef:
                RefineBindingsWithExpectedReturn(rt.InnerType, expectedRef.InnerType, bindings, span);
                break;
            case ArrayType at when expected is ArrayType expectedArray && at.Length == expectedArray.Length:
                RefineBindingsWithExpectedReturn(at.ElementType, expectedArray.ElementType, bindings, span);
                break;
            case StructType st when TypeRegistry.IsSlice(st) &&
                                    expected is StructType expectedSlice &&
                                    TypeRegistry.IsSlice(expectedSlice):
                if (st.TypeArguments.Count > 0 && expectedSlice.TypeArguments.Count > 0)
                    RefineBindingsWithExpectedReturn(st.TypeArguments[0], expectedSlice.TypeArguments[0], bindings,
                        span);
                break;
            case StructType ot when TypeRegistry.IsOption(ot) &&
                                    expected is StructType expectedOption &&
                                    TypeRegistry.IsOption(expectedOption):
                if (ot.TypeArguments.Count > 0 && expectedOption.TypeArguments.Count > 0)
                    RefineBindingsWithExpectedReturn(ot.TypeArguments[0], expectedOption.TypeArguments[0], bindings,
                        span);
                break;
            case StructType st when expected is StructType expectedStruct && st.StructName == expectedStruct.StructName:
                RefineStructBindings(st, expectedStruct, bindings, span);
                break;
        }
    }

    private void RefineStructBindings(StructType template, StructType expected, Dictionary<string, TypeBase> bindings,
        SourceSpan span)
    {
        // First, match type arguments
        // e.g., matching Type<i32> with Type<$T> should bind $T to i32
        if (template.TypeArguments.Count == expected.TypeArguments.Count)
        {
            for (int i = 0; i < template.TypeArguments.Count; i++)
            {
                // If template has a generic parameter, bind it to the expected concrete type
                if (template.TypeArguments[i] is GenericParameterType gp)
                {
                    bindings[gp.ParamName] = expected.TypeArguments[i];
                }
            }
        }

        // Then, match fields
        var expectedFields = new Dictionary<string, TypeBase>();
        foreach (var (name, type) in expected.Fields)
            expectedFields[name] = type;

        foreach (var (fieldName, fieldType) in template.Fields)
        {
            if (!expectedFields.TryGetValue(fieldName, out var expectedFieldType))
                continue;
            RefineBindingsWithExpectedReturn(fieldType, expectedFieldType, bindings, span);
        }
    }

    /// <summary>
    /// Verifies that all literal TypeVars have been resolved to concrete types.
    /// Reports E2001 errors for any that remain as comptime types.
    /// Reports E2029 errors for literals out of range for their inferred type.
    /// </summary>
    public void VerifyAllTypesResolved()
    {
        foreach (var (tv, value) in _literalTypeVars)
        {
            var finalType = tv.Prune();

            // If still a comptime type after pruning, it wasn't resolved
            if (TypeRegistry.IsComptimeType(finalType))
            {
                ReportError(
                    "cannot infer concrete type for literal",
                    tv.DeclarationSpan ?? new SourceSpan(0, 0, 0),
                    "use the literal in a context that requires a specific type or add a type annotation",
                    "E2001");
            }
            else if (finalType is PrimitiveType pt && TypeRegistry.IsIntegerType(pt))
            {
                if (!FitsInType(value, pt))
                {
                    var (min, max) = GetIntegerRange(pt);
                    ReportError(
                        $"literal value `{value}` out of range for `{pt.Name}`",
                        tv.DeclarationSpan ?? new SourceSpan(0, 0, 0),
                        $"valid range: {min}..{max}",
                        "E2029");
                }
            }
        }
    }

    /// <summary>
    /// Checks if a type is the Never type (indicating a previous error).
    /// Used for early-exit to prevent cascading type errors.
    /// </summary>
    private static bool IsNever(TypeBase type) =>
        ReferenceEquals(type.Prune(), TypeRegistry.Never);

    private static bool FitsInType(long value, PrimitiveType pt) => pt.Name switch
    {
        "i8" => value >= sbyte.MinValue && value <= sbyte.MaxValue,
        "i16" => value >= short.MinValue && value <= short.MaxValue,
        "i32" => value >= int.MinValue && value <= int.MaxValue,
        "i64" => true,
        "u8" => value >= 0 && value <= byte.MaxValue,
        "u16" => value >= 0 && value <= ushort.MaxValue,
        "u32" => value >= 0 && value <= uint.MaxValue,
        "u64" => value >= 0,
        "isize" => true,
        "usize" => value >= 0,
        _ => true
    };

    private static (long min, long max) GetIntegerRange(PrimitiveType pt) => pt.Name switch
    {
        "i8" => (sbyte.MinValue, sbyte.MaxValue),
        "i16" => (short.MinValue, short.MaxValue),
        "i32" => (int.MinValue, int.MaxValue),
        "i64" => (long.MinValue, long.MaxValue),
        "u8" => (0, byte.MaxValue),
        "u16" => (0, ushort.MaxValue),
        "u32" => (0, uint.MaxValue),
        "u64" => (0, long.MaxValue),
        "isize" => (long.MinValue, long.MaxValue),
        "usize" => (0, long.MaxValue),
        _ => (long.MinValue, long.MaxValue)
    };

    private void PushScope() => _scopes.Push([]);
    private void PopScope() => _scopes.Pop();

    private void DeclareVariable(string name, TypeBase type, SourceSpan span, bool isConst = false)
    {
        // Allow variable shadowing (like Rust): new declarations replace old ones in the same scope
        var cur = _scopes.Peek();
        cur[name] = new VariableInfo(type, isConst);
    }

    private bool TryLookupVariable(string name, out TypeBase type)
    {
        // First check local scopes
        foreach (var scope in _scopes)
        {
            if (scope.TryGetValue(name, out var info))
            {
                type = info.Type;
                return true;
            }
        }

        // Then check global constants
        if (_compilation.GlobalConstants.TryGetValue(name, out type!))
        {
            return true;
        }

        type = TypeRegistry.Void;
        return false;
    }

    private bool TryLookupVariableInfo(string name, out VariableInfo info)
    {
        // First check local scopes
        foreach (var scope in _scopes)
        {
            if (scope.TryGetValue(name, out info))
                return true;
        }

        // Then check global constants (they're always const)
        if (_compilation.GlobalConstants.TryGetValue(name, out var type))
        {
            info = new VariableInfo(type, IsConst: true);
            return true;
        }

        info = default;
        return false;
    }

    private TypeBase LookupVariable(string name, SourceSpan span)
    {
        if (TryLookupVariable(name, out var type))
            return type;

        ReportError(
            $"cannot find value `{name}` in this scope",
            span,
            "not found in this scope",
            "E2004");
        return TypeRegistry.Never;
    }

    // ===== Generics helpers =====

    private static bool ContainsGeneric(TypeBase t) => t switch
    {
        GenericParameterType => true,
        ReferenceType rt => ContainsGeneric(rt.InnerType),
        ArrayType at => ContainsGeneric(at.ElementType),
        GenericType gt => gt.TypeArguments.Any(ContainsGeneric),
        StructType st => st.TypeArguments.Any(ContainsGeneric),
        EnumType et => et.TypeArguments.Any(ContainsGeneric),
        _ => false
    };

    private static bool IsGenericSignature(IReadOnlyList<TypeBase> parameters, TypeBase returnType)
    {
        if (ContainsGeneric(returnType)) return true;
        foreach (var p in parameters)
            if (ContainsGeneric(p))
                return true;
        return false;
    }

    private static bool IsGenericFunctionDecl(FunctionDeclarationNode fn)
    {
        bool HasGeneric(TypeNode? n)
        {
            if (n == null) return false;
            return n switch
            {
                GenericParameterTypeNode => true,
                ReferenceTypeNode r => HasGeneric(r.InnerType),
                NullableTypeNode nn => HasGeneric(nn.InnerType),
                ArrayTypeNode a => HasGeneric(a.ElementType),
                SliceTypeNode s => HasGeneric(s.ElementType),
                GenericTypeNode g => g.TypeArguments.Any(HasGeneric),
                FunctionTypeNode ft => ft.ParameterTypes.Any(HasGeneric) || HasGeneric(ft.ReturnType),
                AnonymousStructTypeNode ast => ast.Fields.Any(f => HasGeneric(f.FieldType)),
                NamedTypeNode => false,
                _ => throw new InvalidOperationException($"Unhandled TypeNode in IsGenericFunctionDecl: {n.GetType().Name}")
            };
        }

        foreach (var p in fn.Parameters)
            if (HasGeneric(p.Type))
                return true;
        if (HasGeneric(fn.ReturnType)) return true;
        return false;
    }

    private static TypeBase SubstituteGenerics(TypeBase type, Dictionary<string, TypeBase> bindings)
    {
        // Prune TypeVars to get concrete types - this handles comptime_int wrapped in TypeVar
        var pruned = type.Prune();
        return pruned switch
        {
            GenericParameterType gp => bindings.TryGetValue(gp.ParamName, out var b) ? b.Prune() : gp,
            ReferenceType rt => new ReferenceType(SubstituteGenerics(rt.InnerType, bindings)),
            ArrayType at => new ArrayType(SubstituteGenerics(at.ElementType, bindings), at.Length),
            StructType st => SubstituteStructType(st, bindings),
            EnumType et => SubstituteEnumType(et, bindings),
            GenericType gt => new GenericType(gt.BaseName,
                gt.TypeArguments.Select(a => SubstituteGenerics(a, bindings)).ToList()),
            FunctionType ft => new FunctionType(
                ft.ParameterTypes.Select(p => SubstituteGenerics(p, bindings)).ToList(),
                SubstituteGenerics(ft.ReturnType, bindings)),
            _ => pruned
        };
    }

    /// <summary>
    /// Adapts the UFCS receiver type (argTypes[0]) to match the expected parameter type.
    /// UFCS semantics:
    /// - value receiver, value expected: pass as-is
    /// - value receiver, &T expected: lift to reference
    /// - &T receiver, value expected: allow (implicit dereference)
    /// - &T receiver, &T expected: pass as-is
    /// </summary>
    private List<TypeBase> TryAdaptUfcsReceiverType(List<TypeBase> argTypes, TypeBase firstParamType)
    {
        if (argTypes.Count == 0) return argTypes;

        var receiverType = argTypes[0].Prune();
        var paramType = firstParamType.Prune();

        var receiverIsRef = receiverType is ReferenceType;
        var paramExpectsRef = paramType is ReferenceType;

        // No adaptation needed if types already match structurally
        if (receiverIsRef == paramExpectsRef) return argTypes;

        // value receiver, &T expected: lift to reference
        if (!receiverIsRef && paramExpectsRef)
        {
            var adapted = new List<TypeBase>(argTypes);
            adapted[0] = new ReferenceType(receiverType);
            return adapted;
        }

        // &T receiver, value expected: allow pass-through (implicit dereference happens at codegen)
        // The underlying type should match, so we expose the inner type for matching
        if (receiverIsRef && !paramExpectsRef)
        {
            var refType = (ReferenceType)receiverType;
            var adapted = new List<TypeBase>(argTypes);
            adapted[0] = refType.InnerType;
            return adapted;
        }

        return argTypes;
    }

    private bool TryComputeCoercionCost(IReadOnlyList<TypeBase> sources, IReadOnlyList<TypeBase> targets, out int cost)
    {
        cost = 0;
        if (sources.Count != targets.Count) return false;
        for (var i = 0; i < sources.Count; i++)
        {
            if (sources[i].Equals(targets[i])) continue;
            if (!_unificationEngine.CanUnify(sources[i], targets[i])) return false;
            cost++;
        }

        return true;
    }

    /// <summary>
    /// Creates an indentation string based on the current binding depth.
    /// Each level adds 2 spaces for readability.
    /// </summary>
    private string Indent() => new string(' ', _bindingDepth * 2);

    /// <summary>
    /// Disposable scope that automatically manages binding depth for indented logging.
    /// </summary>
    private readonly struct BindingDepthScope : IDisposable
    {
        private readonly TypeChecker _solver;

        public BindingDepthScope(TypeChecker solver)
        {
            _solver = solver;
            _solver._bindingDepth++;
        }

        public void Dispose()
        {
            _solver._bindingDepth--;
        }
    }

    private bool TryBindGeneric(TypeBase param, TypeBase arg, Dictionary<string, TypeBase> bindings,
        out string? conflictParam, out (TypeBase Existing, TypeBase Incoming)? conflictTypes)
    {
        using var _ = new BindingDepthScope(this);
        _logger.LogDebug("{Indent}TryBindGeneric: param={ParamType}('{ParamName}'), arg={ArgType}('{ArgName}')",
            Indent(), param.GetType().Name, param.Name, arg.GetType().Name, arg.Name);
        conflictParam = null;
        conflictTypes = null;
        switch (param)
        {
            case GenericParameterType gp:
                // Prune arg to handle TypeVars bound to comptime types
                var prunedArg = arg.Prune();

                if (bindings.TryGetValue(gp.ParamName, out var existing))
                {
                    var prunedExisting = existing.Prune();

                    // comptime_int in binding + concrete int arg: update binding to concrete type
                    if (prunedExisting is ComptimeInt && TypeRegistry.IsIntegerType(prunedArg))
                    {
                        bindings[gp.ParamName] = prunedArg;
                        return true;
                    }

                    // concrete int in binding + comptime_int arg: propagate concrete type to arg's TypeVar
                    if (prunedArg is ComptimeInt && TypeRegistry.IsIntegerType(prunedExisting))
                    {
                        // If arg is a TypeVar, update it to point to the concrete type
                        if (arg is TypeVar argTv)
                            argTv.Instance = prunedExisting;
                        return true;
                    }

                    // Unbound TypeVar arg (deferred anonymous struct): bind it to the existing type
                    if (prunedArg is TypeVar deferredTv && deferredTv.Instance == null)
                    {
                        deferredTv.Instance = prunedExisting;
                        return true;
                    }

                    if (!prunedExisting.Equals(prunedArg))
                    {
                        conflictParam = gp.ParamName;
                        conflictTypes = (prunedExisting, prunedArg);
                        return false;
                    }

                    return true;
                }

                // No existing binding - use pruned arg for the binding
                bindings[gp.ParamName] = prunedArg;
                return true;
            case ReferenceType pr when arg is ReferenceType ar:
                _logger.LogDebug("{Indent}Recursing into reference types: &{ParamInner} vs &{ArgInner}", Indent(),
                    pr.InnerType.Name, ar.InnerType.Name);
                return TryBindGeneric(pr.InnerType, ar.InnerType, bindings, out conflictParam, out conflictTypes);
            case StructType po when TypeRegistry.IsOption(po) && arg is StructType ao && TypeRegistry.IsOption(ao):
                if (po.TypeArguments.Count > 0 && ao.TypeArguments.Count > 0)
                {
                    _logger.LogDebug("{Indent}Recursing into option types: {ParamInner}? vs {ArgInner}?", Indent(),
                        po.TypeArguments[0].Name, ao.TypeArguments[0].Name);
                    return TryBindGeneric(po.TypeArguments[0], ao.TypeArguments[0], bindings, out conflictParam,
                        out conflictTypes);
                }

                return false;
            case ArrayType pa when arg is ArrayType aa:
                if (pa.Length != aa.Length)
                {
                    _logger.LogDebug(
                        "{Indent}Array length mismatch: [{ParamLength}]{ParamElem} vs [{ArgLength}]{ArgElem}", Indent(),
                        pa.Length, pa.ElementType.Name, aa.Length, aa.ElementType.Name);
                    return false;
                }

                _logger.LogDebug(
                    "{Indent}Recursing into array element types: [{Length}]{ParamElem} vs [{Length}]{ArgElem}",
                    Indent(), pa.Length, pa.ElementType.Name, aa.ElementType.Name);
                return TryBindGeneric(pa.ElementType, aa.ElementType, bindings, out conflictParam, out conflictTypes);
            case StructType ps
                when TypeRegistry.IsSlice(ps) && arg is StructType aslice && TypeRegistry.IsSlice(aslice):
                if (ps.TypeArguments.Count > 0 && aslice.TypeArguments.Count > 0)
                {
                    _logger.LogDebug("{Indent}Recursing into slice element types: []{ParamElem} vs []{ArgElem}",
                        Indent(), ps.TypeArguments[0].Name, aslice.TypeArguments[0].Name);
                    return TryBindGeneric(ps.TypeArguments[0], aslice.TypeArguments[0], bindings, out conflictParam,
                        out conflictTypes);
                }

                return true;
            case GenericType pg when arg is GenericType ag && pg.BaseName == ag.BaseName &&
                                     pg.TypeArguments.Count == ag.TypeArguments.Count:
                for (var i = 0; i < pg.TypeArguments.Count; i++)
                {
                    // Recursively match type arguments
                    // This will handle cases like Type($T) matching Type(i32)
                    _logger.LogDebug("{Indent}Recursing into generic type arg[{Index}]: {ParamArg} vs {ArgArg}",
                        Indent(), i, pg.TypeArguments[i].Name, ag.TypeArguments[i].Name);
                    if (!TryBindGeneric(pg.TypeArguments[i], ag.TypeArguments[i], bindings, out conflictParam,
                            out conflictTypes))
                        return false;
                }

                return true;
            case StructType ps when arg is StructType @as && ps.StructName == @as.StructName:
                {
                    // First, match type arguments
                    // e.g., matching Type<$T> with Type<i32> should bind $T to i32
                    if (ps.TypeArguments.Count == @as.TypeArguments.Count)
                    {
                        for (var i = 0; i < ps.TypeArguments.Count; i++)
                        {
                            var paramType = ps.TypeArguments[i];
                            var argType = @as.TypeArguments[i];

                            _logger.LogDebug("{Indent}Struct type arg[{Index}]: '{ParamType}' vs '{ArgType}'", Indent(), i,
                                paramType.Name, argType.Name);

                            // If param is a generic parameter type, bind it
                            if (paramType is GenericParameterType gp)
                            {
                                var varName = gp.ParamName;
                                _logger.LogDebug("{Indent}Binding type variable '{VarName}' -> '{ArgType}'", Indent(),
                                    varName, argType.Name);

                                if (bindings.TryGetValue(varName, out var existingBinding))
                                {
                                    if (!existingBinding.Equals(argType))
                                    {
                                        _logger.LogDebug(
                                            "{Indent}Conflict: '{VarName}' already bound to '{ExistingType}', cannot rebind to '{NewType}'",
                                            Indent(), varName, existingBinding.Name, argType.Name);
                                        conflictParam = varName;
                                        conflictTypes = (existingBinding, argType);
                                        return false;
                                    }
                                }
                                else
                                {
                                    bindings[varName] = argType;
                                }
                            }
                            else if (!paramType.Equals(argType))
                            {
                                // Concrete type arguments must match exactly
                                _logger.LogDebug("{Indent}Concrete type mismatch: '{ParamType}' != '{ArgType}'", Indent(),
                                    paramType.Name, argType.Name);
                                return false;
                            }
                        }
                    }

                    // Then, match fields
                    var argFields = new Dictionary<string, TypeBase>();
                    foreach (var (name, type) in @as.Fields)
                        argFields[name] = type;

                    foreach (var (fieldName, fieldType) in ps.Fields)
                    {
                        if (!argFields.TryGetValue(fieldName, out var argFieldType))
                        {
                            _logger.LogDebug("{Indent}Field '{FieldName}' not found in arg struct", Indent(), fieldName);
                            return false;
                        }

                        _logger.LogDebug("{Indent}Recursing into field '{FieldName}': {ParamType} vs {ArgType}",
                            Indent(), fieldName, fieldType.Name, argFieldType.Name);
                        if (!TryBindGeneric(fieldType, argFieldType, bindings, out conflictParam, out conflictTypes))
                            return false;
                    }

                    return true;
                }
            case EnumType pe when arg is EnumType ae && pe.Name == ae.Name:
                {
                    // Match type arguments for generic enums
                    // e.g., matching Option($T) with Option(i32) should bind $T to i32
                    if (pe.TypeArguments.Count == ae.TypeArguments.Count)
                    {
                        for (var i = 0; i < pe.TypeArguments.Count; i++)
                        {
                            var paramType = pe.TypeArguments[i];
                            var argType = ae.TypeArguments[i];

                            _logger.LogDebug("{Indent}Enum type arg[{Index}]: '{ParamType}' vs '{ArgType}'", Indent(), i,
                                paramType.Name, argType.Name);

                            // If param is a generic parameter type, bind it
                            if (paramType is GenericParameterType gp)
                            {
                                var varName = gp.ParamName;
                                _logger.LogDebug("{Indent}Binding type variable '{VarName}' -> '{ArgType}'", Indent(),
                                    varName, argType.Name);

                                if (bindings.TryGetValue(varName, out var existingBinding))
                                {
                                    if (!existingBinding.Equals(argType))
                                    {
                                        _logger.LogDebug(
                                            "{Indent}Conflict: '{VarName}' already bound to '{ExistingType}', cannot rebind to '{NewType}'",
                                            Indent(), varName, existingBinding.Name, argType.Name);
                                        conflictParam = varName;
                                        conflictTypes = (existingBinding, argType);
                                        return false;
                                    }
                                }
                                else
                                {
                                    bindings[varName] = argType;
                                }
                            }
                            else if (!TryBindGeneric(paramType, argType, bindings, out conflictParam, out conflictTypes))
                            {
                                // Recursively bind type arguments that may contain nested generics
                                return false;
                            }
                        }
                    }

                    return true;
                }
            case FunctionType pf when arg is FunctionType af:
                {
                    // Match function types: fn($T) T with fn(i32) i32
                    // Parameter counts must match
                    if (pf.ParameterTypes.Count != af.ParameterTypes.Count)
                    {
                        _logger.LogDebug("{Indent}Function parameter count mismatch: {ParamCount} vs {ArgCount}",
                            Indent(), pf.ParameterTypes.Count, af.ParameterTypes.Count);
                        return false;
                    }

                    // Recursively bind each parameter type
                    for (var i = 0; i < pf.ParameterTypes.Count; i++)
                    {
                        _logger.LogDebug("{Indent}Recursing into function param[{Index}]: {ParamType} vs {ArgType}",
                            Indent(), i, pf.ParameterTypes[i].Name, af.ParameterTypes[i].Name);
                        if (!TryBindGeneric(pf.ParameterTypes[i], af.ParameterTypes[i], bindings, out conflictParam, out conflictTypes))
                            return false;
                    }

                    // Recursively bind return type
                    _logger.LogDebug("{Indent}Recursing into function return type: {ParamType} vs {ArgType}",
                        Indent(), pf.ReturnType.Name, af.ReturnType.Name);
                    return TryBindGeneric(pf.ReturnType, af.ReturnType, bindings, out conflictParam, out conflictTypes);
                }
            default:
                // If arg is a TypeVar bound to comptime_int and param is a concrete integer type,
                // update the TypeVar to point to the concrete type
                if (arg is TypeVar argTypeVar && argTypeVar.Prune() is ComptimeInt && TypeRegistry.IsIntegerType(param))
                {
                    argTypeVar.Instance = param;
                    return true;
                }
                return arg.Equals(param) || IsConcreteCompatible(arg, param);
        }
    }

    private static bool IsConcreteCompatible(TypeBase source, TypeBase target)
    {
        if (source.Equals(target)) return true;
        if (TypeRegistry.IsIntegerType(source) && TypeRegistry.IsIntegerType(target)) return true;
        if (source is ArrayType sa && target is StructType ts && TypeRegistry.IsSlice(ts))
        {
            if (ts.TypeArguments.Count > 0)
                return IsConcreteCompatible(sa.ElementType, ts.TypeArguments[0]);
        }

        return false;
    }

    private static void CollectGenericParamOrder(TypeBase t, HashSet<string> seen, List<string> order)
    {
        switch (t)
        {
            case GenericParameterType gp:
                if (seen.Add(gp.ParamName)) order.Add(gp.ParamName);
                break;
            case ReferenceType rt:
                CollectGenericParamOrder(rt.InnerType, seen, order);
                break;
            case ArrayType at:
                CollectGenericParamOrder(at.ElementType, seen, order);
                break;
            case StructType st:
                foreach (var typeArg in st.TypeArguments)
                    CollectGenericParamOrder(typeArg, seen, order);
                break;
            case GenericType gt:
                for (var i = 0; i < gt.TypeArguments.Count; i++)
                    CollectGenericParamOrder(gt.TypeArguments[i], seen, order);
                break;
            default:
                break;
        }
    }

    private static StructType SubstituteStructType(StructType structType, Dictionary<string, TypeBase> bindings)
    {
        var updatedFields = new List<(string Name, TypeBase Type)>(structType.Fields.Count);
        var changed = false;
        foreach (var (name, fieldType) in structType.Fields)
        {
            var substituted = SubstituteGenerics(fieldType, bindings);
            if (!ReferenceEquals(substituted, fieldType))
                changed = true;
            updatedFields.Add((name, substituted));
        }

        // Substitute type arguments recursively (handles nested types like &T)
        var updatedTypeArgs = new List<TypeBase>(structType.TypeArguments.Count);
        foreach (var typeArg in structType.TypeArguments)
        {
            var substituted = SubstituteGenerics(typeArg, bindings);
            if (!ReferenceEquals(substituted, typeArg))
                changed = true;
            updatedTypeArgs.Add(substituted);
        }

        if (!changed)
            return structType;

        return new StructType(structType.StructName, updatedTypeArgs, updatedFields);
    }

    private static EnumType SubstituteEnumType(EnumType enumType, Dictionary<string, TypeBase> bindings)
    {
        var updatedVariants = new List<(string VariantName, TypeBase? PayloadType)>(enumType.Variants.Count);
        var changed = false;
        foreach (var (variantName, payloadType) in enumType.Variants)
        {
            if (payloadType != null)
            {
                var substituted = SubstituteGenerics(payloadType, bindings);
                if (!ReferenceEquals(substituted, payloadType))
                    changed = true;
                updatedVariants.Add((variantName, substituted));
            }
            else
            {
                updatedVariants.Add((variantName, null));
            }
        }

        // Substitute type arguments
        var updatedTypeArgs = new List<TypeBase>(enumType.TypeArguments.Count);
        foreach (var typeArg in enumType.TypeArguments)
        {
            if (typeArg is GenericParameterType gp && bindings.TryGetValue(gp.ParamName, out var boundType))
            {
                changed = true;
                updatedTypeArgs.Add(boundType);
            }
            else
            {
                updatedTypeArgs.Add(typeArg);
            }
        }

        if (!changed)
            return enumType;

        return new EnumType(enumType.Name, updatedTypeArgs, updatedVariants);
    }

    // ==================== AST Deep Clone for Generic Specialization ====================

    /// <summary>
    /// Deep clones a list of statements. Used to create independent AST for each generic specialization.
    /// This is necessary because type checking mutates the AST (e.g., setting ResolvedTarget on CallExpressionNode).
    /// </summary>
    private static List<StatementNode> CloneStatements(IReadOnlyList<StatementNode> statements)
    {
        return statements.Select(CloneStatement).ToList();
    }

    private static StatementNode CloneStatement(StatementNode stmt) => stmt switch
    {
        ReturnStatementNode ret => new ReturnStatementNode(ret.Span, ret.Expression != null ? CloneExpression(ret.Expression) : null),
        ExpressionStatementNode es => new ExpressionStatementNode(es.Span, CloneExpression(es.Expression)),
        VariableDeclarationNode vd => new VariableDeclarationNode(vd.Span, vd.Name, vd.Type, vd.Initializer != null ? CloneExpression(vd.Initializer) : null),
        ForLoopNode fl => new ForLoopNode(fl.Span, fl.IteratorVariable, CloneExpression(fl.IterableExpression), CloneExpression(fl.Body)),
        BreakStatementNode br => new BreakStatementNode(br.Span),
        ContinueStatementNode cont => new ContinueStatementNode(cont.Span),
        DeferStatementNode df => new DeferStatementNode(df.Span, CloneExpression(df.Expression)),
        _ => throw new NotSupportedException($"Cloning not implemented for statement type: {stmt.GetType().Name}")
    };

    private static ExpressionNode CloneExpression(ExpressionNode expr) => expr switch
    {
        IntegerLiteralNode lit => new IntegerLiteralNode(lit.Span, lit.Value),
        BooleanLiteralNode bl => new BooleanLiteralNode(bl.Span, bl.Value),
        StringLiteralNode sl => new StringLiteralNode(sl.Span, sl.Value),
        NullLiteralNode nl => new NullLiteralNode(nl.Span),
        IdentifierExpressionNode id => new IdentifierExpressionNode(id.Span, id.Name),
        BinaryExpressionNode bin => new BinaryExpressionNode(bin.Span, CloneExpression(bin.Left), bin.Operator, CloneExpression(bin.Right)),
        CallExpressionNode call => new CallExpressionNode(call.Span, call.FunctionName, call.Arguments.Select(CloneExpression).ToList(),
            call.UfcsReceiver != null ? CloneExpression(call.UfcsReceiver) : null, call.MethodName),
        IfExpressionNode ie => new IfExpressionNode(ie.Span, CloneExpression(ie.Condition), CloneExpression(ie.ThenBranch), ie.ElseBranch != null ? CloneExpression(ie.ElseBranch) : null),
        BlockExpressionNode blk => new BlockExpressionNode(blk.Span, CloneStatements(blk.Statements), blk.TrailingExpression != null ? CloneExpression(blk.TrailingExpression) : null),
        MemberAccessExpressionNode ma => new MemberAccessExpressionNode(ma.Span, CloneExpression(ma.Target), ma.FieldName),
        IndexExpressionNode ix => new IndexExpressionNode(ix.Span, CloneExpression(ix.Base), CloneExpression(ix.Index)),
        AssignmentExpressionNode ae => new AssignmentExpressionNode(ae.Span, CloneExpression(ae.Target), CloneExpression(ae.Value)),
        AddressOfExpressionNode addr => new AddressOfExpressionNode(addr.Span, CloneExpression(addr.Target)),
        DereferenceExpressionNode deref => new DereferenceExpressionNode(deref.Span, CloneExpression(deref.Target)),
        CastExpressionNode cast => new CastExpressionNode(cast.Span, CloneExpression(cast.Expression), cast.TargetType),
        RangeExpressionNode range => new RangeExpressionNode(range.Span, CloneExpression(range.Start), CloneExpression(range.End)),
        CoalesceExpressionNode coal => new CoalesceExpressionNode(coal.Span, CloneExpression(coal.Left), CloneExpression(coal.Right)),
        NullPropagationExpressionNode np => new NullPropagationExpressionNode(np.Span, CloneExpression(np.Target), np.MemberName),
        MatchExpressionNode match => new MatchExpressionNode(match.Span, CloneExpression(match.Scrutinee), match.Arms.Select(a => new MatchArmNode(a.Span, a.Pattern, CloneExpression(a.ResultExpr))).ToList()),
        ArrayLiteralExpressionNode arr => new ArrayLiteralExpressionNode(arr.Span, arr.Elements.Select(CloneExpression).ToList()),
        AnonymousStructExpressionNode anon => new AnonymousStructExpressionNode(anon.Span, anon.Fields.Select(f => (f.FieldName, CloneExpression(f.Value))).ToList()),
        StructConstructionExpressionNode sc => new StructConstructionExpressionNode(sc.Span, sc.TypeName, sc.Fields.Select(f => (f.FieldName, CloneExpression(f.Value))).ToList()),
        ImplicitCoercionNode ic => new ImplicitCoercionNode(ic.Span, CloneExpression(ic.Inner), ic.TargetType, ic.Kind),
        UnaryExpressionNode un => new UnaryExpressionNode(un.Span, un.Operator, CloneExpression(un.Operand)),
        _ => throw new NotSupportedException($"Cloning not implemented for expression type: {expr.GetType().Name}")
    };

    private FunctionDeclarationNode? EnsureSpecialization(FunctionEntry genericEntry, Dictionary<string, TypeBase> bindings,
        IReadOnlyList<TypeBase> concreteParamTypes)
    {
        var key = BuildSpecKey(genericEntry.Name, concreteParamTypes);
        if (_emittedSpecs.Contains(key))
        {
            // Already specialized - find and return the existing specialized node
            var found = _specializations.FirstOrDefault(s =>
                s.Name == genericEntry.Name &&
                s.Parameters.Count == concreteParamTypes.Count &&
                s.Parameters.Select((p, i) => ResolveTypeNode(p.Type) ?? TypeRegistry.Never).SequenceEqual(concreteParamTypes));
            if (found == null)
            {
                _logger.LogDebug("EnsureSpecialization: key '{Key}' exists but no matching node found in _specializations", key);
            }
            return found;
        }

        // Save current bindings - nested specializations might overwrite them
        var savedBindings = _currentBindings;

        PushGenericScope(genericEntry.AstNode);
        _currentBindings = bindings;
        try
        {
            // Substitute param/return types in the signature
            var newParams = new List<FunctionParameterNode>();
            foreach (var p in genericEntry.AstNode.Parameters)
            {
                var t = ResolveTypeNode(p.Type) ?? TypeRegistry.Never;
                var st = SubstituteGenerics(t, bindings);
                var tnode = CreateTypeNodeFromTypeBase(p.Span, st);
                newParams.Add(new FunctionParameterNode(p.Span, p.Name, tnode));
            }

            TypeNode? newRetNode = null;
            if (genericEntry.AstNode.ReturnType != null)
            {
                var rt = ResolveTypeNode(genericEntry.AstNode.ReturnType) ?? TypeRegistry.Never;
                var srt = SubstituteGenerics(rt, bindings);
                newRetNode = CreateTypeNodeFromTypeBase(genericEntry.AstNode.ReturnType.Span, srt);
            }

            // Keep base name; backend will mangle by parameter types
            // Deep clone the body to avoid shared mutable state between specializations
            // (e.g., CallExpressionNode.ResolvedTarget would be overwritten by subsequent specializations)
            var clonedBody = CloneStatements(genericEntry.AstNode.Body);
            var newFn = new FunctionDeclarationNode(genericEntry.AstNode.Span, genericEntry.Name, newParams, newRetNode,
                clonedBody, genericEntry.IsForeign ? FunctionModifiers.Foreign : FunctionModifiers.None);

            // Register specialization BEFORE checking body to prevent infinite recursion
            // for recursive generic functions (e.g., count_list calling count_list)
            _specializations.Add(newFn);
            _emittedSpecs.Add(key);

            // Check the specialized function body.
            // Note: We keep _currentBindings and the generic scope active so that
            // references to T in the body are properly substituted to concrete types.
            // CheckFunction will push its own scope (which will be empty for newFn),
            // but the outer scope from genericEntry.AstNode will still be active.

            // Temporarily re-register private functions from the generic entry's module
            // so that calls to private functions within the specialized body can resolve
            var privateEntries = genericEntry.ModulePath != null &&
                _privateEntriesByModule.TryGetValue(genericEntry.ModulePath, out var entries)
                    ? entries : null;
            if (privateEntries != null)
            {
                foreach (var (name, entry) in privateEntries)
                {
                    if (!_functions.TryGetValue(name, out var list))
                    {
                        list = [];
                        _functions[name] = list;
                    }
                    list.Add(entry);
                }
            }

            // Temporarily re-register private constants from the generic entry's module
            var privateConstants = genericEntry.ModulePath != null &&
                _privateConstantsByModule.TryGetValue(genericEntry.ModulePath, out var constEntries)
                    ? constEntries : null;
            if (privateConstants != null)
            {
                foreach (var (name, type) in privateConstants)
                {
                    _compilation.GlobalConstants[name] = type;
                }
            }

            try
            {
                CheckFunction(newFn);
            }
            finally
            {
                // Remove private entries again
                if (privateEntries != null)
                {
                    foreach (var (name, entry) in privateEntries)
                    {
                        if (_functions.TryGetValue(name, out var list))
                        {
                            list.Remove(entry);
                            if (list.Count == 0) _functions.Remove(name);
                        }
                    }
                }

                // Remove private constants again
                if (privateConstants != null)
                {
                    foreach (var (name, _) in privateConstants)
                    {
                        _compilation.GlobalConstants.Remove(name);
                    }
                }
            }

            return newFn;
        }
        finally
        {
            _currentBindings = savedBindings;  // Restore previous bindings
            PopGenericScope();
        }
    }

    private static TypeNode CreateTypeNodeFromTypeBase(SourceSpan span, TypeBase t)
    {
        // Prune TypeVars to get concrete types
        var pruned = t.Prune();
        return pruned switch
        {
            // ComptimeInt can appear when specializing with unresolved literals -
            // create a named type that will fail during resolution with proper error
            ComptimeInt => new NamedTypeNode(span, "comptime_int"),
            PrimitiveType pt => new NamedTypeNode(span, pt.Name),
            StructType st when TypeRegistry.IsSlice(st) && st.TypeArguments.Count > 0 =>
                new SliceTypeNode(span, CreateTypeNodeFromTypeBase(span, st.TypeArguments[0])),
            StructType st when TypeRegistry.IsOption(st) && st.TypeArguments.Count > 0 =>
                new NullableTypeNode(span, CreateTypeNodeFromTypeBase(span, st.TypeArguments[0])),
            StructType st => st.TypeArguments.Count == 0
                ? new NamedTypeNode(span, st.StructName)
                : new GenericTypeNode(span, st.StructName,
                    st.TypeArguments.Select(t => CreateTypeNodeFromTypeBase(span, t)).ToList()),
            EnumType et => et.TypeArguments.Count == 0
                ? new NamedTypeNode(span, et.Name)
                : new GenericTypeNode(span, et.Name,
                    et.TypeArguments.Select(t => CreateTypeNodeFromTypeBase(span, t)).ToList()),
            ReferenceType rt => new ReferenceTypeNode(span, CreateTypeNodeFromTypeBase(span, rt.InnerType)),
            ArrayType at => new ArrayTypeNode(span, CreateTypeNodeFromTypeBase(span, at.ElementType), at.Length),
            GenericType gt => new GenericTypeNode(span, gt.BaseName,
                gt.TypeArguments.Select(a => CreateTypeNodeFromTypeBase(span, a)).ToList()),
            GenericParameterType gp => new GenericParameterTypeNode(span, gp.ParamName),
            FunctionType ft => new FunctionTypeNode(span,
                ft.ParameterTypes.Select(p => CreateTypeNodeFromTypeBase(span, p)).ToList(),
                CreateTypeNodeFromTypeBase(span, ft.ReturnType)),
            _ => throw new InvalidOperationException($"Unhandled type in CreateTypeNodeFromTypeBase: {pruned.GetType().Name} ({pruned.Name})")
        };
    }

    public IReadOnlyList<FunctionDeclarationNode> GetSpecializedFunctions() => _specializations;

    public bool IsGenericFunction(FunctionDeclarationNode fn) => IsGenericFunctionDecl(fn);

    // ==================== Enum Variant Construction ====================

    /// <summary>
    /// Try to resolve a call as enum variant construction (short form).
    /// Returns the enum type if successful, null otherwise.
    /// </summary>
    private TypeBase? TryResolveEnumVariantConstruction(string variantName, IReadOnlyList<ExpressionNode> arguments,
        TypeBase? expectedType, SourceSpan span)
    {
        // Check if the function name contains a dot (qualified form: EnumName.Variant)
        if (variantName.Contains('.'))
        {
            var parts = variantName.Split('.');
            if (parts.Length == 2)
            {
                var enumName = parts[0];
                var actualVariantName = parts[1];

                // Try to find the enum
                if (_compilation.Enums.TryGetValue(enumName, out var enumTemplate))
                {
                    // If we have an expected type that's a specialized version of this enum, use that
                    EnumType enumToUse = enumTemplate;
                    if (expectedType is EnumType expectedEnumType &&
                        expectedEnumType.Name == enumTemplate.Name &&
                        expectedEnumType.TypeArguments.Count > 0)
                    {
                        enumToUse = expectedEnumType;
                    }
                    return CheckEnumVariantConstruction(enumToUse, actualVariantName, arguments, span);
                }
            }
        }

        // Short form - try variant lookup in current scope
        if (TryLookupVariable(variantName, out var varType) &&
            varType is EnumType enumFromScope &&
            enumFromScope.Variants.Any(v => v.VariantName == variantName))
        {
            return CheckEnumVariantConstruction(enumFromScope, variantName, arguments, span);
        }

        // Fallback: check expected type
        if (expectedType != null && expectedType is EnumType expectedEnum)
        {
            // Check if the expected enum has this variant
            var variant = expectedEnum.Variants.FirstOrDefault(v => v.VariantName == variantName);
            if (variant != default)
            {
                return CheckEnumVariantConstruction(expectedEnum, variantName, arguments, span);
            }
        }

        return null; // Not an enum variant
    }

    private TypeBase CheckEnumVariantConstruction(EnumType enumType, string variantName,
        IReadOnlyList<ExpressionNode> arguments, SourceSpan span)
    {
        // Find the variant
        var variant = enumType.Variants.FirstOrDefault(v => v.VariantName == variantName);
        if (variant == default)
        {
            ReportError(
                $"enum `{enumType.Name}` has no variant `{variantName}`",
                span,
                null,
                "E2037");
            return enumType;
        }

        // Check argument count
        var expectedArgCount = variant.PayloadType != null
            ? (variant.PayloadType is StructType stmp && stmp.Name.Contains("_payload") ? stmp.Fields.Count : 1)
            : 0;

        if (arguments.Count != expectedArgCount)
        {
            ReportError(
                $"variant `{variantName}` expects {expectedArgCount} argument(s), found {arguments.Count}",
                span,
                null,
                "E2032");
            return enumType;
        }

        // Type check arguments
        if (variant.PayloadType != null)
        {
            if (variant.PayloadType is StructType st && st.Name.Contains("_payload"))
            {
                // Multiple payloads - check each field
                for (int i = 0; i < arguments.Count && i < st.Fields.Count; i++)
                {
                    var expectedFieldType = st.Fields[i].Type;
                    var argType = CheckExpression(arguments[i], expectedFieldType);

                    // Unify argument with field type - TypeVar.Prune() handles propagation
                    var unified = UnifyTypes(argType, expectedFieldType, arguments[i].Span);
                }
            }
            else
            {
                // Single payload
                var argType = CheckExpression(arguments[0], variant.PayloadType);

                // Unify argument with payload type - TypeVar.Prune() handles propagation
                var unified = UnifyTypes(argType, variant.PayloadType, arguments[0].Span);
            }
        }

        return enumType;
    }

    // ==================== Match Expression Type Checking ====================

    private TypeBase CheckMatchExpression(MatchExpressionNode match, TypeBase? expectedType)
    {
        // Check scrutinee type
        var scrutineeType = CheckExpression(match.Scrutinee);
        var prunedScrutinee = scrutineeType.Prune();

        // Allow matching on &EnumType (auto-dereference)
        var needsDereference = false;
        if (prunedScrutinee is ReferenceType rt)
        {
            prunedScrutinee = rt.InnerType;
            needsDereference = true;
        }

        // Scrutinee must be an enum type
        if (prunedScrutinee is not EnumType enumType)
        {
            ReportError(
                "match expression requires enum type",
                match.Scrutinee.Span,
                $"found `{prunedScrutinee}`",
                "E2030");
            return TypeRegistry.Never; // Fallback
        }

        // Store metadata for lowering
        match.NeedsDereference = needsDereference;

        // Track which variants are covered
        var coveredVariants = new HashSet<string>();
        var hasElse = false;

        // Type check each arm and unify result types
        TypeBase? resultType = null;
        foreach (var arm in match.Arms)
        {
            // Check pattern and bind variables
            PushScope(); // Pattern variables are scoped to the arm

            var matchedVariants = CheckPattern(arm.Pattern, enumType, match.Scrutinee.Span);
            foreach (var v in matchedVariants)
            {
                if (v == "_else_")
                    hasElse = true;
                else
                    coveredVariants.Add(v);
            }

            // Check arm expression with expected type to help resolve comptime_int
            // Prefer expectedType (from context like return type) over inferred resultType
            var armType = CheckExpression(arm.ResultExpr, expectedType ?? resultType);

            PopScope();

            // Unify with expected type first if available, then with previous result type
            // TypeVar.Prune() handles propagation automatically - no need for UpdateTypeMapRecursive
            TypeBase unifiedArmType = armType;
            if (expectedType != null)
            {
                unifiedArmType = UnifyTypes(armType, expectedType, arm.Span);
            }
            else if (resultType != null)
            {
                unifiedArmType = UnifyTypes(resultType, armType, arm.Span);
            }

            // Unify with previous arm types
            if (resultType == null)
                resultType = unifiedArmType;
            else
                resultType = UnifyTypes(resultType, unifiedArmType, arm.Span);
        }

        // No second pass needed - TypeVar.Prune() handles type propagation automatically

        // Check exhaustiveness
        if (!hasElse)
        {
            var missingVariants = enumType.Variants
                .Select(v => v.VariantName)
                .Where(name => !coveredVariants.Contains(name))
                .ToList();

            if (missingVariants.Count > 0)
            {
                ReportError(
                    "non-exhaustive pattern match",
                    match.Span,
                    $"missing variants: {string.Join(", ", missingVariants)}",
                    "E2031");
            }
        }

        return resultType ?? TypeRegistry.Never;
    }

    /// <summary>
    /// Check a pattern against an enum type.
    /// Returns the set of variant names this pattern matches.
    /// </summary>
    private List<string> CheckPattern(PatternNode pattern, EnumType enumType, SourceSpan contextSpan)
    {
        switch (pattern)
        {
            case WildcardPatternNode:
                // Wildcard matches anything but doesn't bind
                return new List<string>(); // Doesn't count as covering any specific variant

            case ElsePatternNode:
                // Else matches everything
                return new List<string> { "_else_" };

            case EnumVariantPatternNode evp:
                {
                    // Find the variant
                    string variantName = evp.VariantName;
                    var variant = enumType.Variants.FirstOrDefault(v => v.VariantName == variantName);

                    if (variant == default)
                    {
                        ReportError(
                            $"enum `{enumType.Name}` has no variant `{variantName}`",
                            pattern.Span,
                            null,
                            "E2037");
                        return new List<string>();
                    }

                    // Check sub-pattern arity
                    var expectedSubPatterns = variant.PayloadType != null
                        ? (variant.PayloadType is StructType stArity && stArity.Name.Contains("_payload")
                            ? stArity.Fields.Count
                            : 1)
                        : 0;

                    if (evp.SubPatterns.Count != expectedSubPatterns)
                    {
                        ReportError(
                            $"variant `{variantName}` expects {expectedSubPatterns} field(s), pattern has {evp.SubPatterns.Count}",
                            pattern.Span,
                            null,
                            "E2032");
                    }
                    else if (variant.PayloadType != null)
                    {
                        // Bind sub-pattern variables
                        if (variant.PayloadType is StructType st && st.Name.Contains("_payload"))
                        {
                            // Multiple fields
                            for (int i = 0; i < evp.SubPatterns.Count && i < st.Fields.Count; i++)
                            {
                                BindPatternVariable(evp.SubPatterns[i], st.Fields[i].Type);
                            }
                        }
                        else
                        {
                            // Single field
                            BindPatternVariable(evp.SubPatterns[0], variant.PayloadType);
                        }
                    }

                    return new List<string> { variantName };
                }

            default:
                ReportError(
                    "invalid pattern",
                    pattern.Span,
                    "expected enum variant pattern, wildcard (_), or else",
                    "E1001");
                return new List<string>();
        }
    }

    private void BindPatternVariable(PatternNode pattern, TypeBase type)
    {
        switch (pattern)
        {
            case WildcardPatternNode:
                // Wildcard doesn't bind
                break;

            case VariablePatternNode vp:
                // Bind variable to the payload type (pattern bindings are mutable like let)
                _scopes.Peek()[vp.Name] = new VariableInfo(type, IsConst: false);
                break;

            case EnumVariantPatternNode:
                // Nested enum pattern - would need recursive handling
                // For now, not supported
                ReportError(
                    "nested enum patterns not yet supported",
                    pattern.Span,
                    null,
                    "E1001");
                break;
        }
    }

    private void ReportError(string message, SourceSpan span, string? hint = null, string? code = null)
    {
        _diagnostics.Add(Diagnostic.Error(message, span, hint, code));
    }
}

public class FunctionEntry
{
    public FunctionEntry(string name, IReadOnlyList<TypeBase> parameterTypes, TypeBase returnType,
        FunctionDeclarationNode astNode, bool isForeign, bool isGeneric, string? modulePath = null)
    {
        Name = name;
        ParameterTypes = parameterTypes;
        ReturnType = returnType;
        AstNode = astNode;
        IsForeign = isForeign;
        IsGeneric = isGeneric;
        ModulePath = modulePath;
    }

    public string Name { get; }
    public IReadOnlyList<TypeBase> ParameterTypes { get; }
    public TypeBase ReturnType { get; }
    public FunctionDeclarationNode AstNode { get; }
    public bool IsForeign { get; }
    public bool IsGeneric { get; }
    public string? ModulePath { get; }
}

// ForLoopTypes struct removed - iterator protocol types now stored directly on ForLoopNode
