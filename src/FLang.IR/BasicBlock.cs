using FLang.IR.Instructions;

namespace FLang.IR;

public class BasicBlock
{
    public BasicBlock(string label)
    {
        Label = label;
    }

    public string Label { get; }
    public List<Instruction> Instructions { get; } = [];
}