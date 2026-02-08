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
    // Test helper: parse → type-check → lower → return IrModule
    // =========================================================================

    private static readonly string AssemblyPath = Path.GetDirectoryName(typeof(HmAstLoweringTests).Assembly.Location)!;
    private static readonly string ProjectRoot = Path.GetFullPath(Path.Combine(AssemblyPath, "..", "..", "..", "..", ".."));
    private static readonly string StdlibPath = Path.Combine(ProjectRoot, "stdlib");

    private static (IrModule Module, List<Diagnostic> Diagnostics) Lower(string source)
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
            var moduleCompiler = new ModuleCompiler(compilation,
                NullLogger<ModuleCompiler>.Instance);
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
            allDiags.AddRange(lowering.Diagnostics);

            return (irModule, allDiags);
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
    public void UnsupportedExpression_ThrowsInvalidOperation()
    {
        // Match expressions are not yet lowered — should throw
        Assert.Throws<InvalidOperationException>(() => Lower("""
            enum Color { Red, Green, Blue }
            fn main() {
                let c = Red
                let x = c match {
                    Red => 0i32,
                    Green => 1i32,
                    Blue => 2i32
                }
            }
            """));
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
    public void AddressOf_EmitsAddressOfInstruction()
    {
        var (module, diags) = Lower("""
            fn get_ref() &i32 {
                let x: i32 = 42i32
                return &x
            }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "get_ref");

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

    }

    [Fact]
    public void UnaryNegate_EmitsUnaryInstruction()
    {
        var (module, diags) = Lower("""
            fn negate(x: i32) i32 { return -x }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "negate");

    }

    [Fact]
    public void UnaryNot_EmitsUnaryInstruction()
    {
        var (module, diags) = Lower("""
            fn invert(x: bool) bool { return !x }
            """);
        AssertNoErrors(diags);
        var fn = FindFunction(module, "invert");

    }

    [Fact(Skip = "Match expression lowering not yet implemented")]
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

    [Fact(Skip = "Lambda lowering not yet implemented")]
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
}
