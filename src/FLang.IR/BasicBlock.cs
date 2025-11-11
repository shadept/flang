using System.Collections.Generic;
using FLang.IR.Instructions;

namespace FLang.IR;

public class BasicBlock
{
    public string Label { get; }
    public List<Instruction> Instructions { get; } = new();

    public BasicBlock(string label)
    {
        Label = label;
    }
}
