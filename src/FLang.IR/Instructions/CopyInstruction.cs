using FLang.Core;

namespace FLang.IR.Instructions;

/// <summary>
/// Copies a value from one pointer to another: *dstPtr = *srcPtr
/// Fused from Load(srcPtr, t) + StorePointer(dstPtr, t) when t is single-use.
/// </summary>
public class CopyInstruction : Instruction
{
    public CopyInstruction(SourceSpan span, Value srcPtr, Value dstPtr, IrType valueType)
        : base(span)
    {
        SrcPtr = srcPtr;
        DstPtr = dstPtr;
        ValueType = valueType;
    }

    public Value SrcPtr { get; }
    public Value DstPtr { get; }
    public IrType ValueType { get; }
}
