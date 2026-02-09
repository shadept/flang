using FLang.Core;

namespace FLang.IR.Instructions;

/// <summary>
/// Returns from the current function with the given value.
/// This is a terminator instruction - must be the last instruction in a basic block.
/// </summary>
public class ReturnInstruction : Instruction
{
    public ReturnInstruction(SourceSpan span, Value value)
        : base(span)
    {
        Value = value;
    }

    /// <summary>
    /// The value to return from the function.
    /// For void functions, this should be a void constant.
    /// </summary>
    public Value Value { get; }
}