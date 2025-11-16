namespace FLang.IR.Instructions;

/// <summary>
/// Binary operations supported by the IR.
/// Includes arithmetic operations and comparisons.
/// </summary>
public enum BinaryOp
{
    /// <summary>Addition: left + right</summary>
    Add,

    /// <summary>Subtraction: left - right</summary>
    Subtract,

    /// <summary>Multiplication: left * right</summary>
    Multiply,

    /// <summary>Division: left / right</summary>
    Divide,

    /// <summary>Modulo: left % right</summary>
    Modulo,

    /// <summary>Equality comparison: left == right</summary>
    Equal,

    /// <summary>Inequality comparison: left != right</summary>
    NotEqual,

    /// <summary>Less than comparison: left &lt; right</summary>
    LessThan,

    /// <summary>Greater than comparison: left &gt; right</summary>
    GreaterThan,

    /// <summary>Less than or equal comparison: left &lt;= right</summary>
    LessThanOrEqual,

    /// <summary>Greater than or equal comparison: left &gt;= right</summary>
    GreaterThanOrEqual
}

/// <summary>
/// Represents a binary operation on two values.
/// Result = Left (Operation) Right
/// Examples: addition, subtraction, comparison, etc.
/// </summary>
public class BinaryInstruction : Instruction
{
    public BinaryInstruction(BinaryOp operation, Value left, Value right, Value result)
    {
        Operation = operation;
        Left = left;
        Right = right;
        Result = result;
    }

    /// <summary>
    /// The binary operation to perform.
    /// </summary>
    public BinaryOp Operation { get; }

    /// <summary>
    /// The left operand.
    /// </summary>
    public Value Left { get; }

    /// <summary>
    /// The right operand.
    /// </summary>
    public Value Right { get; }

    /// <summary>
    /// The result value produced by this operation.
    /// </summary>
    public Value Result { get; }
}