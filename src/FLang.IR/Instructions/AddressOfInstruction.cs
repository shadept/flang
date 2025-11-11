namespace FLang.IR.Instructions;

/// <summary>
/// Represents taking the address of a variable: &var
/// Result = AddressOf(VariableName)
/// </summary>
public class AddressOfInstruction : Instruction
{
    public string VariableName { get; }

    public AddressOfInstruction(string variableName)
    {
        VariableName = variableName;
    }
}
