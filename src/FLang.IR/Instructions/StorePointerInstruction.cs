using FLang.Core;

namespace FLang.IR.Instructions;

/// <summary>
/// Represents storing a value to a pointer location: ptr.* = value
/// StorePointer(Pointer, Value)
/// </summary>
public class StorePointerInstruction : Instruction
{
    public StorePointerInstruction(SourceSpan span, Value pointer, Value value)
        : base(span)
    {
        Pointer = pointer;
        Value = value;
    }

    public Value Pointer { get; }
    public Value Value { get; }
}