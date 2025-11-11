namespace FLang.IR.Instructions;

public class StoreInstruction : Instruction
{
    public StoreInstruction(string variableName, Value value)
    {
        VariableName = variableName;
        Value = value;
    }

    public string VariableName { get; }
    public Value Value { get; }
}