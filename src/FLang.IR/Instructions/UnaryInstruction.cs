namespace FLang.IR.Instructions;

/// <summary>
/// Unary operations supported by the IR.
/// </summary>
public enum UnaryOp
{
    /// <summary>Arithmetic negation: -x</summary>
    Negate,

    /// <summary>Logical not: !x</summary>
    Not
}

/// <summary>
/// Represents a unary operation on a single value.
/// Result = (Operation) Operand
/// </summary>
public class UnaryInstruction : Instruction
{
    public UnaryInstruction(UnaryOp operation, Value operand, Value result)
    {
        Operation = operation;
        Operand = operand;
        Result = result;
    }

    public UnaryOp Operation { get; }
    public Value Operand { get; }
    public Value Result { get; }
}
