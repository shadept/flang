using FLang.Core;

namespace FLang.IR.Instructions;

/// <summary>
/// Loads a value from a base pointer plus byte offset: result = *(ResultType*)((char*)srcPtr + byteOffset)
/// Fused from GEP(basePtr, offset, fieldPtr) + Load(fieldPtr, result) when fieldPtr is single-use.
/// </summary>
public class CopyFromOffsetInstruction : Instruction
{
    public CopyFromOffsetInstruction(SourceSpan span, Value srcPtr, Value byteOffset, Value result)
        : base(span)
    {
        SrcPtr = srcPtr;
        ByteOffset = byteOffset;
        Result = result;
    }

    public Value SrcPtr { get; }
    public Value ByteOffset { get; }
    public Value Result { get; }
}
