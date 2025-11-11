namespace FLang.IR.Instructions;

public class JumpInstruction : Instruction
{
    public BasicBlock TargetBlock { get; }

    public JumpInstruction(BasicBlock targetBlock)
    {
        TargetBlock = targetBlock;
    }
}
