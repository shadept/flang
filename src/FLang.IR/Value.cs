namespace FLang.IR;

public abstract class Value
{
    public string Name { get; set; } = "";
}

public class ConstantValue : Value
{
    public long IntValue { get; }

    public ConstantValue(long intValue)
    {
        IntValue = intValue;
        Name = intValue.ToString();
    }
}

public class LocalValue : Value
{
    public LocalValue(string name)
    {
        Name = name;
    }
}
