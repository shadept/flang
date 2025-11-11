namespace FLang.IR.Instructions;

public enum BinaryOp
{
    Add,
    Subtract,
    Multiply,
    Divide,
    Modulo,

    // Comparisons
    Equal,
    NotEqual,
    LessThan,
    GreaterThan,
    LessThanOrEqual,
    GreaterThanOrEqual,
}

public class BinaryInstruction : Instruction
{
    public BinaryOp Operation { get; }
    public Value Left { get; }
    public Value Right { get; }

    public BinaryInstruction(BinaryOp operation, Value left, Value right)
    {
        Operation = operation;
        Left = left;
        Right = right;
    }
}
