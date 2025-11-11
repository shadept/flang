namespace FLang.IR.Instructions;

/// <summary>
/// Represents loading (dereferencing) a value from a pointer: ptr.*
/// Result = Load(Pointer)
/// </summary>
public class LoadInstruction : Instruction
{
    public Value Pointer { get; }

    public LoadInstruction(Value pointer)
    {
        Pointer = pointer;
    }
}
