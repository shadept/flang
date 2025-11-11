namespace FLang.IR.Instructions;

public class ReturnInstruction : Instruction
{
    public Value Value { get; }

    public ReturnInstruction(Value value)
    {
        Value = value;
    }
}