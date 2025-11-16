namespace FLang.IR.Instructions;

/// <summary>
/// Stores a value into a named local variable.
/// Creates a new SSA version of the variable.
/// For storing through a pointer, use <see cref="StorePointerInstruction"/>.
/// </summary>
public class StoreInstruction : Instruction
{
    public StoreInstruction(string variableName, Value value, Value result)
    {
        VariableName = variableName;
        Value = value;
        Result = result;
    }

    /// <summary>
    /// The name of the local variable to store into (for C codegen).
    /// </summary>
    public string VariableName { get; }

    /// <summary>
    /// The value to store.
    /// </summary>
    public Value Value { get; }

    /// <summary>
    /// The SSA result value representing the new version of this variable.
    /// </summary>
    public Value Result { get; }
}