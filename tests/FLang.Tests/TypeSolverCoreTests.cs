using FLang.Core;
using FLang.Semantics;

namespace FLang.Tests;

public class TypeSolverCoreTests
{
    #region Basic Unification Tests

    [Fact]
    public void Unify_IdenticalPrimitives_Succeeds()
    {
        // Arrange
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
        var t1 = TypeRegistry.I32;
        var t2 = TypeRegistry.Bool;

        // Act
        var result = solver.Unify(t1, t2);

        // Assert
        Assert.Single(solver.Diagnostics);
        Assert.Equal("E3001", solver.Diagnostics[0].Code);
        Assert.Contains("i32", solver.Diagnostics[0].Message);
        Assert.Contains("bool", solver.Diagnostics[0].Message);
    }

    [Fact]
    public void Unify_TypeVarWithConcrete_BindsVariable()
    {
        // Arrange
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
        var struct1 = new StructType("Point");
        var struct2 = new StructType("Vector");

        // Act
        solver.Unify(struct1, struct2);

        // Assert
        Assert.Single(solver.Diagnostics);
        Assert.Equal("E3001", solver.Diagnostics[0].Code);
        Assert.Contains("expected 'Point', got 'Vector'", solver.Diagnostics[0].Message);
    }

    [Fact]
    public void Unify_GenericStructs_WithMatchingTypeArgs_Succeeds()
    {
        // Arrange
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
        var struct1 = new StructType("Option", [TypeRegistry.I32]);
        var struct2 = new StructType("Option", [TypeRegistry.Bool]);

        // Act
        solver.Unify(struct1, struct2);

        // Assert
        Assert.NotEmpty(solver.Diagnostics);
        Assert.Contains(solver.Diagnostics, d => d.Code == "E3001");
    }

    #endregion

    #region Comptime Int Hardening Tests

    [Fact]
    public void Unify_ComptimeIntWithI32_HardensToI32()
    {
        // Arrange
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
        var from = TypeRegistry.I16;
        var to = TypeRegistry.I8;

        // Act
        solver.Unify(from, to);

        // Assert
        Assert.NotEmpty(solver.Diagnostics);
        Assert.Equal("E3001", solver.Diagnostics[0].Code);
    }

    [Fact]
    public void IntegerWidening_U8ToU16_Succeeds()
    {
        // Arrange
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore(PointerWidth.Bits32);
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
        var solver = new TypeSolverCore(PointerWidth.Bits64);
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
        var solver = new TypeSolverCore(PointerWidth.Bits32);
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
        var solver = new TypeSolverCore(PointerWidth.Bits64);
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
        var solver = new TypeSolverCore(PointerWidth.Bits64);
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
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
        var solver1 = new TypeSolverCore();
        var solver2 = new TypeSolverCore();
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

    #region Custom Coercion Rule Tests

    [Fact]
    public void CustomCoercionRule_CanBeAdded()
    {
        // Arrange
        var solver = new TypeSolverCore();
        var customRule = new AlwaysTrueCoercionRule();
        solver.CoercionRules.Add(customRule);

        var from = TypeRegistry.I32;
        var to = TypeRegistry.Bool;

        // Act
        var result = solver.Unify(from, to);

        // Assert
        Assert.Equal(to, result);
        Assert.Empty(solver.Diagnostics);
    }

    // Helper test coercion rule
    private class AlwaysTrueCoercionRule : ICoercionRule
    {
        public bool TryApply(TypeBase from, TypeBase to, TypeSolverCore solver)
        {
            return true; // Always allow coercion (for testing)
        }
    }

    #endregion

    #region Error Message Tests

    [Fact]
    public void ErrorMessage_IncludesExpectedAndActualTypes()
    {
        // Arrange
        var solver = new TypeSolverCore();
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
        var solver = new TypeSolverCore();
        var skolem = PrimitiveType.CreateSkolem("T");
        var concrete = TypeRegistry.I32;

        // Act
        solver.Unify(skolem, concrete);

        // Assert
        Assert.Single(solver.Diagnostics);
        Assert.Equal("E3003", solver.Diagnostics[0].Code);
        Assert.Contains("rigid generic parameter", solver.Diagnostics[0].Message);
    }

    #endregion
}
