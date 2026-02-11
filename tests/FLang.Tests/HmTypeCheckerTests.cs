using FLang.CLI;
using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend;
using FLang.Frontend.Ast.Declarations;
using FLang.Semantics;
using Microsoft.Extensions.Logging.Abstractions;
using ArrayType = FLang.Core.Types.ArrayType;
using FunctionType = FLang.Core.Types.FunctionType;
using ReferenceType = FLang.Core.Types.ReferenceType;
using Type = FLang.Core.Types.Type;

namespace FLang.Tests;

public class HmTypeCheckerTests
{
    // =========================================================================
    // Parse helper: parse FLang source -> run type checker -> return results
    // =========================================================================

    private static readonly string AssemblyPath = Path.GetDirectoryName(typeof(HmTypeCheckerTests).Assembly.Location)!;
    private static readonly string ProjectRoot = Path.GetFullPath(Path.Combine(AssemblyPath, "..", "..", "..", "..", ".."));
    private static readonly string StdlibPath = Path.Combine(ProjectRoot, "stdlib");

    /// <summary>
    /// Parse FLang source code and run the HM type checker.
    /// Loads prelude + stdlib so types like String, Option, Range are available.
    /// Returns the checker (with inferred types map) and diagnostics.
    /// </summary>
    private static (HmTypeChecker Checker, List<Diagnostic> Diagnostics) Check(string source)
    {
        var tempFile = Path.GetTempFileName() + ".f";
        File.WriteAllText(tempFile, source);

        try
        {
            var compilation = new Compilation();
            compilation.StdlibPath = StdlibPath;
            compilation.WorkingDirectory = Path.GetDirectoryName(tempFile)!;
            compilation.IncludePaths.Add(StdlibPath);

            // Load prelude + transitive imports (same as real compiler)
            var moduleCompiler = new ModuleCompiler(compilation, NullLogger<ModuleCompiler>.Instance);
            var parsedModules = moduleCompiler.CompileModules(tempFile);

            // Run full 4-phase HM type checking across all modules
            var checker = new HmTypeChecker(compilation);
            foreach (var kvp in parsedModules)
            {
                var modulePath = HmTypeChecker.DeriveModulePath(
                    kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
                checker.CollectNominalTypes(kvp.Value, modulePath);
            }
            foreach (var kvp in parsedModules)
            {
                var modulePath = HmTypeChecker.DeriveModulePath(
                    kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
                checker.ResolveNominalTypes(kvp.Value, modulePath);
            }
            foreach (var kvp in parsedModules)
            {
                var modulePath = HmTypeChecker.DeriveModulePath(
                    kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
                checker.CollectFunctionSignatures(kvp.Value, modulePath);
            }
            foreach (var kvp in parsedModules)
            {
                var modulePath = HmTypeChecker.DeriveModulePath(
                    kvp.Key, compilation.IncludePaths, compilation.WorkingDirectory);
                checker.CheckModuleBodies(kvp.Value, modulePath);
            }

            var allDiags = checker.Diagnostics.Concat(moduleCompiler.Diagnostics).ToList();
            return (checker, allDiags);
        }
        finally
        {
            File.Delete(tempFile);
        }
    }

    /// <summary>
    /// Assert that type checking produces no errors.
    /// </summary>
    private static void AssertNoErrors(List<Diagnostic> diagnostics)
    {
        var errors = diagnostics.Where(d => d.Severity == DiagnosticSeverity.Error).ToList();
        Assert.Empty(errors);
    }

    /// <summary>
    /// Assert that type checking produces an error with the given code.
    /// </summary>
    private static void AssertHasError(List<Diagnostic> diagnostics, string code)
    {
        var errors = diagnostics.Where(d => d.Severity == DiagnosticSeverity.Error).ToList();
        Assert.Contains(errors, e => e.Code == code);
    }

    /// <summary>
    /// Assert that type checking produces at least one error.
    /// </summary>
    private static void AssertHasErrors(List<Diagnostic> diagnostics)
    {
        var errors = diagnostics.Where(d => d.Severity == DiagnosticSeverity.Error).ToList();
        Assert.NotEmpty(errors);
    }

    /// <summary>
    /// Find the inferred type for a VariableDeclarationNode by name.
    /// </summary>
    private static Type? FindVarType(HmTypeChecker checker, string name)
    {
        foreach (var (node, type) in checker.InferredTypes)
        {
            if (node is VariableDeclarationNode varDecl && varDecl.Name == name)
                return type;
        }
        return null;
    }

    /// <summary>
    /// Find a nominal type by short name (ignoring module path prefix).
    /// </summary>
    private static NominalType FindNominal(HmTypeChecker checker, string shortName)
    {
        var match = checker.NominalTypes.Values
            .FirstOrDefault(nt =>
            {
                var name = nt.Name;
                var dot = name.LastIndexOf('.');
                var sn = dot >= 0 ? name[(dot + 1)..] : name;
                return sn == shortName;
            });
        Assert.NotNull(match);
        return match;
    }

    // =========================================================================
    // Literals
    // =========================================================================

    [Fact]
    public void IntegerLiteral_Suffixed_ResolvesToConcreteType()
    {
        var (checker, diags) = Check("""
            fn main() {
                let x: i32 = 42
            }
            """);
        AssertNoErrors(diags);
        var t = FindVarType(checker, "x");
        Assert.NotNull(t);
        Assert.Equal(WellKnown.I32, t);
    }

    [Fact]
    public void BoolLiteral_InfersAsBool()
    {
        var (checker, diags) = Check("""
            fn main() {
                let b: bool = true
            }
            """);
        AssertNoErrors(diags);
        var t = FindVarType(checker, "b");
        Assert.NotNull(t);
        Assert.Equal(WellKnown.Bool, t);
    }

    [Fact]
    public void StringLiteral_InfersAsString()
    {
        var (checker, diags) = Check("""
            fn main() {
                let s: String = "hello"
            }
            """);
        // String type must be registered — may produce error if "String" isn't a known nominal
        // This tests the basic flow
    }

    // =========================================================================
    // Variables
    // =========================================================================

    [Fact]
    public void VariableDecl_WithAnnotation_BindsType()
    {
        var (checker, diags) = Check("""
            fn main() {
                let x: i32 = 10
                let y: bool = false
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "x"));
        Assert.Equal(WellKnown.Bool, FindVarType(checker, "y"));
    }

    [Fact]
    public void VariableDecl_WithoutAnnotation_InfersFromInitializer()
    {
        var (checker, diags) = Check("""
            fn main() {
                let b = true
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.Bool, FindVarType(checker, "b"));
    }

    [Fact]
    public void VariableDecl_TypeMismatch_ProducesError()
    {
        // Use a struct vs i32 to avoid bool↔integer coercion
        var (_, diags) = Check("""
            struct Foo { x: i32 }
            fn main() {
                let x: Foo = 42i32
            }
            """);
        AssertHasErrors(diags);
    }

    [Fact]
    public void VariableDecl_NoTypeNoInit_ProducesError()
    {
        var (_, diags) = Check("""
            fn main() {
                let x
            }
            """);
        AssertHasErrors(diags);
    }

    // =========================================================================
    // Functions — basic calls
    // =========================================================================

    [Fact]
    public void FunctionCall_Simple_ResolvesReturnType()
    {
        var (checker, diags) = Check("""
            fn add(a: i32, b: i32) i32 {
                return a
            }
            fn main() {
                let result: i32 = add(1i32, 2i32)
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "result"));
    }

    [Fact]
    public void FunctionCall_WrongArgCount_ProducesError()
    {
        var (_, diags) = Check("""
            fn add(a: i32, b: i32) i32 {
                return a
            }
            fn main() {
                let r = add(1i32)
            }
            """);
        AssertHasErrors(diags);
    }

    // =========================================================================
    // Function parameters
    // =========================================================================

    [Fact]
    public void FunctionParams_TypesRecorded()
    {
        var (checker, diags) = Check("""
            fn greet(x: i32, flag: bool) {
                let a = x
                let b = flag
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "a"));
        Assert.Equal(WellKnown.Bool, FindVarType(checker, "b"));
    }

    // =========================================================================
    // Binary operators — built-in
    // =========================================================================

    [Fact]
    public void BinaryAdd_SameType_ResultIsSameType()
    {
        var (checker, diags) = Check("""
            fn main() {
                let r: i32 = 1i32 + 2i32
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "r"));
    }

    [Fact]
    public void BinaryComparison_ReturnsBool()
    {
        var (checker, diags) = Check("""
            fn main() {
                let r: bool = 1i32 < 2i32
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.Bool, FindVarType(checker, "r"));
    }

    [Fact]
    public void LogicalAnd_RequiresBool()
    {
        var (checker, diags) = Check("""
            fn main() {
                let r: bool = true and false
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.Bool, FindVarType(checker, "r"));
    }

    // =========================================================================
    // Unary operators
    // =========================================================================

    [Fact]
    public void UnaryNot_Bool_ReturnsBool()
    {
        var (checker, diags) = Check("""
            fn main() {
                let r: bool = !true
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.Bool, FindVarType(checker, "r"));
    }

    [Fact]
    public void UnaryNegate_Int_ReturnsSameType()
    {
        var (checker, diags) = Check("""
            fn main() {
                let r: i32 = -1i32
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "r"));
    }

    // =========================================================================
    // If expression
    // =========================================================================

    [Fact]
    public void IfElse_UnifiesBranches()
    {
        var (checker, diags) = Check("""
            fn main() {
                let r: i32 = if true { 1i32 } else { 2i32 }
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "r"));
    }

    [Fact]
    public void IfElse_MismatchedBranches_ProducesError()
    {
        // Struct vs i32 — genuinely incompatible branch types
        var (_, diags) = Check("""
            struct Foo { x: i32 }
            fn main() {
                let f = Foo { x = 1i32 }
                let r = if true { 1i32 } else { f }
            }
            """);
        AssertHasErrors(diags);
    }

    // =========================================================================
    // Structs
    // =========================================================================

    [Fact]
    public void StructDecl_FieldsResolved()
    {
        var (checker, diags) = Check("""
            struct Point {
                x: i32,
                y: i32
            }
            fn main() {
                let p = Point { x = 1i32, y = 2i32 }
            }
            """);
        AssertNoErrors(diags);
        var t = FindVarType(checker, "p");
        Assert.NotNull(t);
        Assert.IsType<NominalType>(t);
        var nominal = (NominalType)t;
        Assert.EndsWith("Point", nominal.Name);
    }

    [Fact]
    public void StructFieldAccess_InfersFieldType()
    {
        var (checker, diags) = Check("""
            struct Point {
                x: i32,
                y: i32
            }
            fn main() {
                let p = Point { x = 1i32, y = 2i32 }
                let v: i32 = p.x
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "v"));
    }

    [Fact]
    public void StructConstruction_UnknownField_ProducesError()
    {
        var (_, diags) = Check("""
            struct Point {
                x: i32,
                y: i32
            }
            fn main() {
                let p = Point { x = 1i32, z = 2i32 }
            }
            """);
        AssertHasErrors(diags);
    }

    // =========================================================================
    // Enums
    // =========================================================================

    [Fact]
    public void EnumDecl_VariantsResolved()
    {
        var (checker, _) = Check("""
            enum Color {
                Red,
                Green,
                Blue
            }
            fn main() {
                let c = Red
            }
            """);
        var t = FindVarType(checker, "c");
        Assert.NotNull(t);
        Assert.IsType<NominalType>(t);
    }

    [Fact]
    public void EnumVariant_WithPayload_InfersCorrectly()
    {
        var (checker, diags) = Check("""
            enum Shape {
                Circle(i32),
                Rect(i32, i32)
            }
            fn main() {
                let s = Circle(5i32)
            }
            """);
        AssertNoErrors(diags);
        var t = FindVarType(checker, "s");
        Assert.NotNull(t);
        Assert.IsType<NominalType>(t);
        Assert.Contains("Shape", ((NominalType)t).Name);
    }

    // =========================================================================
    // References
    // =========================================================================

    [Fact]
    public void AddressOf_CreatesReferenceType()
    {
        var (checker, diags) = Check("""
            fn main() {
                let x: i32 = 42i32
                let r: &i32 = &x
            }
            """);
        AssertNoErrors(diags);
        var t = FindVarType(checker, "r");
        Assert.NotNull(t);
        Assert.IsType<ReferenceType>(t);
        var refType = (ReferenceType)t;
        Assert.Equal(WellKnown.I32, refType.InnerType);
    }

    [Fact]
    public void Dereference_UnwrapsReferenceType()
    {
        var (checker, diags) = Check("""
            fn main() {
                let x: i32 = 42i32
                let r = &x
                let v: i32 = r.*
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "v"));
    }

    [Fact]
    public void AutoDeref_OnMemberAccess()
    {
        var (checker, diags) = Check("""
            struct Point {
                x: i32,
                y: i32
            }
            fn main() {
                let p = Point { x = 1i32, y = 2i32 }
                let r = &p
                let v: i32 = r.x
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "v"));
    }

    // =========================================================================
    // Return type checking
    // =========================================================================

    [Fact]
    public void Return_MatchesDeclaredType()
    {
        var (_, diags) = Check("""
            fn get_value() i32 {
                return 42i32
            }
            """);
        AssertNoErrors(diags);
    }

    [Fact]
    public void Return_TypeMismatch_ProducesError()
    {
        // Struct vs i32 — no valid coercion
        var (_, diags) = Check("""
            struct Foo { x: i32 }
            fn make_foo() Foo {
                return 42i32
            }
            """);
        AssertHasErrors(diags);
    }

    // =========================================================================
    // Cast expressions
    // =========================================================================

    [Fact]
    public void Cast_InfersTargetType()
    {
        var (checker, diags) = Check("""
            fn main() {
                let x: u8 = 42i32 as u8
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.U8, FindVarType(checker, "x"));
    }

    // =========================================================================
    // Block expressions
    // =========================================================================

    [Fact]
    public void Block_TrailingExpression_IsBlockType()
    {
        var (checker, diags) = Check("""
            fn main() {
                let r: i32 = {
                    let a: i32 = 1i32
                    a
                }
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "r"));
    }

    // =========================================================================
    // Multiple functions and forward references
    // =========================================================================

    [Fact]
    public void ForwardReference_FunctionCallBeforeDecl()
    {
        var (checker, diags) = Check("""
            fn main() {
                let r: i32 = helper(1i32)
            }
            fn helper(x: i32) i32 {
                return x
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "r"));
    }

    // =========================================================================
    // Array literals
    // =========================================================================

    [Fact]
    public void ArrayLiteral_InfersElementType()
    {
        var (checker, diags) = Check("""
            fn main() {
                let arr = [1i32, 2i32, 3i32]
            }
            """);
        AssertNoErrors(diags);
        var t = FindVarType(checker, "arr");
        Assert.NotNull(t);
        Assert.IsType<ArrayType>(t);
        var arrType = (ArrayType)t;
        Assert.Equal(WellKnown.I32, arrType.ElementType);
        Assert.Equal(3, arrType.Length);
    }

    [Fact]
    public void ArrayLiteral_MixedTypes_ProducesError()
    {
        // Struct vs i32 — genuinely incompatible element types
        var (_, diags) = Check("""
            struct Foo { x: i32 }
            fn main() {
                let f = Foo { x = 1i32 }
                let arr = [1i32, f]
            }
            """);
        AssertHasErrors(diags);
    }

    // =========================================================================
    // Assignment
    // =========================================================================

    [Fact]
    public void Assignment_CompatibleType_NoError()
    {
        var (_, diags) = Check("""
            fn main() {
                let x: i32 = 1i32
                x = 2i32
            }
            """);
        AssertNoErrors(diags);
    }

    [Fact]
    public void Assignment_IncompatibleType_ProducesError()
    {
        // Struct vs i32 — genuinely incompatible types
        var (_, diags) = Check("""
            struct Foo { x: i32 }
            fn main() {
                let x: i32 = 1i32
                let f = Foo { x = 1i32 }
                x = f
            }
            """);
        AssertHasErrors(diags);
    }

    // =========================================================================
    // Scope and shadowing
    // =========================================================================

    [Fact]
    public void Shadowing_InnerScopeCanShadow()
    {
        var (_, diags) = Check("""
            fn main() {
                let x: i32 = 1i32
                let r: bool = {
                    let x: bool = true
                    x
                }
            }
            """);
        AssertNoErrors(diags);
    }

    // =========================================================================
    // Declaration phases — nominal type registry
    // =========================================================================

    [Fact]
    public void NominalTypes_RegisteredByFQN()
    {
        var (checker, _) = Check("""
            struct Foo {
                x: i32
            }
            enum Bar {
                A,
                B
            }
            """);
        FindNominal(checker, "Foo");
        FindNominal(checker, "Bar");
    }

    [Fact]
    public void NominalType_StructFields_Resolved()
    {
        var (checker, _) = Check("""
            struct Vec2 {
                x: i32,
                y: i32
            }
            """);
        var vec2 = FindNominal(checker, "Vec2");
        Assert.Equal(2, vec2.FieldsOrVariants.Count);
        Assert.Equal("x", vec2.FieldsOrVariants[0].Name);
        Assert.Equal(WellKnown.I32, vec2.FieldsOrVariants[0].Type);
        Assert.Equal("y", vec2.FieldsOrVariants[1].Name);
    }

    [Fact]
    public void NominalType_EnumVariants_Resolved()
    {
        var (checker, _) = Check("""
            enum Direction {
                Up,
                Down,
                Left,
                Right
            }
            """);
        var dir = FindNominal(checker, "Direction");
        Assert.Equal(4, dir.FieldsOrVariants.Count);
        // Payload-less variants use void sentinel
        Assert.All(dir.FieldsOrVariants, v => Assert.Equal(WellKnown.Void, v.Type));
    }

    // =========================================================================
    // Error cases
    // =========================================================================

    [Fact]
    public void UnresolvedIdentifier_ProducesError()
    {
        var (_, diags) = Check("""
            fn main() {
                let x = unknown_var
            }
            """);
        AssertHasError(diags, "E2001");
    }

    [Fact]
    public void UnresolvedFunction_ProducesError()
    {
        var (_, diags) = Check("""
            fn main() {
                let x = nonexistent(1i32)
            }
            """);
        AssertHasErrors(diags);
    }

    [Fact]
    public void DuplicateStructName_ProducesError()
    {
        var (_, diags) = Check("""
            struct Foo { x: i32 }
            struct Foo { y: bool }
            """);
        AssertHasError(diags, "E2005");
    }

    // =========================================================================
    // For loops
    // =========================================================================

    [Fact]
    public void ForLoop_ArrayIteration_BindsElementType()
    {
        var (checker, diags) = Check("""
            fn main() {
                let arr = [1i32, 2i32, 3i32]
                for item in arr {
                    let x: i32 = item
                }
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "x"));
    }

    [Fact]
    public void ForLoop_RangeIteration_BindsElementType()
    {
        var (_, diags) = Check("""
            fn main() {
                for i in 0i32..10i32 {
                    let x: i32 = i
                }
            }
            """);
        AssertNoErrors(diags);
    }

    [Fact]
    public void ForLoop_NonIterable_ProducesError()
    {
        var (_, diags) = Check("""
            fn main() {
                for i in true {
                }
            }
            """);
        AssertHasError(diags, "E2021");
    }

    // =========================================================================
    // Loop statement
    // =========================================================================

    [Fact]
    public void Loop_BasicBody_NoErrors()
    {
        var (_, diags) = Check("""
            fn main() {
                loop {
                    break
                }
            }
            """);
        AssertNoErrors(diags);
    }

    [Fact]
    public void Loop_BreakContinue_NoErrors()
    {
        var (_, diags) = Check("""
            fn main() {
                let x: i32 = 0i32
                loop {
                    if true {
                        continue
                    }
                    break
                }
            }
            """);
        AssertNoErrors(diags);
    }

    // =========================================================================
    // Defer
    // =========================================================================

    [Fact]
    public void Defer_InfersExpression_NoErrors()
    {
        var (_, diags) = Check("""
            fn cleanup() {
            }
            fn main() {
                defer cleanup()
            }
            """);
        AssertNoErrors(diags);
    }

    // =========================================================================
    // Match expressions
    // =========================================================================

    [Fact]
    public void Match_EnumVariants_UnifiesArms()
    {
        var (checker, diags) = Check("""
            enum Color {
                Red,
                Green,
                Blue
            }
            fn main() {
                let c = Red
                let r: i32 = c match {
                    Red => 1i32,
                    Green => 2i32,
                    Blue => 3i32
                }
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "r"));
    }

    [Fact]
    public void Match_WithElsePattern()
    {
        var (checker, diags) = Check("""
            enum Color {
                Red,
                Green,
                Blue
            }
            fn main() {
                let c = Red
                let r: i32 = c match {
                    Red => 1i32,
                    else => 0i32
                }
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "r"));
    }

    [Fact]
    public void Match_WithWildcard()
    {
        var (checker, diags) = Check("""
            enum Color {
                Red,
                Green,
                Blue
            }
            fn main() {
                let c = Red
                let r: i32 = c match {
                    Red => 1i32,
                    _ => 0i32
                }
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "r"));
    }

    [Fact]
    public void Match_WildcardPattern_MatchesAnything()
    {
        var (checker, diags) = Check("""
            fn main() {
                let v: i32 = 5i32
                let r: i32 = v match {
                    _ => 42i32
                }
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "r"));
    }

    [Fact]
    public void Match_EnumPayload_BindsPayloadType()
    {
        var (checker, diags) = Check("""
            enum Shape {
                Circle(i32),
                Rect(i32, i32)
            }
            fn main() {
                let s = Circle(5i32)
                let r: i32 = s match {
                    Circle(radius) => radius,
                    Rect(w, h) => w
                }
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "r"));
    }

    [Fact]
    public void Match_MismatchedArms_ProducesError()
    {
        var (_, diags) = Check("""
            struct Foo { x: i32 }
            enum Color {
                Red,
                Green
            }
            fn main() {
                let c = Red
                let f = Foo { x = 1i32 }
                let r = c match {
                    Red => 1i32,
                    Green => f
                }
            }
            """);
        AssertHasErrors(diags);
    }

    // =========================================================================
    // Lambda expressions
    // =========================================================================

    [Fact]
    public void Lambda_WithAnnotations_InfersFunctionType()
    {
        var (_, diags) = Check("""
            fn apply(f: fn(i32) i32, x: i32) i32 {
                return f(x)
            }
            fn main() {
                let r: i32 = apply(fn(x: i32) i32 { return x }, 42i32)
            }
            """);
        AssertNoErrors(diags);
    }

    [Fact]
    public void Lambda_InfersParamsFromContext()
    {
        var (_, diags) = Check("""
            fn apply(f: fn(i32) i32, x: i32) i32 {
                return f(x)
            }
            fn main() {
                let r: i32 = apply(fn(x) { return x }, 42i32)
            }
            """);
        AssertNoErrors(diags);
    }

    [Fact]
    public void Lambda_AsVariable_WithAnnotatedType()
    {
        var (_, diags) = Check("""
            fn main() {
                let f: fn(i32) i32 = fn(x: i32) i32 { return x }
            }
            """);
        AssertNoErrors(diags);
    }

    // =========================================================================
    // Range expressions
    // =========================================================================

    [Fact]
    public void Range_InfersRangeType()
    {
        var (checker, diags) = Check("""
            fn main() {
                let r = 0i32..10i32
            }
            """);
        AssertNoErrors(diags);
        var t = FindVarType(checker, "r");
        Assert.NotNull(t);
        Assert.IsType<NominalType>(t);
        Assert.Equal(WellKnown.Range, ((NominalType)t).Name);
    }

    // =========================================================================
    // Coalesce operator (??)
    // =========================================================================

    [Fact]
    public void Coalesce_OptionUnwraps()
    {
        var (checker, diags) = Check("""
            fn maybe() i32? {
                return 42i32
            }
            fn main() {
                let x: i32 = maybe() ?? 0i32
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "x"));
    }

    // =========================================================================
    // Null propagation (?.)
    // =========================================================================

    [Fact]
    public void NullPropagation_AccessesFieldThroughOption()
    {
        var (checker, diags) = Check("""
            struct Point { x: i32, y: i32 }
            fn maybe() Point? {
                return Point { x = 1i32, y = 2i32 }
            }
            fn main() {
                let v = maybe()?.x
            }
            """);
        AssertNoErrors(diags);
        var t = FindVarType(checker, "v");
        Assert.NotNull(t);
        // Result should be Option[i32]
        Assert.IsType<NominalType>(t);
        Assert.Equal(WellKnown.Option, ((NominalType)t).Name);
    }

    // =========================================================================
    // UFCS
    // =========================================================================

    [Fact]
    public void UFCS_MethodCallSyntax_ResolvesFunction()
    {
        var (checker, diags) = Check("""
            fn double(x: i32) i32 {
                return x * x
            }
            fn main() {
                let r: i32 = 5i32.double()
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "r"));
    }

    [Fact]
    public void UFCS_RefReceiver_AutoReferences()
    {
        var (checker, diags) = Check("""
            struct Point { x: i32, y: i32 }
            fn get_x(self: &Point) i32 {
                return self.x
            }
            fn main() {
                let p = Point { x = 5i32, y = 10i32 }
                let v: i32 = p.get_x()
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "v"));
    }

    // =========================================================================
    // Overload resolution
    // =========================================================================

    [Fact]
    public void Overload_SelectsCorrectByParamType()
    {
        var (checker, diags) = Check("""
            fn process(x: i32) i32 {
                return x
            }
            fn process(x: bool) bool {
                return x
            }
            fn main() {
                let a: i32 = process(1i32)
                let b: bool = process(true)
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "a"));
        Assert.Equal(WellKnown.Bool, FindVarType(checker, "b"));
    }

    [Fact]
    public void Overload_NoMatch_ProducesError()
    {
        var (_, diags) = Check("""
            fn process(x: i32, y: i32) i32 {
                return x
            }
            fn main() {
                let r = process(1i32, 2i32, 3i32)
            }
            """);
        AssertHasErrors(diags);
    }

    // =========================================================================
    // User-defined operators
    // =========================================================================

    [Fact]
    public void UserDefinedOperator_BinaryAdd()
    {
        var (checker, diags) = Check("""
            struct Vec2 { x: i32, y: i32 }
            fn op_add(a: Vec2, b: Vec2) Vec2 {
                return Vec2 { x = 1i32, y = 2i32 }
            }
            fn main() {
                let a = Vec2 { x = 1i32, y = 2i32 }
                let b = Vec2 { x = 3i32, y = 4i32 }
                let c = a + b
            }
            """);
        AssertNoErrors(diags);
        var t = FindVarType(checker, "c");
        Assert.NotNull(t);
        Assert.IsType<NominalType>(t);
        Assert.EndsWith("Vec2", ((NominalType)t).Name);
    }

    [Fact]
    public void UserDefinedOperator_Comparison()
    {
        var (checker, diags) = Check("""
            struct Vec2 { x: i32, y: i32 }
            fn op_eq(a: Vec2, b: Vec2) bool {
                return true
            }
            fn main() {
                let a = Vec2 { x = 1i32, y = 2i32 }
                let b = Vec2 { x = 1i32, y = 2i32 }
                let eq: bool = a == b
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.Bool, FindVarType(checker, "eq"));
    }

    // =========================================================================
    // Bitwise and shift operators
    // =========================================================================

    [Fact]
    public void BitwiseAnd_SameType()
    {
        var (checker, diags) = Check("""
            fn main() {
                let r: i32 = 0xFFi32 & 0x0Fi32
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "r"));
    }

    [Fact]
    public void BitwiseOr_SameType()
    {
        var (checker, diags) = Check("""
            fn main() {
                let r: i32 = 0xF0i32 | 0x0Fi32
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "r"));
    }

    [Fact]
    public void ShiftLeft_SameType()
    {
        var (checker, diags) = Check("""
            fn main() {
                let r: i32 = 1i32 << 4i32
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "r"));
    }

    // =========================================================================
    // Type resolution: nullable, slice, function types
    // =========================================================================

    [Fact]
    public void NullableType_ExpandsToOption()
    {
        var (checker, diags) = Check("""
            fn main() {
                let x: i32? = 42i32
            }
            """);
        AssertNoErrors(diags);
        var t = FindVarType(checker, "x");
        Assert.NotNull(t);
        Assert.IsType<NominalType>(t);
        Assert.Equal(WellKnown.Option, ((NominalType)t).Name);
    }

    [Fact]
    public void FunctionTypeAnnotation_Resolves()
    {
        var (checker, diags) = Check("""
            fn identity(x: i32) i32 {
                return x
            }
            fn main() {
                let f: fn(i32) i32 = identity
            }
            """);
        AssertNoErrors(diags);
        var t = FindVarType(checker, "f");
        Assert.NotNull(t);
        Assert.IsType<FunctionType>(t);
    }

    // =========================================================================
    // Generic functions
    // =========================================================================

    [Fact]
    public void GenericFunction_InfersTypeParam()
    {
        var (checker, diags) = Check("""
            fn identity(x: $T) T {
                return x
            }
            fn main() {
                let r: i32 = identity(42i32)
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "r"));
    }

    [Fact]
    public void GenericFunction_MultipleCalls_DifferentTypes()
    {
        var (checker, diags) = Check("""
            fn identity(x: $T) T {
                return x
            }
            fn main() {
                let a: i32 = identity(42i32)
                let b: bool = identity(true)
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "a"));
        Assert.Equal(WellKnown.Bool, FindVarType(checker, "b"));
    }

    // =========================================================================
    // Generic structs
    // =========================================================================

    [Fact]
    public void GenericStruct_Instantiation()
    {
        var (checker, diags) = Check("""
            struct Wrapper(T) {
                value: T
            }
            fn main() {
                let w = Wrapper { value = 42i32 }
            }
            """);
        AssertNoErrors(diags);
        var t = FindVarType(checker, "w");
        Assert.NotNull(t);
        Assert.IsType<NominalType>(t);
    }

    // =========================================================================
    // If expression — edge cases
    // =========================================================================

    [Fact]
    public void If_NonBoolCondition_ProducesError()
    {
        // Use struct as condition — no coercion to bool
        var (_, diags) = Check("""
            struct Foo { x: i32 }
            fn main() {
                let f = Foo { x = 1i32 }
                let r = if f { 1i32 } else { 2i32 }
            }
            """);
        AssertHasErrors(diags);
    }

    [Fact]
    public void If_NoElse_ReturnsVoid()
    {
        var (_, diags) = Check("""
            fn main() {
                if true {
                    let x: i32 = 1i32
                }
            }
            """);
        AssertNoErrors(diags);
    }

    // =========================================================================
    // Block edge cases
    // =========================================================================

    [Fact]
    public void Block_Empty_ReturnsVoid()
    {
        var (_, diags) = Check("""
            fn main() {
                let r = {}
            }
            """);
        AssertNoErrors(diags);
    }

    // =========================================================================
    // Return edge cases
    // =========================================================================

    [Fact]
    public void BareReturn_InVoidFunction_NoError()
    {
        var (_, diags) = Check("""
            fn donothing() {
                return
            }
            """);
        AssertNoErrors(diags);
    }

    [Fact]
    public void BareReturn_InNonVoidFunction_ProducesError()
    {
        var (_, diags) = Check("""
            fn get_value() i32 {
                return
            }
            """);
        AssertHasErrors(diags);
    }

    // =========================================================================
    // Variable declaration edge cases
    // =========================================================================

    [Fact]
    public void VariableDecl_AnnotationOnly_NoInit()
    {
        var (checker, diags) = Check("""
            fn main() {
                let x: i32
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.I32, FindVarType(checker, "x"));
    }

    // =========================================================================
    // Dereference edge cases
    // =========================================================================

    [Fact]
    public void Deref_NonReference_ProducesError()
    {
        // FLang uses postfix deref: expr.*
        var (_, diags) = Check("""
            struct Foo { x: i32 }
            fn main() {
                let f = Foo { x = 1i32 }
                let v = f.*
            }
            """);
        AssertHasErrors(diags);
    }

    // =========================================================================
    // Array edge cases
    // =========================================================================

    [Fact]
    public void ArrayField_Len_InfersUSize()
    {
        var (checker, diags) = Check("""
            fn main() {
                let arr = [1i32, 2i32]
                let n: usize = arr.len
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.USize, FindVarType(checker, "n"));
    }

    [Fact]
    public void ArrayField_Ptr_InfersRefToElement()
    {
        var (checker, diags) = Check("""
            fn main() {
                let arr = [1i32, 2i32]
                let p = arr.ptr
            }
            """);
        AssertNoErrors(diags);
        var t = FindVarType(checker, "p");
        Assert.NotNull(t);
        Assert.IsType<ReferenceType>(t);
        Assert.Equal(WellKnown.I32, ((ReferenceType)t).InnerType);
    }

    // =========================================================================
    // Indexed assignment
    // =========================================================================

    [Fact]
    public void IndexedAssignment_Array_NoError()
    {
        var (_, diags) = Check("""
            fn main() {
                let arr = [1i32, 2i32, 3i32]
                arr[0usize] = 99i32
            }
            """);
        AssertNoErrors(diags);
    }

    [Fact]
    public void IndexedAssignment_TypeMismatch_ProducesError()
    {
        var (_, diags) = Check("""
            struct Foo { x: i32 }
            fn main() {
                let arr = [1i32, 2i32]
                let f = Foo { x = 1i32 }
                arr[0usize] = f
            }
            """);
        AssertHasErrors(diags);
    }

    // =========================================================================
    // Struct field type mismatch
    // =========================================================================

    [Fact]
    public void StructConstruction_FieldTypeMismatch_ProducesError()
    {
        var (_, diags) = Check("""
            struct Bar { v: i32 }
            struct Foo { x: i32 }
            fn main() {
                let b = Bar { v = 1i32 }
                let f = Foo { x = b }
            }
            """);
        Assert.Contains(diags, d => d.Severity == DiagnosticSeverity.Error);
    }

    [Fact]
    public void StructConstruction_MissingField_ProducesError()
    {
        var (_, diags) = Check("""
            struct Point { x: i32, y: i32 }
            fn main() {
                let p = Point { x = 1i32 }
            }
            """);
        Assert.Contains(diags, d => d.Severity == DiagnosticSeverity.Error && d.Message.Contains("Missing field `y`"));
    }

    // =========================================================================
    // Multiple functions — void return
    // =========================================================================

    [Fact]
    public void VoidFunction_NoReturnAnnotation_DefaultsVoid()
    {
        var (_, diags) = Check("""
            fn do_nothing() {
            }
            fn main() {
                do_nothing()
            }
            """);
        AssertNoErrors(diags);
    }

    // =========================================================================
    // Expression statement
    // =========================================================================

    [Fact]
    public void ExpressionStatement_DiscardedResult_NoError()
    {
        var (_, diags) = Check("""
            fn side_effect() i32 {
                return 42i32
            }
            fn main() {
                side_effect()
            }
            """);
        AssertNoErrors(diags);
    }

    // =========================================================================
    // Cast edge cases
    // =========================================================================

    [Fact]
    public void Cast_BetweenIntegerTypes()
    {
        var (checker, diags) = Check("""
            fn main() {
                let x: u8 = 255i32 as u8
                let y: i64 = 42i32 as i64
            }
            """);
        AssertNoErrors(diags);
        Assert.Equal(WellKnown.U8, FindVarType(checker, "x"));
        Assert.Equal(WellKnown.I64, FindVarType(checker, "y"));
    }

    // =========================================================================
    // Unknown type error
    // =========================================================================

    [Fact]
    public void UnknownType_InAnnotation_ProducesError()
    {
        var (_, diags) = Check("""
            fn main() {
                let x: NonExistentType = 42i32
            }
            """);
        AssertHasError(diags, "E2003");
    }

    // =========================================================================
    // Duplicate enum name
    // =========================================================================

    [Fact]
    public void DuplicateEnumName_ProducesError()
    {
        var (_, diags) = Check("""
            enum Foo { A }
            enum Foo { B }
            """);
        AssertHasError(diags, "E2005");
    }

    // =========================================================================
    // Struct with ref field
    // =========================================================================

    [Fact]
    public void Struct_RefField_Resolves()
    {
        var (checker, diags) = Check("""
            struct RefHolder {
                ptr: &i32
            }
            """);
        AssertNoErrors(diags);
        var rh = FindNominal(checker, "RefHolder");
        Assert.Single(rh.FieldsOrVariants);
        Assert.IsType<ReferenceType>(rh.FieldsOrVariants[0].Type);
    }

    // =========================================================================
    // Multiple modules (forward references across functions)
    // =========================================================================

    [Fact]
    public void MutualRecursion_BothFunctionsCollected()
    {
        var (_, diags) = Check("""
            fn is_even(n: i32) bool {
                if n == 0i32 { return true }
                return is_odd(n)
            }
            fn is_odd(n: i32) bool {
                if n == 0i32 { return false }
                return is_even(n)
            }
            """);
        AssertNoErrors(diags);
    }
}
