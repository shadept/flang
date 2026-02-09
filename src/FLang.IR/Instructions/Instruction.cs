using FLang.Core;

namespace FLang.IR.Instructions;

/// <summary>
/// Base class for all IR instructions in the FLang intermediate representation.
/// Instructions are divided into two categories:
/// - Value-producing instructions (Binary, Call, Cast, AddressOf, Load, Alloca, GetElementPtr) have their own Result property
/// - Non-value-producing instructions (Store, StorePointer, Return, Jump, Branch) do not have a Result property
/// </summary>
public abstract class Instruction
{
    protected Instruction(SourceSpan span)
    {
        Span = span;
    }

    /// <summary>
    /// The source location this instruction originated from.
    /// Used by the C code generator to emit #line directives.
    /// </summary>
    public SourceSpan Span { get; }
}