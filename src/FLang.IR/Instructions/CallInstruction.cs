namespace FLang.IR.Instructions;

public class CallInstruction : Instruction
{
    public CallInstruction(string functionName, IReadOnlyList<Value> arguments)
    {
        FunctionName = functionName;
        Arguments = arguments;
    }

    public string FunctionName { get; }
    public IReadOnlyList<Value> Arguments { get; }
}

