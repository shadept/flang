using FLang.Core;
using TypeBase = FLang.Core.TypeBase;

namespace FLang.IR.Instructions;

/// <summary>
/// Calls a function with the given arguments.
/// The result of the call is stored in the Result property.
/// Supports both FLang functions and foreign/C functions.
/// </summary>
public class CallInstruction : Instruction
{
    public CallInstruction(string functionName, IReadOnlyList<Value> arguments, Value result)
    {
        FunctionName = functionName;
        Arguments = arguments;
        Result = result;
    }

    /// <summary>
    /// The name of the function to call (may be mangled or unmangled depending on IsForeignCall).
    /// </summary>
    public string FunctionName { get; }

    /// <summary>
    /// The arguments to pass to the function.
    /// </summary>
    public IReadOnlyList<Value> Arguments { get; }

    /// <summary>
    /// The result value produced by this call.
    /// </summary>
    public Value Result { get; }

    /// <summary>
    /// Parameter types of the callee function.
    /// Used for name mangling when calling FLang functions.
    /// </summary>
    public IReadOnlyList<TypeBase>? CalleeParamTypes { get; set; }

    /// <summary>
    /// True if this is a call to a foreign (C) function that should not be name-mangled.
    /// False for FLang functions that require mangling.
    /// </summary>
    public bool IsForeignCall { get; set; }
}
