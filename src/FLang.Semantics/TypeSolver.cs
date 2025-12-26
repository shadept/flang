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
public class TypeSolver
{
    private readonly ILogger<TypeSolver> _logger;
    private readonly Compilation _compilation;
    private readonly List<Diagnostic> _diagnostics = [];

    // Overload-ready function registry
    private readonly Dictionary<string, List<FunctionEntry>> _functions = new();

    // Variable scopes
    private readonly Stack<Dictionary<string, FType>> _scopes = new();

    // Struct type cache/registry - prevents duplicate struct instances for same fully qualified name
    // Key: struct name (with type parameters if generic)
    private readonly Dictionary<string, StructType> _structs = new();
    private readonly Dictionary<string, StructType> _structSpecializations = new();

    // Anonymous struct literal mapping
    private readonly Dictionary<AnonymousStructExpressionNode, StructType> _anonymousStructTypes = new();
    private readonly Dictionary<ExpressionNode, OptionType> _optionLifts = new();

    // AST type map
    private readonly Dictionary<AstNode, FType> _typeMap = new();

    // Track all instantiated types for global type table generation
    private readonly HashSet<FType> _instantiatedTypes = new();

    // Resolved call targets scoped per function
    private readonly Dictionary<(FunctionDeclarationNode Function, CallExpressionNode Call), ResolvedCall> _resolvedCalls = new();

    private readonly HashSet<string> _emittedSpecs = [];

    private readonly Stack<HashSet<string>> _genericScopes = new();
    private readonly Stack<FunctionDeclarationNode> _functionStack = new();

    // Track binding recursion depth for indented logging
    private int _bindingDepth = 0;

    private static string BuildSpecKey(string name, IReadOnlyList<FType> paramTypes)

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

    private static string BuildStructSpecKey(string name, IReadOnlyList<FType> typeArgs)
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

    private readonly struct ResolvedCall
    {
        public ResolvedCall(string name, IReadOnlyList<FType> parameterTypes, bool isForeign)
        {
            Name = name;
            ParameterTypes = parameterTypes;
            IsForeign = isForeign;
        }

        public string Name { get; }
        public IReadOnlyList<FType> ParameterTypes { get; }
        public bool IsForeign { get; }
    }

    // Specializations to emit
    private readonly List<FunctionDeclarationNode> _specializations = [];
    private readonly HashSet<string> _emittedMangled = [];

    public TypeSolver(Compilation compilation, ILogger<TypeSolver> logger)
    {
        _compilation = compilation;
        _logger = logger;
        PushScope(); // Global scope
    }

    public IReadOnlyList<Diagnostic> Diagnostics => _diagnostics;

    public FType? GetType(AstNode node) => _typeMap.GetValueOrDefault(node);

    public StructType? GetAnonymousStructType(AnonymousStructExpressionNode node)
        => _anonymousStructTypes.GetValueOrDefault(node);

    public IReadOnlySet<FType> InstantiatedTypes => _instantiatedTypes;

    public FType? ResolveTypeName(string typeName)
    {
        var builtInType = TypeRegistry.GetTypeByName(typeName);
        if (builtInType != null) return builtInType;
        if (_structs.TryGetValue(typeName, out var st)) return st;
        return null;
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

    public void CollectFunctionSignatures(ModuleNode module)
    {
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

                var parameterTypes = new List<FType>();
                foreach (var param in function.Parameters)
                {
                    var pt = ResolveTypeNode(param.Type);
                    if (pt == null)
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            $"cannot find type `{(param.Type as NamedTypeNode)?.Name ?? "unknown"}` in this scope",
                            param.Type.Span,
                            "not found in this scope",
                            "E2003"));
                        pt = TypeRegistry.I32;
                    }

                    parameterTypes.Add(pt);
                }

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
    }

    public void CollectStructDefinitions(ModuleNode module)
    {
        foreach (var structDecl in module.Structs)
        {
            var fields = new List<(string, FType)>();
            foreach (var field in structDecl.Fields)
            {
                var ft = ResolveTypeNode(field.Type);
                if (ft == null)
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"cannot find type `{(field.Type as NamedTypeNode)?.Name ?? "unknown"}` in this scope",
                        field.Type.Span,
                        "not found in this scope",
                        "E2003"));
                    ft = TypeRegistry.I32;
                }

                fields.Add((field.Name, ft));
            }

            var stype = new StructType(structDecl.Name, structDecl.TypeParameters, fields);
            _structs[structDecl.Name] = stype;
        }
    }

    public void CheckModuleBodies(ModuleNode module)
    {
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
                var parameterTypes = new List<FType>();
                foreach (var param in function.Parameters)
                {
                    var pt = ResolveTypeNode(param.Type) ?? TypeRegistry.I32;
                    parameterTypes.Add(pt);
                }

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
    }

    private void CheckFunction(FunctionDeclarationNode function)
    {
        PushGenericScope(function);
        PushScope();
        _functionStack.Push(function);
        try
        {
            foreach (var p in function.Parameters)
            {
                var t = ResolveTypeNode(p.Type);
                if (t != null) DeclareVariable(p.Name, t, p.Span);
            }

            var expectedReturn = ResolveTypeNode(function.ReturnType) ?? TypeRegistry.Void;
            foreach (var stmt in function.Body) CheckStatement(stmt, expectedReturn);
        }
        finally
        {
            PopScope();
            PopGenericScope();
            _functionStack.Pop();
        }
    }

    private void CheckStatement(StatementNode statement, FType? expectedReturnType)
    {
        switch (statement)
        {
            case ReturnStatementNode ret:
                CheckReturnStatement(ret, expectedReturnType);
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

    private void CheckReturnStatement(ReturnStatementNode ret, FType? expectedReturnType)
    {
        var et = CheckExpression(ret.Expression, expectedReturnType);
        if (expectedReturnType != null && !CanCoerse(et, expectedReturnType))
        {
            _diagnostics.Add(Diagnostic.Error(
                "mismatched types",
                ret.Span,
                $"expected `{expectedReturnType}`, found `{et}`",
                "E2002"));
        }
        else if (expectedReturnType != null)
        {
            // Update type map with resolved type to avoid comptime_int escape
            var unified = UnifyTypes(et, expectedReturnType);
            UpdateTypeMapRecursive(ret.Expression, unified);
        }
    }

    private void CheckVariableDeclaration(VariableDeclarationNode v)
    {
        var dt = ResolveTypeNode(v.Type);
        var it = v.Initializer != null ? CheckExpression(v.Initializer, dt) : null;
        if (it != null && dt != null)
        {
            // Use general coercion rules
            var coerces = CanCoerse(it, dt);
            if (!coerces)
                _diagnostics.Add(Diagnostic.Error(
                    "mismatched types",
                    v.Initializer!.Span,
                    $"expected `{dt}`, found `{it}`",
                    "E2002"));
            else
            {
                // Update type map with resolved type to avoid comptime_int escape
                var unified = UnifyTypes(it, dt);
                UpdateTypeMapRecursive(v.Initializer!, unified);
            }
            DeclareVariable(v.Name, dt, v.Span);
        }
        else
        {
            // Use declared type if available, otherwise inferred type from initializer
            var varType = dt ?? it;

            if (varType == null)
            {
                // Neither type annotation nor initializer present
                _diagnostics.Add(Diagnostic.Error(
                    "cannot infer type",
                    v.Span,
                    "type annotations needed: variable declaration requires either a type annotation or an initializer",
                    "E2001"));
                DeclareVariable(v.Name, TypeRegistry.I32, v.Span); // Default to i32 to avoid cascading errors
            }
            else if (TypeRegistry.IsComptimeType(varType))
            {
                _diagnostics.Add(Diagnostic.Error(
                    "cannot infer type",
                    v.Span,
                    $"type annotations needed: variable has comptime type `{varType}`",
                    "E2001"));
                DeclareVariable(v.Name, TypeRegistry.ISize, v.Span);
            }
            else
            {
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
        if (fl.IterableExpression is RangeExpressionNode range)
        {
            var st = CheckExpression(range.Start);
            var en = CheckExpression(range.End);
            if (!TypeRegistry.IsIntegerType(st) || !TypeRegistry.IsIntegerType(en))
                _diagnostics.Add(Diagnostic.Error(
                    "range bounds must be integers",
                    fl.IterableExpression.Span,
                    $"found `{st}..{en}`",
                    "E2002"));
            else
            {
                // Resolve comptime_int range bounds to match iterator type (i32)
                // This is valid because the iterator variable constrains the range type
                if (st is ComptimeIntType)
                    UpdateTypeMapRecursive(range.Start, TypeRegistry.I32);
                if (en is ComptimeIntType)
                    UpdateTypeMapRecursive(range.End, TypeRegistry.I32);
            }
            DeclareVariable(fl.IteratorVariable, TypeRegistry.I32, fl.Span);
        }
        else
        {
            CheckExpression(fl.IterableExpression);
            DeclareVariable(fl.IteratorVariable, TypeRegistry.I32, fl.Span);
        }

        CheckExpression(fl.Body);
        PopScope();
    }

    private void CheckDeferStatement(DeferStatementNode ds)
    {
        CheckExpression(ds.Expression);
    }

    private FType CheckStringLiteral(StringLiteralNode strLit)
    {
        if (_structs.TryGetValue("String", out var st))
            return st;

        _diagnostics.Add(Diagnostic.Error(
            "String type not found",
            strLit.Span,
            "make sure to import core.string",
            "E2013"));
        return TypeRegistry.I32;
    }

    private FType CheckIdentifierExpression(IdentifierExpressionNode id)
    {
        // First try variable lookup
        if (TryLookupVariable(id.Name, out var t))
            return t;

        // Check if this identifier is a type name used as a value (type literal)
        var resolvedType = ResolveTypeName(id.Name);
        if (resolvedType != null)
        {
            // This is a type literal: i32, Point, etc. used as a value
            // It has type Type(T) where T is the referenced type
            var typeStruct = TypeRegistry.GetTypeStruct(resolvedType);

            // Track that this type is used as a literal
            _instantiatedTypes.Add(resolvedType);
            return typeStruct;
        }

        // Not found as variable or type
        _diagnostics.Add(Diagnostic.Error(
            $"cannot find value or type `{id.Name}` in this scope",
            id.Span,
            "not found in this scope",
            "E2004"));
        return TypeRegistry.I32;
    }

    private FType CheckBinaryExpression(BinaryExpressionNode be)
    {
        var lt = CheckExpression(be.Left);
        var rt = CheckExpression(be.Right, lt);

        if (be.Operator >= BinaryOperatorKind.Equal && be.Operator <= BinaryOperatorKind.GreaterThanOrEqual)
        {
            if (!IsCompatible(lt, rt))
                _diagnostics.Add(Diagnostic.Error(
                    "mismatched types in comparison",
                    be.Span,
                    $"cannot compare `{lt}` with `{rt}`",
                    "E2002"));
            else
            {
                var unified = UnifyTypes(lt, rt);
                UpdateTypeMapRecursive(be.Left, unified);
                UpdateTypeMapRecursive(be.Right, unified);
            }
            return TypeRegistry.Bool;
        }
        else
        {
            if (!IsCompatible(lt, rt))
            {
                _diagnostics.Add(Diagnostic.Error(
                    "mismatched types",
                    be.Span,
                    $"cannot apply operator to `{lt}` and `{rt}`",
                    "E2002"));
                return lt;
            }
            else
            {
                var unified = UnifyTypes(lt, rt);
                UpdateTypeMapRecursive(be.Left, unified);
                UpdateTypeMapRecursive(be.Right, unified);
                return unified;
            }
        }
    }

    private FType CheckAssignmentExpression(AssignmentExpressionNode ae)
    {
        var vt = LookupVariable(ae.TargetName, ae.Span);
        var val = CheckExpression(ae.Value, vt);
        if (!CanCoerse(val, vt))
            _diagnostics.Add(Diagnostic.Error(
                "mismatched types",
                ae.Value.Span,
                $"expected `{vt}`, found `{val}`",
                "E2002"));
        else
        {
            // Update type map with resolved type to avoid comptime_int escape
            var unified = UnifyTypes(val, vt);
            UpdateTypeMapRecursive(ae.Value, unified);
        }
        return vt;
    }

    private FType CheckCallExpression(CallExpressionNode call, FType? expectedType)
    {
        if (_functions.TryGetValue(call.FunctionName, out var candidates))
        {
            _logger.LogDebug("{Indent}Considering {CandidateCount} candidates for '{FunctionName}'", Indent(), candidates.Count, call.FunctionName);
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
            Dictionary<string, FType>? bestBindings = null;
            List<FType>? bestConcreteParams = null;
            var bestGenericCost = int.MaxValue;
            string? conflictName = null;
            (FType Existing, FType Incoming)? conflictPair = null;

            foreach (var cand in candidates)
            {
                using var _candScope = new BindingDepthScope(this);
                _logger.LogDebug("{Indent}Candidate '{Name}': IsGeneric={IsGeneric}, ParamCount={ParamCount}, ArgCount={ArgCount}",
                    Indent(), cand.Name, cand.IsGeneric, cand.ParameterTypes.Count, argTypes.Count);
                if (!cand.IsGeneric) continue;
                if (cand.ParameterTypes.Count != argTypes.Count) continue;

                _logger.LogDebug("{Indent}Attempting generic binding for '{Name}'", Indent(), cand.Name);
                var bindings = new Dictionary<string, FType>();
                var okGen = true;
                for (var i = 0; i < argTypes.Count; i++)
                {
                    var argType = argTypes[i] ?? throw new NullReferenceException();
                    using var _paramScope = new BindingDepthScope(this);
                    _logger.LogDebug("{Indent}Binding param[{Index}] '{ParamName}' with arg '{ArgType}'",
                        Indent(), i, cand.ParameterTypes[i].Name, argType.Name);
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

                var concreteParams = new List<FType>();
                for (var i = 0; i < cand.ParameterTypes.Count; i++)
                    concreteParams.Add(SubstituteGenerics(cand.ParameterTypes[i], bindings));

                if (!TryComputeCoercionCost(argTypes, concreteParams, out var genCost))
                    continue;

                if (genCost < bestGenericCost)
                {
                    bestGeneric = cand;
                    bestBindings = bindings;
                    bestConcreteParams = concreteParams;
                    bestGenericCost = genCost;
                }
            }

            FunctionEntry? chosen;
            Dictionary<string, FType>? chosenBindings = null;
            List<FType>? chosenConcreteParams = null;

            if (bestNonGeneric != null && (bestGeneric == null || bestNonGenericCost <= bestGenericCost))
            {
                chosen = bestNonGeneric;
            }
            else
            {
                chosen = bestGeneric;
                chosenBindings = bestBindings;
                chosenConcreteParams = bestConcreteParams;
            }

            if (chosen == null)
            {
                if (conflictName != null && conflictPair.HasValue)
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"conflicting bindings for `{conflictName}`",
                        call.Span,
                        $"`{conflictName}` mapped to `{conflictPair.Value.Existing}` and `{conflictPair.Value.Incoming}`",
                        "E2102"));
                }
                else
                {
                    _diagnostics.Add(Diagnostic.Error(
                        $"no applicable overload found for `{call.FunctionName}`",
                        call.Span,
                        "no matching function signature",
                        "E2011"));
                }

                return TypeRegistry.I32;
            }
            else if (!chosen.IsGeneric)
            {
                var type = chosen.ReturnType;
                if (expectedType != null)
                    type = UnifyTypes(type, expectedType);
                for (var i = 0; i < call.Arguments.Count; i++)
                {
                    var unified = UnifyTypes(argTypes[i], chosen.ParameterTypes[i]);
                    UpdateTypeMapRecursive(call.Arguments[i], unified);
                }
                if (_functionStack.Count > 0)
                    _resolvedCalls[(_functionStack.Peek(), call)] =
                        new ResolvedCall(chosen.Name, chosen.ParameterTypes, chosen.IsForeign);
                return type;
            }
            else
            {
                var bindings = chosenBindings!;
                if (expectedType != null)
                    RefineBindingsWithExpectedReturn(chosen.ReturnType, expectedType, bindings);
                var ret = SubstituteGenerics(chosen.ReturnType, bindings);
                var type = expectedType != null ? UnifyTypes(ret, expectedType) : ret;

                var concreteParams = new List<FType>();
                for (var i = 0; i < chosen.ParameterTypes.Count; i++)
                    concreteParams.Add(SubstituteGenerics(chosen.ParameterTypes[i], bindings));

                for (var i = 0; i < call.Arguments.Count; i++)
                {
                    var unified = UnifyTypes(argTypes[i], concreteParams[i]);
                    UpdateTypeMapRecursive(call.Arguments[i], unified);
                }

                _resolvedCalls[(_functionStack.Peek(), call)] =
                    new ResolvedCall(chosen.Name, concreteParams, chosen.IsForeign);
                EnsureSpecialization(chosen, bindings, concreteParams);
                return type;
            }
        }
        else
        {
            // Temporary built-in fallback for C printf without explicit import
            if (call.FunctionName == "printf")
            {
                // Check arguments and resolve comptime_int to i32 for variadic args
                var argTypes = new List<FType>();
                for (var i = 0; i < call.Arguments.Count; i++)
                {
                    var argType = CheckExpression(call.Arguments[i]);
                    if (argType is ComptimeIntType)
                    {
                        // Resolve comptime_int to i32 for variadic functions
                        UpdateTypeMapRecursive(call.Arguments[i], TypeRegistry.I32);
                        argTypes.Add(TypeRegistry.I32);
                    }
                    else
                    {
                        argTypes.Add(argType);
                    }
                }
                if (_functionStack.Count > 0)
                    _resolvedCalls[(_functionStack.Peek(), call)] =
                        new ResolvedCall("printf", argTypes, true);
                return TypeRegistry.I32;
            }

            _diagnostics.Add(Diagnostic.Error(
                $"cannot find function `{call.FunctionName}` in this scope",
                call.Span,
                "not found in this scope",
                "E2004"));
            return TypeRegistry.I32;
        }
    }

    private FType CheckExpression(ExpressionNode expression, FType? expectedType = null)
    {
        FType type;
        switch (expression)
        {
            case IntegerLiteralNode:
                type = TypeRegistry.ComptimeInt;
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
                    if (!ct.Equals(TypeRegistry.Bool))
                        _diagnostics.Add(Diagnostic.Error(
                            "mismatched types",
                            ie.Condition.Span,
                            $"expected `bool`, found `{ct}`",
                            "E2002"));
                    var tt = CheckExpression(ie.ThenBranch);
                    var et = ie.ElseBranch != null ? CheckExpression(ie.ElseBranch) : TypeRegistry.I32;
                    if (!IsCompatible(tt, et))
                        _diagnostics.Add(Diagnostic.Error(
                            "if and else branches have incompatible types",
                            ie.Span,
                            $"`if` branch: `{tt}`, `else` branch: `{et}`",
                            "E2002"));
                    type = UnifyTypes(tt, et);
                    break;
                }
            case BlockExpressionNode bex:
                {
                    PushScope();
                    FType? last = null;
                    foreach (var s in bex.Statements)
                    {
                        if (s is ExpressionStatementNode es) last = CheckExpression(es.Expression);
                        else
                        {
                            CheckStatement(s, null);
                            last = null;
                        }
                    }

                    if (bex.TrailingExpression != null) last = CheckExpression(bex.TrailingExpression);
                    PopScope();
                    type = last ?? TypeRegistry.I32;
                    break;
                }
            case RangeExpressionNode re:
                {
                    var st = CheckExpression(re.Start);
                    var en = CheckExpression(re.End);
                    if (!TypeRegistry.IsIntegerType(st) || !TypeRegistry.IsIntegerType(en))
                        _diagnostics.Add(Diagnostic.Error(
                            "range bounds must be integers",
                            re.Span,
                            $"found `{st}..{en}`",
                            "E2002"));
                    type = TypeRegistry.I32; // placeholder
                    break;
                }
            case AddressOfExpressionNode adr:
                {
                    var tt = CheckExpression(adr.Target);
                    type = new ReferenceType(tt);
                    break;
                }
            case DereferenceExpressionNode dr:
                {
                    var pt = CheckExpression(dr.Target);
                    if (pt is ReferenceType rft) type = rft.InnerType;
                    else if (pt is OptionType opt && opt.InnerType is ReferenceType rf2) type = rf2.InnerType;
                    else
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            "cannot dereference non-reference type",
                            dr.Span,
                            $"expected `&T` or `&T?`, found `{pt}`",
                            "E2012"));
                        type = TypeRegistry.I32;
                    }

                    break;
                }
            case FieldAccessExpressionNode fa:
                {
                    var obj = CheckExpression(fa.Target);

                    // Convert arrays and slices to their canonical struct representations
                    var structType = obj switch
                    {
                        StructType st => st,
                        OptionType opt => TypeRegistry.GetOptionStruct(opt.InnerType),
                        SliceType slice => TypeRegistry.GetSliceStruct(slice.ElementType),
                        ArrayType array => TypeRegistry.GetSliceStruct(array.ElementType),
                        _ => null
                    };

                    if (structType != null)
                    {
                        var ft = structType.GetFieldType(fa.FieldName);
                        if (ft == null)
                        {
                            _diagnostics.Add(Diagnostic.Error(
                                $"no field `{fa.FieldName}` on type `{obj.Name}`",
                                fa.Span,
                                $"type `{obj.Name}` does not have a field named `{fa.FieldName}`",
                                "E2013"));
                            type = TypeRegistry.I32;
                        }
                        else type = ft;
                    }
                    else
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            "cannot access field on non-struct type",
                            fa.Span,
                            $"expected struct type, found `{obj}`",
                            "E2013"));
                        type = TypeRegistry.I32;
                    }

                    break;
                }
            case StructConstructionExpressionNode sc:
                {
                    var resolvedType = ResolveTypeNode(sc.TypeName);
                    OptionType? optionLiteral = null;
                    if (resolvedType is OptionType optionFromAnnotation)
                    {
                        optionLiteral = optionFromAnnotation;
                        resolvedType = TypeRegistry.GetOptionStruct(optionFromAnnotation.InnerType);
                    }
                    if (resolvedType == null)
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            $"cannot find type `{(sc.TypeName as NamedTypeNode)?.Name ?? "unknown"}`",
                            sc.TypeName.Span,
                            "not found in this scope",
                            "E2003"));
                        type = TypeRegistry.I32;
                        break;
                    }

                    if (resolvedType is GenericType genericType)
                        resolvedType = InstantiateStruct(genericType, sc.Span);

                    if (resolvedType is OptionType optFromGeneric)
                    {
                        optionLiteral = optFromGeneric;
                        resolvedType = TypeRegistry.GetOptionStruct(optFromGeneric.InnerType);
                    }

                    if (resolvedType is not StructType st)
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            $"type `{resolvedType.Name}` is not a struct",
                            sc.TypeName.Span,
                            "cannot construct non-struct type",
                            "E2014"));
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
                            _diagnostics.Add(Diagnostic.Error(
                                $"struct `{st.Name}` does not have a field named `{fieldName}`",
                                fieldExpr.Span,
                                "unknown field",
                                "E2013"));
                            continue;
                        }

                        var valueType = CheckExpression(fieldExpr, fieldType);
                        if (!CanCoerse(valueType, fieldType))
                            _diagnostics.Add(Diagnostic.Error(
                                $"mismatched types for field `{fieldName}`",
                                fieldExpr.Span,
                                $"expected `{fieldType}`, found `{valueType}`",
                                "E2002"));
                        else
                        {
                            var unified = UnifyTypes(valueType, fieldType);
                            UpdateTypeMapRecursive(fieldExpr, unified);
                        }
                    }

                    foreach (var (fieldName, _) in st.Fields)
                        if (!provided.Contains(fieldName))
                            _diagnostics.Add(Diagnostic.Error(
                                $"missing field `{fieldName}` in struct construction",
                                sc.Span,
                                $"struct `{st.Name}` requires field `{fieldName}`",
                                "E2015"));
                    type = optionLiteral != null ? optionLiteral : st;
                    break;
                }
            case AnonymousStructExpressionNode anon:
                {
                    StructType? structType = expectedType switch
                    {
                        StructType st => st,
                        OptionType opt => TypeRegistry.GetOptionStruct(opt.InnerType),
                        GenericType gt => InstantiateStruct(gt, anon.Span),
                        _ => null
                    };

                    if (structType == null)
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            "anonymous struct literal requires a target struct type",
                            anon.Span,
                            "add a type annotation",
                            "E2014"));
                        type = TypeRegistry.I32;
                        break;
                    }

                    ValidateStructLiteralFields(structType, anon.Fields, anon.Span);
                    _anonymousStructTypes[anon] = structType;

                    if (expectedType is OptionType optExpected)
                        type = optExpected;
                    else
                        type = structType;

                    break;
                }

            case NullLiteralNode nullLiteral:
                {
                    var optionType = expectedType switch
                    {
                        OptionType opt => opt,
                        StructType st when st.StructName == "Option" && st.Fields.Any(f => f.Name == "value") =>
                            new OptionType(st.Fields.First(f => f.Name == "value").Type),
                        _ => null
                    };

                    if (optionType == null)
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            "cannot infer type of null literal",
                            nullLiteral.Span,
                            "add an option type annotation or use an explicit constructor",
                            "E2001"));
                        type = TypeRegistry.I32;
                    }
                    else
                    {
                        type = optionType;
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
                        _diagnostics.Add(Diagnostic.Error(
                            "cannot infer type of empty array literal",
                            al.Span,
                            "consider adding type annotation",
                            "E2016"));
                        type = new ArrayType(TypeRegistry.I32, 0);
                    }
                    else
                    {
                        var first = CheckExpression(al.Elements[0]);
                        var unified = first;
                        for (var i = 1; i < al.Elements.Count; i++)
                        {
                            var et = CheckExpression(al.Elements[i]);
                            if (!IsCompatible(et, unified))
                                _diagnostics.Add(Diagnostic.Error(
                                    "array elements have incompatible types",
                                    al.Elements[i].Span,
                                    $"expected `{unified}`, found `{et}`",
                                    "E2002"));
                            else unified = UnifyTypes(unified, et);
                        }

                        type = new ArrayType(unified, al.Elements.Count);
                    }

                    break;
                }
            case IndexExpressionNode ix:
                {
                    var bt = CheckExpression(ix.Base);
                    var it = CheckExpression(ix.Index);
                    if (!TypeRegistry.IsIntegerType(it))
                        _diagnostics.Add(Diagnostic.Error(
                            "array index must be an integer",
                            ix.Index.Span,
                            $"found `{it}`",
                            "E2017"));
                    else if (it is ComptimeIntType)
                    {
                        // Resolve comptime_int indices to usize
                        UpdateTypeMapRecursive(ix.Index, TypeRegistry.USize);
                    }
                    if (bt is ArrayType at) type = at.ElementType;
                    else if (bt is SliceType sl) type = sl.ElementType;
                    else
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            $"cannot index into value of type `{bt}`",
                            ix.Base.Span,
                            "only arrays and slices can be indexed",
                            "E2018"));
                        type = TypeRegistry.I32;
                    }

                    break;
                }
            case CastExpressionNode c:
                {
                    var src = CheckExpression(c.Expression);
                    var dst = ResolveTypeNode(c.TargetType) ?? TypeRegistry.I32;
                    if (!CanExplicitCast(src, dst))
                        _diagnostics.Add(Diagnostic.Error(
                            "invalid cast",
                            c.Span,
                            $"cannot cast `{src}` to `{dst}`",
                            "E2020"));
                    type = dst;
                    break;
                }
            default:
                throw new Exception($"Unknown expression type: {expression.GetType().Name}");
        }

        type = ApplyOptionExpectation(expression, type, expectedType);
        _typeMap[expression] = type;
        return type;
    }

    private FType ApplyOptionExpectation(ExpressionNode expression, FType type, FType? expectedType)
    {
        if (expectedType is OptionType expectedOption)
        {
            if (type is OptionType actualOption)
            {
                if (!actualOption.InnerType.Equals(expectedOption.InnerType))
                {
                    _diagnostics.Add(Diagnostic.Error(
                        "mismatched option types",
                        expression.Span,
                        $"expected `{expectedOption}`, found `{actualOption}`",
                        "E2002"));
                }
                return expectedOption;
            }

            if (type is StructType structType && IsOptionStruct(structType, expectedOption.InnerType))
            {
                return expectedOption;
            }

            if (type.Equals(expectedOption.InnerType) ||
                (type is ComptimeIntType && TypeRegistry.IsIntegerType(expectedOption.InnerType)))
            {
                _optionLifts[expression] = expectedOption;
                return expectedOption;
            }
        }

        return type;
    }

    private static bool IsOptionStruct(StructType structType, FType innerType)
    {
        if (structType.StructName != "Option")
            return false;
        var valueField = structType.Fields.FirstOrDefault(f => f.Name == "value");
        return valueField.Type != null && valueField.Type.Equals(innerType);
    }

    private bool CanExplicitCast(FType source, FType target)
    {
        if (source.Equals(target)) return true;
        if (TypeRegistry.IsIntegerType(source) && TypeRegistry.IsIntegerType(target)) return true;
        if (source is ReferenceType && target is ReferenceType) return true;
        if (source is OptionType opt && opt.InnerType is ReferenceType && target is ReferenceType) return true;
        if (source is ReferenceType &&
            (target.Equals(TypeRegistry.USize) || target.Equals(TypeRegistry.ISize))) return true;
        if ((source.Equals(TypeRegistry.USize) || source.Equals(TypeRegistry.ISize)) &&
            target is ReferenceType) return true;

        // String is the canonical u8[] struct type, bidirectionally compatible
        // Slices represented as StructType("Slice", ...) or as SliceType (legacy)
        bool IsU8Slice(FType t) =>
            (t is SliceType st && st.ElementType.Equals(TypeRegistry.U8)) ||
            (t is StructType strt && strt.StructName == "String") ||
            (t is StructType strt2 && strt2.StructName == "Slice" && strt2.TypeParameters.Count > 0 &&
             strt2.TypeParameters[0] == "u8");

        if (source is StructType ss && ss.StructName == "String" && IsU8Slice(target)) return true;
        if (target is StructType ts && ts.StructName == "String" && IsU8Slice(source)) return true;

        // Array -> Slice casts (view cast) - handle both SliceType and StructType slice representations
        if (source is ArrayType arr)
        {
            if (target is SliceType slice && IsCompatible(arr.ElementType, slice.ElementType))
                return true;
            // Check if target is a Slice struct (canonical representation)
            if (target is StructType sliceStruct && sliceStruct.StructName == "Slice")
                return true; // Can cast array to any slice struct
        }

        return false;
    }

    // General implicit coercions used for variable initialization, assignments, arguments, etc.
    // Intent: collect all special-case coercions in one place so behavior is consistent across the solver.
    private bool CanCoerse(FType source, FType target)
    {
        // Trivial and baseline compatibility
        if (source.Equals(target)) return true;
        if (IsCompatible(source, target)) return true;

        if (target is OptionType optionTarget)
        {
            if (source is OptionType optionSource)
                return CanCoerse(optionSource.InnerType, optionTarget.InnerType);
            if (source is StructType optionStruct && IsOptionStruct(optionStruct, optionTarget.InnerType))
                return true;
            if (source.Equals(optionTarget.InnerType))
                return true;
        }

        // Helper: detect canonical slice struct and compare element by name when possible
        bool IsSliceStructOf(FType t, string elemName)
        {
            if (t is StructType st && st.StructName == "Slice")
            {
                // Type parameters are represented as strings (e.g., "u8")
                return st.TypeParameters.Count > 0 && st.TypeParameters[0] == elemName;
            }

            return false;
        }

        // Allow comptime int to any integer type
        if (source is ComptimeIntType && TypeRegistry.IsIntegerType(target)) return true;

        // Allow bool to implicitly cast to any integer type (bool -> 0 or 1)
        if (source.Equals(TypeRegistry.Bool) && TypeRegistry.IsIntegerType(target)) return true;

        // Array -> Slice (legacy SliceType)
        if (source is ArrayType arr && target is SliceType sl)
            return IsCompatible(arr.ElementType, sl.ElementType);

        // Array -> canonical Slice struct with same element
        if (source is ArrayType arr2 && IsSliceStructOf(target, arr2.ElementType.Name))
            return true;

        // &Array -> Slice (legacy SliceType)
        if (source is ReferenceType r1 && r1.InnerType is ArrayType rarr && target is SliceType sl2)
            return IsCompatible(rarr.ElementType, sl2.ElementType);

        // &Array -> canonical Slice struct
        if (source is ReferenceType r2 && r2.InnerType is ArrayType rarr2 &&
            IsSliceStructOf(target, rarr2.ElementType.Name))
            return true;

        // String <-> u8 slice views
        bool IsU8Slice(FType t)
        {
            if (t is SliceType st && st.ElementType.Equals(TypeRegistry.U8)) return true;
            if (t is StructType sst && sst.StructName == "Slice" && sst.TypeParameters.Count > 0 &&
                sst.TypeParameters[0] == "u8")
                return true;
            return false;
        }

        if (source is StructType ss && ss.StructName == "String" && IsU8Slice(target)) return true;
        if (target is StructType ts && ts.StructName == "String" && IsU8Slice(source)) return true;

        // Array decay: [T; N] -> &T (array value to pointer to first element)
        // This enables passing arrays to C functions expecting pointers (e.g., memset, memcpy)
        if (source is ArrayType arrValue && target is ReferenceType refTarget)
            return IsCompatible(arrValue.ElementType, refTarget.InnerType);

        // Pointer conversion: &[T; N] -> &T (pointer to array to pointer to first element)
        // This handles the case when array variables (stored as &[T; N]) are passed to pointer parameters
        if (source is ReferenceType { InnerType: ArrayType arrInRef } &&
            target is ReferenceType { InnerType: var targetInner })
            return IsCompatible(arrInRef.ElementType, targetInner);

        return false;
    }

    public FType? ResolveTypeNode(TypeNode? typeNode)
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
                            _instantiatedTypes.Add(bt);
                        }
                        return bt;
                    }

                    if (_structs.TryGetValue(named.Name, out var st))
                    {
                        // Track non-Type struct usage
                        if (st.StructName != "Type")
                        {
                            _instantiatedTypes.Add(st);
                        }
                        return st;
                    }

                    if (named.Name.Length == 1 && char.IsUpper(named.Name[0]))
                        return new GenericParameterType(named.Name);
                    _diagnostics.Add(Diagnostic.Error(
                        $"cannot find type `{named.Name}` in this scope",
                        named.Span,
                        "not found in this scope",
                        "E2003"));
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
                    return new OptionType(inner);
                }
            case GenericTypeNode gt:
                {
                    var args = new List<FType>();
                    foreach (var a in gt.TypeArguments)
                    {
                        var at = ResolveTypeNode(a);
                        if (at == null) return null;
                        args.Add(at);
                    }

                    // Special case for Type(T)
                    if (gt.Name == "Type")
                    {
                        if (args.Count != 1)
                        {
                            _diagnostics.Add(Diagnostic.Error(
                                "`Type` expects exactly one type argument",
                                gt.Span,
                                "usage: Type(T)",
                                "E2006"));
                            return null;
                        }

                        // Do NOT track Type(T) instantiations!
                        return TypeRegistry.GetTypeStruct(args[0]);
                    }

                    if (gt.Name == "Option")
                    {
                        if (args.Count != 1)
                        {
                            _diagnostics.Add(Diagnostic.Error(
                                "`Option` expects exactly one type argument",
                                gt.Span,
                                "usage: Option(T)",
                                "E2006"));
                            return null;
                        }

                        return new OptionType(args[0]);
                    }

                    if (!_structs.TryGetValue(gt.Name, out var template))
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            $"cannot find generic type `{gt.Name}`",
                            gt.Span,
                            "not found in this scope",
                            "E2003"));
                        return null;
                    }

                    // Track generic struct instantiation
                    var instantiated = InstantiateStruct(template, args, gt.Span);
                    if (instantiated != null)
                    {
                        _instantiatedTypes.Add(instantiated);
                    }
                    return instantiated;
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
                    // Return canonical struct representation instead of SliceType
                    return TypeRegistry.GetSliceStruct(et);
                }
            default:
                return null;
        }
    }

    public StructType? InstantiateStruct(GenericType genericType, SourceSpan span)
    {
        if (!_structs.TryGetValue(genericType.BaseName, out var template))
            return null;
        return InstantiateStruct(template, genericType.TypeArguments, span);
    }

    private StructType InstantiateStruct(StructType template, IReadOnlyList<FType> typeArgs, SourceSpan span)
    {
        if (template.TypeParameters.Count != typeArgs.Count)
        {
            _diagnostics.Add(Diagnostic.Error(
                $"struct `{template.StructName}` expects {template.TypeParameters.Count} type parameter(s)",
                span,
                $"provided {typeArgs.Count}",
                "E2006"));
            return template;
        }

        var key = BuildStructSpecKey(template.StructName, typeArgs);
        if (_structSpecializations.TryGetValue(key, out var cached))
            return cached;

        var bindings = new Dictionary<string, FType>();
        for (var i = 0; i < template.TypeParameters.Count; i++)
            bindings[template.TypeParameters[i]] = typeArgs[i];

        var specializedFields = new List<(string Name, FType Type)>();
        foreach (var (fieldName, fieldType) in template.Fields)
        {
            var specializedType = SubstituteGenerics(fieldType, bindings);
            specializedFields.Add((fieldName, specializedType));
        }

        var paramNames = typeArgs.Select(t => t.Name).ToList();
        var specialized = new StructType(template.StructName, paramNames, specializedFields);
        _structSpecializations[key] = specialized;
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
                _diagnostics.Add(Diagnostic.Error(
                    $"struct `{structType.Name}` does not have a field named `{fieldName}`",
                    expr.Span,
                    "unknown field",
                    "E2013"));
                continue;
            }

            var valueType = CheckExpression(expr, fieldType);
            if (!CanCoerse(valueType, fieldType))
            {
                _diagnostics.Add(Diagnostic.Error(
                    $"mismatched types for field `{fieldName}`",
                    expr.Span,
                    $"expected `{fieldType}`, found `{valueType}`",
                    "E2002"));
            }
            else
            {
                var unified = UnifyTypes(valueType, fieldType);
                UpdateTypeMapRecursive(expr, unified);
            }
        }

        foreach (var (fieldName, _) in structType.Fields)
            if (!provided.Contains(fieldName))
                _diagnostics.Add(Diagnostic.Error(
                    $"missing field `{fieldName}` in struct construction",
                    span,
                    $"struct `{structType.Name}` requires field `{fieldName}`",
                    "E2015"));
    }

    private HashSet<string> CollectGenericParamNames(FunctionDeclarationNode fn)
    {
        var set = new HashSet<string>();

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

        foreach (var p in fn.Parameters) Visit(p.Type);
        Visit(fn.ReturnType);
        return set;
    }

    private bool IsCompatible(FType source, FType target)
    {
        if (source.Equals(target)) return true;
        if (source is ComptimeIntType && TypeRegistry.IsIntegerType(target)) return true;
        if (target is ComptimeIntType && TypeRegistry.IsIntegerType(source)) return true;
        if (source is ComptimeIntType && target is ComptimeIntType) return true;
        if (source is ComptimeFloatType || target is ComptimeFloatType) return true; // placeholder
        if (TypeRegistry.IsIntegerType(source) && TypeRegistry.IsIntegerType(target)) return true;

        // Array -> slice view compatibility (by value or reference)
        if (source is ArrayType sa && target is SliceType ts) return IsCompatible(sa.ElementType, ts.ElementType);
        if (source is ReferenceType rsa && rsa.InnerType is ArrayType ra && target is SliceType tsr)
            return IsCompatible(ra.ElementType, tsr.ElementType);

        // String is binary-compatible with u8[] slices (bidirectional)
        if (source is StructType ss && ss.StructName == "String" && target is SliceType ts2 &&
            ts2.ElementType.Equals(TypeRegistry.U8))
            return true;
        if (source is SliceType sl && sl.ElementType.Equals(TypeRegistry.U8) && target is StructType ts3 &&
            ts3.StructName == "String")
            return true;

        if (source is ArrayType aa && target is ArrayType bb)
            return aa.Length == bb.Length && IsCompatible(aa.ElementType, bb.ElementType);
        return false;
    }

    private FType UnifyTypes(FType a, FType b)
    {
        if (a.Equals(b)) return a;

        // Primitive comptime_int unification
        if (a is ComptimeIntType && TypeRegistry.IsIntegerType(b)) return b;
        if (b is ComptimeIntType && TypeRegistry.IsIntegerType(a)) return a;

        // Array type unification: recursively unify element types
        if (a is ArrayType aa && b is ArrayType bb && aa.Length == bb.Length)
        {
            var unifiedElem = UnifyTypes(aa.ElementType, bb.ElementType);
            // If element types unified to something different, create new ArrayType
            if (!unifiedElem.Equals(aa.ElementType))
                return new ArrayType(unifiedElem, aa.Length);
            return aa;
        }

        return a;
    }

    private void RefineBindingsWithExpectedReturn(FType template, FType expected, Dictionary<string, FType> bindings)
    {
        if (template is GenericParameterType gp)
        {
            if (bindings.TryGetValue(gp.ParamName, out var existing))
                bindings[gp.ParamName] = UnifyTypes(existing, expected);
            else
                bindings[gp.ParamName] = expected;
            return;
        }

        switch (template)
        {
            case ReferenceType rt when expected is ReferenceType expectedRef:
                RefineBindingsWithExpectedReturn(rt.InnerType, expectedRef.InnerType, bindings);
                break;
            case ArrayType at when expected is ArrayType expectedArray && at.Length == expectedArray.Length:
                RefineBindingsWithExpectedReturn(at.ElementType, expectedArray.ElementType, bindings);
                break;
            case SliceType st when expected is SliceType expectedSlice:
                RefineBindingsWithExpectedReturn(st.ElementType, expectedSlice.ElementType, bindings);
                break;
            case OptionType ot when expected is OptionType expectedOption:
                RefineBindingsWithExpectedReturn(ot.InnerType, expectedOption.InnerType, bindings);
                break;
            case StructType st when expected is StructType expectedStruct && st.StructName == expectedStruct.StructName:
                RefineStructBindings(st, expectedStruct, bindings);
                break;
        }
    }

    private void RefineStructBindings(StructType template, StructType expected, Dictionary<string, FType> bindings)
    {
        // First, match type parameters
        // e.g., matching Type(i32) with Type($T) should bind $T to i32
        if (template.TypeParameters.Count == expected.TypeParameters.Count)
        {
            for (int i = 0; i < template.TypeParameters.Count; i++)
            {
                var templateParam = template.TypeParameters[i];
                var expectedParam = expected.TypeParameters[i];

                // Bind the type variable to the expected type
                var expectedType = ResolveTypeName(expectedParam);
                if (expectedType != null)
                {
                    bindings[templateParam] = expectedType;
                }
            }
        }

        // Then, match fields
        var expectedFields = new Dictionary<string, FType>();
        foreach (var (name, type) in expected.Fields)
            expectedFields[name] = type;

        foreach (var (fieldName, fieldType) in template.Fields)
        {
            if (!expectedFields.TryGetValue(fieldName, out var expectedFieldType))
                continue;
            RefineBindingsWithExpectedReturn(fieldType, expectedFieldType, bindings);
        }
    }

    /// <summary>
    /// Updates the type map for an expression and its sub-expressions when coercing to a target type.
    /// This prevents comptime_int from escaping to later compilation stages.
    /// </summary>
    private void UpdateTypeMapRecursive(ExpressionNode expr, FType targetType)
    {
        // For array literals, we need to rebuild the array type with corrected element types
        // before updating the type map
        if (expr is ArrayLiteralExpressionNode arr && targetType is ArrayType arrType)
        {
            // Update all array elements with the resolved element type
            if (arr.IsRepeatSyntax && arr.RepeatValue != null)
            {
                UpdateTypeMapRecursive(arr.RepeatValue, arrType.ElementType);
            }
            else if (arr.Elements != null)
            {
                foreach (var elem in arr.Elements)
                    UpdateTypeMapRecursive(elem, arrType.ElementType);
            }
            // Create a new ArrayType with the corrected element type
            var correctedArrayType = new ArrayType(arrType.ElementType, arrType.Length);
            _typeMap[expr] = correctedArrayType;
        }
        else if (expr is BinaryExpressionNode bin)
        {
            // For binary operations, both operands should have the unified type
            UpdateTypeMapRecursive(bin.Left, targetType);
            UpdateTypeMapRecursive(bin.Right, targetType);
            _typeMap[expr] = targetType;
        }
        else if (expr is IfExpressionNode ifExpr)
        {
            // For if expressions, update both branches with the target type
            UpdateTypeMapRecursive(ifExpr.ThenBranch, targetType);
            if (ifExpr.ElseBranch != null)
                UpdateTypeMapRecursive(ifExpr.ElseBranch, targetType);
            _typeMap[expr] = targetType;
        }
        else if (expr is BlockExpressionNode block)
        {
            // For block expressions, update the trailing expression if it exists
            if (block.TrailingExpression != null)
                UpdateTypeMapRecursive(block.TrailingExpression, targetType);
            _typeMap[expr] = targetType;
        }
        else if (expr is CastExpressionNode cast)
        {
            if (_typeMap.TryGetValue(cast.Expression, out var sourceType) &&
                sourceType != null && TypeRegistry.IsComptimeType(sourceType))
            {
                UpdateTypeMapRecursive(cast.Expression, targetType);
            }

            _typeMap[expr] = targetType;
        }
        else
        {
            if (targetType is OptionType optionTarget)
            {
                if (_typeMap.TryGetValue(expr, out var originalType) && originalType != null)
                {
                    if (originalType.Equals(optionTarget.InnerType))
                        _optionLifts[expr] = optionTarget;
                }
            }

            // Base case: simple expressions (literals, identifiers) just need their own type updated
            _typeMap[expr] = targetType;
        }
    }

    public void EnsureAllTypesResolved()
    {
        foreach (var entry in _typeMap)
        {
            if (!TypeRegistry.IsComptimeType(entry.Value))
                continue;

            _diagnostics.Add(Diagnostic.Error(
                "cannot infer type",
                entry.Key.Span,
                $"type annotations needed: expression still has comptime type `{entry.Value}`",
                "E2001"));
        }
    }

    private void PushScope() => _scopes.Push(new Dictionary<string, FType>());
    private void PopScope() => _scopes.Pop();

    private void DeclareVariable(string name, FType type, SourceSpan span)
    {
        var cur = _scopes.Peek();
        if (!cur.TryAdd(name, type))
            _diagnostics.Add(Diagnostic.Error(
                $"variable `{name}` is already declared",
                span,
                "variable redeclaration",
                "E2005"));
    }

    private bool TryLookupVariable(string name, out FType type)
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

    private FType LookupVariable(string name, SourceSpan span)
    {
        if (TryLookupVariable(name, out var type))
            return type;

        _diagnostics.Add(Diagnostic.Error(
            $"cannot find value `{name}` in this scope",
            span,
            "not found in this scope",
            "E2004"));
        return TypeRegistry.I32;
    }

    // ===== Generics helpers =====

    private static bool ContainsGeneric(FType t) => t switch
    {
        GenericParameterType => true,
        ReferenceType rt => ContainsGeneric(rt.InnerType),
        OptionType ot => ContainsGeneric(ot.InnerType),
        ArrayType at => ContainsGeneric(at.ElementType),
        SliceType st => ContainsGeneric(st.ElementType),
        GenericType gt => gt.TypeArguments.Any(ContainsGeneric),
        StructType strct => strct.TypeParameters.Count > 0,
        _ => false
    };

    private static bool IsGenericSignature(IReadOnlyList<FType> parameters, FType returnType)
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

    private static FType SubstituteGenerics(FType type, Dictionary<string, FType> bindings) => type switch
    {
        GenericParameterType gp => bindings.TryGetValue(gp.ParamName, out var b) ? b : gp,
        ReferenceType rt => new ReferenceType(SubstituteGenerics(rt.InnerType, bindings)),
        OptionType ot => new OptionType(SubstituteGenerics(ot.InnerType, bindings)),
        ArrayType at => new ArrayType(SubstituteGenerics(at.ElementType, bindings), at.Length),
        SliceType st => new SliceType(SubstituteGenerics(st.ElementType, bindings)),
        StructType st => SubstituteStructType(st, bindings),
        GenericType gt => new GenericType(gt.BaseName,
            gt.TypeArguments.Select(a => SubstituteGenerics(a, bindings)).ToList()),
        _ => type
    };

    private bool TryComputeCoercionCost(IReadOnlyList<FType> sources, IReadOnlyList<FType> targets, out int cost)
    {
        cost = 0;
        if (sources.Count != targets.Count) return false;
        for (var i = 0; i < sources.Count; i++)
        {
            if (sources[i].Equals(targets[i])) continue;
            if (!CanCoerse(sources[i], targets[i])) return false;
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
        private readonly TypeSolver _solver;

        public BindingDepthScope(TypeSolver solver)
        {
            _solver = solver;
            _solver._bindingDepth++;
        }

        public void Dispose()
        {
            _solver._bindingDepth--;
        }
    }

    private bool TryBindGeneric(FType param, FType arg, Dictionary<string, FType> bindings,
        out string? conflictParam, out (FType Existing, FType Incoming)? conflictTypes)
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
                _logger.LogDebug("{Indent}Recursing into reference types: &{ParamInner} vs &{ArgInner}",
                    Indent(), pr.InnerType.Name, ar.InnerType.Name);
                return TryBindGeneric(pr.InnerType, ar.InnerType, bindings, out conflictParam, out conflictTypes);
            case OptionType po when arg is OptionType ao:
                _logger.LogDebug("{Indent}Recursing into option types: {ParamInner}? vs {ArgInner}?",
                    Indent(), po.InnerType.Name, ao.InnerType.Name);
                return TryBindGeneric(po.InnerType, ao.InnerType, bindings, out conflictParam, out conflictTypes);
            case ArrayType pa when arg is ArrayType aa:
                if (pa.Length != aa.Length)
                {
                    _logger.LogDebug("{Indent}Array length mismatch: [{ParamLength}]{ParamElem} vs [{ArgLength}]{ArgElem}",
                        Indent(), pa.Length, pa.ElementType.Name, aa.Length, aa.ElementType.Name);
                    return false;
                }
                _logger.LogDebug("{Indent}Recursing into array element types: [{Length}]{ParamElem} vs [{Length}]{ArgElem}",
                    Indent(), pa.Length, pa.ElementType.Name, aa.ElementType.Name);
                return TryBindGeneric(pa.ElementType, aa.ElementType, bindings, out conflictParam, out conflictTypes);
            case SliceType ps when arg is SliceType aslice:
                _logger.LogDebug("{Indent}Recursing into slice element types: []{ParamElem} vs []{ArgElem}",
                    Indent(), ps.ElementType.Name, aslice.ElementType.Name);
                return TryBindGeneric(ps.ElementType, aslice.ElementType, bindings, out conflictParam,
                    out conflictTypes);
            case GenericType pg when arg is GenericType ag && pg.BaseName == ag.BaseName &&
                                     pg.TypeArguments.Count == ag.TypeArguments.Count:
                for (var i = 0; i < pg.TypeArguments.Count; i++)
                {
                    // Recursively match type arguments
                    // This will handle cases like Type($T) matching Type(i32)
                    _logger.LogDebug("{Indent}Recursing into generic type arg[{Index}]: {ParamArg} vs {ArgArg}",
                        Indent(), i, pg.TypeArguments[i].Name, ag.TypeArguments[i].Name);
                    if (!TryBindGeneric(pg.TypeArguments[i], ag.TypeArguments[i], bindings, out conflictParam,
                            out conflictTypes)) return false;
                }

                return true;
            case StructType ps when arg is StructType @as && ps.StructName == @as.StructName:
                {
                    // First, match type parameters
                    // e.g., matching Type($T) with Type(i32) should bind $T to i32
                    if (ps.TypeParameters.Count == @as.TypeParameters.Count)
                    {
                        for (var i = 0; i < ps.TypeParameters.Count; i++)
                        {
                            var paramTypeName = ps.TypeParameters[i];
                            var argTypeName = @as.TypeParameters[i];

                            _logger.LogDebug("{Indent}Struct type param[{Index}]: '{ParamTypeName}' vs '{ArgTypeName}'",
                                Indent(), i, paramTypeName, argTypeName);

                            // Check if param type is a concrete type or a type variable
                            // Type variables are NOT concrete types in the registry
                            var paramAsConcreteType = TypeRegistry.GetTypeByName(paramTypeName);

                            if (paramAsConcreteType == null)
                            {
                                var varName = paramTypeName;
                                var argType = ResolveTypeName(argTypeName);
                                if (argType != null)
                                {
                                    // Bind the type variable (use bare name like "T" for consistency with GenericParameterType bindings)
                                    _logger.LogDebug("{Indent}Binding type variable '{VarName}' -> '{ArgType}'", Indent(), varName, argType.Name);
                                    if (bindings.TryGetValue(varName, out var existingBinding))
                                    {
                                        if (!existingBinding.Equals(argType))
                                        {
                                            _logger.LogDebug("{Indent}Conflict: '{VarName}' already bound to '{ExistingType}', cannot rebind to '{NewType}'",
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
                                else
                                {
                                    _logger.LogDebug("{Indent}Failed to resolve type name '{ArgTypeName}'", Indent(), argTypeName);
                                    return false;
                                }
                            }
                            else if (paramTypeName != argTypeName)
                            {
                                // Concrete type parameters must match exactly
                                _logger.LogDebug("{Indent}Concrete type mismatch: '{ParamTypeName}' != '{ArgTypeName}'", Indent(), paramTypeName, argTypeName);
                                return false;
                            }
                        }
                    }

                    // Then, match fields
                    var argFields = new Dictionary<string, FType>();
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

    private static bool IsConcreteCompatible(FType source, FType target)
    {
        if (source.Equals(target)) return true;
        if (TypeRegistry.IsIntegerType(source) && TypeRegistry.IsIntegerType(target)) return true;
        if (source is ArrayType sa && target is SliceType ts)
            return IsConcreteCompatible(sa.ElementType, ts.ElementType);
        return false;
    }

    private static void CollectGenericParamOrder(FType t, HashSet<string> seen, List<string> order)
    {
        switch (t)
        {
            case GenericParameterType gp:
                if (seen.Add(gp.ParamName)) order.Add(gp.ParamName);
                break;
            case ReferenceType rt:
                CollectGenericParamOrder(rt.InnerType, seen, order);
                break;
            case OptionType ot:
                CollectGenericParamOrder(ot.InnerType, seen, order);
                break;
            case ArrayType at:
                CollectGenericParamOrder(at.ElementType, seen, order);
                break;
            case SliceType st:
                CollectGenericParamOrder(st.ElementType, seen, order);
                break;
            case GenericType gt:
                for (var i = 0; i < gt.TypeArguments.Count; i++)
                    CollectGenericParamOrder(gt.TypeArguments[i], seen, order);
                break;
            default:
                break;
        }
    }

    private static List<FType> CollectTypeArgsOrdered(Dictionary<string, FType> bindings,
        IReadOnlyList<FType> parameterTypes)
    {
        var seen = new HashSet<string>();
        var order = new List<string>();
        for (var i = 0; i < parameterTypes.Count; i++)
            CollectGenericParamOrder(parameterTypes[i], seen, order);

        var result = new List<FType>();
        for (var i = 0; i < order.Count; i++)
        {
            var name = order[i];
            if (bindings.TryGetValue(name, out var t)) result.Add(t);
        }

        // Add any remaining bindings in deterministic (alphabetical) order
        var remaining = new List<string>();
        foreach (var kv in bindings)
            if (!seen.Contains(kv.Key))
                remaining.Add(kv.Key);
        remaining.Sort(StringComparer.Ordinal);
        for (var i = 0; i < remaining.Count; i++) result.Add(bindings[remaining[i]]);
        return result;
    }

    private static StructType SubstituteStructType(StructType structType, Dictionary<string, FType> bindings)
    {
        var updatedFields = new List<(string Name, FType Type)>(structType.Fields.Count);
        var changed = false;
        foreach (var (name, fieldType) in structType.Fields)
        {
            var substituted = SubstituteGenerics(fieldType, bindings);
            if (!ReferenceEquals(substituted, fieldType))
                changed = true;
            updatedFields.Add((name, substituted));
        }

        var updatedParameters = new List<string>(structType.TypeParameters.Count);
        foreach (var param in structType.TypeParameters)
        {
            if (bindings.TryGetValue(param, out var boundType))
            {
                var boundName = boundType.Name;
                if (boundName != param)
                    changed = true;
                updatedParameters.Add(boundName);
                continue;
            }

            updatedParameters.Add(param);
        }

        if (!changed)
            return structType;

        return new StructType(structType.StructName, updatedParameters, updatedFields);
    }

    private void EnsureSpecialization(FunctionEntry genericEntry, Dictionary<string, FType> bindings,
        IReadOnlyList<FType> concreteParamTypes)
    {
        var key = BuildSpecKey(genericEntry.Name, concreteParamTypes);
        if (_emittedSpecs.Contains(key)) return;

        PushGenericScope(genericEntry.AstNode);
        try
        {
            // Substitute param/return types in the signature
            var newParams = new List<FunctionParameterNode>();
            foreach (var p in genericEntry.AstNode.Parameters)
            {
                var t = ResolveTypeNode(p.Type) ?? TypeRegistry.I32;
                var st = SubstituteGenerics(t, bindings);
                var tnode = CreateTypeNodeFromFType(p.Span, st);
                newParams.Add(new FunctionParameterNode(p.Span, p.Name, tnode));
            }

            TypeNode? newRetNode = null;
            if (genericEntry.AstNode.ReturnType != null)
            {
                var rt = ResolveTypeNode(genericEntry.AstNode.ReturnType) ?? TypeRegistry.I32;
                var srt = SubstituteGenerics(rt, bindings);
                newRetNode = CreateTypeNodeFromFType(genericEntry.AstNode.ReturnType.Span, srt);
            }

            // Keep base name; backend will mangle by parameter types
            var newFn = new FunctionDeclarationNode(genericEntry.AstNode.Span, genericEntry.Name, newParams, newRetNode,
                genericEntry.AstNode.Body, genericEntry.IsForeign ? FunctionModifiers.Foreign : FunctionModifiers.None);
            CheckFunction(newFn);
            _specializations.Add(newFn);
            _emittedSpecs.Add(key);
        }
        finally
        {
            PopGenericScope();
        }
    }

    private static TypeNode CreateTypeNodeFromFType(SourceSpan span, FType t) => t switch
    {
        PrimitiveType pt => new NamedTypeNode(span, pt.Name),
        StructType st => st.TypeParameters.Count == 0
            ? new NamedTypeNode(span, st.StructName)
            : new GenericTypeNode(span, st.StructName,
                st.TypeParameters.Select(p => new NamedTypeNode(span, p)).ToList()),
        ReferenceType rt => new ReferenceTypeNode(span, CreateTypeNodeFromFType(span, rt.InnerType)),
        OptionType ot => new NullableTypeNode(span, CreateTypeNodeFromFType(span, ot.InnerType)),
        ArrayType at => new ArrayTypeNode(span, CreateTypeNodeFromFType(span, at.ElementType), at.Length),
        SliceType sl => new SliceTypeNode(span, CreateTypeNodeFromFType(span, sl.ElementType)),
        GenericType gt => new GenericTypeNode(span, gt.BaseName,
            gt.TypeArguments.Select(a => CreateTypeNodeFromFType(span, a)).ToList()),
        GenericParameterType gp => new GenericParameterTypeNode(span, gp.ParamName),
        _ => new NamedTypeNode(span, t.Name)
    };

    public (string Name, IReadOnlyList<FType> ParameterTypes, bool IsForeign)? GetResolvedCall(
        FunctionDeclarationNode function, CallExpressionNode call)
        => _resolvedCalls.TryGetValue((function, call), out var info)
            ? (info.Name, info.ParameterTypes, info.IsForeign)
            : null;

    public OptionType? GetOptionLift(ExpressionNode expression)
        => _optionLifts.TryGetValue(expression, out var optionType) ? optionType : null;

    public IReadOnlyList<FunctionDeclarationNode> GetSpecializedFunctions() => _specializations;

    public bool IsGenericFunction(FunctionDeclarationNode fn) => IsGenericFunctionDecl(fn);
}

public class FunctionEntry
{
    public FunctionEntry(string name, IReadOnlyList<FType> parameterTypes, FType returnType,
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
    public IReadOnlyList<FType> ParameterTypes { get; }
    public FType ReturnType { get; }
    public FunctionDeclarationNode AstNode { get; }
    public bool IsForeign { get; }
    public bool IsGeneric { get; }
}
