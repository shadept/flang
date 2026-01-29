namespace FLang.Core;

/// <summary>
/// Binary operator kinds used in binary expressions.
/// </summary>
public enum BinaryOperatorKind
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
    GreaterThanOrEqual
}

/// <summary>
/// Unary operator kinds used in unary expressions.
/// </summary>
public enum UnaryOperatorKind
{
    Negate,
    Not
}

/// <summary>
/// Maps binary operators to their corresponding operator function names.
/// Operator functions follow the pattern op_add, op_sub, op_eq, etc.
/// </summary>
public static class OperatorFunctions
{
    /// <summary>
    /// Gets the operator function name for a binary operator.
    /// </summary>
    /// <param name="op">The binary operator kind.</param>
    /// <returns>The operator function name (e.g., "op_add" for Add).</returns>
    public static string GetFunctionName(BinaryOperatorKind op) => op switch
    {
        // Arithmetic operators
        BinaryOperatorKind.Add => "op_add",
        BinaryOperatorKind.Subtract => "op_sub",
        BinaryOperatorKind.Multiply => "op_mul",
        BinaryOperatorKind.Divide => "op_div",
        BinaryOperatorKind.Modulo => "op_mod",

        // Comparison operators
        BinaryOperatorKind.Equal => "op_eq",
        BinaryOperatorKind.NotEqual => "op_ne",
        BinaryOperatorKind.LessThan => "op_lt",
        BinaryOperatorKind.GreaterThan => "op_gt",
        BinaryOperatorKind.LessThanOrEqual => "op_le",
        BinaryOperatorKind.GreaterThanOrEqual => "op_ge",

        _ => throw new ArgumentOutOfRangeException(nameof(op), op, "Unknown binary operator")
    };

    /// <summary>
    /// Gets the display symbol for a binary operator (used in error messages).
    /// </summary>
    /// <param name="op">The binary operator kind.</param>
    /// <returns>The operator symbol (e.g., "+" for Add).</returns>
    public static string GetOperatorSymbol(BinaryOperatorKind op) => op switch
    {
        BinaryOperatorKind.Add => "+",
        BinaryOperatorKind.Subtract => "-",
        BinaryOperatorKind.Multiply => "*",
        BinaryOperatorKind.Divide => "/",
        BinaryOperatorKind.Modulo => "%",
        BinaryOperatorKind.Equal => "==",
        BinaryOperatorKind.NotEqual => "!=",
        BinaryOperatorKind.LessThan => "<",
        BinaryOperatorKind.GreaterThan => ">",
        BinaryOperatorKind.LessThanOrEqual => "<=",
        BinaryOperatorKind.GreaterThanOrEqual => ">=",
        _ => "?"
    };

    /// <summary>
    /// Gets the operator function name for a unary operator.
    /// </summary>
    public static string GetFunctionName(UnaryOperatorKind op) => op switch
    {
        UnaryOperatorKind.Negate => "op_neg",
        UnaryOperatorKind.Not => "op_not",
        _ => throw new ArgumentOutOfRangeException(nameof(op), op, "Unknown unary operator")
    };

    /// <summary>
    /// Gets the display symbol for a unary operator (used in error messages).
    /// </summary>
    public static string GetOperatorSymbol(UnaryOperatorKind op) => op switch
    {
        UnaryOperatorKind.Negate => "-",
        UnaryOperatorKind.Not => "!",
        _ => "?"
    };

    /// <summary>
    /// All arithmetic operator function names.
    /// </summary>
    public static readonly string[] ArithmeticOperators = ["op_add", "op_sub", "op_mul", "op_div", "op_mod"];

    /// <summary>
    /// All comparison operator function names.
    /// </summary>
    public static readonly string[] ComparisonOperators = ["op_eq", "op_ne", "op_lt", "op_gt", "op_le", "op_ge"];

    /// <summary>
    /// All unary operator function names.
    /// </summary>
    public static readonly string[] UnaryOperators = ["op_neg", "op_not"];

    /// <summary>
    /// All operator function names.
    /// </summary>
    public static readonly string[] AllOperators =
        [.. ArithmeticOperators, .. ComparisonOperators, .. UnaryOperators];

    /// <summary>
    /// Checks if a function name is an operator function.
    /// </summary>
    public static bool IsOperatorFunction(string name) => name.StartsWith("op_") && AllOperators.Contains(name);
}
