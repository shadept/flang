using TypeBase = FLang.Core.TypeBase;

namespace FLang.IR.Instructions;

/// <summary>
/// Calls a function through a function pointer with the given arguments.
/// Used for indirect calls through function-typed values.
/// </summary>
public class IndirectCallInstruction : Instruction
{
    public IndirectCallInstruction(Value functionPointer, IReadOnlyList<Value> arguments, Value result)
    {
        FunctionPointer = functionPointer;
        Arguments = arguments;
        Result = result;
    }

    /// <summary>
    /// The value containing the function pointer to call.
    /// </summary>
    public Value FunctionPointer { get; }

    /// <summary>
    /// The arguments to pass to the function.
    /// </summary>
    public IReadOnlyList<Value> Arguments { get; }

    /// <summary>
    /// The result value produced by this call.
    /// </summary>
    public Value Result { get; }
}
