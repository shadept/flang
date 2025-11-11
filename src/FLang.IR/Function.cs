namespace FLang.IR;

public class FunctionParameter
{
    public FunctionParameter(string name, string type)
    {
        Name = name;
        Type = type;
    }

    public string Name { get; }
    public string Type { get; } // C type name for now
}

public class Function
{
    public Function(string name)
    {
        Name = name;
    }

    public string Name { get; }
    public List<FunctionParameter> Parameters { get; } = new();
    public List<BasicBlock> BasicBlocks { get; } = new();
    public bool IsForeign { get; set; }
}