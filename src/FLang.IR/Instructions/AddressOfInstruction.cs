namespace FLang.IR.Instructions;

/// <summary>
/// Represents taking the address of a variable: &var
/// Result = AddressOf(VariableName)
/// </summary>
public class AddressOfInstruction : Instruction
{
    public AddressOfInstruction(string variableName, Value result)
    {
        VariableName = variableName;
        Result = result;
    }

    /// <summary>
    /// The name of the variable to take the address of.
    /// </summary>
    public string VariableName { get; }

    /// <summary>
    /// The result value (pointer) produced by this operation.
    /// </summary>
    public Value Result { get; }
}