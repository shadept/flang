namespace FLang.IR.Instructions;

/// <summary>
/// Base class for all IR instructions in the FLang intermediate representation.
/// Instructions are divided into two categories:
/// - Value-producing instructions (Binary, Call, Cast, AddressOf, Load, Alloca, GetElementPtr) have their own Result property
/// - Non-value-producing instructions (Store, StorePointer, Return, Jump, Branch) do not have a Result property
/// </summary>
public abstract class Instruction
{
}