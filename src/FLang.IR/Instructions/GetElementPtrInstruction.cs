namespace FLang.IR.Instructions;

/// <summary>
/// Calculates the address of a field within a struct or array element.
/// Takes a base pointer and a byte offset (constant or dynamic), returns pointer to the field/element.
/// Similar to LLVM's getelementptr instruction (simplified).
/// </summary>
public class GetElementPtrInstruction : Instruction
{
    public GetElementPtrInstruction(Value basePointer, Value byteOffset, Value result)
    {
        BasePointer = basePointer;
        ByteOffset = byteOffset;
        Result = result;
    }

    // Convenience constructor for constant offsets
    public GetElementPtrInstruction(Value basePointer, int byteOffset, Value result)
        : this(basePointer, new ConstantValue(byteOffset), result)
    {
    }

    /// <summary>
    /// The base pointer to offset from.
    /// </summary>
    public Value BasePointer { get; }

    /// <summary>
    /// Byte offset - can be a ConstantValue or a LocalValue for dynamic indexing
    /// </summary>
    public Value ByteOffset { get; }

    /// <summary>
    /// The result value (pointer to element/field) produced by this operation.
    /// </summary>
    public Value Result { get; }
}