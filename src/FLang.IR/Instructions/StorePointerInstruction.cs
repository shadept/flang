namespace FLang.IR.Instructions;

/// <summary>
/// Represents storing a value to a pointer location: ptr.* = value
/// StorePointer(Pointer, Value)
/// </summary>
public class StorePointerInstruction : Instruction
{
    public Value Pointer { get; }
    public Value Value { get; }

    public StorePointerInstruction(Value pointer, Value value)
    {
        Pointer = pointer;
        Value = value;
    }
}
