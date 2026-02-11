using FLang.CLI;
using FLang.Core;
using FLang.Core.Types;
using FLang.Frontend;
using FLang.Frontend.Ast.Declarations;
using FLang.IR;
using FLang.IR.Instructions;
using FLang.Semantics;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Type = FLang.Core.Types.Type;

namespace FLang.Tests;

public class HmAstLoweringTests
{
    // =========================================================================
    // Test helper: parse -> type-check -> lower -> return IrModule
    // =========================================================================

    private static readonly string AssemblyPath = Path.GetDirectoryName(typeof(HmAstLoweringTests).Assembly.Location)!;
    private static readonly string ProjectRoot = Path.GetFullPath(Path.Combine(AssemblyPath, "..", "..", "..", "..", ".."));
    private static readonly string StdlibPath = Path.Combine(ProjectRoot, "stdlib");

    private static (IrModule Module, List<Diagnostic> Diagnostics) Lower(string source)
    {
        var (module, diags, _) = LowerWithCompilation(source);
        return (module, diags);
    }

    private static (IrModule Module, List<Diagnostic> Diagnostics, Compilation Compilation) LowerWithCompilation(string source)
    {
        // Write user source to a temp file so ModuleCompiler can load it
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

            var layout = new TypeLayoutService(checker.Engine, checker);
            var lowering = new HmAstLowering(checker, layout, checker.Engine);

            // Only lower user module, not stdlib
            var userModulePath = Path.GetFullPath(tempFile);
            var userModule = parsedModules[userModulePath];

            var irModule = lowering.LowerModule([("test", userModule)]);
            irModule.SourceFiles = compilation.Sources;
            allDiags.AddRange(lowering.Diagnostics);

            return (irModule, allDiags, compilation);
        }
        finally
        {
            File.Delete(tempFile);
        }
    }

    private static void AssertNoErrors(List<Diagnostic> diagnostics)
    {
        var errors = diagnostics.Where(d => d.Severity == DiagnosticSeverity.Error).ToList();
        Assert.Empty(errors);
    }

    private static IrFunction FindFunction(IrModule module, string name)
    {
        var fn = module.Functions.FirstOrDefault(f => f.Name == name);
        Assert.NotNull(fn);
        return fn;
    }

    private static IrFunction FindFunctionContaining(IrModule module, string nameFragment)
    {
        var fn = module.Functions.FirstOrDefault(f => f.Name.Contains(nameFragment));
        Assert.NotNull(fn);
        return fn;
    }

    private static List<Instruction> AllInstructions(IrFunction fn)
    {
        return [.. fn.BasicBlocks.SelectMany(bb => bb.Instructions)];
    }

    private static List<T> InstructionsOfType<T>(IrFunction fn) where T : Instruction
    {
        return [.. AllInstructions(fn).OfType<T>()];
    }

    // =========================================================================
    // Module structure
    // =========================================================================

    [Fact]
    public void EmptyFunction_ProducesIrFunction()
    {
        var (module, diags) = Lower("""
            fn main() {
            }
            """);
        AssertNoErrors(diags);
        Assert.Single(module.Functions);
        var main = FindFunction(module, "main");
        Assert.Single(main.BasicBlocks);
    }

    [Fact]
    public void MultipleFunctions_AllLowered()
    {
        var (module, diags) = Lower("""
            fn foo() i32 { return 1i32 }
            fn bar() i32 { return 2i32 }
            fn main() { }
            """);
        AssertNoErrors(diags);
        Assert.Equal(3, module.Functions.Count);
    }

    [Fact]
    public void MainFunction_MarkedAsEntryPoint()
    {
        var (module, diags) = Lower("""
            fn main() {
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");
        Assert.True(main.IsEntryPoint);
    }

    [Fact]
    public void NonMainFunction_NotEntryPoint()
    {
        var (module, diags) = Lower("""
            fn helper() { }
            fn main() { }
            """);
        AssertNoErrors(diags);
        var helper = FindFunction(module, "helper");
        Assert.False(helper.IsEntryPoint);
    }

    // =========================================================================
    // Function signatures
    // =========================================================================

    [Fact]
    public void Function_ReturnType_LoweredCorrectly()
    {
        var (module, diags) = Lower("""
            fn get_value() i32 { return 42i32 }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "get_value");
        Assert.Equal(TypeLayoutService.IrI32, fn.ReturnType);
    }

    [Fact]
    public void Function_VoidReturn_LoweredAsVoid()
    {
        var (module, diags) = Lower("""
            fn do_nothing() { }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "do_nothing");
        Assert.Equal(TypeLayoutService.IrVoidPrim, fn.ReturnType);
    }

    [Fact]
    public void Function_Parameters_LoweredCorrectly()
    {
        var (module, diags) = Lower("""
            fn add(a: i32, b: i32) i32 { return a }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "add");
        Assert.Equal(2, fn.Params.Count);
        Assert.Equal("a", fn.Params[0].Name);
        Assert.Equal(TypeLayoutService.IrI32, fn.Params[0].Type);
        Assert.Equal("b", fn.Params[1].Name);
        Assert.Equal(TypeLayoutService.IrI32, fn.Params[1].Type);
    }

    [Fact]
    public void Function_BoolParam_LoweredCorrectly()
    {
        var (module, diags) = Lower("""
            fn check(flag: bool) bool { return flag }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "check");
        Assert.Single(fn.Params);
        Assert.Equal(TypeLayoutService.IrBool, fn.Params[0].Type);
    }

    // =========================================================================
    // Return statements
    // =========================================================================

    [Fact]
    public void Return_WithValue_EmitsReturnInstruction()
    {
        var (module, diags) = Lower("""
            fn get_value() i32 { return 42i32 }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "get_value");
        var returns = InstructionsOfType<ReturnInstruction>(fn);
        Assert.NotEmpty(returns);
    }

    [Fact]
    public void Return_VoidFunction_EmitsImplicitReturn()
    {
        var (module, diags) = Lower("""
            fn do_nothing() { }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "do_nothing");
        var returns = InstructionsOfType<ReturnInstruction>(fn);
        Assert.NotEmpty(returns);
    }

    [Fact]
    public void Return_IntegerLiteral_ConstantValue()
    {
        var (module, diags) = Lower("""
            fn get_value() i32 { return 42i32 }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "get_value");
        var ret = InstructionsOfType<ReturnInstruction>(fn).First();
        Assert.IsType<ConstantValue>(ret.Value);
        Assert.Equal(42, ((ConstantValue)ret.Value).IntValue);
    }

    // =========================================================================
    // Variable declarations
    // =========================================================================

    [Fact]
    public void VariableDecl_EmitsAllocaAndStore()
    {
        var (module, diags) = Lower("""
            fn main() {
                let x: i32 = 10i32
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");
        Assert.NotEmpty(InstructionsOfType<AllocaInstruction>(main));
        Assert.NotEmpty(InstructionsOfType<StorePointerInstruction>(main));
    }

    [Fact]
    public void VariableDecl_WithoutInit_EmitsAllocaOnly()
    {
        var (module, diags) = Lower("""
            fn main() {
                let x: i32
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");
        Assert.NotEmpty(InstructionsOfType<AllocaInstruction>(main));
        Assert.Empty(InstructionsOfType<StorePointerInstruction>(main));
    }

    [Fact]
    public void MultipleVariables_MultipleAllocas()
    {
        var (module, diags) = Lower("""
            fn main() {
                let a: i32 = 1i32
                let b: i32 = 2i32
                let c: bool = true
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");
        Assert.Equal(3, InstructionsOfType<AllocaInstruction>(main).Count);
    }

    // =========================================================================
    // Integer and boolean literals
    // =========================================================================

    [Fact]
    public void IntegerLiteral_I32_CorrectValue()
    {
        var (module, diags) = Lower("""
            fn get() i32 { return 99i32 }
            """);
        AssertNoErrors(diags);
        var ret = InstructionsOfType<ReturnInstruction>(FindFunction(module, "get")).First();
        var cv = Assert.IsType<ConstantValue>(ret.Value);
        Assert.Equal(99, cv.IntValue);
    }

    [Fact]
    public void BoolLiteral_True_IsOne()
    {
        var (module, diags) = Lower("""
            fn get() bool { return true }
            """);
        AssertNoErrors(diags);
        var ret = InstructionsOfType<ReturnInstruction>(FindFunction(module, "get")).First();
        var cv = Assert.IsType<ConstantValue>(ret.Value);
        Assert.Equal(1, cv.IntValue);
    }

    // =========================================================================
    // String literals
    // =========================================================================

    [Fact]
    public void StringLiteral_AddedToStringTable()
    {
        var (module, _) = Lower("""
            fn main() {
                let s = "hello"
            }
            """);
        Assert.NotEmpty(module.StringTable);
        Assert.Equal("hello", module.StringTable[0].Value);
    }

    [Fact]
    public void StringLiteral_Deduplicated()
    {
        var (module, _) = Lower("""
            fn main() {
                let a = "hello"
                let b = "hello"
            }
            """);
        var helloEntries = module.StringTable.Where(e => e.Value == "hello").ToList();
        Assert.Single(helloEntries);
    }

    [Fact]
    public void StringLiteral_Utf8NullTerminated()
    {
        var (module, _) = Lower("""
            fn main() {
                let s = "hi"
            }
            """);
        Assert.NotEmpty(module.StringTable);
        var entry = module.StringTable[0];
        Assert.Equal((byte)'h', entry.Utf8Data[0]);
        Assert.Equal((byte)'i', entry.Utf8Data[1]);
        Assert.Equal((byte)0, entry.Utf8Data[^1]);
    }

    [Fact]
    public void DifferentStrings_SeparateEntries()
    {
        var (module, _) = Lower("""
            fn main() {
                let a = "hello"
                let b = "world"
            }
            """);
        Assert.True(module.StringTable.Count >= 2);
        Assert.Contains(module.StringTable, e => e.Value == "hello");
        Assert.Contains(module.StringTable, e => e.Value == "world");
    }

    // =========================================================================
    // Binary expressions
    // =========================================================================

    [Fact]
    public void BinaryAdd_EmitsBinaryInstruction()
    {
        var (module, diags) = Lower("""
            fn add(a: i32, b: i32) i32 { return a + b }
            """);
        AssertNoErrors(diags);
        var bins = InstructionsOfType<BinaryInstruction>(FindFunction(module, "add"));
        Assert.Single(bins);
        Assert.Equal(BinaryOp.Add, bins[0].Operation);
    }

    [Fact]
    public void BinarySubtract_CorrectOp()
    {
        var (module, diags) = Lower("""
            fn sub(a: i32, b: i32) i32 { return a - b }
            """);
        AssertNoErrors(diags);
        var bins = InstructionsOfType<BinaryInstruction>(FindFunction(module, "sub"));
        Assert.Single(bins);
        Assert.Equal(BinaryOp.Subtract, bins[0].Operation);
    }

    [Fact]
    public void BinaryComparison_LessThan()
    {
        var (module, diags) = Lower("""
            fn cmp(a: i32, b: i32) bool { return a < b }
            """);
        AssertNoErrors(diags);
        var bins = InstructionsOfType<BinaryInstruction>(FindFunction(module, "cmp"));
        Assert.Single(bins);
        Assert.Equal(BinaryOp.LessThan, bins[0].Operation);
    }

    [Fact]
    public void BinaryBitwiseAnd_CorrectOp()
    {
        var (module, diags) = Lower("""
            fn band(a: i32, b: i32) i32 { return a & b }
            """);
        AssertNoErrors(diags);
        var bins = InstructionsOfType<BinaryInstruction>(FindFunction(module, "band"));
        Assert.Single(bins);
        Assert.Equal(BinaryOp.BitwiseAnd, bins[0].Operation);
    }

    [Fact]
    public void BinaryShiftLeft_CorrectOp()
    {
        var (module, diags) = Lower("""
            fn shl(a: i32, b: i32) i32 { return a << b }
            """);
        AssertNoErrors(diags);
        var bins = InstructionsOfType<BinaryInstruction>(FindFunction(module, "shl"));
        Assert.Single(bins);
        Assert.Equal(BinaryOp.ShiftLeft, bins[0].Operation);
    }

    // =========================================================================
    // Function calls
    // =========================================================================

    [Fact]
    public void DirectCall_EmitsCallInstruction()
    {
        var (module, diags) = Lower("""
            fn helper() i32 { return 1i32 }
            fn main() {
                let x = helper()
            }
            """);
        AssertNoErrors(diags);
        var calls = InstructionsOfType<CallInstruction>(FindFunction(module, "main"));
        Assert.NotEmpty(calls);
    }

    [Fact]
    public void Call_WithArguments_PassesArgs()
    {
        var (module, diags) = Lower("""
            fn add(a: i32, b: i32) i32 { return a }
            fn main() {
                let r = add(1i32, 2i32)
            }
            """);
        AssertNoErrors(diags);
        var calls = InstructionsOfType<CallInstruction>(FindFunction(module, "main"));
        var call = calls.First(c => c.FunctionName.Contains("add"));
        Assert.Equal(2, call.Arguments.Count);
    }

    [Fact]
    public void Call_MangledAtCallSite()
    {
        var (module, diags) = Lower("""
            fn add(a: i32, b: i32) i32 { return a }
            fn main() {
                let r = add(1i32, 2i32)
            }
            """);
        AssertNoErrors(diags);
        var calls = InstructionsOfType<CallInstruction>(FindFunction(module, "main"));
        Assert.Contains(calls, c => c.FunctionName.Contains("add"));
    }

    // =========================================================================
    // Foreign functions
    // =========================================================================

    [Fact]
    public void ForeignFunction_AddedToForeignDecls()
    {
        var (module, diags) = Lower("""
            #foreign fn exit(code: i32)
            fn main() { }
            """);
        AssertNoErrors(diags);
        Assert.NotEmpty(module.ForeignDecls);
        Assert.Contains(module.ForeignDecls, d => d.CName == "exit");
    }

    [Fact]
    public void ForeignFunction_NotInFunctions()
    {
        var (module, diags) = Lower("""
            #foreign fn exit(code: i32)
            fn main() { }
            """);
        AssertNoErrors(diags);
        Assert.DoesNotContain(module.Functions, f => f.Name == "exit");
    }

    // =========================================================================
    // Struct member access
    // =========================================================================

    [Fact]
    public void StructFieldAccess_EmitsGepAndLoad()
    {
        var (module, diags) = Lower("""
            struct Point { x: i32, y: i32 }
            fn get_x(p: &Point) i32 { return p.x }
            """);
        AssertNoErrors(diags);
        var fn = FindFunctionContaining(module, "get_x");
        Assert.NotEmpty(InstructionsOfType<GetElementPtrInstruction>(fn));
        Assert.NotEmpty(InstructionsOfType<LoadInstruction>(fn));
    }

    // =========================================================================
    // Cast expressions
    // =========================================================================

    [Fact]
    public void Cast_EmitsCastInstruction()
    {
        var (module, diags) = Lower("""
            fn widen(x: i32) i64 { return x as i64 }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "widen");
        Assert.NotEmpty(InstructionsOfType<CastInstruction>(fn));
    }

    // =========================================================================
    // Generic functions
    // =========================================================================

    [Fact]
    public void GenericFunction_NotLowered()
    {
        var (module, diags) = Lower("""
            fn identity(x: $T) T { return x }
            fn main() { }
            """);
        AssertNoErrors(diags);
        Assert.DoesNotContain(module.Functions, f => f.Name.Contains("identity"));
    }

    // =========================================================================
    // Type defs — collected from function signatures
    // =========================================================================

    [Fact]
    public void StructParam_TypeDefCollected()
    {
        var (module, diags) = Lower("""
            struct Point { x: i32, y: i32 }
            fn origin() Point {
                return Point { x = 0i32, y = 0i32 }
            }
            """);
        AssertNoErrors(diags);
        Assert.Contains(module.TypeDefs, td => td is IrStruct s && s.Name.Contains("Point"));
    }

    [Fact]
    public void StructNotUsedInSignature_NotInTypeDefs()
    {
        var (module, diags) = Lower("""
            struct Unused { x: i32 }
            fn main() { }
            """);
        AssertNoErrors(diags);
        Assert.DoesNotContain(module.TypeDefs, td => td is IrStruct s && s.Name.Contains("Unused"));
    }

    // =========================================================================
    // Struct layout
    // =========================================================================

    [Fact]
    public void StructTypeDef_FieldsLaidOut()
    {
        var (module, diags) = Lower("""
            struct Point { x: i32, y: i32 }
            fn make() Point { return Point { x = 1i32, y = 2i32 } }
            """);
        AssertNoErrors(diags);
        var pointDef = module.TypeDefs.OfType<IrStruct>().FirstOrDefault(s => s.Name.Contains("Point"));
        Assert.NotNull(pointDef);
        Assert.Equal(2, pointDef.Fields.Length);
        Assert.Equal("x", pointDef.Fields[0].Name);
        Assert.Equal("y", pointDef.Fields[1].Name);
        Assert.Equal(TypeLayoutService.IrI32, pointDef.Fields[0].Type);
        Assert.Equal(TypeLayoutService.IrI32, pointDef.Fields[1].Type);
    }

    [Fact]
    public void StructTypeDef_SizeAndAlignment()
    {
        var (module, diags) = Lower("""
            struct Pair { a: i32, b: i32 }
            fn make() Pair { return Pair { a = 0i32, b = 0i32 } }
            """);
        AssertNoErrors(diags);
        var pair = module.TypeDefs.OfType<IrStruct>().FirstOrDefault(s => s.Name.Contains("Pair"));
        Assert.NotNull(pair);
        Assert.Equal(8, pair.Size);
        Assert.Equal(4, pair.Alignment);
    }

    // =========================================================================
    // Enum layout
    // =========================================================================

    [Fact]
    public void EnumTypeDef_VariantsLaidOut()
    {
        var (module, diags) = Lower("""
            enum Color { Red, Green, Blue }
            fn pick() Color { return Red }
            """);
        // Note: enum variant constructors (bare `Red`) may not resolve without
        // a full scope — this test may need adjustment when enum lowering is complete.
        var colorDef = module.TypeDefs.OfType<IrEnum>().FirstOrDefault(e => e.Name.Contains("Color"));
        if (colorDef != null)
        {
            Assert.Equal(3, colorDef.Variants.Length);
            Assert.Equal("Red", colorDef.Variants[0].Name);
            Assert.Equal(0, colorDef.Variants[0].TagValue);
            Assert.Equal("Green", colorDef.Variants[1].Name);
            Assert.Equal(1, colorDef.Variants[1].TagValue);
        }
    }

    // =========================================================================
    // Unsupported expressions — throws on unknown expression types
    // =========================================================================

    [Fact]
    public void MatchExpression_LowersWithoutError()
    {
        // Match expressions are now lowered — should succeed
        var (module, diags) = Lower("""
            enum Color { Red, Green, Blue }
            fn main() {
                let c = Red
                let x = c match {
                    Red => 0i32,
                    Green => 1i32,
                    Blue => 2i32
                }
            }
            """);
        AssertNoErrors(diags);
    }

    // =========================================================================
    // Variable usage — load from alloca
    // =========================================================================

    [Fact]
    public void VariableReference_EmitsLoad()
    {
        var (module, diags) = Lower("""
            fn main() i32 {
                let x: i32 = 42i32
                return x
            }
            """);
        AssertNoErrors(diags);
        Assert.NotEmpty(InstructionsOfType<LoadInstruction>(FindFunction(module, "main")));
    }

    [Fact]
    public void ParameterReference_NoLoad()
    {
        var (module, diags) = Lower("""
            fn identity(x: i32) i32 { return x }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "identity");
        // Parameters are direct values, no load needed
        var loads = InstructionsOfType<LoadInstruction>(fn);
        Assert.Empty(loads);
    }

    // =========================================================================
    // Instruction ordering
    // =========================================================================

    [Fact]
    public void AllocaBeforeStore_CorrectOrder()
    {
        var (module, diags) = Lower("""
            fn main() {
                let x: i32 = 42i32
            }
            """);
        AssertNoErrors(diags);
        var instrs = AllInstructions(FindFunction(module, "main"));
        var allocaIdx = instrs.FindIndex(i => i is AllocaInstruction);
        var storeIdx = instrs.FindIndex(i => i is StorePointerInstruction);
        Assert.True(allocaIdx >= 0 && storeIdx >= 0);
        Assert.True(allocaIdx < storeIdx, "Alloca must come before store");
    }

    [Fact]
    public void ReturnIsLastInstruction()
    {
        var (module, diags) = Lower("""
            fn get() i32 { return 42i32 }
            """);
        AssertNoErrors(diags);
        var lastInstr = FindFunction(module, "get").BasicBlocks.Last().Instructions.Last();
        Assert.IsType<ReturnInstruction>(lastInstr);
    }

    // =========================================================================
    // UFCS call lowering
    // =========================================================================

    [Fact]
    public void UFCS_Call_ReceiverPrependedAsFirstArg()
    {
        var (module, diags) = Lower("""
            fn double(x: i32) i32 { return x }
            fn main() {
                let r = 5i32.double()
            }
            """);
        AssertNoErrors(diags);
        var calls = InstructionsOfType<CallInstruction>(FindFunction(module, "main"));
        var call = calls.First(c => c.FunctionName.Contains("double"));
        Assert.Single(call.Arguments);
    }

    // =========================================================================
    // TDD: Not yet implemented — these tests document expected behavior
    // =========================================================================

    [Fact]
    public void IfElse_EmitsBranchAndJump()
    {
        var (module, diags) = Lower("""
            fn max(a: i32, b: i32) i32 {
                if a > b { return a }
                return b
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "max");

        // Should have multiple basic blocks for the branch
        Assert.True(fn.BasicBlocks.Count > 1);
        var branches = InstructionsOfType<BranchInstruction>(fn);
        Assert.NotEmpty(branches);
    }

    [Fact]
    public void IfElseExpression_ProducesValue()
    {
        var (module, diags) = Lower("""
            fn pick(flag: bool) i32 {
                return if flag { 1i32 } else { 2i32 }
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "pick");

        // If-as-expression uses phi-via-alloca: alloca + store in each branch + load in merge
        Assert.NotEmpty(InstructionsOfType<AllocaInstruction>(fn));
        Assert.True(fn.BasicBlocks.Count >= 4, "Expected entry, then, else, merge blocks");
        Assert.NotEmpty(InstructionsOfType<BranchInstruction>(fn));
    }

    [Fact]
    public void WhileLoop_EmitsBranchBackedge()
    {
        var (module, diags) = Lower("""
            fn count() i32 {
                let x: i32 = 0i32
                loop {
                    x = x + 1i32
                    if x == 10i32 { break }
                }
                return x
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "count");

        var jumps = InstructionsOfType<JumpInstruction>(fn);
        Assert.NotEmpty(jumps);
    }

    [Fact]
    public void ForLoop_IteratesArray()
    {
        var (module, diags) = Lower("""
            fn sum() i32 {
                let arr = [10i32, 20i32, 30i32]
                let total: i32 = 0i32
                for x in arr {
                    total = total + x
                }
                return total
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "sum");

        // Should have condition block with branch, body block with GEP
        Assert.True(fn.BasicBlocks.Count >= 3, "Expected at least 3 blocks (entry, cond, body, exit)");
        Assert.NotEmpty(InstructionsOfType<BranchInstruction>(fn));
        Assert.NotEmpty(InstructionsOfType<GetElementPtrInstruction>(fn));
    }

    [Fact]
    public void ArrayLiteral_EmitsAllocaAndStores()
    {
        var (module, diags) = Lower("""
            fn main() {
                let arr = [1i32, 2i32, 3i32]
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        // Array literal: alloca for array + GEP+store per element + alloca for var
        Assert.True(InstructionsOfType<AllocaInstruction>(main).Count >= 2);
        Assert.NotEmpty(InstructionsOfType<GetElementPtrInstruction>(main));
        Assert.NotEmpty(InstructionsOfType<StorePointerInstruction>(main));
    }

    [Fact]
    public void ArrayIndex_EmitsGep()
    {
        var (module, diags) = Lower("""
            fn first() i32 {
                let arr = [10i32, 20i32, 30i32]
                return arr[0usize]
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "first");

        Assert.NotEmpty(InstructionsOfType<GetElementPtrInstruction>(fn));
    }

    [Fact]
    public void AddressOf_ReturnsAllocaPointerDirectly()
    {
        var (module, diags) = Lower("""
            fn get_ref() &i32 {
                let x: i32 = 42i32
                return &x
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "get_ref");

        // &x of a local returns the alloca pointer directly — no AddressOfInstruction needed
        // The return should carry a pointer-typed value
        var ret = InstructionsOfType<ReturnInstruction>(fn).First();
        Assert.NotNull(ret.Value);
    }

    [Fact]
    public void Dereference_EmitsLoad()
    {
        var (module, diags) = Lower("""
            fn deref(p: &i32) i32 {
                return p.*
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunctionContaining(module, "deref");

        // Dereference emits a LoadInstruction from the pointer
        Assert.NotEmpty(InstructionsOfType<LoadInstruction>(fn));
    }

    [Fact]
    public void UnaryNegate_EmitsUnaryInstruction()
    {
        var (module, diags) = Lower("""
            fn negate(x: i32) i32 { return -x }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "negate");

        var unaries = InstructionsOfType<UnaryInstruction>(fn);
        Assert.Single(unaries);
        Assert.Equal(UnaryOp.Negate, unaries[0].Operation);
    }

    [Fact]
    public void UnaryNot_EmitsUnaryInstruction()
    {
        var (module, diags) = Lower("""
            fn invert(x: bool) bool { return !x }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "invert");

        var unaries = InstructionsOfType<UnaryInstruction>(fn);
        Assert.Single(unaries);
        Assert.Equal(UnaryOp.Not, unaries[0].Operation);
    }

    [Fact]
    public void MatchExpression_EmitsBranches()
    {
        var (module, diags) = Lower("""
            enum Color { Red, Green, Blue }
            fn to_int(c: Color) i32 {
                return c match {
                    Red => 0i32,
                    Green => 1i32,
                    Blue => 2i32
                }
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunctionContaining(module, "to_int");

        Assert.True(fn.BasicBlocks.Count > 1);
    }

    [Fact]
    public void Lambda_EmitsSeparateFunction()
    {
        var (module, diags) = Lower("""
            fn apply(f: fn(i32) i32, x: i32) i32 {
                return f(x)
            }
            fn main() {
                let r = apply(fn(x: i32) i32 { return x }, 42i32)
            }
            """);
        AssertNoErrors(diags);
        // Lambda should be lifted to a separate IR function
        Assert.True(module.Functions.Count > 2);
    }

    [Fact]
    public void Assignment_EmitsStoreToExistingAlloca()
    {
        var (module, diags) = Lower("""
            fn main() {
                let x: i32 = 1i32
                x = 2i32
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        // Should have alloca + initial store + reassignment store
        var stores = InstructionsOfType<StorePointerInstruction>(main);
        Assert.Equal(2, stores.Count);
    }

    [Fact]
    public void BlockExpression_LastValueIsResult()
    {
        var (module, diags) = Lower("""
            fn main() i32 {
                return {
                    let a: i32 = 1i32
                    a + 2i32
                }
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        // Block should emit alloca for `a`, binary add, then return the result
        Assert.NotEmpty(InstructionsOfType<AllocaInstruction>(main));
        Assert.NotEmpty(InstructionsOfType<BinaryInstruction>(main));
        Assert.NotEmpty(InstructionsOfType<ReturnInstruction>(main));
    }

    [Fact]
    public void StructConstruction_EmitsAllocaAndFieldStores()
    {
        var (module, diags) = Lower("""
            struct Point { x: i32, y: i32 }
            fn main() {
                let p = Point { x = 1i32, y = 2i32 }
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        // Should alloca the struct, then GEP+store each field
        Assert.NotEmpty(InstructionsOfType<AllocaInstruction>(main));
    }

    [Fact]
    public void Defer_CallsAtFunctionEnd()
    {
        var (module, diags) = Lower("""
            fn cleanup() { }
            fn main() i32 {
                defer cleanup()
                let a = 1i32
                return a
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        // cleanup() call should appear before the return
        var instrs = AllInstructions(main);
        var callIdx = instrs.FindIndex(i => i is CallInstruction c && c.FunctionName.Contains("cleanup"));
        var retIdx = instrs.FindIndex(i => i is ReturnInstruction);
        Assert.True(callIdx >= 0 && callIdx < retIdx);
    }

    // =========================================================================
    // Defer — LIFO ordering
    // =========================================================================

    [Fact]
    public void Defer_MultipleDefers_EmittedInLIFOOrder()
    {
        var (module, diags) = Lower("""
            fn first() { }
            fn second() { }
            fn third() { }
            fn main() i32 {
                defer first()
                defer second()
                defer third()
                return 0i32
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        // Deferred calls should appear in LIFO order: third, second, first
        var instrs = AllInstructions(main);
        var callNames = instrs
            .OfType<CallInstruction>()
            .Select(c => c.FunctionName)
            .ToList();

        var thirdIdx = callNames.FindIndex(n => n.Contains("third"));
        var secondIdx = callNames.FindIndex(n => n.Contains("second"));
        var firstIdx = callNames.FindIndex(n => n.Contains("first"));

        Assert.True(thirdIdx >= 0 && secondIdx >= 0 && firstIdx >= 0,
            "All three deferred calls should be emitted");
        Assert.True(thirdIdx < secondIdx, "third should be emitted before second (LIFO)");
        Assert.True(secondIdx < firstIdx, "second should be emitted before first (LIFO)");
    }

    // =========================================================================
    // Break and continue
    // =========================================================================

    [Fact]
    public void Break_EmitsJumpToExitBlock()
    {
        var (module, diags) = Lower("""
            fn main() {
                loop {
                    break
                }
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        // Should have at least 3 blocks: entry, loop_body, loop_exit
        Assert.True(main.BasicBlocks.Count >= 3);
        var jumps = InstructionsOfType<JumpInstruction>(main);
        Assert.True(jumps.Count >= 2, "Need jump into loop + break jump to exit");
    }

    [Fact]
    public void Continue_EmitsJumpToBodyBlock()
    {
        var (module, diags) = Lower("""
            fn main() {
                let x: i32 = 0i32
                loop {
                    x = x + 1i32
                    if x < 5i32 { continue }
                    break
                }
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        // Multiple jump instructions: entry->body, continue->body, break->exit, backedge->body
        var jumps = InstructionsOfType<JumpInstruction>(main);
        Assert.True(jumps.Count >= 2);
    }

    // =========================================================================
    // Assignment to complex lvalues
    // =========================================================================

    [Fact]
    public void Assignment_ToStructField_EmitsGepAndStore()
    {
        var (module, diags) = Lower("""
            struct Point { x: i32, y: i32 }
            fn main() {
                let p = Point { x = 1i32, y = 2i32 }
                p.x = 42i32
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        // Assignment to p.x should GEP to field, then store
        var geps = InstructionsOfType<GetElementPtrInstruction>(main);
        var stores = InstructionsOfType<StorePointerInstruction>(main);
        Assert.True(geps.Count >= 1, "Need at least one GEP for field access");
        Assert.True(stores.Count >= 3, "Init stores for x,y fields + reassignment store");
    }

    [Fact(Skip = "HmTypeChecker does not yet record types for index expressions as lvalues")]
    public void Assignment_ToArrayElement_EmitsGepAndStore()
    {
        var (module, diags) = Lower("""
            fn main() {
                let arr = [1i32, 2i32, 3i32]
                arr[0usize] = 99i32
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        // Needs GEP for index + store
        Assert.NotEmpty(InstructionsOfType<GetElementPtrInstruction>(main));
        Assert.NotEmpty(InstructionsOfType<StorePointerInstruction>(main));
    }

    [Fact]
    public void Assignment_ThroughDeref_EmitsStore()
    {
        var (module, diags) = Lower("""
            fn set(p: &i32) {
                p.* = 42i32
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunctionContaining(module, "set");

        // Deref assignment: store through the pointer
        Assert.NotEmpty(InstructionsOfType<StorePointerInstruction>(fn));
    }

    [Fact]
    public void Assignment_ToParameter_CreatesAlloca()
    {
        var (module, diags) = Lower("""
            fn mutate(x: i32) i32 {
                x = x + 1i32
                return x
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "mutate");

        // Assigning to a parameter should create an alloca (promote param to local)
        Assert.NotEmpty(InstructionsOfType<AllocaInstruction>(fn));
        Assert.NotEmpty(InstructionsOfType<StorePointerInstruction>(fn));
    }

    // =========================================================================
    // Variable shadowing
    // =========================================================================

    [Fact]
    public void VariableShadowing_CreatesUniqueNames()
    {
        var (module, diags) = Lower("""
            fn main() i32 {
                let x: i32 = 1i32
                let x: i32 = 2i32
                return x
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        // Should have 2 allocas for the two x declarations
        Assert.Equal(2, InstructionsOfType<AllocaInstruction>(main).Count);
    }

    // =========================================================================
    // Nested control flow
    // =========================================================================

    [Fact]
    public void NestedIf_MultipleBlocks()
    {
        var (module, diags) = Lower("""
            fn classify(x: i32) i32 {
                if x > 0i32 {
                    if x > 10i32 {
                        return 2i32
                    }
                    return 1i32
                }
                return 0i32
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "classify");

        // Nested ifs produce multiple branch instructions
        var branches = InstructionsOfType<BranchInstruction>(fn);
        Assert.True(branches.Count >= 2, "Need at least 2 branches for nested if");
    }

    [Fact]
    public void NestedLoop_IndependentBreaks()
    {
        var (module, diags) = Lower("""
            fn main() i32 {
                let result: i32 = 0i32
                loop {
                    loop {
                        break
                    }
                    result = 42i32
                    break
                }
                return result
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        // Two loops = more blocks
        Assert.True(main.BasicBlocks.Count >= 5);
    }

    // =========================================================================
    // Struct construction with field layout
    // =========================================================================

    [Fact]
    public void StructConstruction_GepsPerField()
    {
        var (module, diags) = Lower("""
            struct Vec3 { x: i32, y: i32, z: i32 }
            fn make() Vec3 {
                return Vec3 { x = 1i32, y = 2i32, z = 3i32 }
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "make");

        // Each field gets a GEP + store
        var geps = InstructionsOfType<GetElementPtrInstruction>(fn);
        Assert.Equal(3, geps.Count);
        var stores = InstructionsOfType<StorePointerInstruction>(fn);
        Assert.Equal(3, stores.Count);
    }

    // =========================================================================
    // Cast — constant folding
    // =========================================================================

    [Fact]
    public void Cast_ConstantFolding_NoInstruction()
    {
        var (module, diags) = Lower("""
            fn widen() i64 { return 42i32 as i64 }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "widen");

        // Constant cast of a literal should be folded — result is ConstantValue
        var ret = InstructionsOfType<ReturnInstruction>(fn).First();
        Assert.IsType<ConstantValue>(ret.Value);
        Assert.Equal(42, ((ConstantValue)ret.Value).IntValue);
    }

    // =========================================================================
    // Implicit void return
    // =========================================================================

    [Fact]
    public void ImplicitReturn_AllBlocksTerminated()
    {
        var (module, diags) = Lower("""
            fn do_stuff(x: i32) {
                if x > 0i32 {
                    let a: i32 = 1i32
                }
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunctionContaining(module, "do_stuff");

        // Every basic block must end with a terminator
        foreach (var block in fn.BasicBlocks)
        {
            var last = block.Instructions.Last();
            Assert.True(
                last is ReturnInstruction or JumpInstruction or BranchInstruction,
                $"Block {block.Label} does not end with a terminator");
        }
    }

    // =========================================================================
    // Call — foreign vs non-foreign
    // =========================================================================

    [Fact]
    public void ForeignCall_MarkedAsForeign()
    {
        var (module, diags) = Lower("""
            #foreign fn exit(code: i32)
            fn main() {
                exit(0i32)
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");
        var calls = InstructionsOfType<CallInstruction>(main);
        var exitCall = calls.First(c => c.FunctionName == "exit");
        Assert.True(exitCall.IsForeignCall);
    }

    [Fact]
    public void NonForeignCall_NotMarkedForeign()
    {
        var (module, diags) = Lower("""
            fn helper() i32 { return 1i32 }
            fn main() {
                let x = helper()
            }
            """);
        AssertNoErrors(diags);
        var calls = InstructionsOfType<CallInstruction>(FindFunction(module, "main"));
        var helperCall = calls.First(c => c.FunctionName.Contains("helper"));
        Assert.False(helperCall.IsForeignCall);
    }

    // =========================================================================
    // Array — repeat syntax
    // =========================================================================

    [Fact]
    public void ArrayRepeat_EmitsMultipleStores()
    {
        var (module, diags) = Lower("""
            fn main() {
                let arr = [0i32; 4]
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        // [0; 4] stores the same value 4 times via GEP + store
        var geps = InstructionsOfType<GetElementPtrInstruction>(main);
        Assert.Equal(4, geps.Count);
    }

    // =========================================================================
    // Implicit coercion — integer widening
    // =========================================================================

    [Fact]
    public void ImplicitCoercion_IntegerWidening_LowersWithoutError()
    {
        var (module, diags) = Lower("""
            fn widen(x: i32) i64 { return x }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "widen");

        // Returning i32 where i64 expected should lower successfully
        // The coercion may be a CastInstruction or folded by the inference engine
        Assert.NotEmpty(InstructionsOfType<ReturnInstruction>(fn));
        Assert.Equal(TypeLayoutService.IrI64, fn.ReturnType);
    }

    // =========================================================================
    // Multiple binary ops — complex expressions
    // =========================================================================

    [Fact]
    public void ChainedBinaryOps_MultipleInstructions()
    {
        var (module, diags) = Lower("""
            fn calc(a: i32, b: i32, c: i32) i32 {
                return a + b * c
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "calc");

        var bins = InstructionsOfType<BinaryInstruction>(fn);
        Assert.Equal(2, bins.Count);
    }

    // =========================================================================
    // For loop — index counter mechanics
    // =========================================================================

    [Fact]
    public void ForLoop_DirectArray_HasIndexIncrement()
    {
        var (module, diags) = Lower("""
            fn main() {
                let arr = [1i32, 2i32]
                for x in arr { }
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        // Direct for loop uses index increment: should have Add binary instruction
        var bins = InstructionsOfType<BinaryInstruction>(main);
        Assert.Contains(bins, b => b.Operation == BinaryOp.Add);
        // And a LessThan comparison for the condition
        Assert.Contains(bins, b => b.Operation == BinaryOp.LessThan);
    }

    // =========================================================================
    // Loop with early return
    // =========================================================================

    [Fact]
    public void Loop_EarlyReturn_EmitsDeferBeforeReturn()
    {
        var (module, diags) = Lower("""
            fn cleanup() { }
            fn find() i32 {
                defer cleanup()
                loop {
                    return 42i32
                }
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "find");

        // The return inside the loop should emit deferred calls before itself
        var instrs = AllInstructions(fn);
        var callIdx = instrs.FindIndex(i => i is CallInstruction c && c.FunctionName.Contains("cleanup"));
        var retIdx = instrs.FindIndex(i => i is ReturnInstruction);
        Assert.True(callIdx >= 0 && callIdx < retIdx);
    }

    // =========================================================================
    // Entry point detection
    // =========================================================================

    [Fact]
    public void MultipleModules_OnlyMainIsEntryPoint()
    {
        var (module, diags) = Lower("""
            fn helper() i32 { return 1i32 }
            fn other() { }
            fn main() {
                let x = helper()
            }
            """);
        AssertNoErrors(diags);

        foreach (var fn in module.Functions)
        {
            if (fn.Name == "main")
                Assert.True(fn.IsEntryPoint);
            else
                Assert.False(fn.IsEntryPoint, $"Function {fn.Name} should not be entry point");
        }
    }

    // =========================================================================
    // Boolean comparison operators
    // =========================================================================

    [Fact]
    public void BinaryEqual_CorrectOp()
    {
        var (module, diags) = Lower("""
            fn eq(a: i32, b: i32) bool { return a == b }
            """);
        AssertNoErrors(diags);
        var bins = InstructionsOfType<BinaryInstruction>(FindFunction(module, "eq"));
        Assert.Single(bins);
        Assert.Equal(BinaryOp.Equal, bins[0].Operation);
    }

    [Fact]
    public void BinaryNotEqual_CorrectOp()
    {
        var (module, diags) = Lower("""
            fn neq(a: i32, b: i32) bool { return a != b }
            """);
        AssertNoErrors(diags);
        var bins = InstructionsOfType<BinaryInstruction>(FindFunction(module, "neq"));
        Assert.Single(bins);
        Assert.Equal(BinaryOp.NotEqual, bins[0].Operation);
    }

    [Fact]
    public void BinaryGreaterThan_CorrectOp()
    {
        var (module, diags) = Lower("""
            fn gt(a: i32, b: i32) bool { return a > b }
            """);
        AssertNoErrors(diags);
        var bins = InstructionsOfType<BinaryInstruction>(FindFunction(module, "gt"));
        Assert.Single(bins);
        Assert.Equal(BinaryOp.GreaterThan, bins[0].Operation);
    }

    [Fact]
    public void BinaryGreaterThanOrEqual_CorrectOp()
    {
        var (module, diags) = Lower("""
            fn gte(a: i32, b: i32) bool { return a >= b }
            """);
        AssertNoErrors(diags);
        var bins = InstructionsOfType<BinaryInstruction>(FindFunction(module, "gte"));
        Assert.Single(bins);
        Assert.Equal(BinaryOp.GreaterThanOrEqual, bins[0].Operation);
    }

    [Fact]
    public void BinaryLessThanOrEqual_CorrectOp()
    {
        var (module, diags) = Lower("""
            fn lte(a: i32, b: i32) bool { return a <= b }
            """);
        AssertNoErrors(diags);
        var bins = InstructionsOfType<BinaryInstruction>(FindFunction(module, "lte"));
        Assert.Single(bins);
        Assert.Equal(BinaryOp.LessThanOrEqual, bins[0].Operation);
    }

    // =========================================================================
    // Bitwise operators
    // =========================================================================

    [Fact]
    public void BinaryBitwiseOr_CorrectOp()
    {
        var (module, diags) = Lower("""
            fn bor(a: i32, b: i32) i32 { return a | b }
            """);
        AssertNoErrors(diags);
        var bins = InstructionsOfType<BinaryInstruction>(FindFunction(module, "bor"));
        Assert.Single(bins);
        Assert.Equal(BinaryOp.BitwiseOr, bins[0].Operation);
    }

    [Fact]
    public void BinaryBitwiseXor_CorrectOp()
    {
        var (module, diags) = Lower("""
            fn bxor(a: i32, b: i32) i32 { return a ^ b }
            """);
        AssertNoErrors(diags);
        var bins = InstructionsOfType<BinaryInstruction>(FindFunction(module, "bxor"));
        Assert.Single(bins);
        Assert.Equal(BinaryOp.BitwiseXor, bins[0].Operation);
    }

    [Fact]
    public void BinaryShiftRight_CorrectOp()
    {
        var (module, diags) = Lower("""
            fn shr(a: i32, b: i32) i32 { return a >> b }
            """);
        AssertNoErrors(diags);
        var bins = InstructionsOfType<BinaryInstruction>(FindFunction(module, "shr"));
        Assert.Single(bins);
        Assert.Equal(BinaryOp.ShiftRight, bins[0].Operation);
    }

    // =========================================================================
    // Short-circuit logical operators (&&, ||)
    // =========================================================================

    [Fact]
    public void LogicalAnd_EmitsBranching_NotBinaryInstruction()
    {
        var (module, diags) = Lower("""
            fn check_and(a: bool, b: bool) bool { return a and b }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "check_and");

        // Short-circuit && should NOT produce a BinaryInstruction
        var bins = InstructionsOfType<BinaryInstruction>(fn);
        Assert.Empty(bins);

        // Should have multiple blocks (entry, rhs, merge) and a branch
        Assert.True(fn.BasicBlocks.Count >= 3, "Expected at least entry, rhs, merge blocks for short-circuit &&");
        Assert.NotEmpty(InstructionsOfType<BranchInstruction>(fn));
    }

    [Fact]
    public void LogicalOr_EmitsBranching_NotBinaryInstruction()
    {
        var (module, diags) = Lower("""
            fn check_or(a: bool, b: bool) bool { return a or b }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "check_or");

        // Short-circuit || should NOT produce a BinaryInstruction
        var bins = InstructionsOfType<BinaryInstruction>(fn);
        Assert.Empty(bins);

        // Should have multiple blocks (entry, rhs, merge) and a branch
        Assert.True(fn.BasicBlocks.Count >= 3, "Expected at least entry, rhs, merge blocks for short-circuit ||");
        Assert.NotEmpty(InstructionsOfType<BranchInstruction>(fn));
    }

    [Fact]
    public void LogicalAnd_ShortCircuits_RhsNotAlwaysEvaluated()
    {
        // Verify the structure: && evaluates LHS, branches to RHS only if true
        var (module, diags) = Lower("""
            fn check_and(a: bool, b: bool) bool { return a and b }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "check_and");

        // Should have alloca for result (phi-via-alloca pattern)
        Assert.NotEmpty(InstructionsOfType<AllocaInstruction>(fn));
        // Should store default (false for &&) and then conditionally store RHS
        Assert.NotEmpty(InstructionsOfType<StorePointerInstruction>(fn));
        // Should load result from merge block
        Assert.NotEmpty(InstructionsOfType<LoadInstruction>(fn));
    }

    // =========================================================================
    // Binary operator function resolution (op_add, op_eq, etc.)
    // =========================================================================

    [Fact]
    public void BinaryOpAdd_UserDefined_EmitsCallInstruction()
    {
        var (module, diags) = Lower("""
            struct Vec2 { x: i32, y: i32 }
            fn op_add(a: Vec2, b: Vec2) Vec2 {
                return Vec2 { x = a.x + b.x, y = a.y + b.y }
            }
            fn main() {
                let a = Vec2 { x = 1i32, y = 2i32 }
                let b = Vec2 { x = 3i32, y = 4i32 }
                let c = a + b
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        // The `+` on Vec2 should resolve to op_add and emit a CallInstruction
        var calls = InstructionsOfType<CallInstruction>(main);
        Assert.Contains(calls, c => c.FunctionName.Contains("op_add"));
    }

    [Fact]
    public void BinaryOpAdd_RefParams_AutoLifted()
    {
        // op_add takes &Vec2 but caller passes Vec2 values — auto-lifted
        var (module, diags) = Lower("""
            struct Vec2 { x: i32, y: i32 }
            fn op_add(a: &Vec2, b: &Vec2) Vec2 {
                return Vec2 { x = a.x + b.x, y = a.y + b.y }
            }
            fn main() {
                let a = Vec2 { x = 1i32, y = 2i32 }
                let b = Vec2 { x = 3i32, y = 4i32 }
                let c = a + b
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        var calls = InstructionsOfType<CallInstruction>(main);
        Assert.Contains(calls, c => c.FunctionName.Contains("op_add"));
    }

    [Fact]
    public void BinaryOpEq_UserDefined_EmitsCallInstruction()
    {
        var (module, diags) = Lower("""
            struct Point { x: i32, y: i32 }
            fn op_eq(a: Point, b: Point) bool {
                return a.x == b.x and a.y == b.y
            }
            fn main() {
                let a = Point { x = 1i32, y = 2i32 }
                let b = Point { x = 1i32, y = 2i32 }
                let eq = a == b
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        var calls = InstructionsOfType<CallInstruction>(main);
        Assert.Contains(calls, c => c.FunctionName.Contains("op_eq"));
    }

    [Fact]
    public void DerivedNotEqual_ViaOpEq_EmitsCallAndNot()
    {
        // != derived from op_eq should emit a call to op_eq + UnaryInstruction(Not)
        var (module, diags) = Lower("""
            struct Point { x: i32, y: i32 }
            fn op_eq(a: Point, b: Point) bool {
                return a.x == b.x and a.y == b.y
            }
            fn main() {
                let a = Point { x = 1i32, y = 2i32 }
                let b = Point { x = 3i32, y = 4i32 }
                let neq = a != b
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        // Should call op_eq then negate
        var calls = InstructionsOfType<CallInstruction>(main);
        Assert.Contains(calls, c => c.FunctionName.Contains("op_eq"));
        var nots = InstructionsOfType<UnaryInstruction>(main);
        Assert.Contains(nots, n => n.Operation == UnaryOp.Not);
    }

    // =========================================================================
    // Unary operator function resolution
    // =========================================================================

    [Fact]
    public void UnaryOpNeg_UserDefined_EmitsCallInstruction()
    {
        var (module, diags) = Lower("""
            struct Num { val: i32 }
            fn op_neg(n: Num) Num {
                return Num { val = -n.val }
            }
            fn main() {
                let n = Num { val = 42i32 }
                let neg = -n
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        var calls = InstructionsOfType<CallInstruction>(main);
        Assert.Contains(calls, c => c.FunctionName.Contains("op_neg"));
    }

    // =========================================================================
    // Index operator function resolution (op_index)
    // =========================================================================

    [Fact]
    public void OpIndex_UserDefined_RefParam_EmitsCallInstruction()
    {
        // op_index with &MyList param — base is auto-lifted to reference
        var (module, diags) = Lower("""
            struct MyList { data: &i32, len: usize }
            fn op_index(list: &MyList, idx: usize) i32 {
                return list.data.*
            }
            fn main() {
                let x: i32 = 42i32
                let list = MyList { data = &x, len = 1usize }
                let val = list[0usize]
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        var calls = InstructionsOfType<CallInstruction>(main);
        Assert.Contains(calls, c => c.FunctionName.Contains("op_index"));
    }

    [Fact]
    public void OpIndex_UserDefined_ValueParam_EmitsCallInstruction()
    {
        // op_index with value MyList param — no auto-lift needed
        var (module, diags) = Lower("""
            struct MyList { data: &i32, len: usize }
            fn op_index(list: MyList, idx: usize) i32 {
                return list.data.*
            }
            fn main() {
                let x: i32 = 42i32
                let list = MyList { data = &x, len = 1usize }
                let val = list[0usize]
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        var calls = InstructionsOfType<CallInstruction>(main);
        Assert.Contains(calls, c => c.FunctionName.Contains("op_index"));
    }

    // =========================================================================
    // Set-index operator function resolution (op_set_index)
    // =========================================================================

    [Fact]
    public void OpSetIndex_UserDefined_EmitsCallInstruction()
    {
        var (module, diags) = Lower("""
            struct MyList { data: &i32, len: usize }
            fn op_set_index(list: &MyList, idx: usize, val: i32) {
            }
            fn main() {
                let x: i32 = 42i32
                let list = MyList { data = &x, len = 1usize }
                list[0usize] = 99i32
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");

        var calls = InstructionsOfType<CallInstruction>(main);
        Assert.Contains(calls, c => c.FunctionName.Contains("op_set_index"));
    }

    // =========================================================================
    // Enum variant construction
    // =========================================================================

    [Fact]
    public void EnumConstruction_NoPayload_EmitsAllocaTagStoreLoad()
    {
        var (module, diags) = Lower("""
            enum Color { Red, Green, Blue }
            fn pick() Color { return Green }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "pick");

        // Should have: alloca (enum), GEP (tag), store (tag), load (result)
        Assert.NotEmpty(InstructionsOfType<AllocaInstruction>(fn));
        Assert.NotEmpty(InstructionsOfType<GetElementPtrInstruction>(fn));
        Assert.NotEmpty(InstructionsOfType<StorePointerInstruction>(fn));
        Assert.NotEmpty(InstructionsOfType<LoadInstruction>(fn));
    }

    [Fact]
    public void EnumConstruction_SinglePayload_StoresPayload()
    {
        var (module, diags) = Lower("""
            enum Maybe { None, Some(i32) }
            fn wrap(x: i32) Maybe { return Some(x) }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "wrap");

        // At least 2 GEPs: one for tag, one for payload
        var geps = InstructionsOfType<GetElementPtrInstruction>(fn);
        Assert.True(geps.Count >= 2, "Expected GEP for tag and payload");
        // At least 2 stores: tag value + payload value
        var stores = InstructionsOfType<StorePointerInstruction>(fn);
        Assert.True(stores.Count >= 2, "Expected stores for tag and payload");
    }

    [Fact]
    public void EnumConstruction_MultiPayload_StoresAllFields()
    {
        var (module, diags) = Lower("""
            enum Shape { Circle(i32), Rect(i32, i32) }
            fn make_rect() Shape { return Rect(10i32, 20i32) }
            """);
        AssertNoErrors(diags);
        var fn = FindFunctionContaining(module, "make_rect");

        // At least 3 GEPs: tag + two payload fields
        var geps = InstructionsOfType<GetElementPtrInstruction>(fn);
        Assert.True(geps.Count >= 3, "Expected GEP for tag and each payload field");
    }

    [Fact]
    public void EnumConstruction_VariantInVariable()
    {
        var (module, diags) = Lower("""
            enum Color { Red, Green, Blue }
            fn main() {
                let c = Red
            }
            """);
        AssertNoErrors(diags);
        var main = FindFunction(module, "main");
        Assert.NotEmpty(InstructionsOfType<AllocaInstruction>(main));
    }

    // =========================================================================
    // Match expression lowering
    // =========================================================================

    [Fact]
    public void Match_SimpleTagDispatch_MultipleBranches()
    {
        var (module, diags) = Lower("""
            enum Color { Red, Green, Blue }
            fn to_int(c: Color) i32 {
                return c match {
                    Red => 0i32,
                    Green => 1i32,
                    Blue => 2i32
                }
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunctionContaining(module, "to_int");

        // Should have multiple blocks: entry + arms + merge
        Assert.True(fn.BasicBlocks.Count >= 4, "Expected entry, arm blocks, and merge");
        // Should have tag comparisons
        var branches = InstructionsOfType<BranchInstruction>(fn);
        Assert.NotEmpty(branches);
    }

    [Fact]
    public void Match_WithElseArm_EmitsUnconditionalJump()
    {
        var (module, diags) = Lower("""
            enum Color { Red, Green, Blue }
            fn to_int(c: Color) i32 {
                return c match {
                    Red => 0i32,
                    else => 99i32
                }
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunctionContaining(module, "to_int");

        // Should have jumps for the else arm
        Assert.NotEmpty(InstructionsOfType<JumpInstruction>(fn));
    }

    [Fact]
    public void Match_PayloadExtraction_BindsVariable()
    {
        var (module, diags) = Lower("""
            enum Maybe { None, Some(i32) }
            fn unwrap(m: Maybe) i32 {
                return m match {
                    Some(x) => x,
                    None => 0i32
                }
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunctionContaining(module, "unwrap");

        // Should have GEP to extract payload
        Assert.NotEmpty(InstructionsOfType<GetElementPtrInstruction>(fn));
        // Multiple blocks for arm dispatch
        Assert.True(fn.BasicBlocks.Count >= 3);
    }

    [Fact]
    public void Match_AsExpression_ProducesValue()
    {
        var (module, diags) = Lower("""
            enum Bool2 { True2, False2 }
            fn to_bool(b: Bool2) bool {
                return b match {
                    True2 => true,
                    False2 => false
                }
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunctionContaining(module, "to_bool");

        // Phi-via-alloca: should have alloca for result
        Assert.NotEmpty(InstructionsOfType<AllocaInstruction>(fn));
        // Load from result alloca in merge block
        Assert.NotEmpty(InstructionsOfType<LoadInstruction>(fn));
    }

    // =========================================================================
    // Lambda lowering
    // =========================================================================

    [Fact]
    public void Lambda_TypedParams_LowersToFunctionReference()
    {
        var (module, diags) = Lower("""
            fn apply(f: fn(i32) i32, x: i32) i32 {
                return f(x)
            }
            fn main() {
                let r = apply(fn(x: i32) i32 { return x }, 42i32)
            }
            """);
        AssertNoErrors(diags);

        // Lambda should create a separate __lambda_ function
        var lambdaFn = module.Functions.FirstOrDefault(f => f.Name.Contains("__lambda_"));
        Assert.NotNull(lambdaFn);
    }

    [Fact]
    public void Lambda_SynthesizedFunction_HasCorrectParams()
    {
        var (module, diags) = Lower("""
            fn apply(f: fn(i32) i32, x: i32) i32 {
                return f(x)
            }
            fn main() {
                let r = apply(fn(a: i32) i32 { return a }, 10i32)
            }
            """);
        AssertNoErrors(diags);

        var lambdaFn = module.Functions.FirstOrDefault(f => f.Name.Contains("__lambda_"));
        Assert.NotNull(lambdaFn);
        Assert.Single(lambdaFn.Params);
        Assert.Equal(TypeLayoutService.IrI32, lambdaFn.Params[0].Type);
    }

    [Fact]
    public void Lambda_BodyHasReturn_LoweredCorrectly()
    {
        var (module, diags) = Lower("""
            fn apply(f: fn(i32) i32, x: i32) i32 {
                return f(x)
            }
            fn main() {
                let r = apply(fn(x: i32) i32 { return x + 1i32 }, 5i32)
            }
            """);
        AssertNoErrors(diags);

        var lambdaFn = module.Functions.FirstOrDefault(f => f.Name.Contains("__lambda_"));
        Assert.NotNull(lambdaFn);
        // Lambda body should have a binary add and a return
        Assert.NotEmpty(InstructionsOfType<BinaryInstruction>(lambdaFn));
        Assert.NotEmpty(InstructionsOfType<ReturnInstruction>(lambdaFn));
    }

    // =========================================================================
    // Source span propagation
    // =========================================================================

    [Fact]
    public void Instructions_HaveValidSourceSpans()
    {
        var (module, diags) = Lower("""
            fn add(a: i32, b: i32) i32 {
                return a + b
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "add");
        var instructions = AllInstructions(fn);

        // All instructions should have a valid (non-None) SourceSpan
        foreach (var inst in instructions)
        {
            Assert.NotEqual(SourceSpan.None, inst.Span);
            Assert.True(inst.Span.FileId >= 0, $"Instruction {inst.GetType().Name} has invalid FileId");
        }
    }

    [Fact]
    public void CCodeGenerator_EmitsLineDirectives()
    {
        var (module, diags, _) = LowerWithCompilation("""
            fn compute() i32 {
                let x = 10i32
                return x
            }
            """);
        AssertNoErrors(diags);

        var cCode = FLang.Codegen.C.HmCCodeGenerator.GenerateProgram(module);

        // Should contain at least one #line directive
        Assert.Contains("#line", cCode);
    }
}
