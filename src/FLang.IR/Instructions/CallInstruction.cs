using System.Collections.Generic;

namespace FLang.IR.Instructions;

public class CallInstruction : Instruction
{
    public string FunctionName { get; }
    public IReadOnlyList<Value> Arguments { get; }

    public CallInstruction(string functionName, IReadOnlyList<Value> arguments)
    {
        FunctionName = functionName;
        Arguments = arguments;
    }
}
