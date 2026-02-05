using System.Numerics;
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
public partial class TypeChecker
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
    private readonly Dictionary<string, FunctionDeclarationNode> _emittedSpecs = [];

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
    private readonly List<(TypeVar Tv, BigInteger Value)> _literalTypeVars = [];

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

    public IReadOnlyList<FunctionDeclarationNode> GetSpecializedFunctions() => _specializations;

    public bool IsGenericFunction(FunctionDeclarationNode fn) => IsGenericFunctionDecl(fn);

    // ==================== Shared Formatting Utilities ====================

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

    // ==================== Module Path ====================

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

    // ==================== Scope Management ====================

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

    // ==================== Shared Helpers ====================

    private bool IsGenericNameInScope(string name, HashSet<string>? explicitScope = null)
    {
        if (explicitScope != null && explicitScope.Contains(name))
            return true;

        foreach (var scope in _genericScopes)
        {
            if (scope.Contains(name))
                return true;
        }

        return false;
    }

    private static string BuildSpecKey(string name, IReadOnlyList<TypeBase> paramTypes)
    {
        var sb = new System.Text.StringBuilder();
        sb.Append(name);
        sb.Append('|');
        for (var i = 0; i < paramTypes.Count; i++)
        {
            if (i > 0) sb.Append(',');
            // Prune types so that comptime_int resolved to e.g. usize produces the same key
            // Use ToString() to include full type with type arguments (e.g., "Option(&u8)" vs "Option(Slice(u8))")
            sb.Append(paramTypes[i].Prune().ToString());
        }

        return sb.ToString();
    }

    /// <summary>
    /// Creates an indentation string based on the current binding depth.
    /// Each level adds 2 spaces for readability.
    /// </summary>
    private string Indent() => new string(' ', _bindingDepth * 2);

    /// <summary>
    /// Checks if a type is the Never type (indicating a previous error).
    /// Used for early-exit to prevent cascading type errors.
    /// </summary>
    private static bool IsNever(TypeBase type) =>
        ReferenceEquals(type.Prune(), TypeRegistry.Never);

    private static bool FitsInType(BigInteger value, PrimitiveType pt) => pt.Name switch
    {
        "i8" => value >= sbyte.MinValue && value <= sbyte.MaxValue,
        "i16" => value >= short.MinValue && value <= short.MaxValue,
        "i32" => value >= int.MinValue && value <= int.MaxValue,
        "i64" => value >= long.MinValue && value <= long.MaxValue,
        "u8" => value >= 0 && value <= byte.MaxValue,
        "u16" => value >= 0 && value <= ushort.MaxValue,
        "u32" => value >= 0 && value <= uint.MaxValue,
        "u64" => value >= 0 && value <= ulong.MaxValue,
        "isize" => value >= long.MinValue && value <= long.MaxValue,
        "usize" => value >= 0 && value <= ulong.MaxValue,
        _ => true
    };

    private static (BigInteger min, BigInteger max) GetIntegerRange(PrimitiveType pt) => pt.Name switch
    {
        "i8" => (sbyte.MinValue, sbyte.MaxValue),
        "i16" => (short.MinValue, short.MaxValue),
        "i32" => (int.MinValue, int.MaxValue),
        "i64" => (long.MinValue, long.MaxValue),
        "u8" => (0, byte.MaxValue),
        "u16" => (0, ushort.MaxValue),
        "u32" => (0, uint.MaxValue),
        "u64" => (0, ulong.MaxValue),
        "isize" => (long.MinValue, long.MaxValue),
        "usize" => (0, ulong.MaxValue),
        _ => (long.MinValue, long.MaxValue)
    };

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
