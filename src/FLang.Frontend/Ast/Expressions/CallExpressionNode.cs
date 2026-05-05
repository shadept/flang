using FLang.Core;
using FLang.Frontend.Ast.Declarations;

namespace FLang.Frontend.Ast.Expressions;

public class CallExpressionNode : ExpressionNode
{
    public CallExpressionNode(SourceSpan span, string functionName, IReadOnlyList<ExpressionNode> arguments,
        ExpressionNode? ufcsReceiver = null, string? methodName = null,
        SourceSpan? functionNameSpan = null) :
        base(span)
    {
        FunctionName = functionName;
        // Store as mutable list to allow TypeChecker to insert coercion nodes
        Arguments = arguments is List<ExpressionNode> list ? list : new List<ExpressionNode>(arguments);
        UfcsReceiver = ufcsReceiver;
        MethodName = methodName;
        FunctionNameSpan = functionNameSpan ?? span;
    }

    public string FunctionName { get; }
    public List<ExpressionNode> Arguments { get; }

    /// <summary>
    /// Span covering just the called name (the identifier or `.method` part), not the
    /// arguments or surrounding parens. Used by LSP and any synthesized AST that needs
    /// to refer back to the original name location without claiming the entire call's
    /// span. Falls back to the full call span when the parser didn't supply one.
    /// </summary>
    public SourceSpan FunctionNameSpan { get; }

    /// <summary>
    /// For UFCS calls (obj.method(args)), this holds the receiver expression (obj).
    /// Null for regular function calls. Settable so the type checker can re-shape an
    /// op_call dispatch (`c(args)` where `c` is a value with an `op_call` method) into
    /// UFCS form, reusing the existing UFCS lowering path without special-casing op_call.
    /// </summary>
    public ExpressionNode? UfcsReceiver { get; set; }

    /// <summary>
    /// For UFCS calls, this holds the method name (just the method part, not "obj.method").
    /// Null for regular function calls. Settable for the same op_call rewrite reason as
    /// <see cref="UfcsReceiver"/>.
    /// </summary>
    public string? MethodName { get; set; }

    /// <summary>
    /// Semantic: The resolved target function declaration.
    /// For generic functions, this points to the specialized FunctionDeclarationNode with concrete types.
    /// Null for indirect calls through function pointers.
    /// </summary>
    public FunctionDeclarationNode? ResolvedTarget { get; set; }

    /// <summary>
    /// Semantic: True if this is an indirect call through a function pointer.
    /// When true and UfcsReceiver/MethodName are set, it's a field-call (vtable pattern).
    /// When true and UfcsReceiver is null, FunctionName is a variable with function type.
    /// </summary>
    public bool IsIndirectCall { get; set; }

    /// <summary>
    /// Semantic: Fully resolved argument list in parameter order, with defaults filled
    /// and named arguments reordered. When set by the type checker, lowering uses this
    /// instead of Arguments. Does NOT include the UFCS receiver.
    /// </summary>
    public List<ExpressionNode>? ResolvedArguments { get; set; }

    /// <summary>
    /// Semantic: True if this call is actually a generic type instantiation in expression context
    /// (e.g., Foo(i32) used as a type-as-value). The lowering should emit a type info reference
    /// instead of a function call.
    /// </summary>
    public bool IsTypeInstantiation { get; set; }

    /// <summary>
    /// Chain of op_deref functions to apply to the UFCS receiver before the call.
    /// For example, rc.length() on Rc(Point) where length takes &amp;Point:
    ///   [Rc(Point).op_deref] — lowering calls op_deref on the receiver first,
    ///   then passes the result as the first argument to length.
    /// Null or empty = no op_deref involved.
    /// </summary>
    public List<FunctionDeclarationNode>? UfcsOpDerefChain { get; set; }

    /// <summary>
    /// Declaration of the local variable or parameter being called, when the callee is
    /// a value rather than a named function (i.e. <see cref="IsIndirectCall"/> is true).
    /// Lets goto-definition navigate from `f(args)` to `let f = …` instead of trying to
    /// find a function named `f`. Null for direct calls and for op_call dispatch (where
    /// the synthesized <see cref="UfcsReceiver"/> identifier already carries the link).
    /// </summary>
    public AstNode? CalleeDeclaration { get; set; }
}