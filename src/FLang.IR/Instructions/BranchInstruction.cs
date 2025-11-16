namespace FLang.IR.Instructions;

/// <summary>
/// Conditional branch instruction that jumps to one of two basic blocks based on a condition.
/// If condition is true (non-zero), jumps to TrueBlock; otherwise jumps to FalseBlock.
/// This is a terminator instruction - must be the last instruction in a basic block.
/// </summary>
public class BranchInstruction : Instruction
{
    public BranchInstruction(Value condition, BasicBlock trueBlock, BasicBlock falseBlock)
    {
        Condition = condition;
        TrueBlock = trueBlock;
        FalseBlock = falseBlock;
    }

    /// <summary>
    /// The boolean condition to evaluate.
    /// </summary>
    public Value Condition { get; }

    /// <summary>
    /// The basic block to jump to if the condition is true.
    /// </summary>
    public BasicBlock TrueBlock { get; }

    /// <summary>
    /// The basic block to jump to if the condition is false.
    /// </summary>
    public BasicBlock FalseBlock { get; }
}