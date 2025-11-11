namespace FLang.IR.Instructions;

public class StoreInstruction : Instruction
{
    public string VariableName { get; }
    public Value Value { get; }

    public StoreInstruction(string variableName, Value value)
    {
        VariableName = variableName;
        Value = value;
    }
}
