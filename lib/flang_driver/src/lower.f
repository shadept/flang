// AST -> FIR lowering: a type-checked `Module` (plus its `TypeCheckResult`,
// for per-node types by span) becomes a `flang_codegen` `IrModule`.
//
// Milestone 1 scope: straight-line single-block scalar functions - params,
// immutable `let`, int/bool literals, arithmetic/bitwise ops, `return`.
// Out-of-subset exprs lower to a placeholder; unsupported signatures skip.
//
// `ast` and `fir` both export `BinaryOp`/`UnaryOp`; neither is named here
// (operators match AST variants and emit through builder methods).

import std.allocator
import std.dict
import std.list
import std.option
import std.string
import std.test
import flang_core.span
import flang_parser.ast
import flang_typer.type
import flang_typer.node_id
import flang_typer.result
import flang_codegen.fir
import flang_codegen.builder
import flang_driver.driver

// Lower every supported top-level function in `ast_module` into a fresh
// `IrModule`. Non-function decls and unsupported functions are skipped.
pub fn lower_module(ast_module: &Module, result: &TypeCheckResult, allocator: &Allocator? = null) IrModule {
    let alloc = allocator.or_global()
    let m = module(alloc)
    for i in 0..ast_module.decls.len {
        let d = &ast_module.decls[i]
        d.* match {
            Function(fd) => lower_function(result, &m, &fd, alloc),
            _ => {},
        }
    }
    return m
}

// Lower one function declaration and append it to `m`. Returns without
// emitting when the body is absent (`#foreign`) or the signature uses a
// type this milestone can't lower yet.
fn lower_function(result: &TypeCheckResult, m: &IrModule, decl: &FunctionDecl, alloc: &Allocator) {
    if decl.body.is_none() { return }

    let return_ir: IrType? = null
    if decl.return_type.is_some() {
        let rt = decl.return_type.unwrap()
        let r = type_expr_to_ir(&rt)
        if r.is_none() { return }
        return_ir = r
    }

    let fb = function(decl.name, return_ir, alloc)
    let env: Dict(String, Operand) = dict(alloc)
    for i in 0..decl.params.len {
        let p = &decl.params[i]
        let pir = type_expr_to_ir(&p.type_expr)
        if pir.is_none() { return }
        let op = fb.param(pir.unwrap())
        env.set(p.name, op)
    }

    let entry = fb.entry()
    let body = decl.body.unwrap()
    let terminated = lower_block(result, &entry, &env, &body, alloc)
    if !terminated {
        if return_ir.is_none() {
            entry.ret_void()
        } else {
            // A value function with no return path is a checker error.
            entry.unreachable()
        }
    }

    m.add_function(fb.finish())
}

// Lower a block's statements then its trailing expression (the implicit
// return value). Returns whether a terminator was emitted.
fn lower_block(result: &TypeCheckResult, bb: &BlockBuilder, env: &Dict(String, Operand), block: &BlockExpr, alloc: &Allocator) bool {
    for i in 0..block.stmts.len {
        if lower_stmt(result, bb, env, &block.stmts[i], alloc) { return true }
    }
    if block.trailing.is_some() {
        let e = block.trailing.unwrap()
        let v = lower_expr(result, bb, env, e, alloc)
        bb.ret(v)
        return true
    }
    return false
}

// Returns whether the statement emitted a block terminator.
fn lower_stmt(result: &TypeCheckResult, bb: &BlockBuilder, env: &Dict(String, Operand), stmt: &Stmt, alloc: &Allocator) bool {
    stmt.* match {
        Return(r) => {
            lower_return(result, bb, env, &r, alloc)
            return true
        },
        Let(l) => lower_let(result, bb, env, &l, alloc),
        Expression(e) => {
            let _u = lower_expr(result, bb, env, &e.expr, alloc)
        },
        _ => {},
    }
    return false
}

fn lower_return(result: &TypeCheckResult, bb: &BlockBuilder, env: &Dict(String, Operand), r: &ReturnStmt, alloc: &Allocator) {
    if r.value.is_some() {
        let e = r.value.unwrap()
        let v = lower_expr(result, bb, env, &e, alloc)
        bb.ret(v)
    } else {
        bb.ret_void()
    }
}

// `let name = init` - immutable scalar binding: the initializer's SSA
// value is bound directly to the name. Mutated or address-taken locals
// (which need a stack slot) arrive with the rest of memory lowering.
fn lower_let(result: &TypeCheckResult, bb: &BlockBuilder, env: &Dict(String, Operand), l: &LetStmt, alloc: &Allocator) {
    if l.init.is_some() {
        let e = l.init.unwrap()
        let v = lower_expr(result, bb, env, &e, alloc)
        env.set(l.name, v)
    }
}

// Expressions

fn lower_expr(result: &TypeCheckResult, bb: &BlockBuilder, env: &Dict(String, Operand), expr: &Expr, alloc: &Allocator) Operand {
    return expr.* match {
        Lit(l) => lower_literal(&l),
        Identifier(id) => lower_identifier(env, &id),
        Binary(b) => lower_binary(result, bb, env, &b, alloc),
        Unary(u) => lower_unary(result, bb, env, &u, alloc),
        // ponytail: M1 placeholder; real lowering lands with later milestones.
        _ => Operand.IntConst(0),
    }
}

fn lower_literal(l: &LiteralExpr) Operand {
    return l.value match {
        Int(i) => Operand.IntConst(parse_int(i.text)),
        Bool(b) => Operand.IntConst(if b.value { 1 } else { 0 }),
        // Float/Char/Byte/String/Null lower later (strings need the data
        // segment; floats need a literal parser).
        _ => Operand.IntConst(0),
    }
}

fn lower_identifier(env: &Dict(String, Operand), id: &IdentifierExpr) Operand {
    let v = env.get(id.name)
    if v.is_some() { return v.unwrap() }
    // ponytail: globals and function references resolve in M2.
    return Operand.IntConst(0)
}

fn lower_binary(result: &TypeCheckResult, bb: &BlockBuilder, env: &Dict(String, Operand), b: &BinaryExpr, alloc: &Allocator) Operand {
    let lhs = lower_expr(result, bb, env, b.lhs, alloc)
    let rhs = lower_expr(result, bb, env, b.rhs, alloc)
    let ty = node_ty(result, b.span)
    let ir = ty_to_ir(&ty)
    let p = prim_of(&ty)
    let fl = is_float(p)
    let sg = is_signed_integer(p)
    return b.op match {
        Add => bb.add_op(ir, fl, lhs, rhs),
        Sub => bb.sub_op(ir, fl, lhs, rhs),
        Mul => bb.mul_op(ir, fl, lhs, rhs),
        Div => bb.div_op(ir, fl, sg, lhs, rhs),
        Mod => bb.mod_op(ir, sg, lhs, rhs),
        BitAnd => bb.iand(ir, lhs, rhs),
        BitOr => bb.ior(ir, lhs, rhs),
        BitXor => bb.ixor(ir, lhs, rhs),
        Shl => bb.ishl(ir, lhs, rhs),
        Shr => bb.shr_op(ir, sg, lhs, rhs),
        UShr => bb.ushr(ir, lhs, rhs),
        // Comparisons and short-circuit `and`/`or` need an i8 result and
        // control flow - they arrive with branching in M3.
        _ => bb.iadd(ir, lhs, rhs),
    }
}

fn add_op(bb: &BlockBuilder, ir: IrType, fl: bool, lhs: Operand, rhs: Operand) Operand {
    if fl { return bb.fadd(ir, lhs, rhs) }
    return bb.iadd(ir, lhs, rhs)
}

fn sub_op(bb: &BlockBuilder, ir: IrType, fl: bool, lhs: Operand, rhs: Operand) Operand {
    if fl { return bb.fsub(ir, lhs, rhs) }
    return bb.isub(ir, lhs, rhs)
}

fn mul_op(bb: &BlockBuilder, ir: IrType, fl: bool, lhs: Operand, rhs: Operand) Operand {
    if fl { return bb.fmul(ir, lhs, rhs) }
    return bb.imul(ir, lhs, rhs)
}

fn div_op(bb: &BlockBuilder, ir: IrType, fl: bool, sg: bool, lhs: Operand, rhs: Operand) Operand {
    if fl { return bb.fdiv(ir, lhs, rhs) }
    if sg { return bb.sdiv(ir, lhs, rhs) }
    return bb.udiv(ir, lhs, rhs)
}

fn mod_op(bb: &BlockBuilder, ir: IrType, sg: bool, lhs: Operand, rhs: Operand) Operand {
    if sg { return bb.srem(ir, lhs, rhs) }
    return bb.urem(ir, lhs, rhs)
}

fn shr_op(bb: &BlockBuilder, ir: IrType, sg: bool, lhs: Operand, rhs: Operand) Operand {
    if sg { return bb.sshr(ir, lhs, rhs) }
    return bb.ushr(ir, lhs, rhs)
}

fn lower_unary(result: &TypeCheckResult, bb: &BlockBuilder, env: &Dict(String, Operand), u: &UnaryExpr, alloc: &Allocator) Operand {
    let v = lower_expr(result, bb, env, u.operand, alloc)
    let ty = node_ty(result, u.span)
    let ir = ty_to_ir(&ty)
    let p = prim_of(&ty)
    return u.op match {
        Neg => bb.neg_op(ir, is_float(p), v),
        BitNot => bb.ixor(ir, v, Operand.IntConst(-1)),
        // `!` on bool lowers via a compare in M3.
        _ => v,
    }
}

fn neg_op(bb: &BlockBuilder, ir: IrType, fl: bool, v: Operand) Operand {
    if fl { return bb.fneg(ir, v) }
    return bb.ineg(ir, v)
}

// Type mapping

// The resolved type of the AST node at `span`, falling back to `i32`
// when the checker never recorded one (unparsed/erroneous input).
fn node_ty(result: &TypeCheckResult, span: SourceSpan) Ty {
    let t = result.get_type(node_id_of(span))
    if t.is_some() { return t.unwrap() }
    return Ty.Prim(PrimitiveKind.I32)
}

// A resolved `Ty` to its FIR scalar type. Aggregates are addressed by
// pointer (M1 never produces aggregate-typed values directly).
fn ty_to_ir(ty: &Ty) IrType {
    return ty.* match {
        Prim(p) => prim_ir(p),
        Ref(_) => IrType.Ptr,
        Func(_) => IrType.Ptr,
        _ => IrType.Ptr,
    }
}

// FIR has no unsigned or boolean primitives - signedness is a per-op
// choice, and bool is a byte. So unsigned/char/size kinds fold onto the
// same-width signed FIR scalar.
fn prim_ir(p: PrimitiveKind) IrType {
    return p match {
        Bool => IrType.I8,
        I8 => IrType.I8,
        U8 => IrType.I8,
        I16 => IrType.I16,
        U16 => IrType.I16,
        I32 => IrType.I32,
        U32 => IrType.I32,
        Char => IrType.I32,
        I64 => IrType.I64,
        U64 => IrType.I64,
        ISize => IrType.I64,
        USize => IrType.I64,
        F32 => IrType.F32,
        F64 => IrType.F64,
    }
}

// A signature `TypeExpr` to its FIR scalar type, or null when the type is
// outside this milestone's scope (aggregates, optionals, generics).
fn type_expr_to_ir(te: &TypeExpr) IrType? {
    return te.* match {
        Named(n) => named_to_ir(n.name),
        Reference(_) => IrType.Ptr,
        _ => null,
    }
}

fn named_to_ir(name: String) IrType? {
    if name == "i8" { return IrType.I8 }
    if name == "u8" { return IrType.I8 }
    if name == "bool" { return IrType.I8 }
    if name == "i16" { return IrType.I16 }
    if name == "u16" { return IrType.I16 }
    if name == "i32" { return IrType.I32 }
    if name == "u32" { return IrType.I32 }
    if name == "char" { return IrType.I32 }
    if name == "i64" { return IrType.I64 }
    if name == "u64" { return IrType.I64 }
    if name == "isize" { return IrType.I64 }
    if name == "usize" { return IrType.I64 }
    if name == "f32" { return IrType.F32 }
    if name == "f64" { return IrType.F64 }
    return null
}

fn prim_of(ty: &Ty) PrimitiveKind {
    return ty.* match {
        Prim(p) => p,
        _ => PrimitiveKind.I32,
    }
}

// Literal parsing

// Parse an integer literal's source text (decimal, `0x`, or `0b`, with
// `_` digit separators) into its value. Suffixes are stripped by the
// lexer, so `text` is digits only.
fn parse_int(text: String) i64 {
    let base: i64 = 10
    let i: usize = 0
    if text.len >= 2 {
        if text[0] == '0' {
            if text[1] == 'x' { base = 16; i = 2 }
            if text[1] == 'b' { base = 2; i = 2 }
        }
    }
    let n: i64 = 0
    while i < text.len {
        let c = text[i]
        if c != '_' {
            n = n * base + digit_val(c)
        }
        i = i + 1
    }
    return n
}

fn digit_val(c: u8) i64 {
    if c >= '0' and c <= '9' { return (c - '0') as i64 }
    if c >= 'a' and c <= 'f' { return ((c - 'a') + 10) as i64 }
    if c >= 'A' and c <= 'F' { return ((c - 'A') + 10) as i64 }
    return 0
}

// Tests

test "lowers a function over parameters into an add and a return" {
    let unit = analyze(from_view("fn add(a: i32, b: i32) i32 { return a + b }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_eq(m.functions.len, 1 as usize, "one function lowered")
    let f = &m.functions[0]
    assert_true(f.name == "add", "function name preserved")
    assert_eq(f.params.len, 2 as usize, "two parameters")
    assert_eq(f.blocks.len, 1 as usize, "single straight-line block")

    let term = f.blocks[0].terminator
    let is_ret = term match { Ret(_) => true, _ => false }
    assert_true(is_ret, "block ends in a return")

    let has_add = false
    let instrs = &f.blocks[0].instrs
    for i in 0..instrs.len {
        instrs[i] match {
            Binary(bi) => bi.op match { IAdd => has_add = true, _ => {} },
            _ => {},
        }
    }
    assert_true(has_add, "emitted an integer add")
}

test "lowers a constant-returning main" {
    let unit = analyze(from_view("fn main() i32 { return 40 + 2 }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_eq(m.functions.len, 1 as usize, "one function lowered")
    let f = &m.functions[0]
    assert_true(f.name == "main", "function name preserved")

    let saw_consts = false
    let instrs = &f.blocks[0].instrs
    for i in 0..instrs.len {
        instrs[i] match {
            Binary(bi) => {
                let l_const = bi.lhs match { IntConst(_) => true, _ => false }
                let r_const = bi.rhs match { IntConst(_) => true, _ => false }
                if l_const and r_const { saw_consts = true }
            },
            _ => {},
        }
    }
    assert_true(saw_consts, "constant operands lowered to IntConst")
}

test "binds an immutable let and reuses it" {
    let unit = analyze(from_view("fn f(a: i32) i32 { let b = a + 1; return b + b }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_eq(m.functions.len, 1 as usize, "one function lowered")
    let f = &m.functions[0]

    let adds = 0
    let instrs = &f.blocks[0].instrs
    for i in 0..instrs.len {
        instrs[i] match {
            Binary(bi) => bi.op match { IAdd => adds = adds + 1, _ => {} },
            _ => {},
        }
    }
    assert_eq(adds as usize, 2 as usize, "let init and the return each add")
}

test "skips a function with an unsupported signature type" {
    let unit = analyze(from_view("fn takes_slice(xs: i32[]) i32 { return 0 }\nfn ok() i32 { return 1 }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_eq(m.functions.len, 1 as usize, "only the scalar function is lowered")
    let f = &m.functions[0]
    assert_true(f.name == "ok", "the slice-taking function was skipped")
}
