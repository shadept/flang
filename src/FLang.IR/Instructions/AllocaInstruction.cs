using FLang.Core;

namespace FLang.IR.Instructions;

/// <summary>
/// Allocates stack space for a value of the given type.
/// Returns a pointer to the allocated space.
/// Similar to LLVM's alloca instruction.
/// </summary>
public class AllocaInstruction : Instruction
{
    public AllocaInstruction(SourceSpan span, int sizeInBytes, Value result)
        : base(span)
    {
        SizeInBytes = sizeInBytes;
        Result = result;
    }

    /// <summary>
    /// Size in bytes to allocate.
    /// </summary>
    public int SizeInBytes { get; }

    /// <summary>
    /// The result value (pointer to allocated space) produced by this operation.
    /// </summary>
    public Value Result { get; }

    /// <summary>
    /// When true, this alloca holds actual array data (not a pointer to an array).
    /// The C codegen should emit a real C array declaration rather than a pointer-sized local.
    /// </summary>
    public bool IsArrayStorage { get; init; }
}
