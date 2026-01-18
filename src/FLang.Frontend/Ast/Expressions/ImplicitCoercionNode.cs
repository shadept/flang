using FLang.Core;

namespace FLang.Frontend.Ast.Expressions;

/// <summary>
/// Represents the kind of implicit coercion being performed.
/// The type system has already validated these coercions; AstLowering trusts these are correct.
/// </summary>
public enum CoercionKind
{
    /// <summary>
    /// Integer widening (e.g., i8 → i32, u8 → u64) including comptime_int hardening.
    /// Generates an integer extend instruction.
    /// </summary>
    IntegerWidening,

    /// <summary>
    /// Reinterpret cast for binary-compatible types.
    /// Examples: String ↔ Slice(u8), [T; N] → Slice(T), Slice(T) → &T.
    /// No code generation needed - these types have the same binary representation.
    /// </summary>
    ReinterpretCast,

    /// <summary>
    /// Wrapping/lifting a value with a type's constructor.
    /// Example: T → Option(T) wraps the value in a Some variant.
    /// </summary>
    Wrap,
}

/// <summary>
/// Represents an implicit type coercion inserted during type checking.
/// This node wraps an expression and indicates that an implicit conversion
/// from the inner expression's type to the target type should be performed.
/// </summary>
public class ImplicitCoercionNode : ExpressionNode
{
    public ImplicitCoercionNode(SourceSpan span, ExpressionNode inner, TypeBase targetType, CoercionKind kind)
        : base(span)
    {
        Inner = inner;
        TargetType = targetType;
        Kind = kind;
        // The Type of this node is the target type
        Type = targetType;
    }

    /// <summary>
    /// The inner expression being coerced.
    /// </summary>
    public ExpressionNode Inner { get; }

    /// <summary>
    /// The target type of the coercion (same as Type property).
    /// </summary>
    public TypeBase TargetType { get; }

    /// <summary>
    /// The kind of coercion being performed.
    /// </summary>
    public CoercionKind Kind { get; }
}
