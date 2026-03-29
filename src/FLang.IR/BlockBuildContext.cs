namespace FLang.IR;

/// <summary>
/// Shared state for all BasicBlocks within an IrFunction.
/// Ensures unique temp names across blocks and provides
/// access to layout/ABI information.
/// </summary>
public class BlockBuildContext
{
    public IrFunction Function { get; }
    public TypeLayoutService Layout { get; }

    private int _counter;

    /// <summary>Current source span, updated by HmAstLowering as it walks the AST.</summary>
    public FLang.Core.SourceSpan Span { get; set; }

    /// <summary>Allocate a unique temp name like "retslot_7".</summary>
    public string FreshName(string hint) => $"{hint}_{_counter++}";

    /// <summary>Create a new LocalValue with a unique name.</summary>
    public LocalValue FreshLocal(string hint, IrType type)
        => new(FreshName(hint), type);

    /// <summary>
    /// Create a new block, register it with the owning function, and return it.
    /// The new block shares this context.
    /// </summary>
    public BasicBlock CreateBlock(string label)
    {
        var block = new BasicBlock($"{label}_{_counter++}", this);
        Function.BasicBlocks.Add(block);
        return block;
    }

    public BlockBuildContext(IrFunction function, TypeLayoutService layout)
    {
        Function = function;
        Layout = layout;
    }
}
