using FLang.Core;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;
using FLang.Frontend.Ast.Types;
using Microsoft.Extensions.Logging;
using ComptimeIntType = FLang.Core.ComptimeInt;

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
    private readonly Stack<Dictionary<string, TypeBase>> _scopes = new();

    // Function registry (stays in TypeChecker - contains AST nodes)
    private readonly Dictionary<string, List<FunctionEntry>> _functions = [];
    private readonly List<FunctionDeclarationNode> _specializations = [];
    private readonly HashSet<string> _emittedSpecs = [];

    // Module-aware state (local to type checking phase)
    private string? _currentModulePath = null;

    // Generic binding state (local to type checking phase)
    private Dictionary<string, TypeBase>? _currentBindings;

    private readonly Stack<HashSet<string>> _genericScopes = new();
    private readonly Stack<FunctionDeclarationNode> _functionStack = new();

    // Track binding recursion depth for indented logging
    private int _bindingDepth = 0;

    // Literal TypeVar tracking for inference
    private int _nextLiteralTypeVarId = 0;
    private readonly List<TypeVar> _literalTypeVars = [];

    /// <summary>
    /// Creates a new TypeVar for a literal, soft-bound to the given comptime type.
    /// Tracks the TypeVar for later verification.
    /// </summary>
    private TypeVar CreateLiteralTypeVar(string id, SourceSpan span, TypeBase comptimeType)
    {
        var tv = new TypeVar(id, span);
        tv.Instance = comptimeType;
        _literalTypeVars.Add(tv);
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
            sb.Append(paramTypes[i].Name);
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

        foreach (var function in module.Functions)
        {
            var mods = function.Modifiers;
            var isPublic = (mods & FunctionModifiers.Public) != 0;
            var isForeign = (mods & FunctionModifiers.Foreign) != 0;
            if (!(isPublic || isForeign)) continue;

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
                    IsGenericSignature(parameterTypes, returnType));
                if (!_functions.TryGetValue(function.Name, out var list))
                {
                    list = [];
                    _functions[function.Name] = list;
                }

                list.Add(entry);
            }
            finally
            {
                PopGenericScope();
            }
        }

        _currentModulePath = null;
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

            // Convert string type parameters to GenericParameterType instances
            var typeArgs = new List<TypeBase>();
            foreach (var param in structDecl.TypeParameters)
                typeArgs.Add(new GenericParameterType(param));

            // Compute FQN for this struct
            var fqn = $"{modulePath}.{structDecl.Name}";

            // Create final struct type with resolved fields
            StructType stype = new(fqn, typeArgs, fields);

            // Replace placeholder with complete struct type
            _compilation.StructsByModule[modulePath][structDecl.Name] = stype;
            _compilation.StructsByFqn[fqn] = stype;
            _compilation.Structs[structDecl.Name] = stype;
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

        // Temporarily add private functions
        var added = new List<(string, FunctionEntry)>();
        foreach (var function in module.Functions)
        {
            var mods = function.Modifiers;
            var isPublic = (mods & FunctionModifiers.Public) != 0;
            var isForeign = (mods & FunctionModifiers.Foreign) != 0;
            if (isPublic || isForeign) continue;

            PushGenericScope(function);
            try
            {
                var returnType = ResolveTypeNode(function.ReturnType) ?? TypeRegistry.Void;
                var parameterTypes = new List<TypeBase>();
                foreach (var param in function.Parameters)
                {
                    var pt = ResolveTypeNode(param.Type) ?? TypeRegistry.Never;
                    // Store resolved type on parameter for AstLowering
                    param.ResolvedType = pt;
                    parameterTypes.Add(pt);
                }

                // Store resolved types on function for AstLowering
                function.ResolvedReturnType = returnType;
                function.ResolvedParameterTypes = parameterTypes;

                var entry = new FunctionEntry(function.Name, parameterTypes, returnType, function, false,
                    IsGenericSignature(parameterTypes, returnType));
                if (!_functions.TryGetValue(function.Name, out var list))
                {
                    list = [];
                    _functions[function.Name] = list;
                }

                list.Add(entry);
                added.Add((function.Name, entry));
            }
            finally
            {
                PopGenericScope();
            }
        }

        // Check non-generic bodies
        foreach (var function in module.Functions)
        {
            if ((function.Modifiers & FunctionModifiers.Foreign) != 0) continue;
            if (IsGenericFunctionDecl(function)) continue;
            CheckFunction(function);
        }

        // Remove private entries
        foreach (var (name, entry) in added)
        {
            if (_functions.TryGetValue(name, out var list))
            {
                list.Remove(entry);
                if (list.Count == 0) _functions.Remove(name);
            }
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

        var et = CheckExpression(ret.Expression, expectedReturnType);
        _logger.LogDebug(
            "[TypeChecker] CheckReturnStatement: expectedReturnType={ExpectedType}, expressionType={ExprType}",
            expectedReturnType?.Name ?? "null", et.Name);

        if (expectedReturnType != null)
        {
            // Unify with expected return type - TypeVar.Prune() handles propagation
            var unified = UnifyTypes(et, expectedReturnType, ret.Expression.Span);

            // Wrap return expression with coercion node if needed
            ret.Expression = WrapWithCoercionIfNeeded(ret.Expression, et.Prune(), expectedReturnType.Prune());

            // Log the unified type
            _logger.LogDebug(
                "[TypeChecker] After unification: unified={UnifiedType}",
                unified.Name);
        }
    }

    private void CheckVariableDeclaration(VariableDeclarationNode v)
    {
        var dt = ResolveTypeNode(v.Type);
        var it = v.Initializer != null ? CheckExpression(v.Initializer, dt) : null;
        if (it != null && dt != null)
        {
            // Unify initializer type with declared type - TypeVar.Prune() handles propagation
            var unified = UnifyTypes(it, dt, v.Initializer!.Span);

            // Wrap initializer with coercion node if needed
            v.Initializer = WrapWithCoercionIfNeeded(v.Initializer!, it.Prune(), dt.Prune());

            v.ResolvedType = dt;
            DeclareVariable(v.Name, dt, v.Span);
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
                DeclareVariable(v.Name, TypeRegistry.Never, v.Span);
            }
            else
            {
                // No immediate check for IsComptimeType - validation happens in VerifyAllTypesResolved
                v.ResolvedType = varType;
                DeclareVariable(v.Name, varType, v.Span);
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
                // Remove generic error and replace with E2021
                var lastDiagnostic = _diagnostics[^1];
                if (lastDiagnostic.Code == "E2004" || lastDiagnostic.Code == "E2011")
                {
                    _diagnostics.RemoveAt(_diagnostics.Count - 1);
                }

                var iterableTypeName = FormatTypeNameForDisplay(iterableType);
                ReportError(
                    $"type `{iterableTypeName}` is not iterable",
                    fl.IterableExpression.Span,
                    $"define `fn iter(&{iterableTypeName})` that returns an iterator state struct type",
                    "E2021");
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

                // If next(&IteratorType) failed, iterator state missing next function
                if (hadNextError)
                {
                    // Remove generic error and replace with E2023
                    var lastDiagnostic = _diagnostics[^1];
                    if (lastDiagnostic.Code == "E2004" || lastDiagnostic.Code == "E2011")
                    {
                        _diagnostics.RemoveAt(_diagnostics.Count - 1);
                    }

                    var iteratorStructName = FormatTypeNameForDisplay(iteratorStruct);
                    ReportError(
                        $"iterator state type `{iteratorStructName}` has no `next` function",
                        fl.IterableExpression.Span,
                        $"define `fn next(&{iteratorStructName})` that returns an option type",
                        "E2023");
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

        // Not found as variable or type
        ReportError(
            $"cannot find value or type `{id.Name}` in this scope",
            id.Span,
            "not found in this scope",
            "E2004");
        return TypeRegistry.Never;
    }

    private TypeBase CheckMemberAccessExpression(MemberAccessExpressionNode ma)
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
                    // This is enum variant construction: EnumType.Variant
                    return CheckEnumVariantConstruction(enumType, ma.FieldName, new List<ExpressionNode>(),
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
        // Auto-dereference references to allow field access on &T
        var structType = prunedObj switch
        {
            ReferenceType reTypeBase => reTypeBase.InnerType switch
            {
                StructType st => st,
                ArrayType array => TypeRegistry.MakeSlice(array.ElementType),
                _ => null
            },
            StructType st => st,
            // Borrow SlideType semantics for arrays (they should behave like slices)
            ArrayType array => TypeRegistry.MakeSlice(array.ElementType),
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
        var rt = CheckExpression(be.Right, lt);

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

    private TypeBase CheckAssignmentExpression(AssignmentExpressionNode ae)
    {
        // Get the type of the assignment target (lvalue)
        TypeBase targetType = ae.Target switch
        {
            IdentifierExpressionNode id => LookupVariable(id.Name, ae.Target.Span),
            MemberAccessExpressionNode fa => CheckExpression(fa),
            _ => throw new Exception($"Invalid assignment target: {ae.Target.GetType().Name}")
        };

        // Check the value expression against the target type
        var val = CheckExpression(ae.Value, targetType);

        // Unify value with target type - TypeVar.Prune() handles propagation
        var unified = UnifyTypes(val, targetType, ae.Value.Span);

        return targetType;
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

        if (_functions.TryGetValue(call.FunctionName, out var candidates))
        {
            _logger.LogDebug("{Indent}Considering {CandidateCount} candidates for '{FunctionName}'", Indent(),
                candidates.Count, call.FunctionName);
            var argTypes = call.Arguments.Select(arg => CheckExpression(arg)).ToList();

            FunctionEntry? bestNonGeneric = null;
            var bestNonGenericCost = int.MaxValue;

            foreach (var cand in candidates)
            {
                if (cand.IsGeneric) continue;
                if (cand.ParameterTypes.Count != argTypes.Count) continue;
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

                _logger.LogDebug("{Indent}Attempting generic binding for '{Name}'", Indent(), cand.Name);
                var bindings = new Dictionary<string, TypeBase>();
                var okGen = true;
                for (var i = 0; i < argTypes.Count; i++)
                {
                    var argType = argTypes[i] ?? throw new NullReferenceException();
                    using var __ = new BindingDepthScope(this);
                    _logger.LogDebug("{Indent}Binding param[{Index}] '{ParamName}' with arg '{ArgType}'", Indent(), i,
                        cand.ParameterTypes[i].Name, argType.Name);
                    if (!TryBindGeneric(cand.ParameterTypes[i], argType, bindings, out var cn, out var ct))
                    {
                        okGen = false;
                        if (cn != null)
                        {
                            conflictName = cn;
                            conflictPair = ct;
                        }

                        break;
                    }
                }

                if (!okGen) continue;

                var concreteParams = new List<TypeBase>();
                for (var i = 0; i < cand.ParameterTypes.Count; i++)
                    concreteParams.Add(SubstituteGenerics(cand.ParameterTypes[i], bindings));

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
                    ReportError(
                        $"no applicable overload found for `{call.FunctionName}`",
                        call.Span,
                        "no matching function signature",
                        "E2011");
                }

                return TypeRegistry.Never;
            }
            else if (!chosen.IsGeneric)
            {
                var type = chosen.ReturnType;
                if (expectedType != null)
                    type = UnifyTypes(type, expectedType, call.Span);
                for (var i = 0; i < call.Arguments.Count; i++)
                {
                    // Unify argument types - TypeVar.Prune() handles propagation
                    var unified = UnifyTypes(argTypes[i], chosen.ParameterTypes[i], call.Arguments[i].Span);

                    // Wrap argument with coercion node if needed
                    call.Arguments[i] = WrapWithCoercionIfNeeded(call.Arguments[i], argTypes[i].Prune(), chosen.ParameterTypes[i].Prune());
                }

                if (_functionStack.Count > 0)
                {
                    call.ResolvedTarget = chosen.AstNode;
                }
                return type;
            }
            else
            {
                var bindings = chosenBindings!;
                if (expectedType != null)
                    RefineBindingsWithExpectedReturn(chosen.ReturnType, expectedType, bindings, call.Span);
                var ret = SubstituteGenerics(chosen.ReturnType, bindings);
                var type = expectedType != null ? UnifyTypes(ret, expectedType, call.Span) : ret;

                var concreteParams = new List<TypeBase>();
                for (var i = 0; i < chosen.ParameterTypes.Count; i++)
                    concreteParams.Add(SubstituteGenerics(chosen.ParameterTypes[i], bindings));

                for (var i = 0; i < call.Arguments.Count; i++)
                {
                    // Unify argument types - TypeVar.Prune() handles propagation
                    var unified = UnifyTypes(argTypes[i], concreteParams[i], call.Arguments[i].Span);

                    // Wrap argument with coercion node if needed
                    call.Arguments[i] = WrapWithCoercionIfNeeded(call.Arguments[i], argTypes[i].Prune(), concreteParams[i].Prune());
                }

                var specializedNode = EnsureSpecialization(chosen, bindings, concreteParams);
                call.ResolvedTarget = specializedNode;
                return type;
            }
        }
        else
        {
            // Temporary built-in fallback for C printf without explicit import
            if (call.FunctionName == "printf")
            {
                // Check arguments and resolve comptime_int to i32 for variadic args
                var argTypes = new List<TypeBase>();
                for (var i = 0; i < call.Arguments.Count; i++)
                {
                    var argType = CheckExpression(call.Arguments[i]);
                    if (argType.Prune() is ComptimeIntType)
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

                if (_functionStack.Count > 0)
                {
                    call.ResolvedTarget = null;  // printf is a special builtin, no FunctionDeclarationNode
                }
                return TypeRegistry.I32;
            }

            ReportError(
                $"cannot find function `{call.FunctionName}` in this scope",
                call.Span,
                "not found in this scope",
                "E2004");
            return TypeRegistry.Never;
        }
    }

    private TypeBase CheckExpression(ExpressionNode expression, TypeBase? expectedType = null)
    {
        TypeBase type;
        switch (expression)
        {
            case IntegerLiteralNode lit:
                var tvId = $"lit_{lit.Span.Index}_{_nextLiteralTypeVarId++}";
                type = CreateLiteralTypeVar(tvId, lit.Span, TypeRegistry.ComptimeInt);
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
            case AssignmentExpressionNode ae:
                type = CheckAssignmentExpression(ae);
                break;
            case CallExpressionNode call:
                type = CheckCallExpression(call, expectedType);
                break;
            case IfExpressionNode ie:
            {
                var ct = CheckExpression(ie.Condition);
                var prunedCt = ct.Prune();
                if (!prunedCt.Equals(TypeRegistry.Bool))
                    ReportError(
                        "mismatched types",
                        ie.Condition.Span,
                        $"expected `bool`, found `{prunedCt}`",
                        "E2002");
                var tt = CheckExpression(ie.ThenBranch);
                if (ie.ElseBranch != null)
                {
                    var et = CheckExpression(ie.ElseBranch);
                    type = UnifyTypes(tt, et, ie.Span);
                }
                else
                {
                    type = TypeRegistry.Never;
                }

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
                var en = CheckExpression(re.End);
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

                // Coerce comptime_int to isize (Range uses isize fields) - unify handles TypeVar propagation
                if (prunedSt is ComptimeIntType)
                    UnifyTypes(st, TypeRegistry.ISize, re.Start.Span);
                if (prunedEn is ComptimeIntType)
                    UnifyTypes(en, TypeRegistry.ISize, re.End.Span);

                // Return Range type from core.range
                // Try FQN lookup first (works after prelude is loaded)
                if (!_compilation.StructsByFqn.TryGetValue("core.range.Range", out var rangeType))
                {
                    ReportError(
                        "Range type not found",
                        re.Span,
                        "ensure `core.range` is loaded via prelude",
                        "E2003");
                    type = TypeRegistry.Never;
                    break;
                }

                type = rangeType;
                break;
            }
            case MatchExpressionNode match:
                type = CheckMatchExpression(match, expectedType);
                break;
            case AddressOfExpressionNode adr:
            {
                var tt = CheckExpression(adr.Target);
                type = new ReferenceType(tt);
                break;
            }
            case DereferenceExpressionNode dr:
            {
                var pt = CheckExpression(dr.Target);
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
                type = CheckMemberAccessExpression(ma);
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
                StructType? structType = expectedType switch
                {
                    StructType st => st,
                    GenericType gt => InstantiateStruct(gt, anon.Span),
                    _ => null
                };

                if (structType == null)
                {
                    ReportError(
                        "anonymous struct literal requires a target struct type",
                        anon.Span,
                        "add a type annotation",
                        "E2018");
                    type = TypeRegistry.I32;
                    break;
                }

                ValidateStructLiteralFields(structType, anon.Fields, anon.Span);
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
                var it = CheckExpression(ix.Index);
                var prunedIt = it.Prune();  // Prune to get the actual type

                if (!TypeRegistry.IsIntegerType(prunedIt))
                    ReportError(
                        "array index must be an integer",
                        ix.Index.Span,
                        $"found `{prunedIt}`",
                        "E2027");
                else if (prunedIt is ComptimeIntType)
                {
                    // Resolve comptime_int indices to usize - unify handles TypeVar propagation
                    UnifyTypes(it, TypeRegistry.USize, ix.Index.Span);
                }

                if (bt is ArrayType at) type = at.ElementType;
                else if (bt is StructType st && TypeRegistry.IsSlice(st)) type = st.TypeArguments[0];
                else
                {
                    ReportError(
                        $"cannot index into value of type `{bt}`",
                        ix.Base.Span,
                        "only arrays and slices can be indexed",
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
                type = dst;
                break;
            }
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

            if (expectedOption.TypeArguments.Count > 0 &&
                (type.Equals(expectedOption.TypeArguments[0]) ||
                 (type is ComptimeIntType && TypeRegistry.IsIntegerType(expectedOption.TypeArguments[0]))))
            {
                return expectedOption;
            }
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
                sourceType is ComptimeIntType &&
                TypeRegistry.IsIntegerType(optionTarget.TypeArguments[0]))
                return CoercionKind.Wrap;
        }

        // Integer widening (includes comptime_int hardening)
        if (sourceType is ComptimeIntType && TypeRegistry.IsIntegerType(targetType))
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
                return TypeRegistry.MakeSlice(et);
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
    /// </summary>
    public void VerifyAllTypesResolved()
    {
        foreach (var tv in _literalTypeVars)
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
        }
    }

    private void PushScope() => _scopes.Push([]);
    private void PopScope() => _scopes.Pop();

    private void DeclareVariable(string name, TypeBase type, SourceSpan span)
    {
        var cur = _scopes.Peek();
        if (!cur.TryAdd(name, type))
            ReportError(
                $"variable `{name}` is already declared",
                span,
                "variable redeclaration",
                "E2005");
    }

    private bool TryLookupVariable(string name, out TypeBase type)
    {
        foreach (var scope in _scopes)
        {
            if (scope.TryGetValue(name, out var t))
            {
                type = t;
                return true;
            }
        }

        type = TypeRegistry.Void;
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
                _ => false
            };
        }

        foreach (var p in fn.Parameters)
            if (HasGeneric(p.Type))
                return true;
        if (HasGeneric(fn.ReturnType)) return true;
        return false;
    }

    private static TypeBase SubstituteGenerics(TypeBase type, Dictionary<string, TypeBase> bindings) => type switch
    {
        GenericParameterType gp => bindings.TryGetValue(gp.ParamName, out var b) ? b : gp,
        ReferenceType rt => new ReferenceType(SubstituteGenerics(rt.InnerType, bindings)),
        ArrayType at => new ArrayType(SubstituteGenerics(at.ElementType, bindings), at.Length),
        StructType st => SubstituteStructType(st, bindings),
        EnumType et => SubstituteEnumType(et, bindings),
        GenericType gt => new GenericType(gt.BaseName,
            gt.TypeArguments.Select(a => SubstituteGenerics(a, bindings)).ToList()),
        _ => type
    };

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
                if (bindings.TryGetValue(gp.ParamName, out var existing))
                {
                    if (existing is ComptimeIntType && TypeRegistry.IsIntegerType(arg))
                    {
                        bindings[gp.ParamName] = arg;
                        return true;
                    }

                    if (arg is ComptimeIntType && TypeRegistry.IsIntegerType(existing))
                        return true;

                    if (!existing.Equals(arg))
                    {
                        conflictParam = gp.ParamName;
                        conflictTypes = (existing, arg);
                        return false;
                    }

                    return true;
                }

                if (arg is ComptimeIntType)
                {
                    bindings[gp.ParamName] = arg;
                    return true;
                }

                bindings[gp.ParamName] = arg;
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
            default:
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

        // Substitute type arguments
        var updatedTypeArgs = new List<TypeBase>(structType.TypeArguments.Count);
        foreach (var typeArg in structType.TypeArguments)
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

    private FunctionDeclarationNode? EnsureSpecialization(FunctionEntry genericEntry, Dictionary<string, TypeBase> bindings,
        IReadOnlyList<TypeBase> concreteParamTypes)
    {
        var key = BuildSpecKey(genericEntry.Name, concreteParamTypes);
        if (_emittedSpecs.Contains(key))
        {
            // Already specialized - find and return the existing specialized node
            return _specializations.FirstOrDefault(s =>
                s.Name == genericEntry.Name &&
                s.Parameters.Count == concreteParamTypes.Count &&
                s.Parameters.Select((p, i) => ResolveTypeNode(p.Type) ?? TypeRegistry.Never).SequenceEqual(concreteParamTypes));
        }

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
            var newFn = new FunctionDeclarationNode(genericEntry.AstNode.Span, genericEntry.Name, newParams, newRetNode,
                genericEntry.AstNode.Body, genericEntry.IsForeign ? FunctionModifiers.Foreign : FunctionModifiers.None);
            CheckFunction(newFn);
            _specializations.Add(newFn);
            _emittedSpecs.Add(key);
            return newFn;
        }
        finally
        {
            _currentBindings = null;
            PopGenericScope();
        }
    }

    private static TypeNode CreateTypeNodeFromTypeBase(SourceSpan span, TypeBase t) => t switch
    {
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
        _ => new NamedTypeNode(span, t.Name)
    };

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
                // Bind variable to the payload type
                _scopes.Peek()[vp.Name] = type;
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
        FunctionDeclarationNode astNode, bool isForeign, bool isGeneric)
    {
        Name = name;
        ParameterTypes = parameterTypes;
        ReturnType = returnType;
        AstNode = astNode;
        IsForeign = isForeign;
        IsGeneric = isGeneric;
    }

    public string Name { get; }
    public IReadOnlyList<TypeBase> ParameterTypes { get; }
    public TypeBase ReturnType { get; }
    public FunctionDeclarationNode AstNode { get; }
    public bool IsForeign { get; }
    public bool IsGeneric { get; }
}

// ForLoopTypes struct removed - iterator protocol types now stored directly on ForLoopNode