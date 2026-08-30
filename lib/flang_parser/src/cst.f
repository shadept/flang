// Concrete Syntax Tree - the lossless tree built directly from the token stream. Every byte of the
// source is reachable through some Token in the CST; reconstructing source is a depth-first walk
// emitting each token's leading + text + trailing trivia in order.
//
// The CST is the substrate for the formatter, refactorings, and syntax-aware tooling. The semantic
// AST (see ast.f) is a typed view computed on demand from the CST and is what the type checker
// consumes.

import std.enum
import std.allocator
import std.list
import flang_parser.token
import flang_parser.trivia

// Every syntactic form gets a NodeKind. One kind per syntactic shape the parser can produce;
// semantic groupings (where two shapes mean the same thing) live on the AST view in ast.f. Adding a
// new syntactic form means adding a kind here AND wiring it through every CST consumer (formatter,
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
    // `type Alias = SomeType` - pure type alias with no struct/enum body.
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
    // `#if cond { ... } else { ... }` directive-driven compile-time branch.
    IfDirectiveStmt

    // ─────────────────────────────────────────────────────────────────────
    // Expressions
    // ─────────────────────────────────────────────────────────────────────

    // `a + b`, `a == b`, etc. - every infix operator.
    BinaryExpr
    // `-a`, `!a`, `~a` - prefix unary.
    UnaryExpr
    // `&a`.
    AddressOfExpr
    // `a.*`.
    DereferenceExpr
    // `a.b` and `a.b()` - field access or UFCS method dispatch.
    MemberAccessExpr
    // `a[i]` and `a[i] = v` - index read/write.
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
    // `expr?` - postfix try.
    TryExpr
    // `0..10`, `0..=9`, `..0`, `1..`.
    RangeExpr
    // `[1, 2, 3]` literal - distinct from `[T; N]` type expressions.
    ArrayLiteralExpr
    // `.{ x = 1, y = 2 }` - needs target type from context.
    AnonymousStructExpr
    // `Point { x = 1, y = 2 }` - nominal struct literal.
    StructConstructionExpr
    // `{ ... }` - block expression with optional trailing value.
    BlockExpr
    // `( expr )` - a parenthesised group. Kept as its own node so the CST retains the parens, but
    // it carries no semantics of its own: it projects to the inner expression, not to a block
    // (which would add a scope the source never asked for).
    ParenExpr
    // `if cond { ... } else { ... }` - also valid in expression position.
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
    // `fn(x: T) U { ... }` - anonymous function literal (may capture).
    LambdaExpr
    // `$"text {expr} more"` and friends.
    InterpolatedStringExpr
    // `name = value` inside a call's argument list.
    NamedArgumentExpr
    // Bare identifier reference.
    IdentifierExpr

    // Literal expressions - one kind per literal shape.
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

    // `_` - matches anything, no binding.
    WildcardPattern
    // Bare identifier binding any value.
    VariablePattern
    // `42`, `"x"`, `true` - equality via op_eq.
    LiteralPattern
    // `Some(x)`, `Move(x, y)` - enum-variant destructure.
    EnumVariantPattern
    // `A | B | C`.
    OrPattern
    // `0..10`, `0..=9` - pattern-only `..=` token allowed here.
    RangePattern
    // `Point { x, y, .. }`.
    StructPattern
    // `(a, b)`.
    TuplePattern
    // `else` arm - catch-all default.
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
    // `T?` - sugar for Option(T).
    OptionalType
    // `(A, B)` - sugar for anonymous struct `{ __0: A, __1: B }`.
    TupleType
    // Inline `struct { ... }` and `enum { ... }` in type position.
    AnonymousStructType
    AnonymousEnumType

    // ─────────────────────────────────────────────────────────────────────
    // Error recovery
    // ─────────────────────────────────────────────────────────────────────

    // Parser produced this where the grammar rejected input. Preserves child tokens so the
    // formatter can still re-emit source on broken syntax - partial trees stay editable.
    Error
}

#enum_utils(NodeKind)

// ─────────────────────────────────────────────────────────────────────
// Storage
// ─────────────────────────────────────────────────────────────────────
//
// The tree is stored struct-of-arrays: one `Cst` owns every node, every token and one flat child
// array, and a node names its children as a window into that array rather than owning a list.
// Children are indices, so nothing is copied, the whole tree is three allocations, and a node
// exists exactly once - teardown is three list frees.

// Index into `Cst.nodes`. A transparent alias (spec.md §2.3.1): the name is for the reader, not
// something the compiler checks.
pub type CstNodeId = u32

// Index into `Cst.tokens`.
pub type CstTokenId = u32

// A node's children as a window into `Cst.children`. Children are contiguous: the parser buffers
// them on a scratch stack and moves them across in one block when the node closes.
pub type ChildSpan = struct {
    start: u32
    len: u32
}

// A stored child: an index plus which array it indexes.
pub type CstChildSlot = enum {
    NodeSlot(CstNodeId)
    TokenSlot(CstTokenId)
}

// One stored node. `start` and `end` cover every child token's byte range, trivia included, and
// children are in source order, so concatenating their bytes yields a substring of the source.
pub type CstNodeData = struct {
    kind: NodeKind
    start: u32
    end: u32
    children: ChildSpan
}

// The tree. Owns the token list, which is moved in from the lexer rather than copied.
//
// `source` is borrowed and must outlive the tree. A node is a byte range and a token is an offset,
// so the text they name and the trivia between them live in the buffer; consumers that need either
// read it from here rather than being handed the source separately.
pub type Cst = struct {
    source: String
    nodes: List(CstNodeData)
    tokens: List(Token)
    children: List(CstChildSlot)
    root: CstNodeId
    allocator: &Allocator?
}

pub fn cst(tokens: List(Token), source: String, allocator: &Allocator? = null) Cst {
    return .{
        source = source,
        nodes = list(64, allocator),
        tokens = tokens,
        children = list(256, allocator),
        root = 0,
        allocator = allocator,
    }
}

// The parser publishes the root once `parse_module` closes the top node.
pub fn set_root(self: &Cst, id: CstNodeId) {
    self.root = id
}

// Frees the nodes, the flat child array and the tokens. `source` is borrowed, not owned.
pub fn deinit(self: &Cst) {
    self.nodes.deinit()
    self.children.deinit()
    self.tokens.deinit()
}

// ─────────────────────────────────────────────────────────────────────
// Traversal
// ─────────────────────────────────────────────────────────────────────

// A cursor at one node: the stored record plus the tree it came from. A stack value, never stored
// in the tree.
pub type CstNode = struct {
    cst: &Cst
    kind: NodeKind
    start: u32
    end: u32
    children: ChildSpan
}

// Child of a CST node: either a sub-node or a leaf token. CST nodes alternate between these freely;
// a `CallExpr` for example has a child token for `(`, a list of argument node children separated by
// `,` tokens, and a closing `)` token - every byte accounted for.
//
// The token arm is a borrow into `Cst.tokens`; it is valid as long as the tree is.
pub type CstChild = enum {
    NodeChild(CstNode)
    TokenChild(&Token)
}

pub fn node_at(self: &Cst, id: CstNodeId) CstNode {
    const d = self.nodes[id]
    return .{ cst = self, kind = d.kind, start = d.start, end = d.end, children = d.children }
}

pub fn root_node(self: &Cst) CstNode {
    return self.node_at(self.root)
}

pub fn child_count(self: CstNode) usize {
    return self.children.len as usize
}

// How many of the children are sub-nodes rather than tokens. Reads the child slots directly, so no
// `CstNode` is materialised per slot. An exact upper bound on what projecting those children
// yields, which is what sizes the projector's lists.
pub fn node_child_count(self: CstNode) usize {
    let n: usize = 0
    for i in 0..(self.children.len as usize) {
        self.cst.children[self.children.start as usize + i] match {
            NodeSlot(_) => { n = n + 1 }
            TokenSlot(_) => {}
        }
    }
    return n
}

// The `i`th child. Out of range panics, the same way indexing past a list does.
pub fn child(self: CstNode, i: usize) CstChild {
    const slot = self.cst.children[self.children.start as usize + i]
    return slot match {
        NodeSlot(id) => CstChild.NodeChild(self.cst.node_at(id))
        TokenSlot(id) => CstChild.TokenChild(&self.cst.tokens[id])
    }
}
