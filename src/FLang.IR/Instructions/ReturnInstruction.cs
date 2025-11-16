namespace FLang.IR.Instructions;

/// <summary>
/// Returns from the current function with the given value.
/// This is a terminator instruction - must be the last instruction in a basic block.
/// </summary>
public class ReturnInstruction : Instruction
{
    public ReturnInstruction(Value value)
    {
        Value = value;
    }

    /// <summary>
    /// The value to return from the function.
    /// For void functions, this should be a void constant.
    /// </summary>
    public Value Value { get; }
}