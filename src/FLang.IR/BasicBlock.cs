using FLang.IR.Instructions;

namespace FLang.IR;

public class BasicBlock(string label)
{
    public string Label { get; } = label;
    public List<Instruction> Instructions { get; } = [];
}
