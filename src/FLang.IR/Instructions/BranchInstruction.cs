namespace FLang.IR.Instructions;

public class BranchInstruction : Instruction
{
    public Value Condition { get; }
    public BasicBlock TrueBlock { get; }
    public BasicBlock FalseBlock { get; }

    public BranchInstruction(Value condition, BasicBlock trueBlock, BasicBlock falseBlock)
    {
        Condition = condition;
        TrueBlock = trueBlock;
        FalseBlock = falseBlock;
    }
}
