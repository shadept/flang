using System.Numerics;
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
    // ==================== Type Resolution ====================

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

    // ==================== Struct / Enum Instantiation ====================

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
        {
            // If the cached specialization has no fields but the template now does,
            // the cache is stale (created before ResolveStructFields ran for the template).
            // Re-instantiate to pick up the resolved fields.
            if (cached.Fields.Count == 0 && template.Fields.Count > 0)
                _compilation.StructSpecializations.Remove(key);
            else
                return cached;
        }

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
        if (!_compilation.StructsByFqn.TryGetValue("core.slice.Slice", out var sliceTemplate)
            || sliceTemplate.Fields.Count == 0)
        {
            // Fallback to TypeRegistry if stdlib not loaded or template fields not yet resolved
            // (phase ordering: struct fields may not be resolved yet during ResolveStructFields)
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
        if (!_compilation.StructsByFqn.TryGetValue("core.range.Range", out var rangeTemplate)
            || rangeTemplate.Fields.Count == 0)
        {
            // Fallback to TypeRegistry if stdlib not loaded or template fields not yet resolved
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

    // ==================== Coercion ====================

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

    // ==================== Unification ====================

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

    // ==================== Generics Helpers ====================

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

    private static TypeBase SubstituteGenerics(TypeBase type, Dictionary<string, TypeBase> bindings,
        HashSet<StructType>? visited = null)
    {
        if (bindings.Count == 0) return type;
        // Prune TypeVars to get concrete types - this handles comptime_int wrapped in TypeVar
        var pruned = type.Prune();
        return pruned switch
        {
            GenericParameterType gp => bindings.TryGetValue(gp.ParamName, out var b) ? b.Prune() : gp,
            ReferenceType rt => new ReferenceType(SubstituteGenerics(rt.InnerType, bindings, visited)),
            ArrayType at => new ArrayType(SubstituteGenerics(at.ElementType, bindings, visited), at.Length),
            StructType st => SubstituteStructType(st, bindings, visited),
            EnumType et => SubstituteEnumType(et, bindings),
            GenericType gt => new GenericType(gt.BaseName,
                gt.TypeArguments.Select(a => SubstituteGenerics(a, bindings, visited)).ToList()),
            FunctionType ft => new FunctionType(
                ft.ParameterTypes.Select(p => SubstituteGenerics(p, bindings, visited)).ToList(),
                SubstituteGenerics(ft.ReturnType, bindings, visited)),
            _ => pruned
        };
    }

    private static StructType SubstituteStructType(StructType structType, Dictionary<string, TypeBase> bindings,
        HashSet<StructType>? visited = null)
    {
        // Prevent infinite recursion from circular type references (e.g. TypeInfo ↔ FieldInfo)
        visited ??= [];
        if (!visited.Add(structType))
            return structType;

        var updatedFields = new List<(string Name, TypeBase Type)>(structType.Fields.Count);
        var changed = false;
        foreach (var (name, fieldType) in structType.Fields)
        {
            var substituted = SubstituteGenerics(fieldType, bindings, visited);
            if (!ReferenceEquals(substituted, fieldType))
                changed = true;
            updatedFields.Add((name, substituted));
        }

        // Substitute type arguments recursively (handles nested types like &T)
        var updatedTypeArgs = new List<TypeBase>(structType.TypeArguments.Count);
        foreach (var typeArg in structType.TypeArguments)
        {
            var substituted = SubstituteGenerics(typeArg, bindings, visited);
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

    // ==================== Generic Binding ====================

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
                    "{Indent}Recursing into array element types: [{ParamLength}]{ParamElem} vs [{ArgLength}]{ArgElem}",
                    Indent(), pa.Length, pa.ElementType.Name, aa.Length, aa.ElementType.Name);
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
                                // Allow comptime_int arg to match concrete integer param
                                var prunedArgType = argType.Prune();
                                if (prunedArgType is ComptimeInt && TypeRegistry.IsIntegerType(paramType))
                                {
                                    // comptime_int can coerce to any integer type
                                    // Propagate the concrete type to the arg's TypeVar if possible
                                    if (argType is TypeVar argTv)
                                        argTv.Instance = paramType;
                                    continue;
                                }

                                // Concrete type arguments must match exactly
                                _logger.LogDebug("{Indent}Concrete type mismatch: '{ParamType}' != '{ArgType}'", Indent(),
                                    paramType.Name, argType.Name);
                                return false;
                            }
                        }
                    }

                    // Skip field recursion when neither struct contains generic parameters.
                    // Same-named concrete structs have identical fields by definition, and
                    // recursing into fields of types with circular references (e.g. TypeInfo ↔ FieldInfo)
                    // would cause infinite recursion.
                    if (!ps.Fields.Any(f => ContainsGenericParam(f.Type)) &&
                        !@as.Fields.Any(f => ContainsGenericParam(f.Type)))
                        return true;

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

    /// <summary>
    /// Shallow check for generic parameters in a type (does not recurse into struct fields
    /// to avoid infinite recursion with circular type references like TypeInfo ↔ FieldInfo).
    /// </summary>
    private static bool ContainsGenericParam(TypeBase type) => type switch
    {
        GenericParameterType => true,
        TypeVar => true,
        ReferenceType rt => ContainsGenericParam(rt.InnerType),
        ArrayType at => ContainsGenericParam(at.ElementType),
        GenericType => true,
        _ => false
    };

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
        IntegerLiteralNode lit => new IntegerLiteralNode(lit.Span, lit.Value, lit.Suffix),
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
        ArrayLiteralExpressionNode arr => new ArrayLiteralExpressionNode(arr.Span, arr.Elements!.Select(CloneExpression).ToList()),
        AnonymousStructExpressionNode anon => new AnonymousStructExpressionNode(anon.Span, anon.Fields.Select(f => (f.FieldName, CloneExpression(f.Value))).ToList()),
        StructConstructionExpressionNode sc => new StructConstructionExpressionNode(sc.Span, sc.TypeName, sc.Fields.Select(f => (f.FieldName, CloneExpression(f.Value))).ToList()),
        ImplicitCoercionNode ic => new ImplicitCoercionNode(ic.Span, CloneExpression(ic.Inner), ic.TargetType, ic.Kind),
        UnaryExpressionNode un => new UnaryExpressionNode(un.Span, un.Operator, CloneExpression(un.Operand)),
        _ => throw new NotSupportedException($"Cloning not implemented for expression type: {expr.GetType().Name}")
    };

    // ==================== Generic Specialization ====================

    private FunctionDeclarationNode? EnsureSpecialization(FunctionEntry genericEntry, Dictionary<string, TypeBase> bindings,
        IReadOnlyList<TypeBase> concreteParamTypes, SourceSpan? instantiationSpan = null)
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

            var diagCountBefore = _diagnostics.Count;
            try
            {
                CheckFunction(newFn);
            }
            finally
            {
                // Attach instantiation notes to any new diagnostics
                if (instantiationSpan.HasValue && _diagnostics.Count > diagCountBefore)
                {
                    var typeArgs = string.Join(", ", concreteParamTypes.Select(FormatTypeNameForDisplay));
                    var note = Diagnostic.Info(
                        $"required from instantiation of `{genericEntry.Name}<{typeArgs}>` here",
                        instantiationSpan.Value,
                        "instantiated here");
                    for (var i = diagCountBefore; i < _diagnostics.Count; i++)
                        _diagnostics[i].Notes.Add(note);
                }

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
            StructType st when string.IsNullOrEmpty(st.StructName) =>
                new AnonymousStructTypeNode(span,
                    st.Fields.Select(f => (f.Name, CreateTypeNodeFromTypeBase(span, f.Type))).ToList()),
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

    // ==================== Verification ====================

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
}
