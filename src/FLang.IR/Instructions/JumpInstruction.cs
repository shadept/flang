namespace FLang.IR.Instructions;

public class JumpInstruction : Instruction
{
    public JumpInstruction(BasicBlock targetBlock)
    {
        TargetBlock = targetBlock;
    }

    public BasicBlock TargetBlock { get; }
}