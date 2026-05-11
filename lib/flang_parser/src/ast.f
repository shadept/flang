// Abstract Syntax Tree — semantic view computed on demand over the CST.
//
// AST nodes wrap meaning; CST nodes wrap source bytes. The type checker
// and every downstream phase consume the AST. The formatter and refactor
// tools consume the CST. Both views share node identity through CST byte
// offsets: an AST node holds a (start, end) range that resolves back to a
// CstNode for diagnostics, hover, and code actions.

import flang_parser.cst

// Semantic categories — coarser than NodeKind. Two CST shapes that mean
// the same thing collapse to one AstKind; e.g. `if expr { … }` and
// `if expr { … } else { … }` are both IfExpr at the AST level, and the
// seven literal NodeKinds collapse to a single LiteralExpr.
pub type AstKind = enum {
    // ─────────────────────────────────────────────────────────────────────
    // File-level
    // ─────────────────────────────────────────────────────────────────────

    Module

    // ─────────────────────────────────────────────────────────────────────
    // Declarations
    // ─────────────────────────────────────────────────────────────────────

    ImportDecl
    FunctionDecl
    StructDecl
    EnumDecl
    TypeAliasDecl
    TestDecl
    // Source-generator definitions and invocations don't reach the type
    // checker — they're expanded into synthetic modules before semantics
    // — but they show up in the AST for tooling that wants to navigate
    // them (LSP goto-definition into a generated module).
    GeneratorDef
    GeneratorInvocation

    // ─────────────────────────────────────────────────────────────────────
    // Statements
    // ─────────────────────────────────────────────────────────────────────

    VariableDecl
    ExpressionStmt
    ReturnStmt
    DeferStmt
    BreakStmt
    ContinueStmt
    IfDirectiveStmt

    // ─────────────────────────────────────────────────────────────────────
    // Expressions
    // ─────────────────────────────────────────────────────────────────────

    BinaryExpr
    UnaryExpr
    AddressOfExpr
    DereferenceExpr
    MemberAccessExpr
    IndexExpr
    CallExpr
    CastExpr
    AssignmentExpr
    CoalesceExpr
    NullPropagationExpr
    TryExpr
    RangeExpr
    ArrayLiteralExpr
    AnonymousStructExpr
    StructConstructionExpr
    BlockExpr
    IfExpr
    ForLoopExpr
    LoopExpr
    WhileExpr
    MatchExpr
    LambdaExpr
    InterpolatedStringExpr
    IdentifierExpr
    LiteralExpr

    // ─────────────────────────────────────────────────────────────────────
    // Patterns
    // ─────────────────────────────────────────────────────────────────────

    WildcardPattern
    VariablePattern
    LiteralPattern
    EnumVariantPattern
    OrPattern
    RangePattern
    StructPattern
    TuplePattern
    ElsePattern

    // ─────────────────────────────────────────────────────────────────────
    // Types (as AST nodes, distinct from the type system's `Type`)
    // ─────────────────────────────────────────────────────────────────────

    NamedType
    FunctionType
    ReferenceType
    ArrayType
    SliceType
    OptionalType
    TupleType
    AnonymousStructType
    AnonymousEnumType
}

// AST node identity. The (cst_start, cst_end) range round-trips back to
// the producing CstNode and feeds position-based queries (hover, goto,
// find-references). Per-kind payload fields land on this struct as the
// semantic types grow.
pub type AstNode = struct {
    kind: AstKind
    cst_start: usize
    cst_end: usize
}
