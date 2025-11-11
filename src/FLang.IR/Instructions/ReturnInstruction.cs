namespace FLang.IR.Instructions;

public class ReturnInstruction : Instruction
{
    public ReturnInstruction(Value value)
    {
        Value = value;
    }

    public Value Value { get; }
}