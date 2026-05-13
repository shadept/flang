// Abstract Syntax Tree — semantic view computed on demand over the CST.
//
// AST nodes wrap meaning; CST nodes wrap source bytes. The type checker
// and every downstream phase consume the AST. The formatter and refactor
// tools consume the CST. Both views share node identity through the
// `SourceSpan` byte range each AST node carries.
//
// Category-split enums (Decl / Stmt / Expr / Pattern / TypeExpr) encode
// the grammar in the type system: an `Expr` can never hold a `Stmt`, a
// `Stmt` can never hold a `Decl`. Recursive children store as `&T`
// references into `Module.arena`; non-recursive children store by value.
//
// Strings (names, literal texts) are non-owning `String` views into the
// original source buffer. The source must outlive the Module.
//
// "Only representable states" is the standing rule. A handful of
// concessions (`Break`/`Continue` valid in any Stmt position regardless
// of enclosing scope; `GenericBind` valid in any TypeExpr position
// instead of param-types only) keep the projector tractable — those are
// the responsibility of later validation passes, not the type system.

import std.allocator
import std.list
import std.option
import std.string
import flang_core.span

// ─────────────────────────────────────────────────────────────────────────
// Module — top-level container
// ─────────────────────────────────────────────────────────────────────────

// One parsed source file. Owns an `ArenaAllocator` that backs every
// recursive child reference (`&Expr`, `&TypeExpr`, `&Pattern`, `&IfExpr`)
// in the tree. Calling `deinit()` releases the entire AST in a single
// bulk free.
pub type Module = struct {
    span: SourceSpan
    decls: List(Decl)
    arena: ArenaAllocator
}

pub fn deinit(self: &Module) {
    self.decls.deinit()
    self.arena.deinit()
}

// ─────────────────────────────────────────────────────────────────────────
// Declarations — top-level constructs in a module
// ─────────────────────────────────────────────────────────────────────────

// One top-level form. Most variants are declarations in the strict sense
// (function, type, const); `Test`, `GenDef`, `GenInvoke`, `IfDirective`
// are declaration-like constructs that share the same module-level
// position. `Error` is a recovery placeholder.
pub type Decl = enum {
    Import(ImportDecl)
    Function(FunctionDecl)
    Type(TypeDecl)
    Const(ConstDecl)
    Test(TestDecl)
    GenDef(GenDef)
    GenInvoke(GenInvoke)
    IfDirective(IfDirectiveDecl)
    Error(DeclError)
}

// Decl-level attributes. `Foreign`, `Inline`, `Intrinsic`, `Simd` are
// flag-shaped; `Deprecated(msg?)` carries an optional reason string.
// Several directives may attach to the same declaration; order is
// source order.
pub type Directive = enum {
    Foreign
    Inline
    Intrinsic
    Simd
    Deprecated(String?)
}

// `[pub] import path.to.module`
pub type ImportDecl = struct {
    span: SourceSpan
    is_pub: bool
    path: List(String)
}

// `[pub] [directives] fn name(params) ret? { body }`
// `body` is None for `#foreign fn` declarations (no `{ ... }`).
// `return_type` is None for void-returning functions (no type after `)`).
pub type FunctionDecl = struct {
    span: SourceSpan
    is_pub: bool
    directives: List(Directive)
    name: String
    params: List(FunctionParam)
    return_type: TypeExpr?
    body: BlockExpr?
}

// One parameter slot. `is_variadic` is true for the trailing `..xs: T`
// form. `default_value` carries the post-`=` expression when a default
// is given. Only the last parameter may legally be variadic; not
// enforced at the type level.
pub type FunctionParam = struct {
    span: SourceSpan
    name: String
    type_expr: TypeExpr
    // The field name avoids `default`, which is a C reserved word and
    // collides at C codegen time after name mangling.
    default_value: Expr?
    is_variadic: bool
}

// `[pub] [directives] type Name = TypeExpr`
// FLang has exactly one declaration form for types. Generics live on
// the RHS TypeExpr (`struct(T) { ... }`, `enum(T, E) { ... }`); a plain
// alias such as `type Index = usize` reuses the same shape with a
// `Named` body.
pub type TypeDecl = struct {
    span: SourceSpan
    is_pub: bool
    directives: List(Directive)
    name: String
    body: TypeExpr
}

// `[pub] const name(: T)? = value`
pub type ConstDecl = struct {
    span: SourceSpan
    is_pub: bool
    name: String
    type_annotation: TypeExpr?
    value: Expr
}

// `test "label" { ... }`
pub type TestDecl = struct {
    span: SourceSpan
    label: String
    body: BlockExpr
}

// `#define(name, P1: K1, P2: K2, ...) { template body }`
// The template body is preserved as a CST byte range for v1; expansion
// reads back from the CST when the source-generator pass runs.
pub type GenDef = struct {
    span: SourceSpan
    name: String
    params: List(GenParam)
    body_start: usize
    body_end: usize
}

// One parameter to a `#define`. `kind` is the parameter-kind keyword
// (`Ident`, `Type`, `Expr`, ...) verbatim from source.
pub type GenParam = struct {
    span: SourceSpan
    name: String
    kind: String
}

// `#name(arg1, arg2, ...)` at top level — invokes a source generator.
pub type GenInvoke = struct {
    span: SourceSpan
    name: String
    args: List(Expr)
}

// `#if(cond) { decls... } else { decls... }` at file/module level.
pub type IfDirectiveDecl = struct {
    span: SourceSpan
    condition: Expr
    then_decls: List(Decl)
    else_decls: List(Decl)
}

// Recovery placeholder. The parser produced unrecognised tokens at
// top level; the CST keeps the bytes verbatim, the AST records the
// span so downstream phases can skip without losing the whole file.
pub type DeclError = struct {
    span: SourceSpan
}

// ─────────────────────────────────────────────────────────────────────────
// Statements — only valid inside a function body or a block expression
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

// `let|const name(: T)? (= init)?` — LHS is an identifier only. There
// is no destructuring `let` in FLang (destructure via `match`). At
// least one of `type_annotation` and `init` is set; both omitted is
// `let x` alone, rejected by the parser upstream. Uninit `let x: T`
// zero-initializes.
pub type LetStmt = struct {
    span: SourceSpan
    is_const: bool
    name: String
    type_annotation: TypeExpr?
    init: Expr?
}

// A bare expression terminated as a statement; the result is discarded.
// Includes UFCS calls, assignments, and any other expression used for
// its side effect.
pub type ExpressionStmt = struct {
    span: SourceSpan
    expr: Expr
}

// `return expr?` — `value` is None for void-return-position `return`.
pub type ReturnStmt = struct {
    span: SourceSpan
    value: Expr?
}

// `defer expr` — `expr` is evaluated at the end of the enclosing scope
// in LIFO order with sibling defers.
pub type DeferStmt = struct {
    span: SourceSpan
    expr: Expr
}

// Bare `break` / `continue`. FLang has no loop labels.
pub type BreakStmt = struct {
    span: SourceSpan
}

pub type ContinueStmt = struct {
    span: SourceSpan
}

// `for name in iterable { body }` — loop variable is a single identifier.
// FLang has no tuple-destructuring `for (k, v) in iter` form. Loops do
// not yield a value; they are statements, not expressions.
pub type ForStmt = struct {
    span: SourceSpan
    var_name: String
    iterable: &Expr
    body: BlockExpr
}

// `while cond { body }` — statement form, evaluates to no value.
pub type WhileStmt = struct {
    span: SourceSpan
    condition: &Expr
    body: BlockExpr
}

// `loop { body }` — unconditional, statement form. Exit via `break` or
// `return`.
pub type LoopStmt = struct {
    span: SourceSpan
    body: BlockExpr
}

// `#if(cond) { stmts... } else { stmts... }` inside a function body.
pub type IfDirectiveStmt = struct {
    span: SourceSpan
    condition: Expr
    then_stmts: List(Stmt)
    else_stmts: List(Stmt)
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

    // Control flow as expression — Block, If, Match yield a value.
    // For / While / Loop are statements (see Stmt).
    Block(BlockExpr)
    If(IfExpr)
    Match(MatchExpr)

    // Anonymous function
    Lambda(LambdaExpr)

    // Recovery
    Error(ErrorExpr)
}

// A literal expression. The seven literal kinds are shared with patterns
// (see `LiteralPattern.value`) — same payload structs, narrower outer
// enum where the grammar is narrower.
pub type LiteralExpr = struct {
    span: SourceSpan
    value: Literal
}

// Shared literal payload between expressions and patterns. `Null` has
// no payload — there is only one null literal value.
pub type Literal = enum {
    Int(IntLiteral)
    Float(FloatLiteral)
    String(StringLiteral)
    Char(CharLiteral)
    Byte(ByteLiteral)
    Bool(BoolLiteral)
    Null
}

// Integer literal — value preserved as the source text; suffix and base
// are separate so downstream phases don't re-parse. `text` includes
// `0x`, `0b`, `_` digit separators if any. Empty `suffix` means
// unsuffixed (subject to constrain-then-resolve at type-check time).
pub type IntLiteral = struct {
    span: SourceSpan
    text: String
    suffix: String
}

// Float literal. `text` is the raw source (`1.5e10`, `3.14`, `1_000.5`);
// `suffix` is `"f32"` / `"f64"` / `""` (unsuffixed).
pub type FloatLiteral = struct {
    span: SourceSpan
    text: String
    suffix: String
}

// String literal — raw source slice excluding the surrounding quotes.
// Escape sequences are NOT expanded at parse time; that is a later
// concern when the literal becomes a runtime value.
pub type StringLiteral = struct {
    span: SourceSpan
    text: String
}

// `'A'`, `'\n'` — single-character literal. `text` excludes the
// surrounding single quotes; escapes are not yet expanded.
pub type CharLiteral = struct {
    span: SourceSpan
    text: String
}

// `b'A'` — byte literal. `text` excludes the `b'` prefix and trailing `'`.
pub type ByteLiteral = struct {
    span: SourceSpan
    text: String
}

// `true` / `false` — boolean literal.
pub type BoolLiteral = struct {
    span: SourceSpan
    value: bool
}

// `$"text {expr} text"`, `$(cap)"…"`, `$(&alloc)"…"`, `$(cap, &alloc)"…"`,
// and `$sb"…"` (write-into-builder). `target` disambiguates the four
// new-string forms (a call to `string_builder(args...)` with 0-2 args)
// from the into-builder form; `parts` is the alternating text/hole
// sequence between the quotes.
pub type InterpolatedStringExpr = struct {
    span: SourceSpan
    target: InterpolationTarget
    parts: List(InterpolationPart)
}

// `NewString(args)` covers `$"…"`, `$(cap)"…"`, `$(&alloc)"…"`,
// `$(cap, &alloc)"…"` uniformly as a call to `string_builder` with 0,
// 1, or 2 arguments — overload resolution at type-check time picks the
// right `string_builder` signature. `IntoBuilder(builder)` is the
// distinct write-into form `$sb"…"`.
pub type InterpolationTarget = enum {
    NewString(List(Expr))
    IntoBuilder(&Expr)
}

// One segment of an interpolated string: either raw text between holes
// or a `{expr}` hole.
pub type InterpolationPart = enum {
    Text(String)
    Hole(InterpolationHole)
}

pub type InterpolationHole = struct {
    span: SourceSpan
    expr: &Expr
    // None when the user wrote `{x}` with no format spec; carries the
    // post-colon text verbatim for `{x:04}` style format directives.
    format: String?
}

// `[1, 2, 3]` or `[v; n]` — array literal. The two shapes share the
// outer node and split on `kind`.
pub type ArrayLiteralExpr = struct {
    span: SourceSpan
    kind: ArrayLiteralKind
}

pub type ArrayLiteralKind = enum {
    // `[1, 2, 3]` — element-by-element.
    Elements(List(Expr))
    // `[value; count]` — count copies of value.
    Repeat(RepeatLiteral)
}

pub type RepeatLiteral = struct {
    span: SourceSpan
    value: &Expr
    count: &Expr
}

// `(a, b, ...)` — tuple literal. The empty tuple `()` is the unit value.
// A single-element tuple is written `(x,)` with a trailing comma.
pub type TupleLiteralExpr = struct {
    span: SourceSpan
    elements: List(Expr)
}

// `Point { x = 10, y = 20 }` and `.{ x = 10, y }` collapse into one
// node — the only difference is whether a target type is named.
// `type_expr` is None for anonymous form (target inferred from context);
// Some for nominal construction.
pub type StructLiteralExpr = struct {
    span: SourceSpan
    type_expr: &TypeExpr?
    fields: List(StructFieldInit)
}

// Field initializer inside a struct literal. `value` is None when the
// user wrote shorthand (`Point { x, y }`) — the identifier `x` is
// reused as the value at type-check time.
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

// `receiver.member` — direct field access AND UFCS dispatch base; the
// resolution choice happens at type-check time. Wrapping a MemberAccess
// in a Call (`a.b()`) becomes a UFCS call.
pub type MemberAccessExpr = struct {
    span: SourceSpan
    receiver: &Expr
    member: String
}

// `&operand` — address-of, producing a reference value.
pub type AddressOfExpr = struct {
    span: SourceSpan
    operand: &Expr
}

// `operand.*` — explicit dereference.
pub type DereferenceExpr = struct {
    span: SourceSpan
    operand: &Expr
}

// `receiver?.member` — short-circuit on null receiver.
pub type NullPropagationExpr = struct {
    span: SourceSpan
    receiver: &Expr
    member: String
}

// `receiver[index]` — `index` is any expression. The slice forms
// (`a[..]`, `a[i..]`, `a[..j]`, `a[i..j]`, `a[i..=j]`) appear as
// `IndexExpr` with `index` being a `RangeExpr`; user-defined indexing
// like `dict["key"]` carries an arbitrary `index` expression. Resolution
// of value-form vs ref-form indexing happens at type-check time.
pub type IndexExpr = struct {
    span: SourceSpan
    receiver: &Expr
    index: &Expr
}

// `callee(args)` — covers regular calls, UFCS dispatch (when `callee`
// is a `MemberAccess`), and `op_call` invocation. Resolution happens at
// type-check time.
pub type CallExpr = struct {
    span: SourceSpan
    callee: &Expr
    args: List(CallArgument)
}

// One slot in a call's argument list — either positional or named.
// Named arguments may appear interleaved with positional ones; ordering
// rules are enforced later.
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

// `lhs op rhs` for every infix operator. Operator desugarings to the
// underlying `op_*` calls happen during lowering, not here.
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

// `op operand` — prefix unary.
pub type UnaryExpr = struct {
    span: SourceSpan
    op: UnaryOp
    operand: &Expr
}

pub type UnaryOp = enum {
    Neg     // `-`
    Not     // `!`
    BitNot  // `~`
}

// `start..end`, `start..=end`, `..end`, `start..`, `..` — every bound is
// optional, inclusivity is a flag. Distinct from `RangePattern` because
// the grammar accepts ranges only in select positions.
pub type RangeExpr = struct {
    span: SourceSpan
    start: &Expr?
    end: &Expr?
    inclusive: bool
}

// `lhs ?? rhs` — null-coalescing. Yields `lhs` if non-null, else `rhs`.
pub type CoalesceExpr = struct {
    span: SourceSpan
    lhs: &Expr
    rhs: &Expr
}

// `operand?` postfix try — desugars to a match against the implementing
// `op_try` at lowering time.
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

// `{ stmts...; trailing? }` — the last statement without a terminator
// becomes the trailing expression. `trailing` is None when the block
// evaluates to unit.
pub type BlockExpr = struct {
    span: SourceSpan
    stmts: List(Stmt)
    trailing: &Expr?
}

// `if cond { then } else { else }` and `if cond { then } else if … { … }`.
// Else-if is encoded as `else_branch` being another `If` — there is no
// separate "else-if" node.
pub type IfExpr = struct {
    span: SourceSpan
    condition: &Expr
    then_branch: BlockExpr
    else_branch: ElseBranch
}

// Tail of an `if`: missing, a block, or another chained if-else.
pub type ElseBranch = enum {
    None
    Block(BlockExpr)
    If(&IfExpr)
}

// `scrutinee match { arm, arm, ... }`
pub type MatchExpr = struct {
    span: SourceSpan
    scrutinee: &Expr
    arms: List(MatchArm)
}

// One arm of a match. `guard` carries the post-`if` condition when the
// arm is `pat if cond => body`.
pub type MatchArm = struct {
    span: SourceSpan
    pattern: Pattern
    guard: &Expr?
    body: &Expr
}

// `fn(params) ret? { body }` — anonymous function. May capture
// surrounding locals (RFC-014 Phase 2 by-value capture). Same shape as
// `FunctionDecl` minus name, directives, and visibility — none of which
// apply to lambdas.
pub type LambdaExpr = struct {
    span: SourceSpan
    params: List(FunctionParam)
    return_type: TypeExpr?
    body: BlockExpr
}

// Recovery placeholder. The parser produced unrecognised tokens where
// an expression was expected; the span lets downstream phases skip
// without losing surrounding structure.
pub type ErrorExpr = struct {
    span: SourceSpan
}

// ─────────────────────────────────────────────────────────────────────────
// Patterns — only appear in match arms
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
}

// `_` and the `else` arm catch-all collapse into Wildcard. The CST
// preserves the keyword distinction; the AST does not.
pub type WildcardPattern = struct {
    span: SourceSpan
}

// A bare identifier in pattern position — binds the matched value to
// `name`. Distinct from a literal pattern that happens to be an
// identifier-looking enum variant; the projector decides which based
// on scope.
pub type VariablePattern = struct {
    span: SourceSpan
    name: String
}

// `42`, `'A'`, `"hi"`, `b'0'`, `true`, `null` — restricted to the
// seven literal forms via the `Literal` enum (same as `LiteralExpr`).
pub type LiteralPattern = struct {
    span: SourceSpan
    value: Literal
}

// `Some(x)`, `Move(x, y)`, `Color.Red`, `Red`. `qualifier` is the
// optional `EnumName.` prefix; `name` is the variant. `payloads` is
// the parenthesised destructure list, empty for nullary variants.
pub type EnumVariantPattern = struct {
    span: SourceSpan
    qualifier: String?
    name: String
    payloads: List(Pattern)
}

// `A | B | C` — matches if any alternative matches. Alternatives must
// bind the same set of variable names; checked at type-check time.
pub type OrPattern = struct {
    span: SourceSpan
    alternatives: List(Pattern)
}

// `0..10`, `0..=9`, `..n`, `n..` — same shape as `RangeExpr` but
// distinct type so the grammar's position restriction is type-encoded.
pub type RangePattern = struct {
    span: SourceSpan
    start: &Expr?
    end: &Expr?
    inclusive: bool
}

// `Point { x, y = pat, .. }`. `has_rest` records the trailing `..`
// placeholder; without it, every field must be listed.
pub type StructPattern = struct {
    span: SourceSpan
    type_expr: &TypeExpr
    fields: List(StructPatternField)
    has_rest: bool
}

// One field slot inside a struct pattern. `binding` is None for
// shorthand (`{ x, y }`) — semantically equivalent to a VariablePattern
// of the same name.
pub type StructPatternField = struct {
    span: SourceSpan
    name: String
    binding: &Pattern?
}

// `(a, b, ...)` — positional destructure of a tuple value.
pub type TuplePattern = struct {
    span: SourceSpan
    elements: List(Pattern)
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
    Error(ErrorType)
}

// `Name`, `Name(T, U)` — named type with optional generic argument list.
pub type NamedType = struct {
    span: SourceSpan
    name: String
    generic_args: List(TypeExpr)
}

// `$T` — introduces a generic parameter at first appearance in a function
// parameter type. Semantically valid only in `FunctionDecl.params` /
// `LambdaExpr.params`; the AST accepts it everywhere and a later pass
// flags misuse.
pub type GenericBindType = struct {
    span: SourceSpan
    name: String
}

// `&T`
pub type ReferenceType = struct {
    span: SourceSpan
    inner: &TypeExpr
}

// `T?` — sugar for `Option(T)`. `&T?` is `Option(&T)`, encoded as
// `Optional(inner = Reference(...))`.
pub type OptionalType = struct {
    span: SourceSpan
    inner: &TypeExpr
}

// `[T; N]` — fixed-size array. `length` is an expression because it
// may reference a constant (e.g. `[u8; BUFFER_SIZE]`).
pub type ArrayType = struct {
    span: SourceSpan
    element: &TypeExpr
    length: &Expr
}

// `T[]` — slice. `&T[]` is a reference to a slice; the AST nests
// `Reference(inner = Slice(...))`.
pub type SliceType = struct {
    span: SourceSpan
    element: &TypeExpr
}

// `(A, B, ...)` — tuple type. The empty tuple `()` is the unit type.
// A single-element tuple is `(A,)` (with trailing comma); whether the
// trailing comma is present is a CST concern, not an AST one.
pub type TupleType = struct {
    span: SourceSpan
    elements: List(TypeExpr)
}

// `fn(P1, P2) R` — function type. `return_type` is None for void.
pub type FunctionType = struct {
    span: SourceSpan
    params: List(TypeExpr)
    return_type: &TypeExpr?
}

// `struct(T1, T2) { field: T, ... }` — generics are optional and live
// on the type expression itself. Same node whether named (RHS of a
// `TypeDecl`) or anonymous in argument position.
pub type AnonStructType = struct {
    span: SourceSpan
    generics: List(GenericParam)
    fields: List(StructField)
}

// One field declaration inside a struct type. FLang struct fields have
// no default initializer — `name: T` is the only shape.
pub type StructField = struct {
    span: SourceSpan
    name: String
    type_expr: &TypeExpr
}

// `enum(T) { Variant, Variant(T) }` — generics optional. Same node
// whether named (RHS of TypeDecl) or anonymous in type position.
pub type AnonEnumType = struct {
    span: SourceSpan
    generics: List(GenericParam)
    variants: List(EnumVariant)
}

// One variant inside an enum type. `payloads` is empty for nullary
// variants (`Red`); non-empty for tuple-style payloads (`Move(i32, i32)`).
// `explicit_tag` carries `= N` for naked enums (`Less = -1`).
pub type EnumVariant = struct {
    span: SourceSpan
    name: String
    payloads: List(TypeExpr)
    explicit_tag: &Expr?
}

// One generic parameter binding inside a struct or enum type expression.
// FLang has no bounds / constraints on generic parameters yet.
pub type GenericParam = struct {
    span: SourceSpan
    name: String
}

// Recovery placeholder for unrecognised type-expression tokens.
pub type ErrorType = struct {
    span: SourceSpan
}
