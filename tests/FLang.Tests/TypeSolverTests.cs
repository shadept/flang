using FLang.Core;
using FLang.Semantics;

namespace FLang.Tests;

public class TypeSolverTests
{
    #region Basic Unification Tests

    [Fact]
    public void Unify_IdenticalPrimitives_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var t1 = TypeRegistry.I32;
        var t2 = TypeRegistry.I32;

        // Act
        var result = solver.Unify(t1, t2);

        // Assert
        Assert.Equal(t1, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void Unify_DifferentPrimitives_WithNoCoercion_Fails()
    {
        // Arrange
        var solver = new TypeSolver();
        var t1 = TypeRegistry.I32;
        var t2 = TypeRegistry.Bool;

        // Act
        var result = solver.Unify(t1, t2);

        // Assert
        Assert.Single(solver.Diagnostics);
        Assert.Equal("E2002", solver.Diagnostics[0].Code);
        Assert.Contains("i32", solver.Diagnostics[0].Message);
        Assert.Contains("bool", solver.Diagnostics[0].Message);
    }

    [Fact]
    public void Unify_TypeVarWithConcrete_BindsVariable()
    {
        // Arrange
        var solver = new TypeSolver();
        var typeVar = new TypeVar("x", new Core.SourceSpan(0, 0, 0));
        var concrete = TypeRegistry.I32;

        // Act
        var result = solver.Unify(typeVar, concrete);

        // Assert
        Assert.Equal(concrete, result);
        Assert.Equal(concrete, typeVar.Instance);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void Unify_ConcreteWithTypeVar_BindsVariable()
    {
        // Arrange
        var solver = new TypeSolver();
        var concrete = TypeRegistry.Bool;
        var typeVar = new TypeVar("y", new Core.SourceSpan(0, 0, 0));

        // Act
        var result = solver.Unify(concrete, typeVar);

        // Assert
        Assert.Equal(concrete, result);
        Assert.Equal(concrete, typeVar.Instance);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void Unify_TwoTypeVars_BindsOneToOther()
    {
        // Arrange
        var solver = new TypeSolver();
        var var1 = new TypeVar("a", new Core.SourceSpan(0, 0, 0));
        var var2 = new TypeVar("b", new Core.SourceSpan(0, 0, 0));

        // Act
        var result = solver.Unify(var1, var2);

        // Assert
        Assert.NotNull(result);
        Assert.Empty(solver.Diagnostics);
        // One should be bound to the other
        Assert.True(var1.Instance == var2 || var2.Instance == var1);
    }

    #endregion

    #region Struct Unification Tests

    [Fact]
    public void Unify_IdenticalStructs_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var struct1 = new StructType("Point").WithFields([
            ("x", TypeRegistry.I32),
            ("y", TypeRegistry.I32)
        ]);
        var struct2 = new StructType("Point").WithFields([
            ("x", TypeRegistry.I32),
            ("y", TypeRegistry.I32)
        ]);

        // Act
        var result = solver.Unify(struct1, struct2);

        // Assert
        Assert.Equal(struct1.Name, result.ToString());
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void Unify_DifferentStructNames_Fails()
    {
        // Arrange
        var solver = new TypeSolver();
        var struct1 = new StructType("Point");
        var struct2 = new StructType("Vector");

        // Act
        solver.Unify(struct1, struct2);

        // Assert
        Assert.Single(solver.Diagnostics);
        Assert.Equal("E2002", solver.Diagnostics[0].Code);
        Assert.Contains("expected `Point`, got `Vector`", solver.Diagnostics[0].Message);
    }

    [Fact]
    public void Unify_GenericStructs_WithMatchingTypeArgs_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var struct1 = new StructType("Option", [TypeRegistry.I32]);
        var struct2 = new StructType("Option", [TypeRegistry.I32]);

        // Act
        var result = solver.Unify(struct1, struct2);

        // Assert
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void Unify_GenericStructs_WithDifferentTypeArgs_Fails()
    {
        // Arrange
        var solver = new TypeSolver();
        var struct1 = new StructType("Option", [TypeRegistry.I32]);
        var struct2 = new StructType("Option", [TypeRegistry.Bool]);

        // Act
        solver.Unify(struct1, struct2);

        // Assert
        Assert.NotEmpty(solver.Diagnostics);
        Assert.Contains(solver.Diagnostics, d => d.Code == "E2002");
    }

    #endregion

    #region Comptime Int Hardening Tests

    [Fact]
    public void Unify_ComptimeIntWithI32_HardensToI32()
    {
        // Arrange
        var solver = new TypeSolver();
        var comptimeInt = TypeRegistry.ComptimeInt;
        var i32 = TypeRegistry.I32;

        // Act
        var result = solver.Unify(comptimeInt, i32);

        // Assert
        Assert.Equal(i32, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void Unify_I64WithComptimeInt_HardensToI64()
    {
        // Arrange
        var solver = new TypeSolver();
        var i64 = TypeRegistry.I64;
        var comptimeInt = TypeRegistry.ComptimeInt;

        // Act
        var result = solver.Unify(i64, comptimeInt);

        // Assert
        Assert.Equal(i64, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void Unify_ComptimeIntWithBool_Fails()
    {
        // Arrange
        var solver = new TypeSolver();
        var comptimeInt = TypeRegistry.ComptimeInt;
        var boolean = TypeRegistry.Bool;

        // Act
        solver.Unify(comptimeInt, boolean);

        // Assert
        Assert.NotEmpty(solver.Diagnostics);
    }

    #endregion

    #region IntegerWideningRule Tests

    [Fact]
    public void IntegerWidening_I8ToI16_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var from = TypeRegistry.I8;
        var to = TypeRegistry.I16;

        // Act
        var result = solver.Unify(from, to);

        // Assert
        Assert.Equal(to, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void IntegerWidening_I8ToI32_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var from = TypeRegistry.I8;
        var to = TypeRegistry.I32;

        // Act
        var result = solver.Unify(from, to);

        // Assert
        Assert.Equal(to, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void IntegerWidening_I32ToI64_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var from = TypeRegistry.I32;
        var to = TypeRegistry.I64;

        // Act
        var result = solver.Unify(from, to);

        // Assert
        Assert.Equal(to, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void IntegerWidening_I16ToI8_Fails()
    {
        // Arrange
        var solver = new TypeSolver();
        var from = TypeRegistry.I16;
        var to = TypeRegistry.I8;

        // Act
        solver.Unify(from, to);

        // Assert
        Assert.NotEmpty(solver.Diagnostics);
        Assert.Equal("E2002", solver.Diagnostics[0].Code);
    }

    [Fact]
    public void IntegerWidening_U8ToU16_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var from = TypeRegistry.U8;
        var to = TypeRegistry.U16;

        // Act
        var result = solver.Unify(from, to);

        // Assert
        Assert.Equal(to, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void IntegerWidening_U8ToU64_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var from = TypeRegistry.U8;
        var to = TypeRegistry.U64;

        // Act
        var result = solver.Unify(from, to);

        // Assert
        Assert.Equal(to, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void IntegerWidening_SignedToUnsigned_Fails()
    {
        // Arrange
        var solver = new TypeSolver();
        var from = TypeRegistry.I8;
        var to = TypeRegistry.U8;

        // Act
        solver.Unify(from, to);

        // Assert
        Assert.NotEmpty(solver.Diagnostics);
    }

    [Fact]
    public void IntegerWidening_UnsignedToSigned_Fails()
    {
        // Arrange
        var solver = new TypeSolver();
        var from = TypeRegistry.U8;
        var to = TypeRegistry.I8;

        // Act
        solver.Unify(from, to);

        // Assert
        Assert.NotEmpty(solver.Diagnostics);
    }

    [Fact]
    public void PlatformEquivalence_ISize32EqualsI32()
    {
        // Arrange - 32-bit architecture where isize === i32
        var solver = new TypeSolver(PointerWidth.Bits32);
        var from = TypeRegistry.ISize;
        var to = TypeRegistry.I32;

        // Act
        var result = solver.Unify(from, to);

        // Assert - Platform equivalence (not coercion)
        Assert.Equal(to, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void PlatformEquivalence_ISize64EqualsI64()
    {
        // Arrange - 64-bit architecture where isize === i64
        var solver = new TypeSolver(PointerWidth.Bits64);
        var from = TypeRegistry.ISize;
        var to = TypeRegistry.I64;

        // Act
        var result = solver.Unify(from, to);

        // Assert - Platform equivalence (not coercion)
        Assert.Equal(to, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void PlatformEquivalence_USize32EqualsU32()
    {
        // Arrange - 32-bit architecture where usize === u32
        var solver = new TypeSolver(PointerWidth.Bits32);
        var from = TypeRegistry.USize;
        var to = TypeRegistry.U32;

        // Act
        var result = solver.Unify(from, to);

        // Assert - Platform equivalence (not coercion)
        Assert.Equal(to, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void PlatformEquivalence_USize64EqualsU64()
    {
        // Arrange - 64-bit architecture where usize === u64
        var solver = new TypeSolver(PointerWidth.Bits64);
        var from = TypeRegistry.USize;
        var to = TypeRegistry.U64;

        // Act
        var result = solver.Unify(from, to);

        // Assert - Platform equivalence (not coercion)
        Assert.Equal(to, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void IntegerWidening_I16ToISize64_Succeeds()
    {
        // Arrange - 64-bit architecture where isize=i64 (rank 4)
        var solver = new TypeSolver(PointerWidth.Bits64);
        var from = TypeRegistry.I16;
        var to = TypeRegistry.ISize;

        // Act
        var result = solver.Unify(from, to);

        // Assert - i16 (rank 2) can widen to isize/i64 (rank 4)
        Assert.Equal(to, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void IntegerWidening_U32ToI64_Succeeds()
    {
        // Arrange - unsigned to signed with higher rank is safe
        var solver = new TypeSolver();
        var from = TypeRegistry.U32;
        var to = TypeRegistry.I64;

        // Act
        var result = solver.Unify(from, to);

        // Assert - u32 max (4.2B) fits in i64 max (9.2 quintillion)
        Assert.Equal(to, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void IntegerWidening_U8ToI16_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var from = TypeRegistry.U8;
        var to = TypeRegistry.I16;

        // Act
        var result = solver.Unify(from, to);

        // Assert - u8 max (255) fits in i16 max (32767)
        Assert.Equal(to, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void IntegerWidening_U32ToI32_Fails()
    {
        // Arrange - same rank, value range doesn't fit
        var solver = new TypeSolver();
        var from = TypeRegistry.U32;
        var to = TypeRegistry.I32;

        // Act
        solver.Unify(from, to);

        // Assert - u32 max (4.2B) exceeds i32 max (2.1B)
        Assert.NotEmpty(solver.Diagnostics);
    }

    [Fact]
    public void IntegerWidening_I32ToU32_Fails()
    {
        // Arrange - signed to unsigned not allowed (negative values)
        var solver = new TypeSolver();
        var from = TypeRegistry.I32;
        var to = TypeRegistry.U32;

        // Act
        solver.Unify(from, to);

        // Assert - negative values can't fit in unsigned
        Assert.NotEmpty(solver.Diagnostics);
    }

    #endregion

    #region OptionWrappingRule Tests

    [Fact]
    public void OptionWrapping_I32ToOptionI32_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var innerType = TypeRegistry.I32;
        var from = innerType;
        var to = TypeRegistry.MakeOption(innerType);

        // Act
        var result = solver.Unify(from, to);

        // Assert
        Assert.Equal(to, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void OptionWrapping_BoolToOptionBool_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var innerType = TypeRegistry.Bool;
        var from = innerType;
        var to = TypeRegistry.MakeOption(innerType);

        // Act
        var result = solver.Unify(from, to);

        // Assert
        Assert.Equal(to, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void OptionWrapping_I32ToOptionI64_Fails()
    {
        // Arrange
        var solver = new TypeSolver();
        var from = TypeRegistry.I32;
        var to = TypeRegistry.MakeOption(TypeRegistry.I64);

        // Act
        solver.Unify(from, to);

        // Assert
        Assert.NotEmpty(solver.Diagnostics);
    }

    [Fact]
    public void OptionWrapping_StructToOptionStruct_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var pointType = new StructType("Point").WithFields([
            ("x", TypeRegistry.I32),
            ("y", TypeRegistry.I32)
        ]);
        var from = pointType;
        var to = TypeRegistry.MakeOption(pointType);

        // Act
        var result = solver.Unify(from, to);

        // Assert
        Assert.Equal(to, result);
        Assert.Empty(solver.Diagnostics);
    }

    #endregion

    #region ArrayToSliceRule Tests

    [Fact]
    public void ArrayToSlice_I32Array_ToI32Slice_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var arrayType = new ArrayType(TypeRegistry.I32, 10);
        var sliceType = TypeRegistry.MakeSlice(TypeRegistry.I32);

        // Act
        var result = solver.Unify(arrayType, sliceType);

        // Assert
        Assert.Equal(sliceType, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void ArrayToSlice_BoolArray_ToBoolSlice_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var arrayType = new ArrayType(TypeRegistry.Bool, 5);
        var sliceType = TypeRegistry.MakeSlice(TypeRegistry.Bool);

        // Act
        var result = solver.Unify(arrayType, sliceType);

        // Assert
        Assert.Equal(sliceType, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void ArrayToSlice_I32Array_ToI64Slice_Fails()
    {
        // Arrange
        var solver = new TypeSolver();
        var arrayType = new ArrayType(TypeRegistry.I32, 10);
        var sliceType = TypeRegistry.MakeSlice(TypeRegistry.I64);

        // Act
        solver.Unify(arrayType, sliceType);

        // Assert
        Assert.NotEmpty(solver.Diagnostics);
    }

    [Fact]
    public void ArrayToSlice_RefArray_ToSlice_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var arrayType = new ArrayType(TypeRegistry.U8, 20);
        var refArrayType = new ReferenceType(arrayType, PointerWidth.Bits64);
        var sliceType = TypeRegistry.MakeSlice(TypeRegistry.U8);

        // Act
        var result = solver.Unify(refArrayType, sliceType);

        // Assert
        Assert.Equal(sliceType, result);
        Assert.Empty(solver.Diagnostics);
    }

    #endregion

    #region StringToByteSliceRule Tests

    [Fact]
    public void StringToByteSlice_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var stringType = TypeRegistry.MakeString();
        var byteSliceType = TypeRegistry.MakeSlice(TypeRegistry.U8);

        // Act
        var result = solver.Unify(stringType, byteSliceType);

        // Assert
        Assert.Equal(byteSliceType, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void StringToByteSlice_ToI8Slice_Fails()
    {
        // Arrange
        var solver = new TypeSolver();
        var stringType = TypeRegistry.MakeString();
        var i8SliceType = TypeRegistry.MakeSlice(TypeRegistry.I8);

        // Act
        solver.Unify(stringType, i8SliceType);

        // Assert
        Assert.NotEmpty(solver.Diagnostics);
    }

    [Fact]
    public void StringToByteSlice_ToU16Slice_Fails()
    {
        // Arrange
        var solver = new TypeSolver();
        var stringType = TypeRegistry.MakeString();
        var u16SliceType = TypeRegistry.MakeSlice(TypeRegistry.U16);

        // Act
        solver.Unify(stringType, u16SliceType);

        // Assert
        Assert.NotEmpty(solver.Diagnostics);
    }

    #endregion

    #region Coercion Chain Tests

    [Fact]
    public void CoercionChain_I8CanWiden_ThenWrapInOption()
    {
        // Arrange
        var solver = new TypeSolver();
        var from = TypeRegistry.I8;
        var to = TypeRegistry.MakeOption(TypeRegistry.I64);

        // Act - This should fail because we don't chain coercions
        solver.Unify(from, to);

        // Assert - Currently this should fail (no transitive coercion)
        Assert.NotEmpty(solver.Diagnostics);
    }

    [Fact]
    public void CoercionChain_ExplicitSteps_Succeeds()
    {
        // Arrange
        var solver1 = new TypeSolver();
        var solver2 = new TypeSolver();
        var from = TypeRegistry.I8;
        var intermediate = TypeRegistry.I64;
        var to = TypeRegistry.MakeOption(TypeRegistry.I64);

        // Act - Step 1: widen i8 -> i64
        var step1 = solver1.Unify(from, intermediate);
        // Step 2: wrap i64 -> Option<i64>
        var step2 = solver2.Unify(step1, to);

        // Assert
        Assert.Empty(solver1.Diagnostics);
        Assert.Empty(solver2.Diagnostics);
        Assert.Equal(to, step2);
    }

    #endregion

    #region Error Message Tests

    [Fact]
    public void ErrorMessage_IncludesExpectedAndActualTypes()
    {
        // Arrange
        var solver = new TypeSolver();
        var from = TypeRegistry.I32;
        var to = TypeRegistry.Bool;

        // Act
        solver.Unify(from, to);

        // Assert
        Assert.Single(solver.Diagnostics);
        var diagnostic = solver.Diagnostics[0];
        Assert.Contains("i32", diagnostic.Message);
        Assert.Contains("bool", diagnostic.Message);
    }

    [Fact]
    public void ErrorMessage_SkolemRigidGeneric_HasSpecificCode()
    {
        // Arrange
        var solver = new TypeSolver();
        var skolem = PrimitiveType.CreateSkolem("T");
        var concrete = TypeRegistry.I32;

        // Act
        solver.Unify(skolem, concrete);

        // Assert
        Assert.Single(solver.Diagnostics);
        Assert.Equal("E2002", solver.Diagnostics[0].Code);
        Assert.Contains("rigid generic parameter", solver.Diagnostics[0].Message);
    }

    #endregion

    #region BoolToIntegerRule Tests (IntegerWideningRule extension)

    [Fact]
    public void BoolToInteger_BoolToI32_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var from = TypeRegistry.Bool;
        var to = TypeRegistry.I32;

        // Act
        var result = solver.Unify(from, to);

        // Assert - bool can coerce to any integer
        Assert.Equal(to, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void BoolToInteger_BoolToU8_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var from = TypeRegistry.Bool;
        var to = TypeRegistry.U8;

        // Act
        var result = solver.Unify(from, to);

        // Assert - bool (0 or 1) fits in u8
        Assert.Equal(to, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void BoolToInteger_BoolToI64_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var from = TypeRegistry.Bool;
        var to = TypeRegistry.I64;

        // Act
        var result = solver.Unify(from, to);

        // Assert
        Assert.Equal(to, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void BoolToInteger_BoolToBool_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var from = TypeRegistry.Bool;
        var to = TypeRegistry.Bool;

        // Act
        var result = solver.Unify(from, to);

        // Assert - identity
        Assert.Equal(to, result);
        Assert.Empty(solver.Diagnostics);
    }

    #endregion

    #region ArrayDecayRule Tests

    [Fact]
    public void ArrayDecay_I32ArrayToI32Ref_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var arrayType = new ArrayType(TypeRegistry.I32, 10);
        var refType = new ReferenceType(TypeRegistry.I32);

        // Act
        var result = solver.Unify(arrayType, refType);

        // Assert - [i32; 10] decays to &i32
        Assert.Equal(refType, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void ArrayDecay_U8ArrayToU8Ref_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var arrayType = new ArrayType(TypeRegistry.U8, 5);
        var refType = new ReferenceType(TypeRegistry.U8);

        // Act
        var result = solver.Unify(arrayType, refType);

        // Assert - [u8; 5] decays to &u8 (useful for memset, memcpy)
        Assert.Equal(refType, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void ArrayDecay_RefArrayToRef_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var arrayType = new ArrayType(TypeRegistry.I32, 3);
        var refArrayType = new ReferenceType(arrayType);
        var refElementType = new ReferenceType(TypeRegistry.I32);

        // Act
        var result = solver.Unify(refArrayType, refElementType);

        // Assert - &[i32; 3] decays to &i32
        Assert.Equal(refElementType, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void ArrayDecay_I32ArrayToI64Ref_Fails()
    {
        // Arrange
        var solver = new TypeSolver();
        var arrayType = new ArrayType(TypeRegistry.I32, 10);
        var refType = new ReferenceType(TypeRegistry.I64);

        // Act
        solver.Unify(arrayType, refType);

        // Assert - element type must match
        Assert.NotEmpty(solver.Diagnostics);
    }

    [Fact]
    public void ArrayDecay_SupportsMemcpyPattern()
    {
        // Arrange - Simulates passing array to memcpy(&u8, &u8, usize)
        var solver = new TypeSolver();
        var i32Array = new ArrayType(TypeRegistry.I32, 3);
        var u8Ref = new ReferenceType(TypeRegistry.U8);

        // Act
        solver.Unify(i32Array, u8Ref);

        // Assert - Different element types, should fail
        Assert.NotEmpty(solver.Diagnostics);
    }

    [Fact]
    public void ArrayDecay_SupportsMemsetPattern()
    {
        // Arrange - Simulates passing u8 array to memset(&u8, i32, usize)
        var solver = new TypeSolver();
        var u8Array = new ArrayType(TypeRegistry.U8, 100);
        var u8Ref = new ReferenceType(TypeRegistry.U8);

        // Act
        var result = solver.Unify(u8Array, u8Ref);

        // Assert - [u8; 100] should decay to &u8
        Assert.Equal(u8Ref, result);
        Assert.Empty(solver.Diagnostics);
    }

    #endregion

    #region SliceToReferenceRule Tests

    [Fact]
    public void SliceToRef_I32SliceToI32Ref_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var sliceType = TypeRegistry.MakeSlice(TypeRegistry.I32);
        var refType = new ReferenceType(TypeRegistry.I32);

        // Act
        var result = solver.Unify(sliceType, refType);

        // Assert - Slice<i32> can coerce to &i32 (extracts .ptr field)
        Assert.Equal(refType, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void SliceToRef_U8SliceToU8Ref_Succeeds()
    {
        // Arrange
        var solver = new TypeSolver();
        var sliceType = TypeRegistry.MakeSlice(TypeRegistry.U8);
        var refType = new ReferenceType(TypeRegistry.U8);

        // Act
        var result = solver.Unify(sliceType, refType);

        // Assert - Slice<u8> to &u8 (useful for C interop)
        Assert.Equal(refType, result);
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void SliceToRef_I32SliceToI64Ref_Fails()
    {
        // Arrange
        var solver = new TypeSolver();
        var sliceType = TypeRegistry.MakeSlice(TypeRegistry.I32);
        var refType = new ReferenceType(TypeRegistry.I64);

        // Act
        solver.Unify(sliceType, refType);

        // Assert - element type must match
        Assert.NotEmpty(solver.Diagnostics);
    }

    [Fact]
    public void SliceToRef_StringSliceToU8Ref_SupportsChaining()
    {
        // Arrange - Test that String → Slice<u8> → &u8 could work
        var solver1 = new TypeSolver();
        var solver2 = new TypeSolver();
        var stringType = TypeRegistry.MakeString();
        var byteSliceType = TypeRegistry.MakeSlice(TypeRegistry.U8);
        var u8RefType = new ReferenceType(TypeRegistry.U8);

        // Act - Step 1: String → Slice<u8>
        var step1 = solver1.Unify(stringType, byteSliceType);
        // Step 2: Slice<u8> → &u8
        var step2 = solver2.Unify(step1, u8RefType);

        // Assert
        Assert.Empty(solver1.Diagnostics);
        Assert.Empty(solver2.Diagnostics);
        Assert.Equal(u8RefType, step2);
    }

    #endregion

    #region TypeVar Literal Wrapping Tests

    [Fact]
    public void TypeVar_ComptimeIntLiteral_UnifiesWithI32()
    {
        // Arrange
        var solver = new TypeSolver();
        var literalTypeVar = new TypeVar("lit_42", new SourceSpan(0, 0, 2));
        literalTypeVar.Instance = TypeRegistry.ComptimeInt;
        var concrete = TypeRegistry.I32;

        // Act
        var result = solver.Unify(literalTypeVar, concrete);

        // Assert
        Assert.Equal(concrete, result);
        Assert.Equal(concrete, literalTypeVar.Prune());
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void TypeVar_TwoLiterals_UnifyToComptimeInt()
    {
        // Arrange
        var solver = new TypeSolver();
        var lit1 = new TypeVar("lit_10", new SourceSpan(0, 0, 2));
        lit1.Instance = TypeRegistry.ComptimeInt;
        var lit2 = new TypeVar("lit_20", new SourceSpan(0, 5, 2));
        lit2.Instance = TypeRegistry.ComptimeInt;

        // Act
        var result = solver.Unify(lit1, lit2);

        // Assert
        // Should unify to ComptimeInt (both literals remain flexible)
        Assert.Equal(TypeRegistry.ComptimeInt, result.Prune());
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void TypeVar_LiteralChain_PathCompression()
    {
        // Arrange
        var solver = new TypeSolver();
        var lit1 = new TypeVar("lit_1", new SourceSpan(0, 0, 1));
        lit1.Instance = TypeRegistry.ComptimeInt;
        var lit2 = new TypeVar("lit_2", new SourceSpan(0, 5, 1));
        lit2.Instance = TypeRegistry.ComptimeInt;
        var lit3 = new TypeVar("lit_3", new SourceSpan(0, 10, 1));
        lit3.Instance = TypeRegistry.ComptimeInt;

        // Act - Chain unifications: lit1 <- lit2 <- lit3 <- I64
        solver.Unify(lit1, lit2);
        solver.Unify(lit2, lit3);
        var result = solver.Unify(lit3, TypeRegistry.I64);

        // Assert - All should resolve to I64 via Prune()
        Assert.Equal(TypeRegistry.I64, lit1.Prune());
        Assert.Equal(TypeRegistry.I64, lit2.Prune());
        Assert.Equal(TypeRegistry.I64, lit3.Prune());
        Assert.Empty(solver.Diagnostics);
    }

    [Fact]
    public void TypeVar_LiteralConflict_ReportsError()
    {
        // Arrange
        var solver1 = new TypeSolver();
        var solver2 = new TypeSolver();
        var lit = new TypeVar("lit_42", new SourceSpan(0, 0, 2));
        lit.Instance = TypeRegistry.ComptimeInt;

        // Act - First harden to I64, then try to unify with U32
        solver1.Unify(lit, TypeRegistry.I64);
        solver2.Unify(lit, TypeRegistry.U32);

        // Assert
        Assert.Empty(solver1.Diagnostics);
        Assert.NotEmpty(solver2.Diagnostics);
        Assert.Contains("E2002", solver2.Diagnostics[0].Code);  // Type mismatch error
    }

    #endregion
}
