using FLang.Core;

namespace FLang.IR.Instructions;

/// <summary>
/// Represents loading (dereferencing) a value from a pointer: ptr.*
/// Result = Load(Pointer)
/// </summary>
public class LoadInstruction : Instruction
{
    public LoadInstruction(SourceSpan span, Value pointer, Value result)
        : base(span)
    {
        Pointer = pointer;
        Result = result;
    }

    /// <summary>
    /// The pointer to dereference.
    /// </summary>
    public Value Pointer { get; }

    /// <summary>
    /// The result value loaded from the pointer.
    /// </summary>
    public Value Result { get; }
}