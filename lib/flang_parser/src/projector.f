// Projector — turns a CST tree into the semantic AST (see ast.f).
//
// The CST is lossless and shape-preserving; the AST is meaning-preserving
// and category-typed. The projector walks each `CstNode`, dispatches on
// `NodeKind`, and produces the corresponding AST node. Recursive children
// are boxed into the Module's arena; non-recursive children are stored by
// value. Strings (names, literal texts) are reused as views into the
// original `Token.text` — the source buffer must outlive the Module.
//
// Tokens that exist only for shape (`(`, `,`, `;`, keywords like `fn` /
// `import` / `else` / `=`) are skipped. Tokens carrying meaning (names,
// literal texts, operator tokens) are extracted by walking the child list
// linearly. Sub-nodes are projected recursively.
//
// The projector is best-effort on malformed input: missing pieces become
// `Error` variants or default zero-spans rather than aborting. It mirrors
// the parser's recover-and-continue stance.

import std.allocator
import std.list
import std.option
import std.string
import flang_parser.token
import flang_parser.cst
import flang_parser.ast
import flang_core.span

// ─────────────────────────────────────────────────────────────────────────
// Projector state
// ─────────────────────────────────────────────────────────────────────────

// Internal state threaded through every projector call. `alloc` is the
// arena-backed allocator the Module owns; `file_id` is forwarded into
// every `SourceSpan` produced. Stored separately from `Module` so the
// arena's value can be moved into the returned Module at the end without
// invalidating in-flight allocations.
type Projector = struct {
    alloc: &Allocator
    file_id: i32
}

// Project a parsed CST `Module` node into the typed AST `Module`.
// `allocator` is the backing allocator for the arena (defaults to the
// global allocator). `file_id` is forwarded into every produced
// `SourceSpan` — pass the workspace-stable id, or `-1` for "none".
pub fn project_module(cst: CstNode, file_id: i32, allocator: &Allocator? = null) Module {
    const backing = allocator.or_global()
    let arena = arena_allocator(backing)
    let arena_a = arena.allocator()
    const p: Projector = .{ alloc = &arena_a, file_id = file_id }

    let decls: List(Decl) = list(0, p.alloc)
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if !is_module_child(child.kind) { continue }
                decls.push(p.project_decl(child))
            }
            TokenChild(_) => {}
        }
    }

    return Module {
        span = p.span_from(cst),
        decls = decls,
        arena = arena,
    }
}

// True for CST kinds that round-trip to an AST `Decl`. Everything else
// at module level (stray tokens, unrecognised forms) is filtered out.
fn is_module_child(kind: NodeKind) bool {
    return kind == NodeKind.ImportDecl
        or kind == NodeKind.FunctionDecl
        or kind == NodeKind.StructDecl
        or kind == NodeKind.EnumDecl
        or kind == NodeKind.TypeAliasDecl
        or kind == NodeKind.VariableDecl
        or kind == NodeKind.TestDecl
        or kind == NodeKind.GeneratorDef
        or kind == NodeKind.GeneratorInvocation
        or kind == NodeKind.IfDirectiveStmt
        or kind == NodeKind.Error
}

// ─────────────────────────────────────────────────────────────────────────
// Span / child helpers
// ─────────────────────────────────────────────────────────────────────────

fn span_from(self: &Projector, cst: CstNode) SourceSpan {
    return .{
        file_id = self.file_id,
        start = cst.start,
        length = cst.end - cst.start,
    }
}

fn span_from_token(self: &Projector, tok: Token) SourceSpan {
    return .{
        file_id = self.file_id,
        start = tok.offset,
        length = tok.text.len,
    }
}

// Return the n-th sub-node child (0-indexed), or null if there are fewer.
// Token children are skipped.
fn nth_node(cst: CstNode, n: usize) CstNode? {
    let seen: usize = 0
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if seen == n { return child }
                seen = seen + 1
            }
            TokenChild(_) => {}
        }
    }
    return null
}

// First sub-node child whose kind matches `kind`, or null.
fn find_node(cst: CstNode, kind: NodeKind) CstNode? {
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => { if child.kind == kind { return child } }
            TokenChild(_) => {}
        }
    }
    return null
}

// First token child whose kind matches `kind`, or null.
fn find_token(cst: CstNode, kind: TokenKind) Token? {
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => { if tok.kind == kind { return tok } }
            NodeChild(_) => {}
        }
    }
    return null
}

fn has_token(cst: CstNode, kind: TokenKind) bool {
    return find_token(cst, kind).is_some()
}

// Text of the first identifier (or identifier-shaped keyword) token, or
// `""` if there is none. Used for names that follow a leading keyword
// (`fn name`, `type Name`, `const x`).
fn first_ident_text(cst: CstNode) String {
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.Identifier { return tok.text }
            }
            NodeChild(_) => {}
        }
    }
    return ""
}

// ─────────────────────────────────────────────────────────────────────────
// Declarations
// ─────────────────────────────────────────────────────────────────────────

fn project_decl(self: &Projector, cst: CstNode) Decl {
    return cst.kind match {
        ImportDecl => Decl.Import(self.project_import(cst)),
        FunctionDecl => Decl.Function(self.project_function(cst)),
        StructDecl => Decl.Type(self.project_struct_decl(cst)),
        EnumDecl => Decl.Type(self.project_enum_decl(cst)),
        TypeAliasDecl => Decl.Type(self.project_type_alias(cst)),
        VariableDecl => Decl.Const(self.project_const_decl(cst)),
        TestDecl => Decl.Test(self.project_test_decl(cst)),
        GeneratorDef => Decl.GenDef(self.project_generator_def(cst)),
        GeneratorInvocation => Decl.GenInvoke(self.project_generator_invocation(cst)),
        IfDirectiveStmt => Decl.IfDirective(self.project_if_directive_decl(cst)),
        else => Decl.Error(DeclError { span = self.span_from(cst) }),
    }
}

fn project_import(self: &Projector, cst: CstNode) ImportDecl {
    let path: List(String) = list(0, self.alloc)
    let seen_import_keyword = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.Import {
                    seen_import_keyword = true
                    continue
                }
                if !seen_import_keyword { continue }
                if tok.kind == TokenKind.Identifier or is_keyword(tok.kind) {
                    path.push(tok.text)
                }
            }
            NodeChild(_) => {}
        }
    }
    return .{
        span = self.span_from(cst),
        is_pub = has_token(cst, TokenKind.Pub),
        path = path,
    }
}

fn project_directives(self: &Projector, cst: CstNode) List(DeclAttribute) {
    let directives: List(DeclAttribute) = list(0, self.alloc)
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if child.kind == NodeKind.Directive {
                    directives.push(self.project_directive(child))
                }
            }
            TokenChild(_) => {}
        }
    }
    return directives
}

// `#foreign`, `#inline`, `#intrinsic`, `#simd`, `#deprecated("…")`. Other
// directive identifiers are flattened to `Inline` as a non-fatal default —
// validation belongs to a later pass.
fn project_directive(self: &Projector, cst: CstNode) DeclAttribute {
    let name: String = ""
    let arg_text: String? = null
    let after_open_paren = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if name.len == 0 and tok.kind == TokenKind.Identifier {
                    name = tok.text
                    continue
                }
                if tok.kind == TokenKind.OpenParenthesis {
                    after_open_paren = true
                    continue
                }
                if after_open_paren and tok.kind == TokenKind.StringLiteral {
                    arg_text = tok.text
                }
            }
            NodeChild(_) => {}
        }
    }
    if name == "foreign" { return DeclAttribute.Foreign }
    if name == "inline" { return DeclAttribute.Inline }
    if name == "intrinsic" { return DeclAttribute.Intrinsic }
    if name == "simd" { return DeclAttribute.Simd }
    if name == "deprecated" { return DeclAttribute.Deprecated(arg_text) }
    // Unknown directive — fold to Inline so the AST stays in a known shape.
    // The parser already filed a warning for unknown directives.
    return DeclAttribute.Inline
}

fn project_function(self: &Projector, cst: CstNode) FunctionDecl {
    let params: List(FunctionParam) = list(0, self.alloc)
    let return_type: TypeExpr? = null
    let body: BlockExpr? = null
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if child.kind == NodeKind.FunctionParam {
                    params.push(self.project_function_param(child))
                } else if child.kind == NodeKind.BlockExpr {
                    body = self.project_block_node(child)
                } else if is_type_kind(child.kind) and return_type.is_none() {
                    return_type = self.project_type_expr(child)
                }
            }
            TokenChild(_) => {}
        }
    }
    return FunctionDecl {
        span = self.span_from(cst),
        is_pub = has_token(cst, TokenKind.Pub),
        directives = self.project_directives(cst),
        name = self.function_name(cst),
        params = params,
        return_type = return_type,
        body = body,
    }
}

// Identifier between `fn` and `(`. We pick the first identifier token
// after `fn`; before `fn`, the only identifier-shaped tokens would be
// inside directives (themselves NodeChildren), so a simple linear scan
// suffices.
fn function_name(self: &Projector, cst: CstNode) String {
    let saw_fn = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.Fn { saw_fn = true; continue }
                if saw_fn and tok.kind == TokenKind.Identifier { return tok.text }
            }
            NodeChild(_) => {}
        }
    }
    return ""
}

fn project_function_param(self: &Projector, cst: CstNode) FunctionParam {
    let name: String = ""
    let type_expr: TypeExpr = TypeExpr.Error(ErrorType { span = self.span_from(cst) })
    let default_value: Expr? = null
    let is_variadic = has_token(cst, TokenKind.DotDot)
    let saw_colon = false
    let saw_equals = false
    let type_seen = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.Identifier and name.len == 0 {
                    name = tok.text
                }
                if tok.kind == TokenKind.Colon { saw_colon = true }
                if tok.kind == TokenKind.Equals { saw_equals = true }
            }
            NodeChild(child) => {
                if saw_equals and default_value.is_none() {
                    default_value = self.project_expr(child)
                } else if !type_seen and is_type_kind(child.kind) {
                    type_expr = self.project_type_expr(child)
                    type_seen = true
                }
            }
        }
    }
    return .{
        span = self.span_from(cst),
        name = name,
        type_expr = type_expr,
        default_value = default_value,
        is_variadic = is_variadic,
    }
}

fn project_struct_decl(self: &Projector, cst: CstNode) TypeDecl {
    let generics: List(GenericParam) = list(0, self.alloc)
    self.collect_generic_params_from_balanced(cst, &generics)
    let fields: List(StructField) = list(0, self.alloc)
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if child.kind == NodeKind.StructField {
                    fields.push(self.project_struct_field(child))
                }
            }
            TokenChild(_) => {}
        }
    }
    const body: TypeExpr = TypeExpr.AnonStruct(AnonStructType {
        span = self.span_from(cst),
        generics = generics,
        fields = fields,
    })
    return TypeDecl {
        span = self.span_from(cst),
        is_pub = has_token(cst, TokenKind.Pub),
        directives = self.project_directives(cst),
        name = self.type_decl_name(cst),
        body = body,
    }
}

fn project_enum_decl(self: &Projector, cst: CstNode) TypeDecl {
    let generics: List(GenericParam) = list(0, self.alloc)
    self.collect_generic_params_from_balanced(cst, &generics)
    let variants: List(EnumVariant) = list(0, self.alloc)
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if child.kind == NodeKind.EnumVariant {
                    variants.push(self.project_enum_variant(child))
                }
            }
            TokenChild(_) => {}
        }
    }
    const body: TypeExpr = TypeExpr.AnonEnum(AnonEnumType {
        span = self.span_from(cst),
        generics = generics,
        variants = variants,
    })
    return TypeDecl {
        span = self.span_from(cst),
        is_pub = has_token(cst, TokenKind.Pub),
        directives = self.project_directives(cst),
        name = self.type_decl_name(cst),
        body = body,
    }
}

fn project_type_alias(self: &Projector, cst: CstNode) TypeDecl {
    let body: TypeExpr = TypeExpr.Error(ErrorType { span = self.span_from(cst) })
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if child.kind == NodeKind.Directive { continue }
                if is_type_kind(child.kind) {
                    body = self.project_type_expr(child)
                    break
                }
            }
            TokenChild(_) => {}
        }
    }
    return TypeDecl {
        span = self.span_from(cst),
        is_pub = has_token(cst, TokenKind.Pub),
        directives = self.project_directives(cst),
        name = self.type_decl_name(cst),
        body = body,
    }
}

// Identifier between `type` keyword and `=`. Same shape for struct, enum,
// and alias decls.
fn type_decl_name(self: &Projector, cst: CstNode) String {
    let saw_type = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.Type { saw_type = true; continue }
                if saw_type and tok.kind == TokenKind.Identifier { return tok.text }
                if saw_type and tok.kind == TokenKind.Equals { break }
            }
            NodeChild(_) => {}
        }
    }
    return ""
}

// Generic params are surfaced as a flat token run inside the struct/enum
// body (see parser's `consume_balanced` on `(...)`). We re-scan the run
// between the first `(` and its matching `)` for identifier tokens.
fn collect_generic_params_from_balanced(self: &Projector, cst: CstNode, out: &List(GenericParam)) {
    let inside_parens = false
    let depth: i32 = 0
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.OpenParenthesis {
                    if !inside_parens { inside_parens = true }
                    depth = depth + 1
                    continue
                }
                if tok.kind == TokenKind.CloseParenthesis {
                    depth = depth - 1
                    if depth == 0 and inside_parens { return }
                    continue
                }
                if inside_parens and tok.kind == TokenKind.Identifier {
                    out.push(GenericParam {
                        span = self.span_from_token(tok),
                        name = tok.text,
                    })
                }
            }
            NodeChild(_) => {}
        }
    }
}

fn project_struct_field(self: &Projector, cst: CstNode) StructField {
    let name: String = ""
    let type_expr: TypeExpr = TypeExpr.Error(ErrorType { span = self.span_from(cst) })
    let saw_colon = false
    let type_seen = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.Identifier and name.len == 0 {
                    name = tok.text
                }
                if tok.kind == TokenKind.Colon { saw_colon = true }
            }
            NodeChild(child) => {
                if !type_seen and is_type_kind(child.kind) {
                    type_expr = self.project_type_expr(child)
                    type_seen = true
                }
            }
        }
    }
    const a = self.alloc
    return .{
        span = self.span_from(cst),
        name = name,
        type_expr = box(a, type_expr),
    }
}

fn project_enum_variant(self: &Projector, cst: CstNode) EnumVariant {
    let name: String = ""
    let payloads: List(TypeExpr) = list(0, self.alloc)
    let explicit_tag: Expr? = null
    let in_payload = false
    let saw_equals = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if name.len == 0 and tok.kind == TokenKind.Identifier {
                    name = tok.text
                    continue
                }
                if tok.kind == TokenKind.OpenParenthesis { in_payload = true; continue }
                if tok.kind == TokenKind.CloseParenthesis { in_payload = false; continue }
                if tok.kind == TokenKind.Equals { saw_equals = true; continue }
                // Explicit-tag integer (with optional leading minus) is captured
                // best-effort as a literal expression.
                if saw_equals and explicit_tag.is_none() and tok.kind == TokenKind.Integer {
                    const lit: Expr = Expr.Lit(LiteralExpr {
                        span = self.span_from_token(tok),
                        value = LiteralValue.Int(IntLiteral {
                            span = self.span_from_token(tok),
                            text = tok.text,
                            suffix = "",
                        }),
                    })
                    explicit_tag = lit
                }
            }
            NodeChild(child) => {
                if in_payload and is_type_kind(child.kind) {
                    payloads.push(self.project_type_expr(child))
                }
            }
        }
    }
    const a = self.alloc
    let boxed_tag: &Expr? = null
    explicit_tag match {
        Some(e) => { boxed_tag = box(a, e) }
        None => {}
    }
    return .{
        span = self.span_from(cst),
        name = name,
        payloads = payloads,
        explicit_tag = boxed_tag,
    }
}

fn project_const_decl(self: &Projector, cst: CstNode) ConstDecl {
    let name: String = ""
    let type_annotation: TypeExpr? = null
    let value: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    let saw_const_or_let = false
    let saw_equals = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.Const or tok.kind == TokenKind.Let {
                    saw_const_or_let = true
                    continue
                }
                if saw_const_or_let and tok.kind == TokenKind.Identifier and name.len == 0 {
                    name = tok.text
                }
                if tok.kind == TokenKind.Equals { saw_equals = true }
            }
            NodeChild(child) => {
                if saw_equals { value = self.project_expr(child) }
                else if is_type_kind(child.kind) and type_annotation.is_none() {
                    type_annotation = self.project_type_expr(child)
                }
            }
        }
    }
    return ConstDecl {
        span = self.span_from(cst),
        is_pub = has_token(cst, TokenKind.Pub),
        name = name,
        type_annotation = type_annotation,
        value = value,
    }
}

fn project_test_decl(self: &Projector, cst: CstNode) TestDecl {
    let label: String = ""
    let body: BlockExpr = .{
        span = self.span_from(cst),
        stmts = list(0, self.alloc),
        trailing = null,
    }
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.StringLiteral and label.len == 0 {
                    label = tok.text
                }
            }
            NodeChild(child) => {
                if child.kind == NodeKind.BlockExpr {
                    body = self.project_block_node(child).unwrap_or(body)
                }
            }
        }
    }
    return .{
        span = self.span_from(cst),
        label = label,
        body = body,
    }
}

fn project_generator_def(self: &Projector, cst: CstNode) GenDef {
    let name: String = ""
    let params: List(GenParam) = list(0, self.alloc)
    let body_start: usize = cst.end
    let body_end: usize = cst.end
    let saw_define = false
    let in_params = false
    let in_body = false
    let depth: i32 = 0
    let pending_param_name: String = ""
    let saw_colon = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if !saw_define and tok.kind == TokenKind.Identifier and tok.text == "define" {
                    saw_define = true
                    continue
                }
                if !saw_define { continue }
                if tok.kind == TokenKind.OpenParenthesis {
                    if !in_params and !in_body { in_params = true; depth = 1; continue }
                    if in_params { depth = depth + 1 }
                    continue
                }
                if tok.kind == TokenKind.CloseParenthesis {
                    if in_params {
                        depth = depth - 1
                        if depth == 0 { in_params = false }
                    }
                    continue
                }
                if tok.kind == TokenKind.OpenBrace {
                    if !in_body {
                        in_body = true
                        body_start = tok.offset + tok.text.len
                        depth = 1
                        continue
                    }
                    depth = depth + 1
                    continue
                }
                if tok.kind == TokenKind.CloseBrace {
                    if in_body {
                        depth = depth - 1
                        if depth == 0 {
                            body_end = tok.offset
                            in_body = false
                        }
                    }
                    continue
                }
                if in_params {
                    if name.len == 0 and tok.kind == TokenKind.Identifier {
                        name = tok.text
                        continue
                    }
                    if tok.kind == TokenKind.Identifier {
                        if pending_param_name.len == 0 {
                            pending_param_name = tok.text
                        } else if saw_colon {
                            params.push(GenParam {
                                span = self.span_from_token(tok),
                                name = pending_param_name,
                                kind = tok.text,
                            })
                            pending_param_name = ""
                            saw_colon = false
                        }
                        continue
                    }
                    if tok.kind == TokenKind.Colon { saw_colon = true }
                }
            }
            NodeChild(_) => {}
        }
    }
    return .{
        span = self.span_from(cst),
        name = name,
        params = params,
        body_start = body_start,
        body_end = body_end,
    }
}

fn project_generator_invocation(self: &Projector, cst: CstNode) GenInvoke {
    let name: String = ""
    let args: List(Expr) = list(0, self.alloc)
    let saw_hash = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.Hash { saw_hash = true; continue }
                if saw_hash and name.len == 0 and tok.kind == TokenKind.Identifier {
                    name = tok.text
                }
                // Inner argument tokens are consumed loosely by the parser's
                // `consume_balanced` — surfaced as a flat token stream
                // without sub-expressions. Until the parser exposes
                // structured generator args, we leave `args` empty rather
                // than fabricate placeholder expressions.
            }
            NodeChild(child) => {
                if is_expr_kind(child.kind) {
                    args.push(self.project_expr(child))
                }
            }
        }
    }
    return .{
        span = self.span_from(cst),
        name = name,
        args = args,
    }
}

fn project_if_directive_decl(self: &Projector, cst: CstNode) IfDirectiveDecl {
    // The parser's `parse_if_directive_stmt` consumes the condition as a
    // balanced run of tokens — no structured expr surfaced. We default
    // the condition to an Error expression for now.
    let then_decls: List(Decl) = list(0, self.alloc)
    let else_decls: List(Decl) = list(0, self.alloc)
    let blocks_seen: usize = 0
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if child.kind == NodeKind.BlockExpr {
                    // Block body holds module-level decls in directive form;
                    // re-walk it as if it were a Module body.
                    let target: &List(Decl) = if blocks_seen == 0 { &then_decls } else { &else_decls }
                    for j in 0..child.children.len {
                        child.children[j] match {
                            NodeChild(sub) => {
                                if is_module_child(sub.kind) {
                                    target.push(self.project_decl(sub))
                                }
                            }
                            TokenChild(_) => {}
                        }
                    }
                    blocks_seen = blocks_seen + 1
                }
            }
            TokenChild(_) => {}
        }
    }
    return .{
        span = self.span_from(cst),
        condition = Expr.Error(ErrorExpr { span = self.span_from(cst) }),
        then_decls = then_decls,
        else_decls = else_decls,
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Statements
// ─────────────────────────────────────────────────────────────────────────

fn project_stmt(self: &Projector, cst: CstNode) Stmt? {
    return cst.kind match {
        VariableDecl => Some(Stmt.Let(self.project_let_stmt(cst))),
        ExpressionStmt => Some(Stmt.Expression(self.project_expression_stmt(cst))),
        ReturnStmt => Some(Stmt.Return(self.project_return_stmt(cst))),
        DeferStmt => Some(Stmt.Defer(self.project_defer_stmt(cst))),
        BreakStmt => Some(Stmt.Break(BreakStmt { span = self.span_from(cst) })),
        ContinueStmt => Some(Stmt.Continue(ContinueStmt { span = self.span_from(cst) })),
        ForLoopExpr => Some(Stmt.For(self.project_for_stmt(cst))),
        WhileExpr => Some(Stmt.While(self.project_while_stmt(cst))),
        LoopExpr => Some(Stmt.Loop(self.project_loop_stmt(cst))),
        IfDirectiveStmt => Some(Stmt.IfDirective(self.project_if_directive_stmt(cst))),
        else => self.project_expr_as_stmt(cst),
    }
}

// `if`/`match`/bare-block in statement position. flang has no statement
// form for these, so the CST drops them straight into a block; without
// this wrapper the projector would silently lose the subtree.
fn project_expr_as_stmt(self: &Projector, cst: CstNode) Stmt? {
    if !is_expr_kind(cst.kind) { return null }
    let expr = self.project_expr(cst)
    return Some(Stmt.Expression(ExpressionStmt {
        span = self.span_from(cst),
        expr = expr,
    }))
}

fn project_let_stmt(self: &Projector, cst: CstNode) LetStmt {
    let name: String = ""
    let is_const = false
    let type_annotation: TypeExpr? = null
    let init: Expr? = null
    let saw_keyword = false
    let saw_equals = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.Const { saw_keyword = true; is_const = true; continue }
                if tok.kind == TokenKind.Let { saw_keyword = true; continue }
                if saw_keyword and tok.kind == TokenKind.Identifier and name.len == 0 {
                    name = tok.text
                }
                if tok.kind == TokenKind.Equals { saw_equals = true }
            }
            NodeChild(child) => {
                if saw_equals and init.is_none() and is_expr_kind(child.kind) {
                    init = self.project_expr(child)
                } else if !saw_equals and is_type_kind(child.kind) and type_annotation.is_none() {
                    type_annotation = self.project_type_expr(child)
                }
            }
        }
    }
    return .{
        span = self.span_from(cst),
        is_const = is_const,
        name = name,
        type_annotation = type_annotation,
        init = init,
    }
}

fn project_expression_stmt(self: &Projector, cst: CstNode) ExpressionStmt {
    let expr: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if is_expr_kind(child.kind) {
                    expr = self.project_expr(child)
                    break
                }
            }
            TokenChild(_) => {}
        }
    }
    return .{ span = self.span_from(cst), expr = expr }
}

fn project_return_stmt(self: &Projector, cst: CstNode) ReturnStmt {
    let value: Expr? = null
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if is_expr_kind(child.kind) and value.is_none() {
                    value = self.project_expr(child)
                }
            }
            TokenChild(_) => {}
        }
    }
    return .{ span = self.span_from(cst), value = value }
}

fn project_defer_stmt(self: &Projector, cst: CstNode) DeferStmt {
    let expr: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if is_expr_kind(child.kind) {
                    expr = self.project_expr(child)
                    break
                }
            }
            TokenChild(_) => {}
        }
    }
    return .{ span = self.span_from(cst), expr = expr }
}

fn project_for_stmt(self: &Projector, cst: CstNode) ForStmt {
    let var_name: String = ""
    let iterable: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    let body: BlockExpr = .{
        span = self.span_from(cst),
        stmts = list(0, self.alloc),
        trailing = null,
    }
    let saw_for = false
    let body_seen = false
    let iterable_seen = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.For { saw_for = true; continue }
                if saw_for and tok.kind == TokenKind.Identifier and var_name.len == 0 {
                    var_name = tok.text
                }
            }
            NodeChild(child) => {
                if child.kind == NodeKind.BlockExpr {
                    body = self.project_block_node(child).unwrap_or(body)
                    body_seen = true
                } else if !iterable_seen and is_expr_kind(child.kind) {
                    iterable = self.project_expr(child)
                    iterable_seen = true
                }
            }
        }
    }
    const a = self.alloc
    return .{
        span = self.span_from(cst),
        var_name = var_name,
        iterable = box(a, iterable),
        body = body,
    }
}

fn project_while_stmt(self: &Projector, cst: CstNode) WhileStmt {
    let condition: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    let body: BlockExpr = .{
        span = self.span_from(cst),
        stmts = list(0, self.alloc),
        trailing = null,
    }
    let cond_seen = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if child.kind == NodeKind.BlockExpr {
                    body = self.project_block_node(child).unwrap_or(body)
                } else if !cond_seen and is_expr_kind(child.kind) {
                    condition = self.project_expr(child)
                    cond_seen = true
                }
            }
            TokenChild(_) => {}
        }
    }
    const a = self.alloc
    return .{
        span = self.span_from(cst),
        condition = box(a, condition),
        body = body,
    }
}

fn project_loop_stmt(self: &Projector, cst: CstNode) LoopStmt {
    let body: BlockExpr = .{
        span = self.span_from(cst),
        stmts = list(0, self.alloc),
        trailing = null,
    }
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if child.kind == NodeKind.BlockExpr {
                    body = self.project_block_node(child).unwrap_or(body)
                }
            }
            TokenChild(_) => {}
        }
    }
    return .{ span = self.span_from(cst), body = body }
}

fn project_if_directive_stmt(self: &Projector, cst: CstNode) IfDirectiveStmt {
    let then_stmts: List(Stmt) = list(0, self.alloc)
    let else_stmts: List(Stmt) = list(0, self.alloc)
    let blocks_seen: usize = 0
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if child.kind == NodeKind.BlockExpr {
                    let target: &List(Stmt) = if blocks_seen == 0 { &then_stmts } else { &else_stmts }
                    self.collect_block_stmts(child, target)
                    blocks_seen = blocks_seen + 1
                }
            }
            TokenChild(_) => {}
        }
    }
    return .{
        span = self.span_from(cst),
        condition = Expr.Error(ErrorExpr { span = self.span_from(cst) }),
        then_stmts = then_stmts,
        else_stmts = else_stmts,
    }
}

fn collect_block_stmts(self: &Projector, block: CstNode, out: &List(Stmt)) {
    for i in 0..block.children.len {
        block.children[i] match {
            NodeChild(child) => {
                const projected = self.project_stmt(child)
                projected match {
                    Some(s) => { out.push(s) }
                    None => {}
                }
            }
            TokenChild(_) => {}
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Expressions
// ─────────────────────────────────────────────────────────────────────────

fn is_expr_kind(kind: NodeKind) bool {
    return kind == NodeKind.BinaryExpr
        or kind == NodeKind.UnaryExpr
        or kind == NodeKind.AddressOfExpr
        or kind == NodeKind.DereferenceExpr
        or kind == NodeKind.MemberAccessExpr
        or kind == NodeKind.IndexExpr
        or kind == NodeKind.CallExpr
        or kind == NodeKind.CastExpr
        or kind == NodeKind.AssignmentExpr
        or kind == NodeKind.CoalesceExpr
        or kind == NodeKind.NullPropagationExpr
        or kind == NodeKind.TryExpr
        or kind == NodeKind.RangeExpr
        or kind == NodeKind.ArrayLiteralExpr
        or kind == NodeKind.AnonymousStructExpr
        or kind == NodeKind.StructConstructionExpr
        or kind == NodeKind.BlockExpr
        or kind == NodeKind.IfExpr
        or kind == NodeKind.ForLoopExpr
        or kind == NodeKind.LoopExpr
        or kind == NodeKind.WhileExpr
        or kind == NodeKind.MatchExpr
        or kind == NodeKind.LambdaExpr
        or kind == NodeKind.InterpolatedStringExpr
        or kind == NodeKind.IdentifierExpr
        or kind == NodeKind.IntegerLiteralExpr
        or kind == NodeKind.FloatLiteralExpr
        or kind == NodeKind.StringLiteralExpr
        or kind == NodeKind.CharLiteralExpr
        or kind == NodeKind.ByteLiteralExpr
        or kind == NodeKind.BooleanLiteralExpr
        or kind == NodeKind.NullLiteralExpr
}

fn project_expr(self: &Projector, cst: CstNode) Expr {
    return cst.kind match {
        IntegerLiteralExpr => Expr.Lit(self.project_int_literal(cst)),
        FloatLiteralExpr => Expr.Lit(self.project_float_literal(cst)),
        StringLiteralExpr => Expr.Lit(self.project_string_literal(cst)),
        CharLiteralExpr => Expr.Lit(self.project_char_literal(cst)),
        ByteLiteralExpr => Expr.Lit(self.project_byte_literal(cst)),
        BooleanLiteralExpr => Expr.Lit(self.project_bool_literal(cst)),
        NullLiteralExpr => Expr.Lit(LiteralExpr {
            span = self.span_from(cst),
            value = LiteralValue.Null,
        }),
        IdentifierExpr => Expr.Identifier(IdentifierExpr {
            span = self.span_from(cst),
            name = first_ident_text(cst),
        }),
        BinaryExpr => self.project_binary_expr(cst),
        UnaryExpr => self.project_unary_expr(cst),
        AddressOfExpr => self.project_address_of(cst),
        DereferenceExpr => self.project_dereference(cst),
        MemberAccessExpr => self.project_member_access(cst),
        NullPropagationExpr => self.project_null_propagation(cst),
        IndexExpr => self.project_index(cst),
        CallExpr => self.project_call(cst),
        CastExpr => self.project_cast(cst),
        AssignmentExpr => self.project_assignment(cst),
        CoalesceExpr => self.project_coalesce(cst),
        TryExpr => self.project_try(cst),
        RangeExpr => self.project_range(cst),
        ArrayLiteralExpr => self.project_array_literal(cst),
        AnonymousStructExpr => self.project_anon_struct_or_tuple(cst),
        StructConstructionExpr => self.project_struct_construction(cst),
        BlockExpr => {
            const block = self.project_block_node(cst)
            block match {
                Some(b) => Expr.Block(b),
                None => Expr.Error(ErrorExpr { span = self.span_from(cst) }),
            }
        }
        IfExpr => Expr.If(self.project_if_expr(cst)),
        MatchExpr => Expr.Match(self.project_match_expr(cst)),
        LambdaExpr => Expr.Lambda(self.project_lambda_expr(cst)),
        InterpolatedStringExpr => Expr.InterpolatedString(self.project_interp_string(cst)),
        else => Expr.Error(ErrorExpr { span = self.span_from(cst) }),
    }
}

fn project_int_literal(self: &Projector, cst: CstNode) LiteralExpr {
    const tok = find_token(cst, TokenKind.Integer)
    let text: String = ""
    tok match {
        Some(t) => { text = t.text }
        None => {}
    }
    const text_str = text
    const split = split_numeric_suffix(text_str, false)
    return .{
        span = self.span_from(cst),
        value = LiteralValue.Int(IntLiteral {
            span = self.span_from(cst),
            text = split.body,
            suffix = split.suffix,
        }),
    }
}

fn project_float_literal(self: &Projector, cst: CstNode) LiteralExpr {
    const tok = find_token(cst, TokenKind.Float)
    let text: String = ""
    tok match {
        Some(t) => { text = t.text }
        None => {}
    }
    const split = split_numeric_suffix(text, true)
    return .{
        span = self.span_from(cst),
        value = LiteralValue.Float(FloatLiteral {
            span = self.span_from(cst),
            text = split.body,
            suffix = split.suffix,
        }),
    }
}

fn project_string_literal(self: &Projector, cst: CstNode) LiteralExpr {
    const tok = find_token(cst, TokenKind.StringLiteral)
    let raw: String = ""
    tok match {
        Some(t) => { raw = t.text }
        None => {}
    }
    // Strip the surrounding quotes if present.
    const text = strip_quotes(raw)
    return .{
        span = self.span_from(cst),
        value = LiteralValue.String(StringLiteral {
            span = self.span_from(cst),
            text = text,
        }),
    }
}

fn project_char_literal(self: &Projector, cst: CstNode) LiteralExpr {
    const tok = find_token(cst, TokenKind.CharLiteral)
    let raw: String = ""
    tok match {
        Some(t) => { raw = t.text }
        None => {}
    }
    const text = strip_quotes(raw)
    return .{
        span = self.span_from(cst),
        value = LiteralValue.Char(CharLiteral {
            span = self.span_from(cst),
            text = text,
        }),
    }
}

fn project_byte_literal(self: &Projector, cst: CstNode) LiteralExpr {
    const tok = find_token(cst, TokenKind.ByteLiteral)
    let raw: String = ""
    tok match {
        Some(t) => { raw = t.text }
        None => {}
    }
    // `b'X'` — drop leading `b'` and trailing `'`.
    let text = raw
    if text.len >= 3 and text[0] == b'b' and text[1] == b'\'' {
        text = slice_str(text, 2, text.len - 1)
    }
    return .{
        span = self.span_from(cst),
        value = LiteralValue.Byte(ByteLiteral {
            span = self.span_from(cst),
            text = text,
        }),
    }
}

fn project_bool_literal(self: &Projector, cst: CstNode) LiteralExpr {
    let value = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.True { value = true; break }
                if tok.kind == TokenKind.False { value = false; break }
            }
            NodeChild(_) => {}
        }
    }
    return .{
        span = self.span_from(cst),
        value = LiteralValue.Bool(BoolLiteral {
            span = self.span_from(cst),
            value = value,
        }),
    }
}

fn project_binary_expr(self: &Projector, cst: CstNode) Expr {
    let lhs: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    let rhs: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    let op: BinaryOp = BinaryOp.Add
    let saw_lhs = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if !saw_lhs { lhs = self.project_expr(child); saw_lhs = true }
                else { rhs = self.project_expr(child) }
            }
            TokenChild(tok) => {
                const mapped = map_binary_op(tok.kind)
                mapped match {
                    Some(o) => { op = o }
                    None => {}
                }
            }
        }
    }
    const a = self.alloc
    return Expr.Binary(BinaryExpr {
        span = self.span_from(cst),
        op = op,
        lhs = box(a, lhs),
        rhs = box(a, rhs),
    })
}

fn map_binary_op(kind: TokenKind) BinaryOp? {
    return kind match {
        Plus => Some(BinaryOp.Add),
        Minus => Some(BinaryOp.Sub),
        Star => Some(BinaryOp.Mul),
        Slash => Some(BinaryOp.Div),
        Percent => Some(BinaryOp.Mod),
        EqualsEquals => Some(BinaryOp.Eq),
        NotEquals => Some(BinaryOp.Ne),
        LessThan => Some(BinaryOp.Lt),
        GreaterThan => Some(BinaryOp.Gt),
        LessThanOrEqual => Some(BinaryOp.Le),
        GreaterThanOrEqual => Some(BinaryOp.Ge),
        And => Some(BinaryOp.And),
        Or => Some(BinaryOp.Or),
        Ampersand => Some(BinaryOp.BitAnd),
        Pipe => Some(BinaryOp.BitOr),
        Caret => Some(BinaryOp.BitXor),
        ShiftLeft => Some(BinaryOp.Shl),
        ShiftRight => Some(BinaryOp.Shr),
        UnsignedShiftRight => Some(BinaryOp.UShr),
        else => null,
    }
}

fn project_unary_expr(self: &Projector, cst: CstNode) Expr {
    let op: UnaryOp = UnaryOp.Neg
    let operand: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.Minus { op = UnaryOp.Neg }
                else if tok.kind == TokenKind.Bang { op = UnaryOp.Not }
                else if tok.kind == TokenKind.Tilde { op = UnaryOp.BitNot }
            }
            NodeChild(child) => { operand = self.project_expr(child) }
        }
    }
    const a = self.alloc
    return Expr.Unary(UnaryExpr {
        span = self.span_from(cst),
        op = op,
        operand = box(a, operand),
    })
}

fn project_address_of(self: &Projector, cst: CstNode) Expr {
    let operand: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    nth_node(cst, 0) match {
        Some(child) => { operand = self.project_expr(child) }
        None => {}
    }
    const a = self.alloc
    return Expr.AddressOf(AddressOfExpr {
        span = self.span_from(cst),
        operand = box(a, operand),
    })
}

fn project_dereference(self: &Projector, cst: CstNode) Expr {
    let operand: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    nth_node(cst, 0) match {
        Some(child) => { operand = self.project_expr(child) }
        None => {}
    }
    const a = self.alloc
    return Expr.Dereference(DereferenceExpr {
        span = self.span_from(cst),
        operand = box(a, operand),
    })
}

fn project_member_access(self: &Projector, cst: CstNode) Expr {
    let receiver: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    let member: String = ""
    nth_node(cst, 0) match {
        Some(child) => { receiver = self.project_expr(child) }
        None => {}
    }
    let saw_dot = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.Dot { saw_dot = true; continue }
                if saw_dot and member.len == 0 {
                    if tok.kind == TokenKind.Identifier or tok.kind == TokenKind.Integer {
                        member = tok.text
                    }
                }
            }
            NodeChild(_) => {}
        }
    }
    const a = self.alloc
    return Expr.MemberAccess(MemberAccessExpr {
        span = self.span_from(cst),
        receiver = box(a, receiver),
        member = member,
    })
}

fn project_null_propagation(self: &Projector, cst: CstNode) Expr {
    let receiver: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    let member: String = ""
    nth_node(cst, 0) match {
        Some(child) => { receiver = self.project_expr(child) }
        None => {}
    }
    let saw_question_dot = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.QuestionDot { saw_question_dot = true; continue }
                if saw_question_dot and member.len == 0 and tok.kind == TokenKind.Identifier {
                    member = tok.text
                }
            }
            NodeChild(_) => {}
        }
    }
    const a = self.alloc
    return Expr.NullPropagation(NullPropagationExpr {
        span = self.span_from(cst),
        receiver = box(a, receiver),
        member = member,
    })
}

fn project_index(self: &Projector, cst: CstNode) Expr {
    let receiver: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    let index: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    nth_node(cst, 0) match {
        Some(child) => { receiver = self.project_expr(child) }
        None => {}
    }
    nth_node(cst, 1) match {
        Some(child) => { index = self.project_expr(child) }
        None => {}
    }
    const a = self.alloc
    return Expr.Index(IndexExpr {
        span = self.span_from(cst),
        receiver = box(a, receiver),
        index = box(a, index),
    })
}

// CST encodes callees as tokens: bare `foo` is an Identifier token (no
// NodeChild), and `a.b.method` is NodeChild(a.b) + Dot + Identifier(method).
// Rebuild from everything before the first `(` so the function name and
// UFCS method name don't get dropped.
fn project_call(self: &Projector, cst: CstNode) Expr {
    let args: List(CallArgument) = list(0, self.alloc)
    // Split children at the first `(`: callee tokens before, args after.
    let paren_idx: usize = cst.children.len
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.OpenParenthesis and paren_idx == cst.children.len {
                    paren_idx = i
                }
            }
            NodeChild(_) => {}
        }
    }
    let callee: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    let have_callee = false
    let pending_dot = false
    let callee_start: usize = cst.start
    let callee_end: usize = cst.start
    for i in 0..paren_idx {
        cst.children[i] match {
            NodeChild(child) => {
                if is_expr_kind(child.kind) {
                    callee = self.project_expr(child)
                    have_callee = true
                    callee_start = child.start
                    callee_end = child.end
                }
            }
            TokenChild(tok) => {
                if tok.kind == TokenKind.Dot {
                    pending_dot = true
                    continue
                }
                if tok.kind == TokenKind.Identifier {
                    const tok_span: SourceSpan = .{
                        file_id = self.file_id,
                        start = tok.offset,
                        length = tok.text.len,
                    }
                    if have_callee and pending_dot {
                        const member_span: SourceSpan = .{
                            file_id = self.file_id,
                            start = callee_start,
                            length = (tok.offset + tok.text.len) - callee_start,
                        }
                        const prev = callee
                        callee = Expr.MemberAccess(MemberAccessExpr {
                            span = member_span,
                            receiver = box(self.alloc, prev),
                            member = tok.text,
                        })
                        callee_end = tok.offset + tok.text.len
                    } else {
                        callee = Expr.Identifier(IdentifierExpr {
                            span = tok_span,
                            name = tok.text,
                        })
                        have_callee = true
                        callee_start = tok.offset
                        callee_end = tok.offset + tok.text.len
                    }
                    pending_dot = false
                }
            }
        }
    }
    // Walk args (everything after the `(`).
    for i in (paren_idx + 1)..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if child.kind == NodeKind.NamedArgumentExpr {
                    args.push(CallArgument.Named(self.project_named_argument(child)))
                } else if is_expr_kind(child.kind) {
                    const e = self.project_expr(child)
                    args.push(CallArgument.Positional(box(self.alloc, e)))
                }
            }
            TokenChild(_) => {}
        }
    }
    return Expr.Call(CallExpr {
        span = self.span_from(cst),
        callee = box(self.alloc, callee),
        args = args,
    })
}

fn project_named_argument(self: &Projector, cst: CstNode) NamedCallArgument {
    let name: String = ""
    let value: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.Identifier and name.len == 0 { name = tok.text }
            }
            NodeChild(child) => {
                if is_expr_kind(child.kind) { value = self.project_expr(child) }
            }
        }
    }
    const a = self.alloc
    return .{
        span = self.span_from(cst),
        name = name,
        value = box(a, value),
    }
}

fn project_cast(self: &Projector, cst: CstNode) Expr {
    let operand: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    let target: TypeExpr = TypeExpr.Error(ErrorType { span = self.span_from(cst) })
    let target_seen = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if is_expr_kind(child.kind) and !target_seen {
                    operand = self.project_expr(child)
                } else if is_type_kind(child.kind) {
                    target = self.project_type_expr(child)
                    target_seen = true
                }
            }
            TokenChild(_) => {}
        }
    }
    const a = self.alloc
    return Expr.Cast(CastExpr {
        span = self.span_from(cst),
        operand = box(a, operand),
        target = box(a, target),
    })
}

fn project_assignment(self: &Projector, cst: CstNode) Expr {
    let lhs: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    let rhs: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    let saw_lhs = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if is_expr_kind(child.kind) {
                    if !saw_lhs { lhs = self.project_expr(child); saw_lhs = true }
                    else { rhs = self.project_expr(child) }
                }
            }
            TokenChild(_) => {}
        }
    }
    const a = self.alloc
    return Expr.Assignment(AssignmentExpr {
        span = self.span_from(cst),
        lhs = box(a, lhs),
        rhs = box(a, rhs),
    })
}

fn project_coalesce(self: &Projector, cst: CstNode) Expr {
    let lhs: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    let rhs: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    let saw_lhs = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if is_expr_kind(child.kind) {
                    if !saw_lhs { lhs = self.project_expr(child); saw_lhs = true }
                    else { rhs = self.project_expr(child) }
                }
            }
            TokenChild(_) => {}
        }
    }
    const a = self.alloc
    return Expr.Coalesce(CoalesceExpr {
        span = self.span_from(cst),
        lhs = box(a, lhs),
        rhs = box(a, rhs),
    })
}

fn project_try(self: &Projector, cst: CstNode) Expr {
    let operand: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    nth_node(cst, 0) match {
        Some(child) => { operand = self.project_expr(child) }
        None => {}
    }
    const a = self.alloc
    return Expr.Try(TryExpr {
        span = self.span_from(cst),
        operand = box(a, operand),
    })
}

// `start..end` / `start..=end` / `..end` / `start..` / `..`. Parser
// always emits a `DotDot` token (no separate `DotDotEquals` surfaces yet),
// so inclusivity defaults to false. End-bound presence is detected by
// whether a second sub-node follows.
fn project_range(self: &Projector, cst: CstNode) Expr {
    let start: Expr? = null
    let end: Expr? = null
    let saw_dotdot = false
    let inclusive = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.DotDot { saw_dotdot = true }
                if tok.kind == TokenKind.DotDotEquals { saw_dotdot = true; inclusive = true }
            }
            NodeChild(child) => {
                if is_expr_kind(child.kind) {
                    if !saw_dotdot and start.is_none() { start = self.project_expr(child) }
                    else if end.is_none() { end = self.project_expr(child) }
                }
            }
        }
    }
    const a = self.alloc
    let start_ref: &Expr? = null
    start match {
        Some(e) => { start_ref = box(a, e) }
        None => {}
    }
    let end_ref: &Expr? = null
    end match {
        Some(e) => { end_ref = box(a, e) }
        None => {}
    }
    return Expr.Range(RangeExpr {
        span = self.span_from(cst),
        start = start_ref,
        end = end_ref,
        inclusive = inclusive,
    })
}

// `[1, 2, 3]` or `[v; n]`. The semicolon between value and count
// distinguishes the two forms.
fn project_array_literal(self: &Projector, cst: CstNode) Expr {
    let saw_semicolon = false
    let exprs: List(Expr) = list(0, self.alloc)
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.Semicolon { saw_semicolon = true }
            }
            NodeChild(child) => {
                if is_expr_kind(child.kind) { exprs.push(self.project_expr(child)) }
            }
        }
    }
    const a = self.alloc
    if saw_semicolon and exprs.len >= 2 {
        const value: Expr = exprs[0]
        const count: Expr = exprs[1]
        return Expr.ArrayLit(ArrayLiteralExpr {
            span = self.span_from(cst),
            kind = ArrayLiteralKind.Repeat(RepeatLiteral {
                span = self.span_from(cst),
                value = box(a, value),
                count = box(a, count),
            }),
        })
    }
    return Expr.ArrayLit(ArrayLiteralExpr {
        span = self.span_from(cst),
        kind = ArrayLiteralKind.Elements(exprs),
    })
}

// `(a, b)` parenthesised tuple vs `.{ x = 1 }` anonymous struct vs `(e)`
// grouped expression. The CST reuses `AnonymousStructExpr` for the
// tuple form (see parser `parse_paren_expression`); we distinguish by
// the leading token kind.
fn project_anon_struct_or_tuple(self: &Projector, cst: CstNode) Expr {
    let leads_with_dot = false
    let leads_with_paren = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.Dot { leads_with_dot = true; break }
                if tok.kind == TokenKind.OpenParenthesis { leads_with_paren = true; break }
                break
            }
            NodeChild(_) => { break }
        }
    }
    if leads_with_paren {
        let elements: List(Expr) = list(0, self.alloc)
        for i in 0..cst.children.len {
            cst.children[i] match {
                NodeChild(child) => {
                    if is_expr_kind(child.kind) { elements.push(self.project_expr(child)) }
                }
                TokenChild(_) => {}
            }
        }
        return Expr.TupleLit(TupleLiteralExpr {
            span = self.span_from(cst),
            elements = elements,
        })
    }
    return self.project_struct_literal(cst, false)
}

fn project_struct_construction(self: &Projector, cst: CstNode) Expr {
    return self.project_struct_literal(cst, true)
}

// `nominal` is true when the construction names a type (`Point { ... }`,
// `Type(T) { ... }`); false for the anonymous `.{ ... }` form.
fn project_struct_literal(self: &Projector, cst: CstNode, nominal: bool) Expr {
    let fields: List(StructFieldInit) = list(0, self.alloc)
    let type_expr_opt: TypeExpr? = null
    if nominal {
        type_expr_opt = self.struct_construction_type(cst)
    }
    // Field walk: identifier (= expr)?, comma. Names without `=` are
    // shorthand (`Point { x, y }`).
    let pending_name: String = ""
    let pending_span = self.span_from(cst)
    let pending_value: Expr? = null
    let pending_active = false
    let saw_equals = false
    let saw_open_brace = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.OpenBrace { saw_open_brace = true; continue }
                if !saw_open_brace { continue }
                if tok.kind == TokenKind.Identifier {
                    // Flush previous pending field as shorthand.
                    if pending_active {
                        fields.push(self.make_struct_field_init(pending_name, pending_span, pending_value))
                    }
                    pending_name = tok.text
                    pending_span = self.span_from_token(tok)
                    pending_value = null
                    pending_active = true
                    saw_equals = false
                    continue
                }
                if tok.kind == TokenKind.Equals { saw_equals = true; continue }
                if tok.kind == TokenKind.Comma {
                    if pending_active {
                        fields.push(self.make_struct_field_init(pending_name, pending_span, pending_value))
                        pending_active = false
                        pending_value = null
                    }
                    continue
                }
                if tok.kind == TokenKind.CloseBrace {
                    if pending_active {
                        fields.push(self.make_struct_field_init(pending_name, pending_span, pending_value))
                        pending_active = false
                        pending_value = null
                    }
                    continue
                }
            }
            NodeChild(child) => {
                if saw_open_brace and saw_equals and pending_active and is_expr_kind(child.kind) {
                    pending_value = self.project_expr(child)
                    // Field span covers `name = value` so source-click
                    // can find the field from inside the value.
                    pending_span = .{
                        file_id = pending_span.file_id,
                        start = pending_span.start,
                        length = child.end - pending_span.start,
                    }
                    saw_equals = false
                }
            }
        }
    }
    if pending_active {
        fields.push(self.make_struct_field_init(pending_name, pending_span, pending_value))
    }
    const a = self.alloc
    let type_ref: &TypeExpr? = null
    type_expr_opt match {
        Some(t) => { type_ref = box(a, t) }
        None => {}
    }
    return Expr.StructLit(StructLiteralExpr {
        span = self.span_from(cst),
        type_expr = type_ref,
        fields = fields,
    })
}

fn make_struct_field_init(self: &Projector, name: String, span: SourceSpan, value: Expr?) StructFieldInit {
    const a = self.alloc
    let v_ref: &Expr? = null
    value match {
        Some(e) => { v_ref = box(a, e) }
        None => {}
    }
    return .{
        span = span,
        name = name,
        value = v_ref,
    }
}

// `Point { ... }` or `Point(T) { ... }`. Reconstruct the named type by
// reading the leading identifier (plus optional `( ... )` generic-arg
// tokens before the `{`).
fn struct_construction_type(self: &Projector, cst: CstNode) TypeExpr? {
    let name: String = ""
    let name_span = self.span_from(cst)
    let generic_args: List(TypeExpr) = list(0, self.alloc)
    let in_generic = false
    let depth: i32 = 0
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.OpenBrace { break }
                if tok.kind == TokenKind.Identifier and name.len == 0 {
                    name = tok.text
                    name_span = self.span_from_token(tok)
                    continue
                }
                if tok.kind == TokenKind.OpenParenthesis {
                    in_generic = true
                    depth = depth + 1
                    continue
                }
                if tok.kind == TokenKind.CloseParenthesis {
                    depth = depth - 1
                    if depth == 0 { in_generic = false }
                    continue
                }
            }
            NodeChild(child) => {
                if in_generic and is_type_kind(child.kind) {
                    generic_args.push(self.project_type_expr(child))
                }
            }
        }
    }
    if name.len == 0 { return null }
    return TypeExpr.Named(NamedType {
        span = name_span,
        name = name,
        generic_args = generic_args,
    })
}

// Block: walks statements; last statement-expr without a terminator
// becomes `trailing`. The parser doesn't currently tag the trailing
// expression explicitly — we identify it as a final ExpressionStmt that
// the parser produced without a trailing semicolon.
fn project_block_node(self: &Projector, cst: CstNode) BlockExpr? {
    if cst.kind != NodeKind.BlockExpr { return null }
    let stmts: List(Stmt) = list(0, self.alloc)
    let trailing: Expr? = null
    // First pass: identify the last NodeChild — candidate for trailing.
    let last_child_idx: usize = 0
    let have_last = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(_) => { last_child_idx = i; have_last = true }
            TokenChild(_) => {}
        }
    }
    let last_consumed_as_trailing = false
    // Trailing eligibility: the last sub-node is an ExpressionStmt whose
    // own child is an expression and no semicolon token follows it inside
    // the block. We approximate by: last sub-node is ExpressionStmt and
    // the parser elided its semicolon (which we can't easily detect from
    // children alone). Conservative approach: every ExpressionStmt
    // projects to Stmt.Expression; callers that need trailing detection
    // can read the last stmt and treat it as trailing themselves. For now
    // we leave `trailing = null` and surface everything as a statement.
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if have_last and i == last_child_idx and child.kind == NodeKind.ExpressionStmt {
                    // Promote to trailing if the parser elided the semicolon.
                    if !ends_with_semicolon(child) {
                        for j in 0..child.children.len {
                            child.children[j] match {
                                NodeChild(inner) => {
                                    if is_expr_kind(inner.kind) {
                                        trailing = self.project_expr(inner)
                                        last_consumed_as_trailing = true
                                        break
                                    }
                                }
                                TokenChild(_) => {}
                            }
                        }
                        if last_consumed_as_trailing { continue }
                    }
                }
                const projected = self.project_stmt(child)
                projected match {
                    Some(s) => { stmts.push(s) }
                    None => {}
                }
            }
            TokenChild(_) => {}
        }
    }
    let trailing_ref: &Expr? = null
    trailing match {
        Some(e) => { trailing_ref = box(self.alloc, e) }
        None => {}
    }
    return BlockExpr {
        span = self.span_from(cst),
        stmts = stmts,
        trailing = trailing_ref,
    }
}

fn ends_with_semicolon(cst: CstNode) bool {
    if cst.children.len == 0 { return false }
    cst.children[cst.children.len - 1] match {
        TokenChild(tok) => { return tok.kind == TokenKind.Semicolon }
        NodeChild(_) => { return false }
    }
}

fn project_if_expr(self: &Projector, cst: CstNode) IfExpr {
    let condition: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    let then_branch: BlockExpr = .{
        span = self.span_from(cst),
        stmts = list(0, self.alloc),
        trailing = null,
    }
    let else_branch: ElseBranch = ElseBranch.NoElse
    let cond_seen = false
    let then_seen = false
    let saw_else = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.Else { saw_else = true }
            }
            NodeChild(child) => {
                if !cond_seen and is_expr_kind(child.kind) and child.kind != NodeKind.BlockExpr and child.kind != NodeKind.IfExpr {
                    condition = self.project_expr(child)
                    cond_seen = true
                    continue
                }
                if !then_seen and child.kind == NodeKind.BlockExpr {
                    then_branch = self.project_block_node(child).unwrap_or(then_branch)
                    then_seen = true
                    continue
                }
                if saw_else {
                    if child.kind == NodeKind.BlockExpr {
                        const b = self.project_block_node(child)
                        b match {
                            Some(blk) => { else_branch = ElseBranch.Block(blk) }
                            None => {}
                        }
                    } else if child.kind == NodeKind.IfExpr {
                        const a = self.alloc
                        const inner = self.project_if_expr(child)
                        else_branch = ElseBranch.If(box(a, inner))
                    }
                }
            }
        }
    }
    const a = self.alloc
    return IfExpr {
        span = self.span_from(cst),
        condition = box(a, condition),
        then_branch = then_branch,
        else_branch = else_branch,
    }
}

fn project_match_expr(self: &Projector, cst: CstNode) MatchExpr {
    let scrutinee: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    let arms: List(MatchArm) = list(0, self.alloc)
    let scrutinee_seen = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if !scrutinee_seen and is_expr_kind(child.kind) {
                    scrutinee = self.project_expr(child)
                    scrutinee_seen = true
                    continue
                }
                if child.kind == NodeKind.MatchArm {
                    arms.push(self.project_match_arm(child))
                }
            }
            TokenChild(_) => {}
        }
    }
    const a = self.alloc
    return .{
        span = self.span_from(cst),
        scrutinee = box(a, scrutinee),
        arms = arms,
    }
}

// `pat (if guard)? => body`. The parser doesn't surface pattern sub-nodes
// — it consumes pattern tokens loosely, then a `=>` token, then a body
// expression. The guard, if present, appears as a sub-node BEFORE `=>`.
// We extract: pattern from tokens, guard from the optional sub-node
// preceding `=>`, body from the sub-node AFTER `=>`.
fn project_match_arm(self: &Projector, cst: CstNode) MatchArm {
    let pattern_tokens: List(Token) = list(0, self.alloc)
    let guard: Expr? = null
    let body: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    let saw_arrow = false
    let in_guard = false
    let pattern_start: usize = cst.start
    let pattern_end: usize = cst.start
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.FatArrow { saw_arrow = true; continue }
                if tok.kind == TokenKind.If and !saw_arrow {
                    in_guard = true
                    continue
                }
                if !saw_arrow and !in_guard {
                    if pattern_tokens.len == 0 { pattern_start = tok.offset }
                    pattern_end = tok.offset + tok.text.len
                    pattern_tokens.push(tok)
                }
            }
            NodeChild(child) => {
                if !saw_arrow and in_guard and guard.is_none() and is_expr_kind(child.kind) {
                    guard = self.project_expr(child)
                    continue
                }
                if saw_arrow and is_expr_kind(child.kind) {
                    body = self.project_expr(child)
                }
            }
        }
    }
    const pattern = self.project_pattern_from_tokens(pattern_tokens, pattern_start, pattern_end)
    const a = self.alloc
    let guard_ref: &Expr? = null
    guard match {
        Some(e) => { guard_ref = box(a, e) }
        None => {}
    }
    return .{
        span = self.span_from(cst),
        pattern = pattern,
        guard = guard_ref,
        body = box(a, body),
    }
}

fn project_lambda_expr(self: &Projector, cst: CstNode) LambdaExpr {
    let params: List(FunctionParam) = list(0, self.alloc)
    let return_type: TypeExpr? = null
    let body: BlockExpr = .{
        span = self.span_from(cst),
        stmts = list(0, self.alloc),
        trailing = null,
    }
    // Lambda params are surfaced as a loose token run: identifier (`:`
    // type-node)? (`,` ...). We walk children, pairing each identifier
    // with the immediately-following type sub-node.
    let pending_name: String = ""
    let pending_span = self.span_from(cst)
    let pending_active = false
    let saw_open_paren = false
    let after_close_paren = false
    let body_seen = false
    let depth: i32 = 0
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.OpenParenthesis {
                    if !saw_open_paren { saw_open_paren = true; depth = 1; continue }
                    depth = depth + 1
                    continue
                }
                if tok.kind == TokenKind.CloseParenthesis {
                    depth = depth - 1
                    if depth == 0 {
                        if pending_active {
                            params.push(self.make_lambda_param(pending_name, pending_span))
                            pending_active = false
                        }
                        after_close_paren = true
                    }
                    continue
                }
                if saw_open_paren and !after_close_paren {
                    if tok.kind == TokenKind.Identifier {
                        if pending_active {
                            params.push(self.make_lambda_param(pending_name, pending_span))
                        }
                        pending_name = tok.text
                        pending_span = self.span_from_token(tok)
                        pending_active = true
                        continue
                    }
                    if tok.kind == TokenKind.Comma and pending_active {
                        params.push(self.make_lambda_param(pending_name, pending_span))
                        pending_active = false
                    }
                }
            }
            NodeChild(child) => {
                if child.kind == NodeKind.BlockExpr {
                    body = self.project_block_node(child).unwrap_or(body)
                    body_seen = true
                    continue
                }
                if !saw_open_paren or after_close_paren {
                    // Either before `(` (shouldn't happen) or after `)` —
                    // type-expression role: return type.
                    if after_close_paren and is_type_kind(child.kind) and return_type.is_none() {
                        return_type = self.project_type_expr(child)
                    }
                    continue
                }
                // Inside the param list — a type-node attaches to the
                // pending identifier.
                if is_type_kind(child.kind) and pending_active {
                    const t = self.project_type_expr(child)
                    params.push(FunctionParam {
                        span = pending_span,
                        name = pending_name,
                        type_expr = t,
                        default_value = null,
                        is_variadic = false,
                    })
                    pending_active = false
                }
            }
        }
    }
    return .{
        span = self.span_from(cst),
        params = params,
        return_type = return_type,
        body = body,
    }
}

fn make_lambda_param(self: &Projector, name: String, span: SourceSpan) FunctionParam {
    return .{
        span = span,
        name = name,
        type_expr = TypeExpr.Error(ErrorType { span = span }),
        default_value = null,
        is_variadic = false,
    }
}

fn project_interp_string(self: &Projector, cst: CstNode) InterpolatedStringExpr {
    let parts: List(InterpolationPart) = list(0, self.alloc)
    let target_args: List(Expr) = list(0, self.alloc)
    let into_builder: Expr? = null
    let after_dollar = false
    let after_paren = false
    let paren_depth: i32 = 0
    let in_body = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.Dollar { after_dollar = true; continue }
                if after_dollar and tok.kind == TokenKind.OpenParenthesis {
                    after_paren = true
                    paren_depth = paren_depth + 1
                    continue
                }
                if after_paren and tok.kind == TokenKind.CloseParenthesis {
                    paren_depth = paren_depth - 1
                    if paren_depth == 0 { after_paren = false }
                    continue
                }
                if after_dollar and !after_paren and !in_body and tok.kind == TokenKind.Identifier {
                    // `$sb"…"` write-into-builder form.
                    into_builder = Expr.Identifier(IdentifierExpr {
                        span = self.span_from_token(tok),
                        name = tok.text,
                    })
                    continue
                }
                if tok.kind == TokenKind.InterpStringStart { in_body = true; continue }
                if tok.kind == TokenKind.InterpStringEnd { in_body = false; continue }
                if in_body and tok.kind == TokenKind.InterpSegment {
                    parts.push(InterpolationPart.Text(tok.text))
                    continue
                }
            }
            NodeChild(child) => {
                if in_body and is_expr_kind(child.kind) {
                    const e = self.project_expr(child)
                    const a = self.alloc
                    parts.push(InterpolationPart.Hole(InterpolationHole {
                        span = self.span_from(child),
                        expr = box(a, e),
                        format = null,
                    }))
                    continue
                }
                if after_paren and is_expr_kind(child.kind) {
                    target_args.push(self.project_expr(child))
                }
            }
        }
    }
    let target: InterpolationTarget = InterpolationTarget.NewString(target_args)
    into_builder match {
        Some(e) => {
            const a = self.alloc
            target = InterpolationTarget.IntoBuilder(box(a, e))
        }
        None => {}
    }
    return .{
        span = self.span_from(cst),
        target = target,
        parts = parts,
    }
}

// ─────────────────────────────────────────────────────────────────────────
// Type expressions
// ─────────────────────────────────────────────────────────────────────────

fn is_type_kind(kind: NodeKind) bool {
    return kind == NodeKind.NamedType
        or kind == NodeKind.ReferenceType
        or kind == NodeKind.OptionalType
        or kind == NodeKind.ArrayType
        or kind == NodeKind.SliceType
        or kind == NodeKind.TupleType
        or kind == NodeKind.FunctionType
        or kind == NodeKind.AnonymousStructType
        or kind == NodeKind.AnonymousEnumType
}

fn project_type_expr(self: &Projector, cst: CstNode) TypeExpr {
    return cst.kind match {
        NamedType => self.project_named_type(cst),
        ReferenceType => self.project_reference_type(cst),
        OptionalType => self.project_optional_type(cst),
        ArrayType => self.project_array_type(cst),
        SliceType => self.project_slice_type(cst),
        TupleType => self.project_tuple_type(cst),
        FunctionType => self.project_function_type(cst),
        AnonymousStructType => self.project_anon_struct_type(cst),
        AnonymousEnumType => self.project_anon_enum_type(cst),
        else => TypeExpr.Error(ErrorType { span = self.span_from(cst) }),
    }
}

// `Name`, `Name(T, U)`, or `$T` (generic param binder).
fn project_named_type(self: &Projector, cst: CstNode) TypeExpr {
    let saw_dollar = false
    let name: String = ""
    let generic_args: List(TypeExpr) = list(0, self.alloc)
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.Dollar { saw_dollar = true; continue }
                if tok.kind == TokenKind.Identifier and name.len == 0 { name = tok.text }
            }
            NodeChild(child) => {
                if is_type_kind(child.kind) { generic_args.push(self.project_type_expr(child)) }
            }
        }
    }
    if saw_dollar {
        return TypeExpr.GenericBind(GenericBindType {
            span = self.span_from(cst),
            name = name,
        })
    }
    return TypeExpr.Named(NamedType {
        span = self.span_from(cst),
        name = name,
        generic_args = generic_args,
    })
}

fn project_reference_type(self: &Projector, cst: CstNode) TypeExpr {
    let inner: TypeExpr = TypeExpr.Error(ErrorType { span = self.span_from(cst) })
    nth_node(cst, 0) match {
        Some(child) => { if is_type_kind(child.kind) { inner = self.project_type_expr(child) } }
        None => {}
    }
    const a = self.alloc
    return TypeExpr.Reference(ReferenceType {
        span = self.span_from(cst),
        inner = box(a, inner),
    })
}

fn project_optional_type(self: &Projector, cst: CstNode) TypeExpr {
    let inner: TypeExpr = TypeExpr.Error(ErrorType { span = self.span_from(cst) })
    nth_node(cst, 0) match {
        Some(child) => { if is_type_kind(child.kind) { inner = self.project_type_expr(child) } }
        None => {}
    }
    const a = self.alloc
    return TypeExpr.Optional(OptionalType {
        span = self.span_from(cst),
        inner = box(a, inner),
    })
}

fn project_array_type(self: &Projector, cst: CstNode) TypeExpr {
    let element: TypeExpr = TypeExpr.Error(ErrorType { span = self.span_from(cst) })
    let length: Expr = Expr.Error(ErrorExpr { span = self.span_from(cst) })
    let element_seen = false
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if is_type_kind(child.kind) and !element_seen {
                    element = self.project_type_expr(child)
                    element_seen = true
                } else if is_expr_kind(child.kind) {
                    length = self.project_expr(child)
                }
            }
            TokenChild(_) => {}
        }
    }
    const a = self.alloc
    return TypeExpr.Array(ArrayType {
        span = self.span_from(cst),
        element = box(a, element),
        length = box(a, length),
    })
}

fn project_slice_type(self: &Projector, cst: CstNode) TypeExpr {
    let element: TypeExpr = TypeExpr.Error(ErrorType { span = self.span_from(cst) })
    nth_node(cst, 0) match {
        Some(child) => { if is_type_kind(child.kind) { element = self.project_type_expr(child) } }
        None => {}
    }
    const a = self.alloc
    return TypeExpr.Slice(SliceType {
        span = self.span_from(cst),
        element = box(a, element),
    })
}

fn project_tuple_type(self: &Projector, cst: CstNode) TypeExpr {
    let elements: List(TypeExpr) = list(0, self.alloc)
    for i in 0..cst.children.len {
        cst.children[i] match {
            NodeChild(child) => {
                if is_type_kind(child.kind) { elements.push(self.project_type_expr(child)) }
            }
            TokenChild(_) => {}
        }
    }
    return TypeExpr.Tuple(TupleType {
        span = self.span_from(cst),
        elements = elements,
    })
}

fn project_function_type(self: &Projector, cst: CstNode) TypeExpr {
    let params: List(TypeExpr) = list(0, self.alloc)
    let return_type: TypeExpr? = null
    let in_params = false
    let saw_close = false
    let depth: i32 = 0
    for i in 0..cst.children.len {
        cst.children[i] match {
            TokenChild(tok) => {
                if tok.kind == TokenKind.OpenParenthesis {
                    if !in_params { in_params = true; depth = 1; continue }
                    depth = depth + 1
                    continue
                }
                if tok.kind == TokenKind.CloseParenthesis and in_params {
                    depth = depth - 1
                    if depth == 0 { in_params = false; saw_close = true }
                    continue
                }
            }
            NodeChild(child) => {
                if !is_type_kind(child.kind) { continue }
                if in_params {
                    params.push(self.project_type_expr(child))
                } else if saw_close and return_type.is_none() {
                    return_type = self.project_type_expr(child)
                }
            }
        }
    }
    const a = self.alloc
    let ret_ref: &TypeExpr? = null
    return_type match {
        Some(t) => { ret_ref = box(a, t) }
        None => {}
    }
    return TypeExpr.Function(FunctionType {
        span = self.span_from(cst),
        params = params,
        return_type = ret_ref,
    })
}

// Inline `struct { ... }` in type position — parser consumes the body as
// loose tokens. We surface generics from `(...)` and a best-effort scan
// of `name : type` pairs inside the braces; type-side cannot be recovered
// faithfully without re-parsing.
fn project_anon_struct_type(self: &Projector, cst: CstNode) TypeExpr {
    let generics: List(GenericParam) = list(0, self.alloc)
    self.collect_generic_params_from_balanced(cst, &generics)
    let fields: List(StructField) = list(0, self.alloc)
    return TypeExpr.AnonStruct(AnonStructType {
        span = self.span_from(cst),
        generics = generics,
        fields = fields,
    })
}

fn project_anon_enum_type(self: &Projector, cst: CstNode) TypeExpr {
    let generics: List(GenericParam) = list(0, self.alloc)
    self.collect_generic_params_from_balanced(cst, &generics)
    let variants: List(EnumVariant) = list(0, self.alloc)
    return TypeExpr.AnonEnum(AnonEnumType {
        span = self.span_from(cst),
        generics = generics,
        variants = variants,
    })
}

// ─────────────────────────────────────────────────────────────────────────
// Patterns — best-effort projection from a loose token run
// ─────────────────────────────────────────────────────────────────────────
//
// The parser does not surface pattern sub-nodes (see parse_match_arm).
// Until it does, we infer the pattern from the token stream:
//   - empty / single `_` / single `else` → Wildcard
//   - single identifier → Variable
//   - integer / float / string / char / byte / true / false / null → Literal
//   - `Name(...)` or `Enum.Variant(...)` token-shape → EnumVariant
//   - anything else → an error-flavoured Wildcard (preserves span only)

fn project_pattern_from_tokens(self: &Projector, tokens: List(Token), start: usize, end: usize) Pattern {
    const span: SourceSpan = .{ file_id = self.file_id, start = start, length = end - start }
    if tokens.len == 0 {
        return Pattern.Wildcard(WildcardPattern { span = span })
    }
    if tokens.len == 1 {
        const tok = tokens[0]
        if tok.kind == TokenKind.Underscore {
            return Pattern.Wildcard(WildcardPattern { span = span })
        }
        if tok.kind == TokenKind.Else {
            return Pattern.Wildcard(WildcardPattern { span = span })
        }
        if tok.kind == TokenKind.Identifier {
            return Pattern.Variable(VariablePattern { span = span, name = tok.text })
        }
        return self.literal_pattern_for(tok, span)
    }
    // Multi-token: try `Qualifier.Name(...)` or `Name(...)` enum variant.
    return self.enum_variant_pattern_from_tokens(tokens, span)
}

fn literal_pattern_for(self: &Projector, tok: Token, span: SourceSpan) Pattern {
    if tok.kind == TokenKind.Integer {
        const split = split_numeric_suffix(tok.text, false)
        return Pattern.Literal(LiteralPattern {
            span = span,
            value = LiteralValue.Int(IntLiteral { span = span, text = split.body, suffix = split.suffix }),
        })
    }
    if tok.kind == TokenKind.Float {
        const split = split_numeric_suffix(tok.text, true)
        return Pattern.Literal(LiteralPattern {
            span = span,
            value = LiteralValue.Float(FloatLiteral { span = span, text = split.body, suffix = split.suffix }),
        })
    }
    if tok.kind == TokenKind.StringLiteral {
        return Pattern.Literal(LiteralPattern {
            span = span,
            value = LiteralValue.String(StringLiteral { span = span, text = strip_quotes(tok.text) }),
        })
    }
    if tok.kind == TokenKind.CharLiteral {
        return Pattern.Literal(LiteralPattern {
            span = span,
            value = LiteralValue.Char(CharLiteral { span = span, text = strip_quotes(tok.text) }),
        })
    }
    if tok.kind == TokenKind.ByteLiteral {
        let text = tok.text
        if text.len >= 3 and text[0] == b'b' and text[1] == b'\'' {
            text = slice_str(text, 2, text.len - 1)
        }
        return Pattern.Literal(LiteralPattern {
            span = span,
            value = LiteralValue.Byte(ByteLiteral { span = span, text = text }),
        })
    }
    if tok.kind == TokenKind.True {
        return Pattern.Literal(LiteralPattern {
            span = span,
            value = LiteralValue.Bool(BoolLiteral { span = span, value = true }),
        })
    }
    if tok.kind == TokenKind.False {
        return Pattern.Literal(LiteralPattern {
            span = span,
            value = LiteralValue.Bool(BoolLiteral { span = span, value = false }),
        })
    }
    if tok.kind == TokenKind.Null {
        return Pattern.Literal(LiteralPattern { span = span, value = LiteralValue.Null })
    }
    return Pattern.Wildcard(WildcardPattern { span = span })
}

fn enum_variant_pattern_from_tokens(self: &Projector, tokens: List(Token), span: SourceSpan) Pattern {
    let qualifier: String? = null
    let name: String = ""
    let payloads: List(Pattern) = list(0, self.alloc)
    // Read leading `Ident (`.`Ident)?` for qualifier + name; then descend
    // into the parenthesised payload list (one pattern per top-level
    // comma).
    let idx: usize = 0
    if idx < tokens.len and tokens[idx].kind == TokenKind.Identifier {
        name = tokens[idx].text
        idx = idx + 1
    }
    if idx < tokens.len and tokens[idx].kind == TokenKind.Dot {
        idx = idx + 1
        if idx < tokens.len and tokens[idx].kind == TokenKind.Identifier {
            qualifier = name
            name = tokens[idx].text
            idx = idx + 1
        }
    }
    if idx >= tokens.len {
        return Pattern.EnumVariant(EnumVariantPattern {
            span = span,
            qualifier = qualifier,
            name = name,
            payloads = payloads,
        })
    }
    // Expect `(` — otherwise fall back to a wildcard pattern.
    if tokens[idx].kind != TokenKind.OpenParenthesis {
        return Pattern.Wildcard(WildcardPattern { span = span })
    }
    idx = idx + 1
    let depth: i32 = 1
    let segment_start = idx
    while idx < tokens.len and depth > 0 {
        const tok = tokens[idx]
        if tok.kind == TokenKind.OpenParenthesis { depth = depth + 1 }
        else if tok.kind == TokenKind.CloseParenthesis {
            depth = depth - 1
            if depth == 0 {
                payloads.push(self.payload_pattern_slice(tokens, segment_start, idx))
                idx = idx + 1
                break
            }
        } else if tok.kind == TokenKind.Comma and depth == 1 {
            payloads.push(self.payload_pattern_slice(tokens, segment_start, idx))
            segment_start = idx + 1
        }
        idx = idx + 1
    }
    return Pattern.EnumVariant(EnumVariantPattern {
        span = span,
        qualifier = qualifier,
        name = name,
        payloads = payloads,
    })
}

fn payload_pattern_slice(self: &Projector, tokens: List(Token), lo: usize, hi: usize) Pattern {
    let slice_list: List(Token) = list(0, self.alloc)
    for i in lo..hi {
        slice_list.push(tokens[i])
    }
    let start: usize = 0
    let end: usize = 0
    if slice_list.len > 0 {
        const first = slice_list[0]
        const last = slice_list[slice_list.len - 1]
        start = first.offset
        end = last.offset + last.text.len
    }
    return self.project_pattern_from_tokens(slice_list, start, end)
}

// ─────────────────────────────────────────────────────────────────────────
// String / numeric utilities
// ─────────────────────────────────────────────────────────────────────────

type SuffixSplit = struct {
    body: String
    suffix: String
}

// Split `123i32` into `("123", "i32")`. Recognises the integer suffixes
// `i8/i16/i32/i64`, `u8/u16/u32/u64`, `usize/isize` and the float
// suffixes `f32/f64`. The first recognised suffix wins; anything else
// keeps the body unchanged with an empty suffix.
fn split_numeric_suffix(text: String, is_float: bool) SuffixSplit {
    if is_float {
        const float_suffixes = ["f32", "f64"]
        for i in 0..float_suffixes.len {
            const s = float_suffixes[i]
            if text.len >= s.len and tail_equals(text, s) {
                return SuffixSplit {
                    body = slice_str(text, 0, text.len - s.len),
                    suffix = s,
                }
            }
        }
        return SuffixSplit { body = text, suffix = "" }
    }
    const int_suffixes = ["i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "usize", "isize"]
    for i in 0..int_suffixes.len {
        const s = int_suffixes[i]
        if text.len >= s.len and tail_equals(text, s) {
            return SuffixSplit {
                body = slice_str(text, 0, text.len - s.len),
                suffix = s,
            }
        }
    }
    return SuffixSplit { body = text, suffix = "" }
}

fn tail_equals(text: String, suffix: String) bool {
    if text.len < suffix.len { return false }
    for i in 0..suffix.len {
        if text[text.len - suffix.len + i] != suffix[i] { return false }
    }
    return true
}

fn slice_str(s: String, lo: usize, hi: usize) String {
    if hi <= lo { return "" }
    if hi > s.len { return s }
    const ptr_offset = s.ptr as usize + lo
    return slice_from_raw_parts(ptr_offset as &u8, hi - lo)
}

// Drop one leading and one trailing byte if they form a matching quote
// pair (`"…"` for strings, `'…'` for chars). Leaves the body unchanged
// otherwise so malformed literals still surface their raw bytes.
fn strip_quotes(s: String) String {
    if s.len < 2 { return s }
    const first = s[0]
    const last = s[s.len - 1]
    const is_dq = first == b'"' and last == b'"'
    const is_sq = first == b'\'' and last == b'\''
    if is_dq or is_sq {
        return slice_str(s, 1, s.len - 1)
    }
    return s
}
