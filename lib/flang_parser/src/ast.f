// Abstract Syntax Tree - semantic view computed on demand over the CST.
//
// AST nodes wrap meaning; CST nodes wrap source bytes. The type checker and every downstream phase
// consume the AST. The formatter and refactor tools consume the CST. Both views share node identity
// through the `SourceSpan` byte range each AST node carries.
//
// Category-split enums (Decl / Stmt / Expr / Pattern / TypeExpr) encode the grammar in the type
// system: an `Expr` can never hold a `Stmt`, a `Stmt` can never hold a `Decl`. Recursive children
// store as `&T` references into `Module.arena`; non-recursive children store by value.
//
// Strings (names, literal texts) are non-owning `String` views into the original source buffer. The
// source must outlive the Module.
//
// "Only representable states" is the standing rule. A handful of concessions (`Break`/`Continue`
// valid in any Stmt position regardless of enclosing scope; `GenericBind` valid in any TypeExpr
// position instead of param-types only) keep the projector tractable - those are the responsibility
// of later validation passes, not the type system.

import std.allocator
import std.collections.list
import std.option

import flang_core.span

// ─────────────────────────────────────────────────────────────────────────
// Module - top-level container
// ─────────────────────────────────────────────────────────────────────────

// One parsed source file. Owns an `ArenaAllocator` that backs every recursive child reference
// (`&Expr`, `&TypeExpr`, `&Pattern`, `&IfExpr`) in the tree. Calling `deinit()` releases the entire
// AST in a single bulk free.
pub type Module = struct {
    span: SourceSpan
    decls: List(Decl)
    arena: ArenaAllocator
}

// Scoped mutability: `decls` is writable only in this file. Installs the resolved decl list after
// decl-level #if flattening (see comptime.f). The old list's buffer stays in the arena; it is
// reclaimed with it.
// Append declarations produced by template expansion (RFC-021 §2). The
// Decl values are copied; whatever they point into must outlive the module.
//
// Rebuilds the list on the global allocator rather than growing in place: `decls`' stored allocator
// points at a projection-time local (dead once `project_module` returns), so a push that reallocs
// would go through a dangling allocator. The old buffer stays behind in the module arena.
//
// ponytail: the rebuilt buffer leaks at Module.deinit (arena-only free); fine, modules live to end
// of build.
pub fn append_decls(self: &Module, decls: &List(Decl)) {
    // Both modules read the same nodes: a declaration's own slices stay in the arena that built
    // them.
    let merged: List(Decl) = list(self.decls.len + decls.len)
    merged.push_all(self.decls.as_slice())
    merged.push_all(decls.as_slice())
    // Swapped out, never released: releasing would free through the dead allocator above, and the
    // buffer is the arena's to reclaim.
    const _stale = replace(&self.decls, merged)
}

// The elements of `xs` as the slice an AST node holds. The list is never released: its buffer lives
// as long as the allocator that holds it, which for a projected node is the module arena.
pub fn frozen(xs: move List($T)) T[] {
    return xs.as_slice()
}

pub fn set_decls(self: &Module, decls: move List(Decl)) {
    self.decls = move decls
}

pub fn deinit(self: move Module) {
    // Every AST allocation - the decls list's buffer and every nested list in the tree - lives in
    // the arena, so ONE bulk free reclaims it all. Do not walk the tree element-wise: the nested
    // lists carry allocator pointers into the (stack-local) arena view they were built with, which
    // does not survive the Module being moved (see docs/known-issues.md on allocator identity).
    self.arena.deinit()
}

// ─────────────────────────────────────────────────────────────────────────
// Declarations - top-level constructs in a module
// ─────────────────────────────────────────────────────────────────────────

// One top-level form. Most variants are declarations in the strict sense (function, type, const);
// `Test`, `GenDef`, `GenInvoke`, `IfDirective` are declaration-like constructs that share the same
// module-level position. `Error` is a recovery placeholder.
pub type Decl = enum {
    Import(ImportDecl)
    Function(FunctionDecl)
    Type(TypeDecl)
    Const(ConstDecl)
    Context(ContextDecl)
    Test(TestDecl)
    GenDef(GenDef)
    GenInvoke(GenInvoke)
    IfDirective(IfDirectiveDecl)
    Error(DeclError)
}

// Decl-level attributes. `Foreign`, `Inline`, `Intrinsic`, `Simd` are flag-shaped;
// `Deprecated(msg?)` carries an optional reason string; `Allow(codes)` names the diagnostic codes
// that stay silent within the declaration's span. Several directives may attach to the same
// declaration; order is source order.
pub type DeclAttribute = enum {
    Foreign
    Inline
    Intrinsic
    Simd
    Deprecated(String?)
    Allow(String[])
}

// Whether a declaration's directives mark it as a SIMD vector type.
pub fn is_simd_directive(ds: DeclAttribute[]) bool {
    for &d in ds {
        let f = d.* match { Simd => true, _ => false }
        if f {
            return true
        }
    }
    return false
}

// Whether a declaration's directives mark it as a foreign import.
pub fn is_foreign_directive(ds: DeclAttribute[]) bool {
    for &d in ds {
        let f = d.* match { Foreign => true, _ => false }
        if f {
            return true
        }
    }
    return false
}

// The `#deprecated` reason attached to a declaration, or null when it carries no such directive. A
// bare `#deprecated` yields the empty string - present, but with nothing to say.
pub fn deprecation_of(ds: DeclAttribute[]) String? {
    for &d in ds {
        d.* match {
            Deprecated(msg) => return Some(msg.unwrap_or(""))
            _ => {}
        }
    }
    return null
}

// `[pub] import path.to.module`
pub type ImportDecl = struct {
    span: SourceSpan
    is_pub: bool
    path: String[]
}

// `[pub] [directives] fn name(params) ret? where? { body }` `body` is None for `#foreign fn`
// declarations (no `{ ... }`). `return_type` is None for void-returning functions (no type after
// `)`).
pub type FunctionDecl = struct {
    span: SourceSpan
    is_pub: bool
    directives: DeclAttribute[]
    name: String
    params: FunctionParam[]
    return_type: &TypeExpr?
    bounds: TypeBound[]
    body: &BlockExpr?
}

// One `param: bound` entry of a `where` clause (RFC-035). `bound` is a contract: `copyable`, a
// named or anonymous contract, a function type, or a `+` combination of them. `path` holds the
// associated-type names after `param` in `I.Item: Hash` (RFC-036), empty for a plain parameter.
// `subject_spans[k]` covers the subject up to its k-th name: `I`, then `I.Item`.
pub type TypeBound = struct {
    span: SourceSpan
    param: String
    path: String[]
    subject_spans: SourceSpan[]
    bound: &TypeExpr
}

// One parameter slot. `is_variadic` is true for the trailing `..xs: T` form. `default_value`
// carries the post-`=` expression when a default is given. Only the last parameter may legally be
// variadic; not enforced at the type level.
pub type FunctionParam = struct {
    span: SourceSpan
    name: String
    type_expr: &TypeExpr
    // The field name avoids `default`, which is a C reserved word and collides at C codegen time
    // after name mangling.
    default_value: &Expr?
    is_variadic: bool
    // `x: move T` - the function takes ownership of its argument (RFC-033). Without it a by-value
    // slot only reads.
    is_move: bool
    // `x: &move T` - a slot the function may take the value out of, on the obligation of leaving
    // one behind. Declared in `core` alone.
    is_slot: bool
}

// `[pub] [directives] type Name = TypeExpr`
// FLang has exactly one declaration form for types. Generics live on the RHS TypeExpr (`struct(T) {
// ... }`, `enum(T, E) { ... }`); a plain alias such as `type Index = usize` reuses the same shape
// with a `Named` body.
pub type TypeDecl = struct {
    span: SourceSpan
    is_pub: bool
    directives: DeclAttribute[]
    name: String
    body: &TypeExpr
}

// `[pub] const name(: T)? = value`
pub type ConstDecl = struct {
    span: SourceSpan
    is_pub: bool
    name: String
    type_annotation: &TypeExpr?
    value: &Expr
}

// `[pub] context name: T = default` - one field of the program's runtime context (RFC-038). The
// parser requires both the type and the default; a missing one projects as an `Error` node.
pub type ContextDecl = struct {
    span: SourceSpan
    is_pub: bool
    name: String
    // The name token's own span; equals `span` when error recovery produced no name.
    name_span: SourceSpan
    type_annotation: &TypeExpr
    value: &Expr
}

// `test "label" { ... }`
pub type TestDecl = struct {
    span: SourceSpan
    directives: DeclAttribute[]
    label: String
    body: &BlockExpr
}

// `#define(name, P1: K1, P2: K2, ...) { template body }` The template body is preserved as a CST
// byte range for v1; expansion reads back from the CST when the source-generator pass runs.
pub type GenDef = struct {
    span: SourceSpan
    name: String
    params: GenParam[]
    body_start: usize
    body_end: usize
}

// One parameter to a `#define`. `kind` is the parameter-kind keyword (`Ident`, `Type`) verbatim
// from source; `variadic` marks `..Name: Kind` (only legal last).
pub type GenParam = struct {
    span: SourceSpan
    name: String
    kind: String
    variadic: bool
}

// `#name(arg1, arg2, ...)` at top level - invokes a source generator.
pub type GenInvoke = struct {
    span: SourceSpan
    name: String
    args: GenArg[]
}

// One generator argument: a bare identifier or a type expression.
pub type GenArg = enum {
    IdentArg(GenIdentArg)
    TypeArg(TypeExpr)
}

pub type GenIdentArg = struct {
    span: SourceSpan
    name: String
}

// `#if cond { decls... } else { decls... }` at file/module level.
pub type IfDirectiveDecl = struct {
    span: SourceSpan
    condition: &Expr
    then_decls: Decl[]
    else_decls: Decl[]
}

// Recovery placeholder. The parser produced unrecognised tokens at top level; the CST keeps the
// bytes verbatim, the AST records the span so downstream phases can skip without losing the whole
// file.
pub type DeclError = struct {
    span: SourceSpan
}

// ─────────────────────────────────────────────────────────────────────────
// Statements - only valid inside a function body or a block expression
// ─────────────────────────────────────────────────────────────────────────

pub type Stmt = enum {
    Let(LetStmt)
    Expression(ExpressionStmt)
    Return(ReturnStmt)
    Defer(DeferStmt)
    Break(BreakStmt)
    Continue(ContinueStmt)
    For(ForStmt)
    While(WhileStmt)
    Loop(LoopStmt)
    IfDirective(IfDirectiveStmt)
}

// `let|const name(: T)? (= init)?` - LHS is an identifier only. There is no destructuring `let` in
// FLang (destructure via `match`). At least one of `type_annotation` and `init` is set; both
// omitted is `let x` alone, rejected by the parser upstream. Uninit `let x: T` zero-initializes.
pub type LetStmt = struct {
    span: SourceSpan
    is_const: bool
    name: String
    // The name token's own span; equals `span` when error recovery produced no name.
    name_span: SourceSpan
    type_annotation: &TypeExpr?
    init: &Expr?
}

// A bare expression terminated as a statement; the result is discarded. Includes UFCS calls,
// assignments, and any other expression used for its side effect.
pub type ExpressionStmt = struct {
    span: SourceSpan
    expr: &Expr
}

// `return expr?` - `value` is None for void-return-position `return`.
pub type ReturnStmt = struct {
    span: SourceSpan
    value: &Expr?
}

// `defer expr` - `expr` is evaluated at the end of the enclosing scope in LIFO order with sibling
// defers.
pub type DeferStmt = struct {
    span: SourceSpan
    expr: &Expr
}

// Bare `break` / `continue`. FLang has no loop labels.
pub type BreakStmt = struct {
    span: SourceSpan
}

pub type ContinueStmt = struct {
    span: SourceSpan
}

// `for name in iterable { body }` - loop variable is a single identifier. FLang has no
// tuple-destructuring `for (k, v) in iter` form. Loops do not yield a value; they are statements,
// not expressions.
pub type ForStmt = struct {
    span: SourceSpan
    var_name: String
    // The loop variable token's own span; equals `span` when error recovery produced no name.
    var_span: SourceSpan
    // `for &x in xs`: iterate through `iter_ref` (elements by reference).
    by_ref: bool
    iterable: &Expr
    body: &BlockExpr
}

// `while cond { body }` - statement form, evaluates to no value.
pub type WhileStmt = struct {
    span: SourceSpan
    condition: &Expr
    body: &BlockExpr
}

// `loop { body }` - unconditional, statement form. Exit via `break` or `return`.
pub type LoopStmt = struct {
    span: SourceSpan
    body: &BlockExpr
}

// `#if cond { stmts... } else { stmts... }` inside a function body.
pub type IfDirectiveStmt = struct {
    span: SourceSpan
    condition: &Expr
    then_stmts: Stmt[]
    else_stmts: Stmt[]
}

// ─────────────────────────────────────────────────────────────────────────
// Expressions
// ─────────────────────────────────────────────────────────────────────────

pub type Expr = enum {
    // Literals
    Lit(LiteralExpr)
    InterpolatedString(InterpolatedStringExpr)

    // Composite literals
    ArrayLit(ArrayLiteralExpr)
    TupleLit(TupleLiteralExpr)
    StructLit(StructLiteralExpr)

    // References / access
    Identifier(IdentifierExpr)
    MemberAccess(MemberAccessExpr)
    AddressOf(AddressOfExpr)
    Move(MoveExpr)
    Dereference(DereferenceExpr)
    NullPropagation(NullPropagationExpr)
    Index(IndexExpr)
    Call(CallExpr)
    Cast(CastExpr)

    // Operators
    Binary(BinaryExpr)
    Unary(UnaryExpr)
    Range(RangeExpr)
    Coalesce(CoalesceExpr)
    Try(TryExpr)
    Assignment(AssignmentExpr)

    // Control flow as expression - Block, If, Match yield a value. For / While / Loop are
    // statements (see Stmt).
    Block(BlockExpr)
    If(IfExpr)
    Match(MatchExpr)

    // Anonymous function
    Lambda(LambdaExpr)

    // Runtime context (RFC-038): bare `context`, and `context(args) { body }`. A field read is a
    // `MemberAccess` on a `Context` receiver.
    Context(ContextExpr)
    ContextBind(ContextBindExpr)

    // Recovery
    Error(ErrorExpr)
}

// A literal expression. The seven literal kinds are shared with patterns (see
// `LiteralPattern.value`) - same payload structs, narrower outer enum where the grammar is
// narrower.
pub type LiteralExpr = struct {
    span: SourceSpan
    value: LiteralValue
}

// Shared literal payload between expressions and patterns. `Null` has no payload - there is only
// one null literal value.
pub type LiteralValue = enum {
    Int(IntLiteral)
    Float(FloatLiteral)
    String(StringLiteral)
    Char(CharLiteral)
    Byte(ByteLiteral)
    Bool(BoolLiteral)
    Null
}

// Integer literal - value preserved as the source text; suffix and base are separate so downstream
// phases don't re-parse. `text` includes `0x`, `0b`, `_` digit separators if any. Empty `suffix`
// means unsuffixed (subject to constrain-then-resolve at type-check time).
pub type IntLiteral = struct {
    span: SourceSpan
    text: String
    suffix: String
}

// Float literal. `text` is the raw source (`1.5e10`, `3.14`, `1_000.5`); `suffix` is `"f32"` /
// `"f64"` / `""` (unsuffixed).
pub type FloatLiteral = struct {
    span: SourceSpan
    text: String
    suffix: String
}

// String literal - raw source slice excluding the surrounding quotes. Escape sequences are NOT
// expanded at parse time; that is a later concern when the literal becomes a runtime value.
pub type StringLiteral = struct {
    span: SourceSpan
    text: String
}

// `'A'`, `'\n'` - single-character literal. `text` excludes the surrounding single quotes; escapes
// are not yet expanded.
pub type CharLiteral = struct {
    span: SourceSpan
    text: String
}

// `b'A'` - byte literal. `text` excludes the `b'` prefix and trailing `'`.
pub type ByteLiteral = struct {
    span: SourceSpan
    text: String
}

// `true` / `false` - boolean literal.
pub type BoolLiteral = struct {
    span: SourceSpan
    value: bool
}

// `$"text {expr} text"`, `$(cap)"…"`, `$(&alloc)"…"`, `$(cap, &alloc)"…"`,
// and `$sb"…"` (write-into-builder). `target` disambiguates the four
// new-string forms (a call to `string_builder(args...)` with 0-2 args) from the into-builder form;
// `parts` is the alternating text/hole sequence between the quotes.
pub type InterpolatedStringExpr = struct {
    span: SourceSpan
    target: InterpolationTarget
    parts: InterpolationPart[]
}

// `NewString(args)` covers `$"…"`, `$(cap)"…"`, `$(&alloc)"…"`,
// `$(cap, &alloc)"…"` uniformly as a call to `string_builder` with 0,
// 1, or 2 arguments - overload resolution at type-check time picks the right `string_builder`
// signature. `IntoBuilder(builder)` is the
// distinct write-into form `$sb"…"`.
pub type InterpolationTarget = enum {
    NewString(Expr[])
    IntoBuilder(&Expr)
}

// One segment of an interpolated string: either raw text between holes or a `{expr}` hole.
pub type InterpolationPart = enum {
    Text(String)
    Hole(InterpolationHole)
}

pub type InterpolationHole = struct {
    span: SourceSpan
    expr: &Expr
    // None when the user wrote `{x}` with no format spec; carries the post-colon text verbatim for
    // `{x:04}` style format directives.
    format: String?
}

// `[1, 2, 3]` or `[v; n]` - array literal. The two shapes share the outer node and split on `kind`.
pub type ArrayLiteralExpr = struct {
    span: SourceSpan
    kind: ArrayLiteralKind
}

pub type ArrayLiteralKind = enum {
    // `[1, 2, 3]` - element-by-element.
    Elements(Expr[])
    // `[value; count]` - count copies of value.
    Repeat(RepeatLiteral)
}

pub type RepeatLiteral = struct {
    span: SourceSpan
    value: &Expr
    count: &Expr
}

// `(a, b, ...)` - tuple literal. The empty tuple `()` is the unit value. A single-element tuple is
// written `(x,)` with a trailing comma.
pub type TupleLiteralExpr = struct {
    span: SourceSpan
    elements: Expr[]
}

// `Point { x = 10, y = 20 }` and `.{ x = 10, y }` collapse into one node - the only difference is
// whether a target type is named. `type_expr` is None for anonymous form (target inferred from
// context); Some for nominal construction.
pub type StructLiteralExpr = struct {
    span: SourceSpan
    type_expr: &TypeExpr?
    fields: StructFieldInit[]
}

// Field initializer inside a struct literal. `value` is None when the user wrote shorthand (`Point
// { x, y }`) - the identifier `x` is reused as the value at type-check time.
pub type StructFieldInit = struct {
    span: SourceSpan
    name: String
    value: &Expr?
}

// Bare identifier reference: a name to resolve at type-check time.
pub type IdentifierExpr = struct {
    span: SourceSpan
    name: String
}

// `receiver.member` - direct field access AND UFCS dispatch base; the resolution choice happens at
// type-check time. Wrapping a MemberAccess in a Call (`a.b()`) becomes a UFCS call.
pub type MemberAccessExpr = struct {
    span: SourceSpan
    receiver: &Expr
    member: String
}

// `&operand` - address-of, producing a reference value.
pub type AddressOfExpr = struct {
    span: SourceSpan
    operand: &Expr
}

// `move operand` - a transfer, not a copy. Emits nothing; the operand's own type is the result.
pub type MoveExpr = struct {
    span: SourceSpan
    operand: &Expr
}

// `operand.*` - explicit dereference.
pub type DereferenceExpr = struct {
    span: SourceSpan
    operand: &Expr
}

// `receiver?.member` - short-circuit on null receiver.
pub type NullPropagationExpr = struct {
    span: SourceSpan
    receiver: &Expr
    member: String
}

// `receiver[index]` - `index` is any expression. The slice forms (`a[..]`, `a[i..]`, `a[..j]`,
// `a[i..j]`, `a[i..=j]`) appear as `IndexExpr` with `index` being a `RangeExpr`; user-defined
// indexing like `dict["key"]` carries an arbitrary `index` expression. Resolution of value-form vs
// ref-form indexing happens at type-check time.
pub type IndexExpr = struct {
    span: SourceSpan
    receiver: &Expr
    index: &Expr
}

// `callee(args)` - covers regular calls, UFCS dispatch (when `callee` is a `MemberAccess`), and
// `op_call` invocation. Resolution happens at type-check time.
pub type CallExpr = struct {
    span: SourceSpan
    callee: &Expr
    args: CallArgument[]
}

// One slot in a call's argument list - either positional or named. Named arguments may appear
// interleaved with positional ones; ordering rules are enforced later.
pub type CallArgument = enum {
    Positional(&Expr)
    Named(NamedCallArgument)
}

pub type NamedCallArgument = struct {
    span: SourceSpan
    name: String
    value: &Expr
}

// `expr as TypeExpr`
pub type CastExpr = struct {
    span: SourceSpan
    operand: &Expr
    target: &TypeExpr
}

// `lhs op rhs` for every infix operator. Operator desugarings to the underlying `op_*` calls happen
// during lowering, not here.
pub type BinaryExpr = struct {
    span: SourceSpan
    op: BinaryOp
    lhs: &Expr
    rhs: &Expr
}

// Every infix operator. `UShr` is the logical right shift `>>>`.
pub type BinaryOp = enum {
    Add Sub Mul Div Mod
    Eq Ne Lt Gt Le Ge
    And Or
    BitAnd BitOr BitXor
    Shl Shr UShr
}

// `op operand` - prefix unary.
pub type UnaryExpr = struct {
    span: SourceSpan
    op: UnaryOp
    operand: &Expr
}

pub type UnaryOp = enum {
    Neg // `-`
    Not // `!`
    BitNot // `~`
}

// `start..end`, `start..=end`, `..end`, `start..`, `..` - every bound is optional, inclusivity is a
// flag. Distinct from `RangePattern` because the grammar accepts ranges only in select positions.
pub type RangeExpr = struct {
    span: SourceSpan
    start: &Expr?
    end: &Expr?
    inclusive: bool
}

// `lhs ?? rhs` - null-coalescing. Yields `lhs` if non-null, else `rhs`.
pub type CoalesceExpr = struct {
    span: SourceSpan
    lhs: &Expr
    rhs: &Expr
}

// `operand?` postfix try - desugars to a match against the implementing `op_try` at lowering time.
pub type TryExpr = struct {
    span: SourceSpan
    operand: &Expr
}

// `lhs = rhs`. FLang has no compound-assign operators (`+=`, `-=`, etc.).
pub type AssignmentExpr = struct {
    span: SourceSpan
    lhs: &Expr
    rhs: &Expr
}

// `{ stmts...; trailing? }` - the last statement without a terminator becomes the trailing
// expression. `trailing` is None when the block evaluates to unit.
pub type BlockExpr = struct {
    span: SourceSpan
    stmts: Stmt[]
    trailing: &Expr?
}

// `if cond { then } else { else }` and `if cond { then } else if … { … }`.
// Else-if is encoded as `else_branch` being another `If` - there is no separate "else-if" node.
pub type IfExpr = struct {
    span: SourceSpan
    condition: &Expr
    then_branch: &BlockExpr
    else_branch: ElseBranch
}

// Tail of an `if`: missing, a block, or another chained if-else. `NoElse` rather than `None` to
// avoid the unqualified-variant clash against `Option.None` (see docs/known-issues.md).
pub type ElseBranch = enum {
    NoElse
    Block(&BlockExpr)
    If(&IfExpr)
}

// `scrutinee match { arm, arm, ... }`
pub type MatchExpr = struct {
    span: SourceSpan
    scrutinee: &Expr
    arms: MatchArm[]
}

// One arm of a match. `guard` carries the post-`if` condition when the arm is `pat if cond =>
// body`.
pub type MatchArm = struct {
    span: SourceSpan
    pattern: &Pattern
    guard: &Expr?
    body: &Expr
}

// `{ params => body }` (RFC-039) - anonymous function; `return_type` is set only by the removed
// `fn(params) R { body }` form, still projected for error recovery (E1053). May capture surrounding
// locals (RFC-014 Phase 2 by-value capture). Same shape as `FunctionDecl` minus name, directives,
// and visibility - none of which apply to lambdas.
pub type LambdaExpr = struct {
    span: SourceSpan
    params: FunctionParam[]
    return_type: &TypeExpr?
    body: &BlockExpr
    // `{ body }` with no `=>`: `params` holds one unannotated `it`, spanning the `{`, which the
    // expected callable's arity keeps (one) or drops (none).
    arrowless: bool
    // Written after the call's `)` or name; the last positional argument of its call.
    trailing: bool
}

// The parameters the lambda takes when its call expects `arity`: an arrow-less lambda's `it` is
// kept only at one.
pub fn params_at(self: &LambdaExpr, arity: usize) FunctionParam[] {
    if self.arrowless and arity == 0 {
        return self.params[0..0]
    }
    return self.params
}

// Bare `context`: a copy of the current context, of type `Context`.
pub type ContextExpr = struct {
    span: SourceSpan
}

// `context(base?, name = value, ...) { body }` - `body` runs under a new context: a copy of `base`
// (the current context when absent) with the named fields replaced. `args` keeps the call grammar;
// the checker enforces at most one positional, first.
pub type ContextBindExpr = struct {
    span: SourceSpan
    args: CallArgument[]
    body: &BlockExpr
}

// Recovery placeholder. The parser produced unrecognised tokens where an expression was expected;
// the span lets downstream phases skip without losing surrounding structure.
pub type ErrorExpr = struct {
    span: SourceSpan
}

// The source span of any expression. Used as node identity for type-check results and lowering. The
// source span of a pattern, mirroring `expr_span`. Consumers key per-node results (types, resolved
// variants) by span fingerprint, so a pattern needs the same accessor an expression has.
pub fn pattern_span(p: &Pattern) SourceSpan {
    return p.* match {
        Wildcard(x) => x.span
        Variable(x) => x.span
        Literal(x) => x.span
        EnumVariant(x) => x.span
        Or(x) => x.span
        Range(x) => x.span
        Struct(x) => x.span
        Tuple(x) => x.span
        Error(x) => x.span
    }
}

pub fn type_expr_span(t: &TypeExpr) SourceSpan {
    return t.* match {
        Named(n) => n.span
        GenericBind(g) => g.span
        Reference(r) => r.span
        Optional(o) => o.span
        Array(a) => a.span
        Slice(s) => s.span
        Tuple(tu) => tu.span
        Function(f) => f.span
        AnonStruct(st) => st.span
        AnonEnum(en) => en.span
        Contract(c) => c.span
        Combined(c) => c.span
        Projection(p) => p.span
        Error(er) => er.span
    }
}

pub fn expr_span(e: &Expr) SourceSpan {
    return e.* match {
        Lit(x) => x.span
        InterpolatedString(x) => x.span
        ArrayLit(x) => x.span
        TupleLit(x) => x.span
        StructLit(x) => x.span
        Identifier(x) => x.span
        MemberAccess(x) => x.span
        AddressOf(x) => x.span
        Move(x) => x.span
        Dereference(x) => x.span
        NullPropagation(x) => x.span
        Index(x) => x.span
        Call(x) => x.span
        Cast(x) => x.span
        Binary(x) => x.span
        Unary(x) => x.span
        Range(x) => x.span
        Coalesce(x) => x.span
        Try(x) => x.span
        Assignment(x) => x.span
        Block(x) => x.span
        If(x) => x.span
        Match(x) => x.span
        Lambda(x) => x.span
        Context(x) => x.span
        ContextBind(x) => x.span
        Error(x) => x.span
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Patterns - only appear in match arms
// ─────────────────────────────────────────────────────────────────────────

pub type Pattern = enum {
    Wildcard(WildcardPattern)
    Variable(VariablePattern)
    Literal(LiteralPattern)
    EnumVariant(EnumVariantPattern)
    Or(OrPattern)
    Range(RangePattern)
    Struct(StructPattern)
    Tuple(TuplePattern)
    // A pattern the front end could not represent. Distinct from `Wildcard`: a wildcard matches
    // everything *by intent*, whereas this records that the source said something else and it was
    // lost. Consumers must refuse to lower a match containing one rather than treat it as
    // irrefutable and silently take the arm.
    Error(ErrorPattern)
}

pub type ErrorPattern = struct {
    span: SourceSpan
}

// `_` and the `else` arm catch-all collapse into Wildcard. The CST preserves the keyword
// distinction; the AST does not.
pub type WildcardPattern = struct {
    span: SourceSpan
}

// A bare identifier in pattern position - binds the matched value to `name`. Distinct from a
// literal pattern that happens to be an identifier-looking enum variant; the projector decides
// which based on scope.
pub type VariablePattern = struct {
    span: SourceSpan
    name: String
}

// `42`, `'A'`, `"hi"`, `b'0'`, `true`, `null` - restricted to the seven literal forms via the
// `Literal` enum (same as `LiteralExpr`).
pub type LiteralPattern = struct {
    span: SourceSpan
    value: LiteralValue
}

// `Some(x)`, `Move(x, y)`, `Color.Red`, `Red`. `qualifier` is the optional `EnumName.` prefix;
// `name` is the variant. `payloads` is the parenthesised destructure list, empty for nullary
// variants.
pub type EnumVariantPattern = struct {
    span: SourceSpan
    qualifier: String?
    name: String
    payloads: Pattern[]
}

// `A | B | C` - matches if any alternative matches. Alternatives must bind the same set of variable
// names; checked at type-check time.
pub type OrPattern = struct {
    span: SourceSpan
    alternatives: Pattern[]
}

// `0..10`, `0..=9`, `..n`, `n..` - same shape as `RangeExpr` but distinct type so the grammar's
// position restriction is type-encoded.
pub type RangePattern = struct {
    span: SourceSpan
    start: &Expr?
    end: &Expr?
    inclusive: bool
}

// `Point { x, y = pat, .. }`. `has_rest` records the trailing `..` placeholder; without it, every
// field must be listed.
pub type StructPattern = struct {
    span: SourceSpan
    type_expr: &TypeExpr
    fields: StructPatternField[]
    has_rest: bool
}

// One field slot inside a struct pattern. `binding` is None for shorthand (`{ x, y }`) -
// semantically equivalent to a VariablePattern of the same name.
pub type StructPatternField = struct {
    span: SourceSpan
    name: String
    binding: &Pattern?
}

// `(a, b, ...)` - positional destructure of a tuple value.
pub type TuplePattern = struct {
    span: SourceSpan
    elements: Pattern[]
}

// ─────────────────────────────────────────────────────────────────────────
// Type expressions
// ─────────────────────────────────────────────────────────────────────────

pub type TypeExpr = enum {
    Named(NamedType)
    GenericBind(GenericBindType)
    Reference(ReferenceType)
    Optional(OptionalType)
    Array(ArrayType)
    Slice(SliceType)
    Tuple(TupleType)
    Function(FunctionType)
    AnonStruct(AnonStructType)
    AnonEnum(AnonEnumType)
    Contract(ContractType)
    Combined(CombinedType)
    Projection(ProjectionType)
    Error(ErrorType)
}

// `Name`, `Name(T, U)` - named type with optional generic argument list.
pub type NamedType = struct {
    span: SourceSpan
    name: String
    generic_args: TypeExpr[]
    // `Item = T` and `Item: Bound` arguments of a contract application (RFC-036), after the
    // positional ones.
    assoc_args: AssocArg[]
}

// `Item = T` (pinned) or `Item: Bound` - a constraint on a contract's associated type.
pub type AssocArg = struct {
    span: SourceSpan
    name: String
    pinned: bool
    ty: &TypeExpr
}

// `X.Item` - the associated type `Item` of the contract bounding `X` (RFC-036). `base` is a named
// type parameter, `Self`, or another projection.
pub type ProjectionType = struct {
    span: SourceSpan
    base: &TypeExpr
    name: String
}

// `$T` - introduces a generic parameter at first appearance in a function parameter type.
// Semantically valid only in `FunctionDecl.params` / `LambdaExpr.params`; the AST accepts it
// everywhere and a later pass flags misuse.
pub type GenericBindType = struct {
    span: SourceSpan
    name: String
}

// `&T`
pub type ReferenceType = struct {
    span: SourceSpan
    inner: &TypeExpr
}

// `T?` - sugar for `Option(T)`. `&T?` is `Option(&T)`, encoded as `Optional(inner =
// Reference(...))`.
pub type OptionalType = struct {
    span: SourceSpan
    inner: &TypeExpr
}

// `[T; N]` - fixed-size array. `length` is an expression because it may reference a constant (e.g.
// `[u8; BUFFER_SIZE]`).
pub type ArrayType = struct {
    span: SourceSpan
    element: &TypeExpr
    length: &Expr
}

// `T[]` - slice. `&T[]` is a reference to a slice; the AST nests `Reference(inner = Slice(...))`.
pub type SliceType = struct {
    span: SourceSpan
    element: &TypeExpr
}

// `(A, B, ...)` - tuple type. The empty tuple `()` is the unit type. A single-element tuple is
// `(A,)` (with trailing comma); whether the trailing comma is present is a CST concern, not an AST
// one.
pub type TupleType = struct {
    span: SourceSpan
    elements: TypeExpr[]
}

// `fn(P1, move P2) R` - function type. `return_type` is None for void. `param_names[i]` is the
// optional `name:` before `params[i]` ("" when unnamed) and `param_moves[i]` whether it is declared
// `move`; both always the same length as `params`.
pub type FunctionType = struct {
    span: SourceSpan
    params: TypeExpr[]
    param_names: String[]
    param_moves: bool[]
    return_type: &TypeExpr?
}

// `struct(T1, T2) { field: T, ... }` - generics are optional and live on the type expression
// itself. Same node whether named (RHS of a `TypeDecl`) or anonymous in argument position.
pub type AnonStructType = struct {
    span: SourceSpan
    generics: GenericParam[]
    fields: StructField[]
}

// One field declaration inside a struct type. FLang struct fields have no default initializer -
// `name: T` and `owned name: T` are the only shapes.
pub type StructField = struct {
    span: SourceSpan
    name: String
    type_expr: &TypeExpr
    // `owned name: T` - the field holds a resource the value must release (RFC-028).
    owned: bool
}

// `enum(T) { Variant, Variant(T) }` - generics optional. Same node whether named (RHS of TypeDecl)
// or anonymous in type position.
pub type AnonEnumType = struct {
    span: SourceSpan
    generics: GenericParam[]
    variants: EnumVariant[]
}

// One variant inside an enum type. `payloads` is empty for nullary variants (`Red`); non-empty for
// tuple-style payloads (`Move(i32, i32)`). `explicit_tag` carries `= N` for naked enums (`Less =
// -1`).
pub type EnumVariant = struct {
    span: SourceSpan
    name: String
    payloads: TypeExpr[]
    explicit_tag: &Expr?
}

// One type parameter of a struct, enum or contract: `T` or `T: Bound` (RFC-036).
pub type GenericParam = struct {
    span: SourceSpan
    name: String
    bound: &TypeExpr?
}

// `contract(T: B) { fn next(self: &Self) T?  type S: Iterator }` (RFC-035). Same node whether named
// (RHS of a `TypeDecl`) or anonymous in bound position.
pub type ContractType = struct {
    span: SourceSpan
    generics: GenericParam[]
    requirements: ContractRequirement[]
    assoc_types: AssocType[]
}

// `fn name(params) ret` - a function of this name and shape must be callable on `Self`.
pub type ContractRequirement = struct {
    span: SourceSpan
    name: String
    signature: FunctionType
}

// `type S` / `type S: Bound` - a type the contract solves rather than takes. `type S = T` is
// derived instead: `value` is set and `bound` is not.
pub type AssocType = struct {
    span: SourceSpan
    name: String
    bound: &TypeExpr?
    value: &TypeExpr?
}

// `A + B + ...` - satisfied when every part is. Parts are contracts.
pub type CombinedType = struct {
    span: SourceSpan
    parts: TypeExpr[]
}

// Recovery placeholder for unrecognised type-expression tokens.
pub type ErrorType = struct {
    span: SourceSpan
}

// ─────────────────────────────────────────────────────────────────────────
// Signature predicates
// ─────────────────────────────────────────────────────────────────────────

// Whether the declaration introduces a generic parameter (`$T`) anywhere in its signature. `$T`
// binds at its first appearance in a parameter type, so this is the whole test - a use of an
// already-bound `T` reads as a plain `Named("T")`. Shared by the checker (generic templates are
// only validated per instantiation) and lowering (templates never emit).
pub fn declares_generic(decl: &FunctionDecl) bool {
    for i in 0..decl.params.len {
        if mentions_generic(decl.params[i].type_expr) {
            return true
        }
    }
    for &b in decl.bounds {
        if mentions_generic(b.bound) {
            return true
        }
    }
    return decl.return_type match {
        Some(rt) => mentions_generic(rt)
        None => false
    }
}

// The `$T` names a function's parameters, return type and `where` bounds introduce, each once, in
// order.
pub fn generic_names(decl: &FunctionDecl, out: &List(String)) {
    for &p in decl.params {
        collect_generic_names(p.type_expr, out)
    }
    decl.return_type match {
        Some(rt) => collect_generic_names(rt, out)
        None => {}
    }
    for &b in decl.bounds {
        collect_generic_names(b.bound, out)
    }
}

// The `$T` names a function's `where` bounds introduce, each once, in order.
pub fn bound_generic_names(decl: &FunctionDecl, out: &List(String)) {
    for &b in decl.bounds {
        collect_generic_names(b.bound, out)
    }
}

fn collect_generic_names(te: &TypeExpr, out: &List(String)) {
    te.* match {
        GenericBind(g) => {
            if !out.contains(g.name) {
                out.push(g.name)
            }
        }
        Named(n) => {
            collect_generic_list(n.generic_args, out)
            for &a in n.assoc_args {
                collect_generic_names(a.ty, out)
            }
        }
        Reference(r) => collect_generic_names(r.inner, out)
        Optional(o) => collect_generic_names(o.inner, out)
        Array(a) => collect_generic_names(a.element, out)
        Slice(sl) => collect_generic_names(sl.element, out)
        Tuple(t) => collect_generic_list(t.elements, out)
        Function(f) => {
            collect_generic_list(f.params, out)
            f.return_type match {
                Some(rt) => collect_generic_names(rt, out)
                None => {}
            }
        }
        Combined(c) => collect_generic_list(c.parts, out)
        Contract(c) => {
            for &r in c.requirements {
                collect_generic_list(r.signature.params, out)
                r.signature.return_type match {
                    Some(rt) => collect_generic_names(rt, out)
                    None => {}
                }
            }
        }
        _ => {}
    }
}

fn collect_generic_list(tes: TypeExpr[], out: &List(String)) {
    for &te in tes {
        collect_generic_names(te, out)
    }
}

pub fn mentions_generic(te: &TypeExpr) bool {
    return te.* match {
        GenericBind(_) => true
        Named(n) => any_generic(n.generic_args) or assoc_generic(n.assoc_args)
        Reference(r) => mentions_generic(r.inner)
        Optional(o) => mentions_generic(o.inner)
        Array(a) => mentions_generic(a.element)
        Slice(sl) => mentions_generic(sl.element)
        Tuple(t) => any_generic(t.elements)
        Function(f) => function_mentions_generic(&f)
        AnonStruct(_) => false
        AnonEnum(_) => false
        Contract(c) => contract_mentions_generic(&c)
        Combined(c) => any_generic(c.parts)
        Projection(_) => false
        Error(_) => false
    }
}

// Whether `te` names `name` as a type: `name` itself, `name.Item`, or anywhere inside.
pub fn mentions_name(te: &TypeExpr, name: String) bool {
    return te.* match {
        Named(n) => n.name == name or any_names(n.generic_args, name)
            or assoc_names(n.assoc_args, name)
        Projection(p) => mentions_name(p.base, name)
        Reference(r) => mentions_name(r.inner, name)
        Optional(o) => mentions_name(o.inner, name)
        Array(a) => mentions_name(a.element, name)
        Slice(sl) => mentions_name(sl.element, name)
        Tuple(t) => any_names(t.elements, name)
        Function(f) => function_names(&f, name)
        Combined(c) => any_names(c.parts, name)
        Contract(c) => contract_names(&c, name)
        _ => false
    }
}

fn any_names(tes: TypeExpr[], name: String) bool {
    for &te in tes {
        if mentions_name(te, name) {
            return true
        }
    }
    return false
}

fn assoc_names(args: AssocArg[], name: String) bool {
    for &a in args {
        if mentions_name(a.ty, name) {
            return true
        }
    }
    return false
}

fn function_names(f: &FunctionType, name: String) bool {
    if any_names(f.params, name) {
        return true
    }
    return f.return_type match {
        Some(rt) => mentions_name(rt, name)
        None => false
    }
}

fn contract_names(c: &ContractType, name: String) bool {
    for &r in c.requirements {
        if function_names(&r.signature, name) {
            return true
        }
    }
    return false
}

fn assoc_generic(args: AssocArg[]) bool {
    for &a in args {
        if mentions_generic(a.ty) {
            return true
        }
    }
    return false
}

fn contract_mentions_generic(c: &ContractType) bool {
    for &r in c.requirements {
        if function_mentions_generic(&r.signature) {
            return true
        }
    }
    return false
}

fn function_mentions_generic(f: &FunctionType) bool {
    if any_generic(f.params) {
        return true
    }
    return f.return_type match {
        Some(rt) => mentions_generic(rt)
        None => false
    }
}

fn any_generic(tes: TypeExpr[]) bool {
    for &te in tes {
        if mentions_generic(te) {
            return true
        }
    }
    return false
}
