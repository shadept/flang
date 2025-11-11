using FLang.Core;
using FType = FLang.Core.Type;

namespace FLang.IR.Instructions;

/// <summary>
/// Allocates stack space for a value of the given type.
/// Returns a pointer to the allocated space.
/// Similar to LLVM's alloca instruction.
/// </summary>
public class AllocaInstruction : Instruction
{
    /// <summary>
    /// The type to allocate space for.
    /// </summary>
    public FType AllocatedType { get; }

    /// <summary>
    /// Size in bytes to allocate.
    /// </summary>
    public int SizeInBytes { get; }

    public AllocaInstruction(FType allocatedType, int sizeInBytes)
    {
        AllocatedType = allocatedType;
        SizeInBytes = sizeInBytes;
    }
}
