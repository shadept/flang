using FLang.Core;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;
using FLang.Frontend.Ast.Types;
using Microsoft.Extensions.Logging;

namespace FLang.Semantics;

public partial class TypeChecker
{
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
    private static bool ContainsTypeDirectly(TypeBase type, string targetFqn)
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
            _compilation.ModuleImports[modulePath] = [];

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
        // Skip if errors already exist — unresolved literals are likely a consequence
        if (!_diagnostics.Any(d => d.Severity == DiagnosticSeverity.Error))
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

            // Implicit return: if the function is non-void and the last statement is
            // an expression statement, treat it as a tail expression (like blocks do).
            // Rewrite `expr` → `return expr` so return type checking and lowering work normally.
            if (!expectedReturn.Equals(TypeRegistry.Void) && function.Body.Count > 0
                && function.Body[^1] is ExpressionStatementNode tailExpr
                && function.Body is List<StatementNode> bodyList)
            {
                var returnStmt = new ReturnStatementNode(tailExpr.Span, tailExpr.Expression);
                bodyList[^1] = returnStmt;
                CheckReturnStatement(returnStmt);
            }

            // Check for missing return in non-void functions.
            // After implicit return rewriting, the last statement should be a return
            // if the function has a non-void return type.
            if (!expectedReturn.Equals(TypeRegistry.Void) && !IsNever(expectedReturn))
            {
                var hasReturn = function.Body.Count > 0 && function.Body[^1] is ReturnStatementNode;
                if (!hasReturn)
                {
                    var span = function.Body.Count > 0
                        ? function.Body[^1].Span
                        : function.Span;
                    var returnTypeName = FormatTypeNameForDisplay(expectedReturn);
                    ReportError(
                        $"function `{function.Name}` expects return type `{returnTypeName}` but body does not return a value",
                        span,
                        "missing return",
                        "E2049");
                }
            }
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

    // --- Colocated utilities (only used by declaration methods) ---

    private void PushGenericScope(FunctionDeclarationNode function)
    {
        _genericScopes.Push(CollectGenericParamNames(function));
    }

    private void PopGenericScope()
    {
        if (_genericScopes.Count > 0)
            _genericScopes.Pop();
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
}
