using FLang.Core;

namespace FLang.IR;

public abstract class Value
{
    public string Name { get; set; } = "";
    public FType? Type { get; set; } // FLang type carried in IR
}

public class ConstantValue : Value
{
    public ConstantValue(long intValue)
    {
        IntValue = intValue;
        Name = intValue.ToString();
    }

    public long IntValue { get; }
}

public class StringConstantValue : Value
{
    public StringConstantValue(string stringValue, string name)
    {
        StringValue = stringValue;
        Name = name;
    }

    public string StringValue { get; }
}

public class LocalValue : Value
{
    public LocalValue(string name)
    {
        Name = name;
    }
}
