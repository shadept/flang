// Concrete Syntax Tree — the lossless tree built directly from the token
// stream. Every byte of the source is reachable through some Token in the
// CST; reconstructing source is a depth-first walk emitting each token's
// leading + text + trailing trivia in order.
//
// The CST is the substrate for the formatter, refactorings, and syntax-aware
// tooling. The semantic AST (see ast.f) is a typed view computed on demand
// from the CST and is what the type checker consumes.

import std.list
import flang_parser.token

// Every syntactic form gets a NodeKind. One kind per syntactic shape the
// parser can produce; semantic groupings (where two shapes mean the same
// thing) live on the AST view in ast.f. Adding a new syntactic form means
// adding a kind here AND wiring it through every CST consumer (formatter,
// navigator, refactor passes).
pub type NodeKind = enum {
    // ─────────────────────────────────────────────────────────────────────
    // File-level
    // ─────────────────────────────────────────────────────────────────────

    // Top-level container: imports, declarations, tests.
    Module

    // ─────────────────────────────────────────────────────────────────────
    // Declarations
    // ─────────────────────────────────────────────────────────────────────

    // `import path.to.module` and `pub import path.to.module`.
    ImportDecl
    // `fn name(params) ret { body }` and foreign declarations.
    FunctionDecl
    // One parameter slot inside a FunctionDecl.
    FunctionParam
    // `type Name = struct { ... }`.
    StructDecl
    // Field inside a struct declaration.
    StructField
    // `type Name = enum { Variant, Variant(T) }`.
    EnumDecl
    // Variant inside an enum declaration.
    EnumVariant
    // `type Alias = SomeType` — pure type alias with no struct/enum body.
    TypeAliasDecl
    // `test "name" { ... }` block.
    TestDecl
    // `#define(name, ...) { ... }` source generator definition.
    GeneratorDef
    // `#name(args)` source generator invocation.
    GeneratorInvocation
    // `#foreign`, `#inline`, `#deprecated`, etc. on a declaration.
    Directive

    // ─────────────────────────────────────────────────────────────────────
    // Statements
    // ─────────────────────────────────────────────────────────────────────

    // `let x = expr` or `const x: T = expr`.
    VariableDecl
    // A bare expression terminated by a newline; result is discarded.
    ExpressionStmt
    // `return expr` (expr optional for void).
    ReturnStmt
    // `defer expr`.
    DeferStmt
    // `break` and `continue`.
    BreakStmt
    ContinueStmt
    // `#if(cond) { ... } else { ... }` directive-driven compile-time branch.
    IfDirectiveStmt

    // ─────────────────────────────────────────────────────────────────────
    // Expressions
    // ─────────────────────────────────────────────────────────────────────

    // `a + b`, `a == b`, etc. — every infix operator.
    BinaryExpr
    // `-a`, `!a`, `~a` — prefix unary.
    UnaryExpr
    // `&a`.
    AddressOfExpr
    // `a.*`.
    DereferenceExpr
    // `a.b` and `a.b()` — field access or UFCS method dispatch.
    MemberAccessExpr
    // `a[i]` and `a[i] = v` — index read/write.
    IndexExpr
    // `f(a, b)`, including UFCS calls and op_call dispatch.
    CallExpr
    // `expr as Type`.
    CastExpr
    // `a = b`, `a += b`, etc.
    AssignmentExpr
    // `a ?? b`.
    CoalesceExpr
    // `a?.b`.
    NullPropagationExpr
    // `expr?` — postfix try.
    TryExpr
    // `0..10`, `0..=9`, `..0`, `1..`.
    RangeExpr
    // `[1, 2, 3]` literal — distinct from `[T; N]` type expressions.
    ArrayLiteralExpr
    // `.{ x = 1, y = 2 }` — needs target type from context.
    AnonymousStructExpr
    // `Point { x = 1, y = 2 }` — nominal struct literal.
    StructConstructionExpr
    // `{ ... }` — block expression with optional trailing value.
    BlockExpr
    // `if cond { ... } else { ... }` — also valid in expression position.
    IfExpr
    // `for x in iter { ... }`.
    ForLoopExpr
    // `loop { ... }`.
    LoopExpr
    // `while cond { ... }`.
    WhileExpr
    // `expr match { pat => result, ... }`.
    MatchExpr
    // One arm inside a match expression.
    MatchArm
    // `fn(x: T) U { ... }` — anonymous function literal (may capture).
    LambdaExpr
    // `$"text {expr} more"` and friends.
    InterpolatedStringExpr
    // `name = value` inside a call's argument list.
    NamedArgumentExpr
    // Bare identifier reference.
    IdentifierExpr

    // Literal expressions — one kind per literal shape.
    IntegerLiteralExpr
    FloatLiteralExpr
    StringLiteralExpr
    CharLiteralExpr
    ByteLiteralExpr
    BooleanLiteralExpr
    NullLiteralExpr

    // ─────────────────────────────────────────────────────────────────────
    // Patterns (match arms and destructuring)
    // ─────────────────────────────────────────────────────────────────────

    // `_` — matches anything, no binding.
    WildcardPattern
    // Bare identifier binding any value.
    VariablePattern
    // `42`, `"x"`, `true` — equality via op_eq.
    LiteralPattern
    // `Some(x)`, `Move(x, y)` — enum-variant destructure.
    EnumVariantPattern
    // `A | B | C`.
    OrPattern
    // `0..10`, `0..=9` — pattern-only `..=` token allowed here.
    RangePattern
    // `Point { x, y, .. }`.
    StructPattern
    // `(a, b)`.
    TuplePattern
    // `else` arm — catch-all default.
    ElsePattern

    // ─────────────────────────────────────────────────────────────────────
    // Type expressions
    // ─────────────────────────────────────────────────────────────────────

    // Named type with optional generic args: `Option(i32)`, `Point`.
    NamedType
    // `fn(T1, T2) R`.
    FunctionType
    // `&T`.
    ReferenceType
    // `[T; N]`.
    ArrayType
    // `T[]`.
    SliceType
    // `T?` — sugar for Option(T).
    OptionalType
    // `(A, B)` — sugar for anonymous struct `{ __0: A, __1: B }`.
    TupleType
    // Inline `struct { ... }` and `enum { ... }` in type position.
    AnonymousStructType
    AnonymousEnumType

    // ─────────────────────────────────────────────────────────────────────
    // Error recovery
    // ─────────────────────────────────────────────────────────────────────

    // Parser produced this where the grammar rejected input. Preserves
    // child tokens so the formatter can still re-emit source on broken
    // syntax — partial trees stay editable.
    Error
}

// Child of a CST node: either a sub-node or a leaf token. CST nodes
// alternate between these freely; a `CallExpr` for example has a child
// token for `(`, a list of argument node children separated by `,` tokens,
// and a closing `)` token — every byte accounted for.
pub type CstChild = enum {
    NodeChild(CstNode)
    TokenChild(Token)
}

// A node in the CST. `start` and `end` cover every child token's byte
// range (including the trivia attached to the first and last tokens).
// Children are stored in source order — iterating them and concatenating
// their bytes yields a substring of the original source.
pub type CstNode = struct {
    kind: NodeKind
    start: usize
    end: usize
    children: List(CstChild)
}
