using FLang.Core;

namespace FLang.IR.Instructions;

/// <summary>
/// Stores a value to a base pointer plus byte offset: *(Type*)((char*)dstPtr + byteOffset) = val
/// Fused from GEP(basePtr, offset, fieldPtr) + StorePointer(fieldPtr, val) when fieldPtr is single-use.
/// </summary>
public class CopyToOffsetInstruction : Instruction
{
    public CopyToOffsetInstruction(SourceSpan span, Value val, Value dstPtr, Value byteOffset, IrType valueType)
        : base(span)
    {
        Val = val;
        DstPtr = dstPtr;
        ByteOffset = byteOffset;
        ValueType = valueType;
    }

    public Value Val { get; }
    public Value DstPtr { get; }
    public Value ByteOffset { get; }
    public IrType ValueType { get; }
}
