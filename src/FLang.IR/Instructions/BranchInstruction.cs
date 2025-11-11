namespace FLang.IR.Instructions;

public class BranchInstruction : Instruction
{
    public BranchInstruction(Value condition, BasicBlock trueBlock, BasicBlock falseBlock)
    {
        Condition = condition;
        TrueBlock = trueBlock;
        FalseBlock = falseBlock;
    }

    public Value Condition { get; }
    public BasicBlock TrueBlock { get; }
    public BasicBlock FalseBlock { get; }
}