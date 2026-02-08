using FLang.Core;
using FLang.Core.Types;
using FLang.Semantics;
using ArrayType = FLang.Core.Types.ArrayType;
using FunctionType = FLang.Core.Types.FunctionType;
using NominalType = FLang.Core.Types.NominalType;
using PrimitiveType = FLang.Core.Types.PrimitiveType;
using ReferenceType = FLang.Core.Types.ReferenceType;
using Type = FLang.Core.Types.Type;
using TypeVar = FLang.Core.Types.TypeVar;

namespace FLang.Tests;

public class InferenceEngineTests
{
    private static InferenceEngine CreateEngine()
    {
        var engine = new InferenceEngine();
        engine.AddCoercionRule(new IntegerWideningCoercionRule(true));
        engine.AddCoercionRule(new OptionWrappingCoercionRule());
        engine.AddCoercionRule(new StringToByteSliceCoercionRule());
        engine.AddCoercionRule(new ArrayDecayCoercionRule());
        engine.AddCoercionRule(new SliceToReferenceCoercionRule());
        return engine;
    }

    private static InferenceEngine CreateBareEngine() => new();

    // =========================================================================
    // Unify — Primitives
    // =========================================================================

    [Fact]
    public void Unify_IdenticalPrimitives_ZeroCost()
    {
        var engine = CreateBareEngine();
        var result = engine.Unify(WellKnown.I32, WellKnown.I32, SourceSpan.None);
        Assert.Equal(WellKnown.I32, result.Type);
        Assert.Equal(0, result.Cost);
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_DifferentPrimitives_NoCoercion_Fails()
    {
        var engine = CreateBareEngine();
        engine.Unify(WellKnown.Bool, WellKnown.Char, SourceSpan.None);
        Assert.Single(engine.Diagnostics);
        Assert.Contains("Bool", engine.Diagnostics[0].Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Unify_VoidWithVoid()
    {
        var engine = CreateBareEngine();
        var result = engine.Unify(WellKnown.Void, WellKnown.Void, SourceSpan.None);
        Assert.Equal(WellKnown.Void, result.Type);
        Assert.Empty(engine.Diagnostics);
    }

    // =========================================================================
    // Unify — TypeVar binding
    // =========================================================================

    [Fact]
    public void Unify_TypeVar_WithConcrete_BindsAndResolves()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        var result = engine.Unify(v, WellKnown.I32, SourceSpan.None);
        Assert.Equal(WellKnown.I32, result.Type);
        Assert.Equal(WellKnown.I32, engine.Resolve(v));
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_Concrete_WithTypeVar_BindsAndResolves()
    {
        // Reversed argument order — concrete on left, var on right
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        var result = engine.Unify(WellKnown.Bool, v, SourceSpan.None);
        Assert.Equal(WellKnown.Bool, result.Type);
        Assert.Equal(WellKnown.Bool, engine.Resolve(v));
    }

    [Fact]
    public void Unify_TwoTypeVars_LinkedThenResolved()
    {
        var engine = CreateBareEngine();
        var a = engine.FreshVar();
        var b = engine.FreshVar();
        engine.Unify(a, b, SourceSpan.None);
        engine.Unify(a, WellKnown.Bool, SourceSpan.None);
        Assert.Equal(WellKnown.Bool, engine.Resolve(a));
        Assert.Equal(WellKnown.Bool, engine.Resolve(b));
    }

    [Fact]
    public void Unify_ThreeTypeVars_ChainResolution()
    {
        var engine = CreateBareEngine();
        var a = engine.FreshVar();
        var b = engine.FreshVar();
        var c = engine.FreshVar();
        engine.Unify(a, b, SourceSpan.None);
        engine.Unify(b, c, SourceSpan.None);
        engine.Unify(c, WellKnown.U64, SourceSpan.None);
        Assert.Equal(WellKnown.U64, engine.Resolve(a));
        Assert.Equal(WellKnown.U64, engine.Resolve(b));
        Assert.Equal(WellKnown.U64, engine.Resolve(c));
    }

    [Fact]
    public void Unify_TypeVar_BoundTwice_ToSameType_Succeeds()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        engine.Unify(v, WellKnown.I32, SourceSpan.None);
        engine.Unify(v, WellKnown.I32, SourceSpan.None);
        Assert.Equal(WellKnown.I32, engine.Resolve(v));
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_TypeVar_BoundTwice_ToDifferentTypes_Fails()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        engine.Unify(v, WellKnown.I32, SourceSpan.None);
        engine.Unify(v, WellKnown.Bool, SourceSpan.None);
        Assert.NotEmpty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_TypeVar_WithItself_Succeeds()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        var result = engine.Unify(v, v, SourceSpan.None);
        Assert.Empty(engine.Diagnostics);
    }

    // =========================================================================
    // Unify — Occurs check
    // =========================================================================

    [Fact]
    public void Unify_OccursCheck_DirectCycle()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        var fn = new FunctionType([v], WellKnown.I32);
        engine.Unify(v, fn, SourceSpan.None);
        Assert.Single(engine.Diagnostics);
        Assert.Contains("Cyclic", engine.Diagnostics[0].Message);
    }

    [Fact]
    public void Unify_OccursCheck_NestedCycle()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        // v = &[v; 5] — cyclic through reference and array
        var arr = new ArrayType(v, 5);
        var refArr = new ReferenceType(arr);
        engine.Unify(v, refArr, SourceSpan.None);
        Assert.Single(engine.Diagnostics);
        Assert.Contains("Cyclic", engine.Diagnostics[0].Message);
    }

    [Fact]
    public void Unify_OccursCheck_InNominalTypeArg()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        var s = new NominalType("List", NominalKind.Struct, [v]);
        engine.Unify(v, s, SourceSpan.None);
        Assert.Single(engine.Diagnostics);
    }


    // =========================================================================
    // Unify — FunctionType structural
    // =========================================================================

    [Fact]
    public void Unify_FunctionTypes_SameShape()
    {
        var engine = CreateBareEngine();
        var fn1 = new FunctionType([WellKnown.I32, WellKnown.Bool], WellKnown.Void);
        var fn2 = new FunctionType([WellKnown.I32, WellKnown.Bool], WellKnown.Void);
        var result = engine.Unify(fn1, fn2, SourceSpan.None);
        Assert.Equal(fn1, result.Type);
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_FunctionTypes_WithTypeVars()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        var fn1 = new FunctionType([WellKnown.I32], v);
        var fn2 = new FunctionType([WellKnown.I32], WellKnown.Bool);
        engine.Unify(fn1, fn2, SourceSpan.None);
        Assert.Equal(WellKnown.Bool, engine.Resolve(v));
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_FunctionTypes_ParamCountMismatch()
    {
        var engine = CreateBareEngine();
        var fn1 = new FunctionType([WellKnown.I32], WellKnown.Void);
        var fn2 = new FunctionType([WellKnown.I32, WellKnown.Bool], WellKnown.Void);
        engine.Unify(fn1, fn2, SourceSpan.None);
        Assert.Single(engine.Diagnostics);
        Assert.Contains("parameter count", engine.Diagnostics[0].Message);
    }

    [Fact]
    public void Unify_FunctionTypes_ParamTypeMismatch()
    {
        var engine = CreateBareEngine();
        var fn1 = new FunctionType([WellKnown.I32], WellKnown.Void);
        var fn2 = new FunctionType([WellKnown.Bool], WellKnown.Void);
        engine.Unify(fn1, fn2, SourceSpan.None);
        Assert.NotEmpty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_FunctionTypes_ReturnTypeMismatch()
    {
        var engine = CreateBareEngine();
        var fn1 = new FunctionType([WellKnown.I32], WellKnown.Bool);
        var fn2 = new FunctionType([WellKnown.I32], WellKnown.Char);
        engine.Unify(fn1, fn2, SourceSpan.None);
        Assert.NotEmpty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_FunctionTypes_ZeroParams()
    {
        var engine = CreateBareEngine();
        var fn1 = new FunctionType([], WellKnown.I32);
        var fn2 = new FunctionType([], WellKnown.I32);
        var result = engine.Unify(fn1, fn2, SourceSpan.None);
        Assert.Equal(fn1, result.Type);
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_FunctionType_WithNonFunction_Fails()
    {
        var engine = CreateBareEngine();
        var fn = new FunctionType([WellKnown.I32], WellKnown.Bool);
        engine.Unify(fn, WellKnown.I32, SourceSpan.None);
        Assert.NotEmpty(engine.Diagnostics);
    }

    // =========================================================================
    // Unify — ReferenceType structural
    // =========================================================================

    [Fact]
    public void Unify_ReferenceTypes_SameInner()
    {
        var engine = CreateBareEngine();
        var r1 = new ReferenceType(WellKnown.I32);
        var r2 = new ReferenceType(WellKnown.I32);
        var result = engine.Unify(r1, r2, SourceSpan.None);
        Assert.Equal(r1, result.Type);
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_ReferenceTypes_WithTypeVar()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        var r1 = new ReferenceType(v);
        var r2 = new ReferenceType(WellKnown.Bool);
        engine.Unify(r1, r2, SourceSpan.None);
        Assert.Equal(WellKnown.Bool, engine.Resolve(v));
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_ReferenceTypes_DifferentInner_Fails()
    {
        var engine = CreateBareEngine();
        var r1 = new ReferenceType(WellKnown.I32);
        var r2 = new ReferenceType(WellKnown.Bool);
        engine.Unify(r1, r2, SourceSpan.None);
        Assert.NotEmpty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_ReferenceType_WithNonReference_Fails()
    {
        var engine = CreateBareEngine();
        var r = new ReferenceType(WellKnown.I32);
        engine.Unify(r, WellKnown.I32, SourceSpan.None);
        Assert.NotEmpty(engine.Diagnostics);
    }

    // =========================================================================
    // Unify — ArrayType structural
    // =========================================================================

    [Fact]
    public void Unify_ArrayTypes_SameShape()
    {
        var engine = CreateBareEngine();
        var a1 = new ArrayType(WellKnown.U8, 10);
        var a2 = new ArrayType(WellKnown.U8, 10);
        var result = engine.Unify(a1, a2, SourceSpan.None);
        Assert.Equal(a1, result.Type);
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_ArrayTypes_WithTypeVar()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        var a1 = new ArrayType(v, 3);
        var a2 = new ArrayType(WellKnown.Char, 3);
        engine.Unify(a1, a2, SourceSpan.None);
        Assert.Equal(WellKnown.Char, engine.Resolve(v));
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_ArrayTypes_LengthMismatch()
    {
        var engine = CreateBareEngine();
        var a1 = new ArrayType(WellKnown.I32, 5);
        var a2 = new ArrayType(WellKnown.I32, 10);
        engine.Unify(a1, a2, SourceSpan.None);
        Assert.Single(engine.Diagnostics);
        Assert.Contains("length", engine.Diagnostics[0].Message);
    }

    [Fact]
    public void Unify_ArrayTypes_ElementMismatch()
    {
        var engine = CreateBareEngine();
        var a1 = new ArrayType(WellKnown.I32, 5);
        var a2 = new ArrayType(WellKnown.Bool, 5);
        engine.Unify(a1, a2, SourceSpan.None);
        Assert.NotEmpty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_ArrayType_WithNonArray_Fails()
    {
        var engine = CreateBareEngine();
        var a = new ArrayType(WellKnown.I32, 5);
        engine.Unify(a, WellKnown.I32, SourceSpan.None);
        Assert.NotEmpty(engine.Diagnostics);
    }

    // =========================================================================
    // Unify — NominalType structural
    // =========================================================================

    [Fact]
    public void Unify_NominalTypes_SameName_NoArgs()
    {
        var engine = CreateBareEngine();
        var s1 = new NominalType("Point", NominalKind.Struct);
        var s2 = new NominalType("Point", NominalKind.Struct);
        var result = engine.Unify(s1, s2, SourceSpan.None);
        Assert.Equal(s1, result.Type);
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_NominalTypes_SameName_WithTypeArgs()
    {
        var engine = CreateBareEngine();
        var s1 = new NominalType("List", NominalKind.Struct, [WellKnown.I32]);
        var s2 = new NominalType("List", NominalKind.Struct, [WellKnown.I32]);
        var result = engine.Unify(s1, s2, SourceSpan.None);
        Assert.Equal(s1, result.Type);
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_NominalTypes_SameName_TypeArgVarResolved()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        var s1 = new NominalType("Option", NominalKind.Struct, [v]);
        var s2 = new NominalType("Option", NominalKind.Struct, [WellKnown.Bool]);
        engine.Unify(s1, s2, SourceSpan.None);
        Assert.Equal(WellKnown.Bool, engine.Resolve(v));
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_NominalTypes_DifferentNames_NoCoercion_Fails()
    {
        var engine = CreateBareEngine();
        var s1 = new NominalType("Point", NominalKind.Struct);
        var s2 = new NominalType("Vec2", NominalKind.Struct);
        engine.Unify(s1, s2, SourceSpan.None);
        Assert.NotEmpty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_NominalTypes_SameName_ArityMismatch()
    {
        var engine = CreateBareEngine();
        var s1 = new NominalType("Dict", NominalKind.Struct, [WellKnown.I32]);
        var s2 = new NominalType("Dict", NominalKind.Struct, [WellKnown.I32, WellKnown.Bool]);
        engine.Unify(s1, s2, SourceSpan.None);
        Assert.Single(engine.Diagnostics);
        Assert.Contains("arity", engine.Diagnostics[0].Message);
    }

    [Fact]
    public void Unify_NominalTypes_SameName_TypeArgMismatch()
    {
        var engine = CreateBareEngine();
        var s1 = new NominalType("List", NominalKind.Struct, [WellKnown.I32]);
        var s2 = new NominalType("List", NominalKind.Struct, [WellKnown.Bool]);
        engine.Unify(s1, s2, SourceSpan.None);
        Assert.NotEmpty(engine.Diagnostics);
    }

    // (Enum-specific structural tests removed — NominalType is unified, tests above cover both)

    // =========================================================================
    // Unify — Nested / complex types
    // =========================================================================

    [Fact]
    public void Unify_NestedTypeVars_InFunction()
    {
        // fn(&?a, [?b; 3]) -> Option[?a]  unified with  fn(&i32, [bool; 3]) -> Option[i32]
        var engine = CreateBareEngine();
        var a = engine.FreshVar();
        var b = engine.FreshVar();
        var fn1 = new FunctionType(
            [new ReferenceType(a), new ArrayType(b, 3)],
            new NominalType("Option", NominalKind.Struct, [a]));
        var fn2 = new FunctionType(
            [new ReferenceType(WellKnown.I32), new ArrayType(WellKnown.Bool, 3)],
            new NominalType("Option", NominalKind.Struct, [WellKnown.I32]));

        engine.Unify(fn1, fn2, SourceSpan.None);
        Assert.Equal(WellKnown.I32, engine.Resolve(a));
        Assert.Equal(WellKnown.Bool, engine.Resolve(b));
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_DeepNestedReference()
    {
        // &&i32 unified with &&i32
        var engine = CreateBareEngine();
        var r1 = new ReferenceType(new ReferenceType(WellKnown.I32));
        var r2 = new ReferenceType(new ReferenceType(WellKnown.I32));
        var result = engine.Unify(r1, r2, SourceSpan.None);
        Assert.Equal(r1, result.Type);
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_NominalWithNestedVar()
    {
        // List[Option[?a]] unified with List[Option[i32]]
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        var s1 = new NominalType("List", NominalKind.Struct, [new NominalType("Option", NominalKind.Struct, [v])]);
        var s2 = new NominalType("List", NominalKind.Struct, [new NominalType("Option", NominalKind.Struct, [WellKnown.I32])]);
        engine.Unify(s1, s2, SourceSpan.None);
        Assert.Equal(WellKnown.I32, engine.Resolve(v));
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_FunctionReturningFunction()
    {
        // fn(i32) fn(bool) char  unified with  fn(i32) fn(bool) ?a
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        var fn1 = new FunctionType([WellKnown.I32], new FunctionType([WellKnown.Bool], WellKnown.Char));
        var fn2 = new FunctionType([WellKnown.I32], new FunctionType([WellKnown.Bool], v));
        engine.Unify(fn1, fn2, SourceSpan.None);
        Assert.Equal(WellKnown.Char, engine.Resolve(v));
        Assert.Empty(engine.Diagnostics);
    }

    // =========================================================================
    // Unify — Cross-type mismatches
    // =========================================================================

    [Fact]
    public void Unify_FunctionWithNominal_Fails()
    {
        var engine = CreateBareEngine();
        var fn = new FunctionType([WellKnown.I32], WellKnown.Bool);
        var s = new NominalType("Foo", NominalKind.Struct);
        engine.Unify(fn, s, SourceSpan.None);
        Assert.NotEmpty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_ArrayWithReference_Fails()
    {
        var engine = CreateBareEngine();
        var a = new ArrayType(WellKnown.I32, 5);
        var r = new ReferenceType(WellKnown.I32);
        engine.Unify(a, r, SourceSpan.None);
        Assert.NotEmpty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_NominalTypes_SameName_Succeeds()
    {
        // With unified NominalType, same name = same type regardless of struct/enum origin
        var engine = CreateBareEngine();
        var s = new NominalType("Foo", NominalKind.Struct);
        var e = new NominalType("Foo", NominalKind.Struct);
        var result = engine.Unify(s, e, SourceSpan.None);
        Assert.Equal(s, result.Type);
        Assert.Empty(engine.Diagnostics);
    }

    // =========================================================================
    // Coercion — Integer widening (detailed)
    // =========================================================================

    [Theory]
    [InlineData("i8", "i16")]
    [InlineData("i8", "i32")]
    [InlineData("i8", "i64")]
    [InlineData("i8", "isize")]
    [InlineData("i16", "i32")]
    [InlineData("i16", "i64")]
    [InlineData("i32", "i64")]
    [InlineData("i32", "isize")]
    [InlineData("u8", "u16")]
    [InlineData("u8", "u32")]
    [InlineData("u8", "u64")]
    [InlineData("u8", "usize")]
    [InlineData("u16", "u32")]
    [InlineData("u32", "u64")]
    public void Unify_IntegerWidening_Succeeds(string from, string to)
    {
        var engine = CreateEngine();
        var fromType = new PrimitiveType(from);
        var toType = new PrimitiveType(to);
        var result = engine.Unify(fromType, toType, SourceSpan.None);
        Assert.Equal(toType, result.Type);
        Assert.Equal(1, result.Cost);
        Assert.Empty(engine.Diagnostics);
    }

    [Theory]
    [InlineData("u8", "i16")]
    [InlineData("u8", "i32")]
    [InlineData("u16", "i32")]
    [InlineData("u16", "i64")]
    [InlineData("u32", "i64")]
    public void Unify_CrossSignednessWidening_Succeeds(string from, string to)
    {
        var engine = CreateEngine();
        var fromType = new PrimitiveType(from);
        var toType = new PrimitiveType(to);
        var result = engine.Unify(fromType, toType, SourceSpan.None);
        Assert.Equal(toType, result.Type);
        Assert.Equal(1, result.Cost);
        Assert.Empty(engine.Diagnostics);
    }

    [Theory]
    [InlineData("u32", "i32")]  // same rank — not strictly higher
    [InlineData("u64", "i64")]  // same rank
    [InlineData("i32", "u32")]  // signed→unsigned not supported
    public void Unify_CrossSignedness_InvalidCases_Fails(string from, string to)
    {
        var engine = CreateEngine();
        var fromType = new PrimitiveType(from);
        var toType = new PrimitiveType(to);
        engine.Unify(fromType, toType, SourceSpan.None);
        Assert.NotEmpty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_BoolToInteger()
    {
        var engine = CreateEngine();
        var result = engine.Unify(WellKnown.Bool, WellKnown.I32, SourceSpan.None);
        Assert.Equal(WellKnown.I32, result.Type);
        Assert.Equal(1, result.Cost);
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_IntegerWidening_BothDirections()
    {
        // Coercion rules try both a→b and b→a
        var engine = CreateEngine();
        var result = engine.Unify(WellKnown.I32, WellKnown.I8, SourceSpan.None);
        // i8 → i32 should work (reversed direction)
        Assert.Equal(WellKnown.I32, result.Type);
        Assert.Equal(1, result.Cost);
        Assert.Empty(engine.Diagnostics);
    }

    // =========================================================================
    // Coercion — Option wrapping
    // =========================================================================

    [Fact]
    public void Unify_OptionWrapping_ValueToOption()
    {
        var engine = CreateEngine();
        var optI32 = new NominalType(WellKnown.Option, NominalKind.Struct, [WellKnown.I32]);
        var result = engine.Unify(WellKnown.I32, optI32, SourceSpan.None);
        Assert.Equal(optI32, result.Type);
        Assert.Equal(1, result.Cost);
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_OptionWrapping_WrongInnerType_Fails()
    {
        var engine = CreateEngine();
        var optBool = new NominalType(WellKnown.Option, NominalKind.Struct, [WellKnown.Bool]);
        engine.Unify(WellKnown.I32, optBool, SourceSpan.None);
        Assert.NotEmpty(engine.Diagnostics);
    }

    // =========================================================================
    // Coercion — String to byte slice
    // =========================================================================

    [Fact]
    public void Unify_StringToByteSlice()
    {
        var engine = CreateEngine();
        var str = new NominalType(WellKnown.String, NominalKind.Struct);
        var slice = new NominalType(WellKnown.Slice, NominalKind.Struct, [WellKnown.U8]);
        var result = engine.Unify(str, slice, SourceSpan.None);
        Assert.Equal(slice, result.Type);
        Assert.Equal(1, result.Cost);
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_StringToNonByteSlice_Fails()
    {
        var engine = CreateEngine();
        var str = new NominalType(WellKnown.String, NominalKind.Struct);
        var slice = new NominalType(WellKnown.Slice, NominalKind.Struct, [WellKnown.I32]);
        engine.Unify(str, slice, SourceSpan.None);
        Assert.NotEmpty(engine.Diagnostics);
    }

    // =========================================================================
    // Coercion — Array decay
    // =========================================================================

    [Fact]
    public void Unify_ArrayToSlice()
    {
        var engine = CreateEngine();
        var arr = new ArrayType(WellKnown.I32, 5);
        var slice = new NominalType(WellKnown.Slice, NominalKind.Struct, [WellKnown.I32]);
        var result = engine.Unify(arr, slice, SourceSpan.None);
        Assert.Equal(slice, result.Type);
        Assert.Equal(1, result.Cost);
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_RefArrayToSlice()
    {
        var engine = CreateEngine();
        var refArr = new ReferenceType(new ArrayType(WellKnown.U8, 10));
        var slice = new NominalType(WellKnown.Slice, NominalKind.Struct, [WellKnown.U8]);
        var result = engine.Unify(refArr, slice, SourceSpan.None);
        Assert.Equal(slice, result.Type);
        Assert.Equal(1, result.Cost);
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_ArrayToReference()
    {
        var engine = CreateEngine();
        var arr = new ArrayType(WellKnown.I32, 5);
        var refT = new ReferenceType(WellKnown.I32);
        var result = engine.Unify(arr, refT, SourceSpan.None);
        Assert.Equal(refT, result.Type);
        Assert.Equal(1, result.Cost);
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_ArrayToSlice_ElementMismatch_Fails()
    {
        var engine = CreateEngine();
        var arr = new ArrayType(WellKnown.I32, 5);
        var slice = new NominalType(WellKnown.Slice, NominalKind.Struct, [WellKnown.Bool]);
        engine.Unify(arr, slice, SourceSpan.None);
        Assert.NotEmpty(engine.Diagnostics);
    }

    // =========================================================================
    // Coercion — Slice to reference
    // =========================================================================

    [Fact]
    public void Unify_SliceToReference()
    {
        var engine = CreateEngine();
        var slice = new NominalType(WellKnown.Slice, NominalKind.Struct, [WellKnown.U8]);
        var refT = new ReferenceType(WellKnown.U8);
        var result = engine.Unify(slice, refT, SourceSpan.None);
        Assert.Equal(refT, result.Type);
        Assert.Equal(1, result.Cost);
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void Unify_SliceToReference_ElementMismatch_Fails()
    {
        var engine = CreateEngine();
        var slice = new NominalType(WellKnown.Slice, NominalKind.Struct, [WellKnown.U8]);
        var refT = new ReferenceType(WellKnown.I32);
        engine.Unify(slice, refT, SourceSpan.None);
        Assert.NotEmpty(engine.Diagnostics);
    }

    // =========================================================================
    // Coercion — Cost accumulation
    // =========================================================================

    [Fact]
    public void Unify_MultipleCoercions_CostAccumulates()
    {
        // fn(i8) -> i8  unified with  fn(i32) -> i32
        // Two widening coercions (param + return) = cost 2
        var engine = CreateEngine();
        var fn1 = new FunctionType([WellKnown.I8], WellKnown.I8);
        var fn2 = new FunctionType([WellKnown.I32], WellKnown.I32);
        var result = engine.Unify(fn1, fn2, SourceSpan.None);
        Assert.Equal(2, result.Cost);
        Assert.Empty(engine.Diagnostics);
    }

    // =========================================================================
    // Coercion — TypeVar + coercion interaction
    // =========================================================================

    [Fact]
    public void Unify_TypeVar_ThenCoercion()
    {
        // Bind ?a to i8, then unify ?a with i32 — should widen
        var engine = CreateEngine();
        var v = engine.FreshVar();
        engine.Unify(v, WellKnown.I8, SourceSpan.None);
        var result = engine.Unify(v, WellKnown.I32, SourceSpan.None);
        Assert.Equal(WellKnown.I32, result.Type);
        Assert.Equal(1, result.Cost);
        Assert.Empty(engine.Diagnostics);
    }

    // =========================================================================
    // TryUnify — speculative rollback
    // =========================================================================

    [Fact]
    public void TryUnify_Success_ReturnsResultWithCost()
    {
        var engine = CreateEngine();
        var result = engine.TryUnify(WellKnown.I8, WellKnown.I32);
        Assert.NotNull(result);
        Assert.Equal(WellKnown.I32, result.Value.Type);
        Assert.Equal(1, result.Value.Cost);
    }

    [Fact]
    public void TryUnify_Failure_ReturnsNull_NoDiagnostics()
    {
        var engine = CreateBareEngine();
        var result = engine.TryUnify(WellKnown.Bool, WellKnown.Char);
        Assert.Null(result);
        Assert.Empty(engine.Diagnostics);
    }

    [Fact]
    public void TryUnify_DoesNotLeakTypeVarBindings()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        engine.TryUnify(v, WellKnown.I32);
        // v should still be unbound
        Assert.IsType<TypeVar>(engine.Resolve(v));
    }

    [Fact]
    public void TryUnify_MultipleCandidates_PicksLowestCost()
    {
        // Simulate overload resolution: pick the candidate with lowest cost
        var engine = CreateEngine();
        var argType = WellKnown.I8;

        // Candidate 1: fn(i32) -> void  (cost 1: i8 → i32)
        var cand1 = new FunctionType([WellKnown.I32], WellKnown.Void);
        // Candidate 2: fn(i64) -> void  (cost 1: i8 → i64)
        var cand2 = new FunctionType([WellKnown.I64], WellKnown.Void);
        // Candidate 3: fn(i8) -> void  (cost 0: exact match)
        var cand3 = new FunctionType([WellKnown.I8], WellKnown.Void);

        var results = new List<(int Index, UnifyResult Result)>();
        foreach (var (i, cand) in new[] { cand1, cand2, cand3 }.Select((c, i) => (i, c)))
        {
            var r = engine.TryUnify(argType, cand.ParameterTypes[0]);
            if (r != null)
                results.Add((i, r.Value));
        }

        Assert.Equal(3, results.Count);
        var best = results.MinBy(r => r.Result.Cost);
        Assert.Equal(2, best.Index); // candidate 3 (index 2) is exact match
        Assert.Equal(0, best.Result.Cost);
    }

    [Fact]
    public void TryUnify_FailedCandidate_DoesNotBlockNextCandidate()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();

        // Try to unify v with fn(i32) -> bool — fails because v is not a function
        // Actually v is a typevar, so this would succeed by binding v
        // Use a concrete type instead
        var result1 = engine.TryUnify(WellKnown.I32, WellKnown.Bool);
        Assert.Null(result1); // fails

        // Next candidate should still work
        var result2 = engine.TryUnify(WellKnown.I32, WellKnown.I32);
        Assert.NotNull(result2);
        Assert.Equal(0, result2.Value.Cost);
    }

    // =========================================================================
    // Resolve
    // =========================================================================

    [Fact]
    public void Resolve_UnboundVar_ReturnsSelf()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        var resolved = engine.Resolve(v);
        Assert.Same(v, resolved);
    }

    [Fact]
    public void Resolve_BoundVar_ReturnsConcrete()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        engine.Unify(v, WellKnown.I32, SourceSpan.None);
        Assert.Equal(WellKnown.I32, engine.Resolve(v));
    }

    [Fact]
    public void Resolve_DeepStructure()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        engine.Unify(v, WellKnown.Bool, SourceSpan.None);

        var type = new FunctionType(
            [new ReferenceType(v), new NominalType("List", NominalKind.Struct, [v])],
            new ArrayType(v, 3));

        var resolved = engine.Resolve(type);
        var fn = Assert.IsType<FunctionType>(resolved);
        Assert.Equal(new ReferenceType(WellKnown.Bool), fn.ParameterTypes[0]);
        Assert.Equal(new NominalType("List", NominalKind.Struct, [WellKnown.Bool]), fn.ParameterTypes[1]);
        Assert.Equal(new ArrayType(WellKnown.Bool, 3), fn.ReturnType);
    }

    [Fact]
    public void Resolve_Primitive_ReturnsSelf()
    {
        var engine = CreateBareEngine();
        Assert.Same(WellKnown.I32, engine.Resolve(WellKnown.I32));
    }

    [Fact]
    public void Resolve_NoChangeNominal_ReturnsSameInstance()
    {
        var engine = CreateBareEngine();
        var s = new NominalType("Point", NominalKind.Struct);
        Assert.Same(s, engine.Resolve(s));
    }

    // =========================================================================
    // Generalize / Specialize
    // =========================================================================

    [Fact]
    public void Generalize_MonomorphicType_IsMonomorphic()
    {
        var engine = CreateBareEngine();
        var scheme = engine.Generalize(WellKnown.I32);
        Assert.True(scheme.IsMonomorphic);
        Assert.Equal(WellKnown.I32, scheme.Body);
    }

    [Fact]
    public void Generalize_VarAtCurrentLevel_NotQuantified()
    {
        var engine = CreateBareEngine();
        // var created at level 0, generalize at level 0 — should NOT quantify
        var v = engine.FreshVar();
        var scheme = engine.Generalize(v);
        Assert.True(scheme.IsMonomorphic);
    }

    [Fact]
    public void Generalize_VarAtDeeperLevel_IsQuantified()
    {
        var engine = CreateBareEngine();
        engine.EnterLevel();
        var v = engine.FreshVar(); // level 1
        engine.ExitLevel();
        var scheme = engine.Generalize(v); // at level 0
        Assert.False(scheme.IsMonomorphic);
        Assert.Contains(v.Id, scheme.QuantifiedVarIds);
    }

    [Fact]
    public void Generalize_MixedLevels_OnlyDeepQuantified()
    {
        var engine = CreateBareEngine();
        var outer = engine.FreshVar(); // level 0
        engine.EnterLevel();
        var inner = engine.FreshVar(); // level 1
        engine.ExitLevel();

        var fnType = new FunctionType([outer], inner);
        var scheme = engine.Generalize(fnType);
        Assert.False(scheme.IsMonomorphic);
        Assert.Contains(inner.Id, scheme.QuantifiedVarIds);
        Assert.DoesNotContain(outer.Id, scheme.QuantifiedVarIds);
    }

    [Fact]
    public void Generalize_BoundVar_ResolvesBeforeGeneralizing()
    {
        var engine = CreateBareEngine();
        engine.EnterLevel();
        var v = engine.FreshVar(); // level 1
        engine.Unify(v, WellKnown.I32, SourceSpan.None);
        engine.ExitLevel();

        var scheme = engine.Generalize(v);
        // v is bound to i32, which is concrete — should be monomorphic
        Assert.True(scheme.IsMonomorphic);
        Assert.Equal(WellKnown.I32, scheme.Body);
    }

    [Fact]
    public void Specialize_MonomorphicScheme_ReturnsSameBody()
    {
        var engine = CreateBareEngine();
        var scheme = new PolymorphicType(WellKnown.I32);
        var result = engine.Specialize(scheme);
        Assert.Equal(WellKnown.I32, result);
    }

    [Fact]
    public void Specialize_PolymorphicScheme_CreatesFreshVars()
    {
        var engine = CreateBareEngine();
        engine.EnterLevel();
        var v = engine.FreshVar();
        var fnType = new FunctionType([v], v);
        engine.ExitLevel();
        var scheme = engine.Generalize(fnType);

        var inst = Assert.IsType<FunctionType>(engine.Specialize(scheme));
        // Param and return should be the same fresh var (not v)
        Assert.IsType<TypeVar>(inst.ParameterTypes[0]);
        Assert.IsType<TypeVar>(inst.ReturnType);
        Assert.NotSame(v, inst.ParameterTypes[0]);
        // Param and return should reference the same var
        Assert.Same(inst.ParameterTypes[0], inst.ReturnType);
    }

    [Fact]
    public void Specialize_MultipleVars()
    {
        var engine = CreateBareEngine();
        engine.EnterLevel();
        var a = engine.FreshVar();
        var b = engine.FreshVar();
        var fnType = new FunctionType([a, b], a);
        engine.ExitLevel();
        var scheme = engine.Generalize(fnType);

        var inst = Assert.IsType<FunctionType>(engine.Specialize(scheme));
        // Two different fresh vars for a and b
        var p0 = Assert.IsType<TypeVar>(inst.ParameterTypes[0]);
        var p1 = Assert.IsType<TypeVar>(inst.ParameterTypes[1]);
        var ret = Assert.IsType<TypeVar>(inst.ReturnType);
        Assert.NotSame(p0, p1);
        Assert.Same(p0, ret); // a maps to the same fresh var in param[0] and return
    }

    [Fact]
    public void Specialize_IndependentInstances()
    {
        var engine = CreateBareEngine();
        engine.EnterLevel();
        var v = engine.FreshVar();
        var fnType = new FunctionType([v], v);
        engine.ExitLevel();
        var scheme = engine.Generalize(fnType);

        var inst1 = Assert.IsType<FunctionType>(engine.Specialize(scheme));
        var inst2 = Assert.IsType<FunctionType>(engine.Specialize(scheme));

        // Bind inst1 to i32
        engine.Unify(inst1.ParameterTypes[0], WellKnown.I32, SourceSpan.None);
        Assert.Equal(WellKnown.I32, engine.Resolve(inst1.ReturnType));

        // inst2 should be unaffected
        Assert.IsType<TypeVar>(engine.Resolve(inst2.ParameterTypes[0]));
    }

    // =========================================================================
    // Zonk
    // =========================================================================

    [Fact]
    public void Zonk_Primitive_Unchanged()
    {
        var engine = CreateBareEngine();
        Assert.Equal(WellKnown.I32, engine.Zonk(WellKnown.I32));
    }

    [Fact]
    public void Zonk_BoundVar_Resolved()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        engine.Unify(v, WellKnown.Bool, SourceSpan.None);
        Assert.Equal(WellKnown.Bool, engine.Zonk(v));
    }

    [Fact]
    public void Zonk_UnboundVar_ReportsError()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        var result = engine.Zonk(v);
        Assert.IsType<TypeVar>(result);
        Assert.Single(engine.Diagnostics);
        Assert.Contains("Could not infer", engine.Diagnostics[0].Message);
    }

    [Fact]
    public void Zonk_FunctionType_ResolvesAll()
    {
        var engine = CreateBareEngine();
        var a = engine.FreshVar();
        var b = engine.FreshVar();
        engine.Unify(a, WellKnown.I32, SourceSpan.None);
        engine.Unify(b, WellKnown.Bool, SourceSpan.None);
        var fn = new FunctionType([a], b);
        var zonked = Assert.IsType<FunctionType>(engine.Zonk(fn));
        Assert.Equal(WellKnown.I32, zonked.ParameterTypes[0]);
        Assert.Equal(WellKnown.Bool, zonked.ReturnType);
    }

    [Fact]
    public void Zonk_ReferenceType()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        engine.Unify(v, WellKnown.Char, SourceSpan.None);
        var zonked = engine.Zonk(new ReferenceType(v));
        Assert.Equal(new ReferenceType(WellKnown.Char), zonked);
    }

    [Fact]
    public void Zonk_ArrayType()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        engine.Unify(v, WellKnown.U8, SourceSpan.None);
        var zonked = engine.Zonk(new ArrayType(v, 4));
        Assert.Equal(new ArrayType(WellKnown.U8, 4), zonked);
    }

    [Fact]
    public void Zonk_NominalType()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        engine.Unify(v, WellKnown.I64, SourceSpan.None);
        var zonked = engine.Zonk(new NominalType("List", NominalKind.Struct, [v]));
        Assert.Equal(new NominalType("List", NominalKind.Struct, [WellKnown.I64]), zonked);
    }

    [Fact]
    public void Zonk_PolymorphicType()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        engine.Unify(v, WellKnown.I32, SourceSpan.None);
        var poly = new PolymorphicType(new HashSet<int> { 999 }, new FunctionType([v], v));
        var zonked = Assert.IsType<PolymorphicType>(engine.Zonk(poly));
        Assert.Equal(new FunctionType([WellKnown.I32], WellKnown.I32), zonked.Body);
    }

    [Fact]
    public void Zonk_DeepNesting()
    {
        var engine = CreateBareEngine();
        var v = engine.FreshVar();
        engine.Unify(v, WellKnown.U8, SourceSpan.None);

        var type = new FunctionType(
            [new ReferenceType(new NominalType("Slice", NominalKind.Struct, [v]))],
            new ArrayType(v, 2));

        var zonked = Assert.IsType<FunctionType>(engine.Zonk(type));
        Assert.Equal(
            new ReferenceType(new NominalType("Slice", NominalKind.Struct, [WellKnown.U8])),
            zonked.ParameterTypes[0]);
        Assert.Equal(new ArrayType(WellKnown.U8, 2), zonked.ReturnType);
    }

    // =========================================================================
    // Factorial — end-to-end test ported from Inference.cs prototype
    // =========================================================================

    [Fact]
    public void Factorial_EndToEnd()
    {
        var engine = CreateEngine();
        var scopes = new TypeScopes();

        // op_eq: forall a. fn(a, a) bool
        engine.EnterLevel();
        var eqVar = engine.FreshVar();
        var opEqType = new FunctionType([eqVar, eqVar], WellKnown.Bool);
        engine.ExitLevel();
        scopes.Bind("op_eq", engine.Generalize(opEqType));

        // mul, sub: fn(i32, i32) i32
        scopes.Bind("mul", new PolymorphicType(new FunctionType([WellKnown.I32, WellKnown.I32], WellKnown.I32)));
        scopes.Bind("sub", new PolymorphicType(new FunctionType([WellKnown.I32, WellKnown.I32], WellKnown.I32)));

        // let fac = \x -> if (op_eq(x, 0)) then 1 else mul(x, fac(sub(x, 1))) in fac
        engine.EnterLevel();
        var facVar = engine.FreshVar();
        scopes.Bind("fac", new PolymorphicType(facVar));

        scopes.PushScope();
        var xVar = engine.FreshVar();
        scopes.Bind("x", new PolymorphicType(xVar));

        // op_eq(x, 0) → bool
        var opEqInst = Assert.IsType<FunctionType>(engine.Specialize(scopes.Lookup("op_eq")!));
        engine.Unify(opEqInst.ParameterTypes[0], engine.Resolve(xVar), SourceSpan.None);
        engine.Unify(opEqInst.ParameterTypes[1], WellKnown.I32, SourceSpan.None);
        engine.Unify(engine.Resolve(opEqInst.ReturnType), WellKnown.Bool, SourceSpan.None);

        var thenType = WellKnown.I32;

        // sub(x, 1)
        var subInst = Assert.IsType<FunctionType>(engine.Specialize(scopes.Lookup("sub")!));
        engine.Unify(subInst.ParameterTypes[0], engine.Resolve(xVar), SourceSpan.None);
        engine.Unify(subInst.ParameterTypes[1], WellKnown.I32, SourceSpan.None);

        // fac(sub(x, 1))
        var facInst = engine.Specialize(scopes.Lookup("fac")!);
        var facCallResult = engine.FreshVar();
        engine.Unify(facInst, new FunctionType([engine.Resolve(subInst.ReturnType)], facCallResult), SourceSpan.None);

        // mul(x, fac(...))
        var mulInst = Assert.IsType<FunctionType>(engine.Specialize(scopes.Lookup("mul")!));
        engine.Unify(mulInst.ParameterTypes[0], engine.Resolve(xVar), SourceSpan.None);
        engine.Unify(mulInst.ParameterTypes[1], engine.Resolve(facCallResult), SourceSpan.None);
        var elseType = engine.Resolve(mulInst.ReturnType);

        // Unify branches
        var resultVar = engine.FreshVar();
        engine.Unify(resultVar, thenType, SourceSpan.None);
        engine.Unify(resultVar, elseType, SourceSpan.None);

        // Lambda type
        engine.Unify(facVar, new FunctionType([engine.Resolve(xVar)], engine.Resolve(resultVar)), SourceSpan.None);

        scopes.PopScope();
        engine.ExitLevel();

        scopes.Bind("fac", engine.Generalize(engine.Resolve(facVar)));
        var finalType = engine.Specialize(scopes.Lookup("fac")!);
        var zonked = engine.Zonk(finalType);

        Assert.Empty(engine.Diagnostics);
        var fn = Assert.IsType<FunctionType>(zonked);
        Assert.Equal(WellKnown.I32, fn.ParameterTypes[0]);
        Assert.Equal(WellKnown.I32, fn.ReturnType);
    }

    // =========================================================================
    // Identity function — polymorphic end-to-end
    // =========================================================================

    [Fact]
    public void Identity_Polymorphic_UsedAtMultipleTypes()
    {
        var engine = CreateBareEngine();
        var scopes = new TypeScopes();

        // let id = \x -> x
        engine.EnterLevel();
        var x = engine.FreshVar();
        var idType = new FunctionType([x], x);
        engine.ExitLevel();
        scopes.Bind("id", engine.Generalize(idType));

        // id(42) — use at i32
        var inst1 = Assert.IsType<FunctionType>(engine.Specialize(scopes.Lookup("id")!));
        engine.Unify(inst1.ParameterTypes[0], WellKnown.I32, SourceSpan.None);
        Assert.Equal(WellKnown.I32, engine.Resolve(inst1.ReturnType));

        // id(true) — use at bool
        var inst2 = Assert.IsType<FunctionType>(engine.Specialize(scopes.Lookup("id")!));
        engine.Unify(inst2.ParameterTypes[0], WellKnown.Bool, SourceSpan.None);
        Assert.Equal(WellKnown.Bool, engine.Resolve(inst2.ReturnType));

        // First use should still be i32
        Assert.Equal(WellKnown.I32, engine.Resolve(inst1.ReturnType));
        Assert.Empty(engine.Diagnostics);
    }

    // =========================================================================
    // TypeScopes
    // =========================================================================

    [Fact]
    public void TypeScopes_Lookup_InnerShadowsOuter()
    {
        var scopes = new TypeScopes();
        scopes.Bind("x", new PolymorphicType(WellKnown.I32));
        scopes.PushScope();
        scopes.Bind("x", new PolymorphicType(WellKnown.Bool));
        Assert.Equal(WellKnown.Bool, scopes.Lookup("x")!.Body);
        scopes.PopScope();
        Assert.Equal(WellKnown.I32, scopes.Lookup("x")!.Body);
    }

    [Fact]
    public void TypeScopes_Lookup_NotFound_ReturnsNull()
    {
        var scopes = new TypeScopes();
        Assert.Null(scopes.Lookup("nonexistent"));
    }

    [Fact]
    public void TypeScopes_PopGlobalScope_Throws()
    {
        var scopes = new TypeScopes();
        Assert.Throws<InvalidOperationException>(() => scopes.PopScope());
    }
}
