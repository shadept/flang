namespace FLang.IR.Instructions;

/// <summary>
/// Unconditional jump instruction that transfers control to a target basic block.
/// This is a terminator instruction - must be the last instruction in a basic block.
/// </summary>
public class JumpInstruction : Instruction
{
    public JumpInstruction(BasicBlock targetBlock)
    {
        TargetBlock = targetBlock;
    }

    /// <summary>
    /// The basic block to jump to unconditionally.
    /// </summary>
    public BasicBlock TargetBlock { get; }
}