using FLang.Core;

namespace FLang.IR;

public class FunctionParameter
{
    public FunctionParameter(string name, FType type)
    {
        Name = name;
        Type = type;
    }

    public string Name { get; }
    public FType Type { get; } // FLang type
}

public class Function
{
    public Function(string name)
    {
        Name = name;
    }

    public string Name { get; }
    public FType ReturnType { get; set; } = TypeRegistry.I32; // FLang type
    public List<FunctionParameter> Parameters { get; } = new();
    public List<BasicBlock> BasicBlocks { get; } = new();
    public bool IsForeign { get; set; }
}

