using FLang.Core;

namespace FLang.IR.Instructions;

public class CastInstruction : Instruction
{
    public CastInstruction(Value source, FType targetType)
    {
        Source = source;
        TargetType = targetType;
    }

    public Value Source { get; }
    public FType TargetType { get; }
}
