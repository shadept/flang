using FLang.Core;
using FType = FLang.Core.TypeBase;

namespace FLang.IR.Instructions;

/// <summary>
/// Allocates stack space for a value of the given type.
/// Returns a pointer to the allocated space.
/// Similar to LLVM's alloca instruction.
/// </summary>
public class AllocaInstruction : Instruction
{
    public AllocaInstruction(FType allocatedType, int sizeInBytes, Value result)
    {
        AllocatedType = allocatedType;
        SizeInBytes = sizeInBytes;
        Result = result;
    }

    /// <summary>
    /// The type to allocate space for.
    /// </summary>
    public FType AllocatedType { get; }

    /// <summary>
    /// Size in bytes to allocate.
    /// </summary>
    public int SizeInBytes { get; }

    /// <summary>
    /// The result value (pointer to allocated space) produced by this operation.
    /// </summary>
    public Value Result { get; }
}
