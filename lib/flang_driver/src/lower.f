// AST -> FIR lowering: a type-checked `Module` (plus its `TypeCheckResult`,
// for per-node types by span) becomes a `flang_codegen` `IrModule`.
//
// Milestone 1 scope: straight-line single-block scalar functions - params,
// immutable `let`, int/bool literals, arithmetic/bitwise ops, `return`.
// Milestone 2 adds direct and UFCS calls to functions whose signatures
// lower. Out-of-subset exprs lower to a placeholder; unsupported
// signatures skip.
//
// `ast` and `fir` both export `BinaryOp`/`UnaryOp`; neither is named here
// (operators match AST variants and emit through builder methods).

import std.allocator
import std.dict
import std.list
import std.option
import std.string
import std.string_builder
import std.test
import flang_core.span
import flang_parser.ast
import flang_typer.type
import flang_typer.node_id
import flang_typer.result
import flang_typer.nominal_registry
import flang_typer.function_registry
import flang_typer.inference_results
import flang_typer.scheme
import flang_codegen.fir
import flang_codegen.builder
import flang_driver.driver
import flang_driver.layout

// Symbol table
//
// Definitions and call sites have to agree on every emitted C symbol. The
// merged program puts all modules in one translation unit, so a name is
// unique only after module-path mangling plus an ordinal for same-name
// overloads — and an ordinal handed out while walking definitions is not
// something a call site can re-derive. So symbols are assigned once, up
// front, and both sides read the same table.
//
// Call sites key by `FunctionScheme.id` — the id the checker records on
// each resolved call node as `RtFunction`. Definitions key by the decl's
// span fingerprint, which is how a `FunctionDecl` finds its own id.
//
// Membership is also the "is this callable?" gate: a function whose
// signature this milestone cannot lower is left out, so a call to it
// falls back to a placeholder rather than naming a symbol the module
// never defines — which would fail to link.
pub type SymbolTable = struct {
    by_fn_id: Dict(u32, String)
    by_decl: Dict(NodeId, u32)
}

pub fn lookup_symbol(self: &SymbolTable, fn_id: u32) String? {
    return self.by_fn_id.get(fn_id)
}

// The registry id of the function this declaration declares.
pub fn decl_fn_id(self: &SymbolTable, decl: &FunctionDecl) u32? {
    return self.by_decl.get(node_id_of(decl.span))
}

pub fn deinit(self: &SymbolTable) {
    self.by_fn_id.deinit()
    self.by_decl.deinit()
}

// Assigns symbols across a whole program. `seen` carries the ordinal
// counter across modules, so the walk order fixes the ordinals — which is
// why symbols are assigned before any body lowers, not during.
// The two tables are held flat rather than as a nested `SymbolTable`:
// mutating a dict two field-hops deep through a reference does not stick.
type SymbolBuilder = struct {
    by_fn_id: Dict(u32, String)
    by_decl: Dict(NodeId, u32)
    by_decl_params: Dict(NodeId, List(Ty))
    nominals: &NominalRegistry
    allocator: &Allocator
}

// Index every registered scheme by its declaration span up front, together
// with the declared parameter types the symbol is derived from; the
// per-module walk then maps each decl to its id with one lookup.
fn symbol_builder(result: &TypeCheckResult, allocator: &Allocator? = null) SymbolBuilder {
    let alloc = allocator.or_global()
    let by_fn_id: Dict(u32, String) = dict(alloc)
    let by_decl: Dict(NodeId, u32) = dict(alloc)
    let by_decl_params: Dict(NodeId, List(Ty)) = dict(alloc)
    for entry in result.functions.by_name {
        let overloads = entry.value
        for i in 0..overloads.len {
            let f = &overloads[i]
            let nid = node_id_of(f.decl_span)
            by_decl.set(nid, f.id)
            by_decl_params.set(nid, scheme_params(&f.signature, alloc))
        }
    }
    return .{
        by_fn_id = by_fn_id,
        by_decl = by_decl,
        by_decl_params = by_decl_params,
        nominals = &result.nominals,
        allocator = alloc,
    }
}

// The declared parameter types of a function scheme. A scheme whose body
// isn't a function type has no parameters to encode.
fn scheme_params(s: &Scheme, allocator: &Allocator) List(Ty) {
    return s.body match {
        Func(ft) => ft.params,
        _ => list(0, allocator),
    }
}

// Record a symbol for each of `ast_module`'s callable functions.
fn add_module(self: &SymbolBuilder, ast_module: &Module, fqn: String) {
    for i in 0..ast_module.decls.len {
        let d = &ast_module.decls[i]
        d.* match {
            Function(fd) => add_function_symbol(self, &fd, fqn),
            _ => {},
        }
    }
}

fn add_function_symbol(self: &SymbolBuilder, decl: &FunctionDecl, fqn: String) {
    if !is_callable_signature(decl) { return }
    let nid = node_id_of(decl.span)
    let fid = self.by_decl.get(nid)
    if fid.is_none() { return }
    let params: List(Ty) = list(0, self.allocator)
    let declared = self.by_decl_params.get(nid)
    if declared.is_some() { params = declared.unwrap() }
    let sym = mangle_symbol(fqn, decl.name, is_foreign_directive(&decl.directives),
        &params, self.nominals, self.allocator)
    self.by_fn_id.set(fid.unwrap(), sym)
}

fn finish(self: &SymbolBuilder) SymbolTable {
    self.by_decl_params.deinit()
    return SymbolTable { by_fn_id = self.by_fn_id, by_decl = self.by_decl }
}

// Whether a call to this function can be lowered: every parameter and the
// return type must map to a FIR scalar. Variadic functions are declared
// (so the backend still emits their extern) but not called — the variadic
// portion needs per-argument types the call site doesn't carry yet.
fn is_callable_signature(decl: &FunctionDecl) bool {
    if decl.return_type.is_some() {
        let rt = decl.return_type.unwrap()
        if type_expr_to_ir(&rt).is_none() { return false }
    }
    for i in 0..decl.params.len {
        let p = &decl.params[i]
        if p.is_variadic { return false }
        if type_expr_to_ir(&p.type_expr).is_none() { return false }
    }
    return true
}

// Lowering context — everything the walk needs besides the block cursor
// and the local environment. Bundled rather than threaded separately so
// later milestones (loop labels for M3, arm state for M5) get a home
// without touching every signature again.
type LowerCtx = struct {
    result: &TypeCheckResult
    syms: &SymbolTable
    allocator: &Allocator
}

// Lower every supported top-level function in `ast_module` into a fresh
// `IrModule`. Non-function decls and unsupported functions are skipped.
pub fn lower_module(ast_module: &Module, result: &TypeCheckResult, allocator: &Allocator? = null) IrModule {
    let alloc = allocator.or_global()
    let m = module(alloc)
    let sb = symbol_builder(result, alloc)
    sb.add_module(ast_module, "")
    let syms = sb.finish()
    let ctx = LowerCtx { result = result, syms = &syms, allocator = alloc }
    lower_into(&m, &ctx, ast_module, "")
    syms.deinit()
    return m
}

// Lower every supported module of a checked project into one `IrModule`,
// sharing the project-wide `TypeCheckResult`. Cross-module references
// resolve through that result; every function lands in one program so the
// backend links it in a single pass. `fqns` is parallel to `modules`; each
// function's symbol is namespaced by its module so merged same-named
// functions cannot collide.
pub fn lower_program(modules: &List(Module), fqns: &List(OwnedString), result: &TypeCheckResult, allocator: &Allocator? = null) IrModule {
    let alloc = allocator.or_global()
    let m = module(alloc)
    let sb = symbol_builder(result, alloc)
    for i in 0..modules.len {
        sb.add_module(&modules[i], fqns[i].as_view())
    }
    let syms = sb.finish()
    let ctx = LowerCtx { result = result, syms = &syms, allocator = alloc }
    for i in 0..modules.len {
        lower_into(&m, &ctx, &modules[i], fqns[i].as_view())
    }
    syms.deinit()
    return m
}

// Lower `ast_module`'s supported functions into the existing `m`.
fn lower_into(m: &IrModule, ctx: &LowerCtx, ast_module: &Module, fqn: String) {
    for i in 0..ast_module.decls.len {
        let d = &ast_module.decls[i]
        d.* match {
            Function(fd) => lower_decl(m, ctx, &fd, fqn),
            _ => {},
        }
    }
}

// A function declaration becomes a defined FIR function, or — when it has
// no body — an external declaration so calls to it compile. Both are
// gated on the signature; `SymbolTable` membership mirrors that gate.
fn lower_decl(m: &IrModule, ctx: &LowerCtx, decl: &FunctionDecl, fqn: String) {
    if decl.body.is_none() {
        let fd = foreign_decl_of(decl, ctx.allocator)
        if fd.is_some() { m.add_foreign(fd.unwrap()) }
        return
    }
    lower_function(m, ctx, decl)
}

// A body-less declaration as an external symbol. Null when a parameter or
// the return type is outside the subset — the backend can't spell it, and
// nothing can call it. The variadic tail is dropped from `param_types`
// and flagged, matching C's `(fixed..., ...)` shape.
fn foreign_decl_of(decl: &FunctionDecl, allocator: &Allocator) ForeignDecl? {
    let ret: IrType? = null
    if decl.return_type.is_some() {
        let rt = decl.return_type.unwrap()
        let r = type_expr_to_ir(&rt)
        if r.is_none() { return null }
        ret = r
    }
    let ptys: List(IrType) = list(decl.params.len, allocator)
    let variadic = false
    for i in 0..decl.params.len {
        let p = &decl.params[i]
        if p.is_variadic {
            variadic = true
            continue
        }
        let pir = type_expr_to_ir(&p.type_expr)
        if pir.is_none() {
            ptys.deinit()
            return null
        }
        ptys.push(pir.unwrap())
    }
    return ForeignDecl {
        name = decl.name,
        return_ty = ret,
        param_types = ptys,
        variadic = variadic,
        cc = CallConv.C,
    }
}

// Symbol mangling (docs/spec.md 7.1.1, docs/adr/0004)
//
// A symbol is a `_`-joined sequence of escaped segments: the module path,
// the function name, then one token per parameter type. Parameter types are
// what separate overloads, so no counter is involved and a symbol is a pure
// function of the declaration — inserting a function cannot rename another.
//
// Escaping: a literal `_` in a source identifier is written `_0`, so a lone
// `_` never occurs inside a segment and the `__` from joining is
// unambiguously a separator. Without this, module `a.b` fn `c` and module
// `a` fn `b__c` both produced `a__b__c`.

// Append `s` with source underscores escaped as `_0`.
fn append_escaped(sb: &StringBuilder, s: String) {
    for i in 0..s.len {
        if s[i] == '_' {
            sb.append("_0")
        } else {
            sb.append_byte(s[i])
        }
    }
}

// Append a module path: `.` becomes the segment separator, and source
// underscores inside each segment are escaped, in one pass.
fn append_module_path(sb: &StringBuilder, fqn: String) {
    for i in 0..fqn.len {
        if fqn[i] == '.' {
            sb.append("__")
        } else {
            if fqn[i] == '_' {
                sb.append("_0")
            } else {
                sb.append_byte(fqn[i])
            }
        }
    }
}

// One token per parameter type. Distinct types must produce distinct
// tokens; unresolved and inference types collapse to `t` because they
// cannot appear in a lowered signature (the callable gate rejects them).
fn append_type_token(sb: &StringBuilder, ty: &Ty, reg: &NominalRegistry) {
    ty.* match {
        Prim(p) => sb.append(prim_token(p)),
        Ref(inner) => {
            sb.append("ref_")
            append_type_token(sb, inner, reg)
        },
        Array(arr) => {
            sb.append("arr")
            sb.append(arr.length as u64)
            sb.append("_")
            append_type_token(sb, arr.elem, reg)
        },
        Tuple(elems) => {
            sb.append("tup")
            for i in 0..elems.len {
                sb.append("_")
                append_type_token(sb, &elems[i], reg)
            }
        },
        Nominal(nr) => {
            // The name is an FQN, so it carries dots - route it through the
            // same escaping as a module path or the token is not a valid C
            // identifier.
            append_module_path(sb, nominal_name(reg, nr.id))
            for i in 0..nr.args.len {
                sb.append("_")
                append_type_token(sb, &nr.args[i], reg)
            }
        },
        Void => sb.append("void"),
        Never => sb.append("never"),
        _ => sb.append("t"),
    }
}

// The declaring FQN, so two same-named types from different modules do
// not produce the same token.
fn nominal_name(reg: &NominalRegistry, id: NominalId) String {
    return reg.get(id).* match {
        NomStruct(s) => s.fqn,
        NomEnum(e) => e.fqn,
    }
}

fn prim_token(p: PrimitiveKind) String {
    return p match {
        Bool => "bool",
        I8 => "i8",
        U8 => "u8",
        I16 => "i16",
        U16 => "u16",
        I32 => "i32",
        U32 => "u32",
        Char => "char",
        I64 => "i64",
        U64 => "u64",
        ISize => "isize",
        USize => "usize",
        F32 => "f32",
        F64 => "f64",
    }
}

// The C symbol a function lowers to. The entry point and foreign functions
// keep their declared names — both name symbols fixed outside the compiler
// (the backend's entry wiring, and the C linker). Everything else is
// qualified by module path and separated by parameter types.
fn mangle_symbol(fqn: String, name: String, is_foreign: bool, params: &List(Ty), reg: &NominalRegistry, allocator: &Allocator? = null) String {
    if is_foreign { return name }
    if name == "main" { return name }

    let sb = string_builder(fqn.len + name.len + 16, allocator)
    if fqn.len > 0 {
        append_module_path(&sb, fqn)
        sb.append("__")
    }
    append_escaped(&sb, name)
    for i in 0..params.len {
        sb.append("__")
        append_type_token(&sb, &params[i], reg)
    }
    // ponytail: symbol strings are leaked - one-shot builds exit before it
    // matters; arena-own IrModule names if the LSP ever lowers.
    let owned = sb.to_string()
    sb.deinit()
    return owned.as_view()
}

// Lower one function definition and append it to `m`. Returns without
// emitting when the signature uses a type this milestone can't lower, or
// when the symbol pre-pass didn't register one — the two gates are the
// same test, so a skipped definition is also an uncallable one.
fn lower_function(m: &IrModule, ctx: &LowerCtx, decl: &FunctionDecl) {
    let fid = ctx.syms.decl_fn_id(decl)
    if fid.is_none() { return }
    let sym_opt = ctx.syms.lookup_symbol(fid.unwrap())
    if sym_opt.is_none() { return }
    let sym = sym_opt.unwrap()

    let return_ir: IrType? = null
    if decl.return_type.is_some() {
        let rt = decl.return_type.unwrap()
        let r = type_expr_to_ir(&rt)
        if r.is_none() { return }
        return_ir = r
    }

    let fb = function(sym, return_ir, ctx.allocator)
    let env: Dict(String, Operand) = dict(ctx.allocator)
    for i in 0..decl.params.len {
        let p = &decl.params[i]
        let pir = type_expr_to_ir(&p.type_expr)
        if pir.is_none() { return }
        let op = fb.param(pir.unwrap())
        env.set(p.name, op)
    }

    let entry = fb.entry()
    let body = decl.body.unwrap()
    let terminated = lower_block(ctx, &entry, &env, &body)
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
fn lower_block(ctx: &LowerCtx, bb: &BlockBuilder, env: &Dict(String, Operand), block: &BlockExpr) bool {
    for i in 0..block.stmts.len {
        if lower_stmt(ctx, bb, env, &block.stmts[i]) { return true }
    }
    if block.trailing.is_some() {
        let e = block.trailing.unwrap()
        let v = lower_expr(ctx, bb, env, e)
        bb.ret(v)
        return true
    }
    return false
}

// Returns whether the statement emitted a block terminator.
fn lower_stmt(ctx: &LowerCtx, bb: &BlockBuilder, env: &Dict(String, Operand), stmt: &Stmt) bool {
    stmt.* match {
        Return(r) => {
            lower_return(ctx, bb, env, &r)
            return true
        },
        Let(l) => lower_let(ctx, bb, env, &l),
        Expression(e) => {
            let _u = lower_expr(ctx, bb, env, &e.expr)
        },
        _ => {},
    }
    return false
}

fn lower_return(ctx: &LowerCtx, bb: &BlockBuilder, env: &Dict(String, Operand), r: &ReturnStmt) {
    if r.value.is_some() {
        let e = r.value.unwrap()
        let v = lower_expr(ctx, bb, env, &e)
        bb.ret(v)
    } else {
        bb.ret_void()
    }
}

// `let name = init` - immutable scalar binding: the initializer's SSA
// value is bound directly to the name. Mutated or address-taken locals
// (which need a stack slot) arrive with the rest of memory lowering.
fn lower_let(ctx: &LowerCtx, bb: &BlockBuilder, env: &Dict(String, Operand), l: &LetStmt) {
    if l.init.is_some() {
        let e = l.init.unwrap()
        let v = lower_expr(ctx, bb, env, &e)
        env.set(l.name, v)
    }
}

// Expressions

fn lower_expr(ctx: &LowerCtx, bb: &BlockBuilder, env: &Dict(String, Operand), expr: &Expr) Operand {
    return expr.* match {
        Lit(l) => lower_literal(&l),
        Identifier(id) => lower_identifier(env, &id),
        Binary(b) => lower_binary(ctx, bb, env, &b),
        Unary(u) => lower_unary(ctx, bb, env, &u),
        StructLit(s) => lower_struct_lit(ctx, bb, env, &s),
        MemberAccess(m) => lower_member(ctx, bb, env, &m),
        Call(c) => lower_call(ctx, bb, env, &c),
        // ponytail: M1 placeholder; real lowering lands with later milestones.
        _ => Operand.IntConst(0),
    }
}

// Calls (M2)
//
// The checker already picked the callee — overload, UFCS receiver, and
// default arguments are all settled by the time lowering runs, and the
// winner is recorded on the call node as `RtFunction(id)`. So lowering
// does not re-resolve anything: it maps that id through the symbol table
// and emits the args in order.
//
// A call falls back to the placeholder when the node carries no
// `RtFunction` (a variant constructor, an indirect call, or one of the
// checker's deliberate fresh-var fallbacks such as named arguments), or
// when the callee's signature was outside the lowerable subset — in that
// case there is no definition in the module to link against.
fn lower_call(ctx: &LowerCtx, bb: &BlockBuilder, env: &Dict(String, Operand), call: &CallExpr) Operand {
    let sym_opt = callee_symbol(ctx, call)
    if sym_opt.is_none() { return Operand.IntConst(0) }
    let sym = sym_opt.unwrap()

    let args: List(Operand) = list(call.args.len + 1, ctx.allocator)
    // A UFCS call `recv.f(a)` resolved to a free function takes the
    // receiver as its first argument; the AST still shows it as the
    // callee's member base, so it is prepended here. A member-access
    // callee that resolved to a free function is UFCS by construction —
    // a field holding a function value resolves indirectly and never
    // reaches here (no `RtFunction`, so `callee_symbol` already bailed).
    call.callee.* match {
        MemberAccess(ma) => args.push(lower_expr(ctx, bb, env, ma.receiver)),
        _ => {},
    }
    for i in 0..call.args.len {
        call.args[i] match {
            Positional(e) => args.push(lower_expr(ctx, bb, env, e)),
            // Named arguments never reach here: the checker leaves those
            // calls unresolved, so `callee_symbol` already bailed.
            Named(_) => {},
        }
    }

    let ret = node_ty(ctx.result, call.span)
    let is_void = ret match { Void => true, _ => false }
    if is_void {
        bb.call_void(sym, args)
        return Operand.IntConst(0)
    }
    return bb.call(sym, ty_to_ir(&ret), args)
}

// The emitted symbol for a resolved call, or null when the call has no
// lowerable direct target.
fn callee_symbol(ctx: &LowerCtx, call: &CallExpr) String? {
    let target = ctx.result.get_target(node_id_of(call.span))
    if target.is_none() { return null }
    let fid = target.unwrap() match {
        RtFunction(id) => Some(id),
        _ => null,
    }
    if fid.is_none() { return null }
    return ctx.syms.lookup_symbol(fid.unwrap())
}

// Structs and member access (M4, minimal)
//
// FIR is flat - aggregates are opaque byte buffers addressed by pointer. A
// struct value is therefore the pointer to its bytes: a literal allocates a
// stack slot and stores each field at its layout offset, and a member access
// geps to the field's offset and loads it. Field offsets come from
// `layout.struct_layout` (auto-repr reorders fields, but offsets stay keyed by
// declaration index, so a field's declared position addresses them directly).

// A struct value's registry definition (field names and types) paired with
// its computed byte layout (per-field offsets, total size, alignment).
type StructTarget = struct {
    def: StructDef
    layout: StructLayout
}

// `S { f = v, ... }` - allocate a slot the size of the struct and store each
// initializer at its field offset. The value is the slot pointer. Aggregate
// fields copy their bytes; scalar fields store by value.
fn lower_struct_lit(ctx: &LowerCtx, bb: &BlockBuilder, env: &Dict(String, Operand), lit: &StructLiteralExpr) Operand {
    let reg = &ctx.result.nominals
    let ty = node_ty(ctx.result, lit.span)
    let target = resolve_struct(&ty, reg, ctx.allocator)
    if target.is_none() { return Operand.IntConst(0) }
    let st = target.unwrap()

    let slot = bb.stack_slot(st.layout.size as u64, st.layout.align as u64)
    for i in 0..lit.fields.len {
        let fi = &lit.fields[i]
        let di = field_index(&st.def, fi.name)
        if di < 0 { continue }
        let didx = di as usize
        let off = st.layout.offsets[didx]
        let fty = &st.def.fields[didx].ty
        let v = lower_field_init(ctx, bb, env, fi)
        let fp = bb.gep(slot, Operand.IntConst(off as i64))
        if is_aggregate(fty) {
            bb.memcpy(fp, v, Operand.IntConst(layout_of(fty, reg, ctx.allocator).size as i64))
        } else {
            bb.store(ty_to_ir(fty), v, fp)
        }
    }
    return slot
}

// The value of a field initializer: the explicit expression, or - for
// shorthand `S { x }` - the in-scope binding named like the field.
fn lower_field_init(ctx: &LowerCtx, bb: &BlockBuilder, env: &Dict(String, Operand), fi: &StructFieldInit) Operand {
    if fi.value.is_some() {
        return lower_expr(ctx, bb, env, fi.value.unwrap())
    }
    let got = env.get(fi.name)
    if got.is_some() { return got.unwrap() }
    return Operand.IntConst(0)
}

// Place lowering (docs/spec.md 3.4.1, docs/adr/0003)
//
// `lower_expr` yields a VALUE; `lower_place` yields the ADDRESS of a storage
// location. They are deliberately separate entry points: a place context that
// reaches for `lower_expr` copies the aggregate, and every write through the
// result is silently discarded — the defect ADR 0003 documents on the C# side,
// found at four independent sites there. Null means the expression is not a
// place and has no address.
//
// FIR addresses aggregates by pointer, so today `lower_expr` and `lower_place`
// happen to agree on a struct-typed member. They do *not* agree on a scalar
// member — `lower_expr` loads it — which is exactly what assignment (M3), `&`,
// and element stores need. The split is established now, before those land, so
// the C# archaeology is not repeated here.
fn lower_place(ctx: &LowerCtx, bb: &BlockBuilder, env: &Dict(String, Operand), expr: &Expr) Operand? {
    return expr.* match {
        Identifier(id) => place_of_identifier(env, &id),
        MemberAccess(ma) => member_address(ctx, bb, env, &ma),
        // `p.*` — the pointer already is the address.
        Dereference(d) => Some(lower_expr(ctx, bb, env, d.operand)),
        _ => null,
    }
}

// The address of a base in a place context. Place-ness propagates leftward
// through a path (spec 3.4.1), so a base that is itself a place is addressed
// rather than copied; anything else falls back to its value.
fn lower_base_address(ctx: &LowerCtx, bb: &BlockBuilder, env: &Dict(String, Operand), base: &Expr) Operand {
    let p = lower_place(ctx, bb, env, base)
    if p.is_some() { return p.unwrap() }
    return lower_expr(ctx, bb, env, base)
}

// A local's storage. Aggregate locals are bound to their slot pointer, so the
// binding is already the address.
//
// ponytail: scalar locals are bound as SSA values with no stack slot (M1), so
// they have no address to hand back. M3 must give mutated and address-taken
// locals a slot; until then `x = v` and `&x` on a scalar are out of subset.
fn place_of_identifier(env: &Dict(String, Operand), id: &IdentifierExpr) Operand? {
    return env.get(id.name)
}

// The address of `ma`'s field: gep to the field offset off the receiver's
// address. Null when the receiver isn't a resolvable struct.
fn member_address(ctx: &LowerCtx, bb: &BlockBuilder, env: &Dict(String, Operand), ma: &MemberAccessExpr) Operand? {
    let reg = &ctx.result.nominals
    let recv_ty = node_ty(ctx.result, expr_span(ma.receiver))
    let target = resolve_struct(&recv_ty, reg, ctx.allocator)
    if target.is_none() { return null }
    let st = target.unwrap()
    let di = field_index(&st.def, ma.member)
    if di < 0 { return null }
    let off = st.layout.offsets[di as usize]

    let base = lower_base_address(ctx, bb, env, ma.receiver)
    return Some(bb.gep(base, Operand.IntConst(off as i64)))
}

// `recv.field` in VALUE position - address the field, then load a scalar. An
// aggregate member yields its address (FIR addresses aggregates by pointer),
// so nested `a.b.c` chains gep without an intermediate copy.
fn lower_member(ctx: &LowerCtx, bb: &BlockBuilder, env: &Dict(String, Operand), ma: &MemberAccessExpr) Operand {
    let fpo = member_address(ctx, bb, env, ma)
    if fpo.is_none() { return Operand.IntConst(0) }
    let fp = fpo.unwrap()
    let mty = node_ty(ctx.result, ma.span)
    if is_aggregate(&mty) { return fp }
    return bb.load(ty_to_ir(&mty), fp)
}

// Resolve a value's static type to the struct it names, peeling one
// reference. Null for enums, scalars, and unresolved types - the caller
// emits its placeholder rather than crash.
fn resolve_struct(ty: &Ty, reg: &NominalRegistry, allocator: &Allocator?) StructTarget? {
    let peeled = ty.* match {
        Ref(inner) => inner.*,
        _ => ty.*,
    }
    let nr = peeled match {
        Nominal(n) => n,
        _ => return null,
    }
    return reg.get(nr.id).* match {
        NomStruct(s) => Some(StructTarget { def = s, layout = struct_layout(&s, &nr.args, reg, allocator) }),
        _ => null,
    }
}

// Declaration index of a named field, or -1 when absent (an already-reported
// checker error - the caller emits a placeholder rather than index past the
// list).
fn field_index(def: &StructDef, name: String) i64 {
    for i in 0..def.fields.len {
        if def.fields[i].name == name { return i as i64 }
    }
    return -1
}

// Whether a type is addressed by pointer in FIR. Aggregates yield their
// address on member access and copy their bytes when stored into a field;
// scalars (including references and function values) are held by value.
fn is_aggregate(ty: &Ty) bool {
    return ty.* match {
        Nominal(_) => true,
        Record(_) => true,
        Tuple(_) => true,
        Array(_) => true,
        _ => false,
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

fn lower_binary(ctx: &LowerCtx, bb: &BlockBuilder, env: &Dict(String, Operand), b: &BinaryExpr) Operand {
    let lhs = lower_expr(ctx, bb, env, b.lhs)
    let rhs = lower_expr(ctx, bb, env, b.rhs)
    let ty = node_ty(ctx.result, b.span)
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
    if is_const_zero(&rhs) { return Operand.IntConst(0) }
    if fl { return bb.fdiv(ir, lhs, rhs) }
    if sg { return bb.sdiv(ir, lhs, rhs) }
    return bb.udiv(ir, lhs, rhs)
}

fn mod_op(bb: &BlockBuilder, ir: IrType, sg: bool, lhs: Operand, rhs: Operand) Operand {
    if is_const_zero(&rhs) { return Operand.IntConst(0) }
    if sg { return bb.srem(ir, lhs, rhs) }
    return bb.urem(ir, lhs, rhs)
}

// A literal zero divisor is a constant expression C refuses to compile;
// placeholder lowering produces them, so dividing by one lowers to a
// placeholder value too.
fn is_const_zero(op: &Operand) bool {
    return op.* match {
        IntConst(n) => n == 0,
        _ => false,
    }
}

fn shr_op(bb: &BlockBuilder, ir: IrType, sg: bool, lhs: Operand, rhs: Operand) Operand {
    if sg { return bb.sshr(ir, lhs, rhs) }
    return bb.ushr(ir, lhs, rhs)
}

fn lower_unary(ctx: &LowerCtx, bb: &BlockBuilder, env: &Dict(String, Operand), u: &UnaryExpr) Operand {
    let v = lower_expr(ctx, bb, env, u.operand)
    let ty = node_ty(ctx.result, u.span)
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

// A resolved `Ty` to its FIR scalar type. References and function values
// are pointers; anything outside this milestone's subset folds to `i64`
// so placeholder arithmetic over it still emits compilable C (a pointer
// operand inside a float op does not).
fn ty_to_ir(ty: &Ty) IrType {
    return ty.* match {
        Prim(p) => prim_ir(p),
        Ref(_) => IrType.Ptr,
        Func(_) => IrType.Ptr,
        _ => IrType.I64,
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

// The callee of the first call instruction in `f`, or "" when it emits
// none. Test helper.
fn first_callee(f: &Function) String {
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            let hit = instrs[i] match {
                Call(c) => c.callee,
                _ => "",
            }
            if hit.len > 0 { return hit }
        }
    }
    return ""
}

// How many arguments the first call instruction in `f` passes.
fn first_call_argc(f: &Function) usize {
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            let n = instrs[i] match {
                Call(c) => c.args.len + 1,
                _ => 0 as usize,
            }
            if n > 0 { return n - 1 }
        }
    }
    return 0
}

fn find_fn(m: &IrModule, name: String) usize {
    for i in 0..m.functions.len {
        if m.functions[i].name == name { return i }
    }
    return m.functions.len
}

test "assigns one symbol per callable function, keyed by registry id" {
    let unit = analyze(from_view("fn add(a: i32, b: i32) i32 { return a + b }"), "test.f")
    let sb = symbol_builder(&unit.result)
    assert_eq(sb.by_decl.length, 1 as usize, "the decl span keys back to a registry id")
    sb.add_module(&unit.module, "")
    assert_eq(sb.by_fn_id.length, 1 as usize, "one symbol assigned")
}

test "lowers a direct call to the callee's mangled symbol" {
    let unit = analyze(from_view("fn callee(a: i32) i32 { return a }\nfn main() i32 { return callee(7) }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_eq(m.functions.len, 2 as usize, "both functions lowered")
    let mi = find_fn(&m, "main")
    assert_true(mi < m.functions.len, "main was lowered")
    assert_true(first_callee(&m.functions[mi]) == "callee__i32", "call names the callee's signature symbol")
    assert_eq(first_call_argc(&m.functions[mi]), 1 as usize, "one argument passed")
}

test "a UFCS call passes the receiver as the first argument" {
    let unit = analyze(from_view("fn twice(a: i32) i32 { return a + a }\nfn main() i32 { let x = 5 return x.twice() }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let mi = find_fn(&m, "main")
    assert_true(mi < m.functions.len, "main was lowered")
    assert_true(first_callee(&m.functions[mi]) == "twice__i32", "UFCS resolves to the free function")
    assert_eq(first_call_argc(&m.functions[mi]), 1 as usize, "the receiver is the only argument")
}

test "a call site names the resolved overload's symbol, not the other one" {
    let unit = analyze(from_view("fn f(a: i32) i32 { return a }\nfn f(a: i32, b: i32) i32 { return a + b }\nfn main() i32 { return f(1, 2) }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let mi = find_fn(&m, "main")
    let callee = first_callee(&m.functions[mi])
    // The call resolved to the two-parameter overload, so it must name that
    // overload's symbol - and that symbol must be defined in the module.
    // Both sides read the one table, so they cannot drift.
    assert_true(callee == "f__i32__i32", "the call names the two-parameter overload")
    assert_true(find_fn(&m, callee) < m.functions.len, "the named symbol is defined in the module")
    assert_true(find_fn(&m, "f__i32") < m.functions.len, "the one-parameter overload is defined too")
}

test "a call to an out-of-subset callee stays a placeholder" {
    let unit = analyze(from_view("fn takes_slice(xs: i32[]) i32 { return 0 }\nfn main() i32 { return takes_slice([1]) }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let mi = find_fn(&m, "main")
    assert_true(mi < m.functions.len, "main was lowered")
    // The callee's signature never lowered, so no definition exists to
    // link against; emitting a call would break the build.
    assert_true(first_callee(&m.functions[mi]) == "", "no call instruction emitted")
}

test "a body-less declaration becomes a foreign decl calls can name" {
    let unit = analyze(from_view("#foreign fn puts(s: &u8) i32\nfn main() i32 { return 0 }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_eq(m.foreigns.len, 1 as usize, "the foreign declaration reached the module")
    assert_true(m.foreigns[0].name == "puts", "foreign keeps its bare C name")
}

test "lowers a function over parameters into an add and a return" {
    let unit = analyze(from_view("fn add(a: i32, b: i32) i32 { return a + b }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_eq(m.functions.len, 1 as usize, "one function lowered")
    let f = &m.functions[0]
    assert_true(f.name == "add__i32__i32", "definition carries its signature symbol")
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

test "mangles symbols by module fqn, keeping main and foreigns bare" {
    let reg = nominal_registry()
    defer reg.deinit()
    let none: List(Ty) = list(0)
    defer none.deinit()

    // Source underscores escape to `_0`, so a lone `_` never appears inside a
    // segment and `__` is unambiguously the separator.
    assert_true(mangle_symbol("flang_typer.checker", "deinit", false, &none, &reg) == "flang_0typer__checker__deinit", "dotted fqn separates, underscores escape")
    assert_true(mangle_symbol("core.io", "printf", true, &none, &reg) == "printf", "foreign names pass through")
    assert_true(mangle_symbol("app.entry", "main", false, &none, &reg) == "main", "main stays bare")
    assert_true(mangle_symbol("", "add", false, &none, &reg) == "add", "no fqn, bare name")
}

test "escaping keeps a dotted path distinct from an underscored name" {
    // The previous encoding mapped `.` to `__` and left source underscores
    // alone, so module `a.b` fn `c` and module `a` fn `b__c` both produced
    // `a__b__c` — two different functions, one symbol.
    let reg = nominal_registry()
    defer reg.deinit()
    let none: List(Ty) = list(0)
    defer none.deinit()

    let dotted = mangle_symbol("a.b", "c", false, &none, &reg)
    let underscored = mangle_symbol("a", "b__c", false, &none, &reg)
    assert_true(dotted == "a__b__c", "dotted path uses the separator")
    assert_true(underscored == "a__b_0_0c", "source underscores escape")
    assert_true(!(dotted == underscored), "the two no longer collide")
}

// Whether every byte of `s` is legal in a C identifier.
fn is_c_identifier(s: String) bool {
    if s.len == 0 { return false }
    for i in 0..s.len {
        let c = s[i]
        let ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or (c >= '0' and c <= '9')
        if !ok { return false }
        if i == 0 {
            if c >= '0' and c <= '9' { return false }
        }
    }
    return true
}

test "a nominal parameter mangles to a valid C identifier" {
    // A nominal's token comes from its FQN, which carries dots. Emitting them
    // raw would produce `take__ref_test.Pt` - not a C identifier, and a
    // syntax error rather than a link error.
    let unit = analyze(from_view("type Pt = struct { x: i32 }\nfn take(p: &Pt) i32 { return p.x }\nfn main() i32 { return 0 }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(m.functions.len >= 2 as usize, "both functions lowered")
    for i in 0..m.functions.len {
        assert_true(is_c_identifier(m.functions[i].name), "every emitted symbol is a valid C identifier")
    }
}

test "overloads separate by parameter type, with no counter" {
    // Symbols are a pure function of the declaration: same name, different
    // parameters, different symbol — regardless of declaration order or of
    // how many overloads the walk has already seen.
    let reg = nominal_registry()
    defer reg.deinit()

    let one: List(Ty) = list(1)
    defer one.deinit()
    one.push(Ty.Prim(PrimitiveKind.I32))

    let two: List(Ty) = list(2)
    defer two.deinit()
    two.push(Ty.Prim(PrimitiveKind.I32))
    two.push(Ty.Prim(PrimitiveKind.I32))

    let a = mangle_symbol("m", "f", false, &one, &reg)
    let b = mangle_symbol("m", "f", false, &two, &reg)
    assert_true(a == "m__f__i32", "one i32 parameter")
    assert_true(b == "m__f__i32__i32", "two i32 parameters")
    assert_true(!(a == b), "arities separate")

    // Re-mangling the same declaration yields the same symbol — the property
    // the ordinal scheme could not provide.
    assert_true(mangle_symbol("m", "f", false, &one, &reg) == a, "deterministic across calls")
}

test "lower_place addresses a nested path; lower_expr loads the scalar" {
    // The two entry points must NOT agree on a scalar member: the place is the
    // field address, the value is a load from it. A place context that reached
    // for lower_expr would write through a loaded scalar. See adr/0003.
    let unit = analyze(from_view("type I = struct { n: i32 }\ntype M = struct { i: I }\nfn main() i32 { let m = M { i = I { n = 3 } } return m.i.n }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_eq(m.functions.len, 1 as usize, "one function lowered")
    let f = &m.functions[0]

    // A two-hop read geps twice (outer field, then inner field) and loads once.
    // A copied intermediate would show up as an extra store/memcpy pair.
    let geps: usize = 0
    let loads: usize = 0
    let instrs = &f.blocks[0].instrs
    for i in 0..instrs.len {
        instrs[i] match {
            Gep(_) => geps = geps + 1,
            Load(_) => loads = loads + 1,
            _ => {},
        }
    }
    assert_true(geps >= 2 as usize, "the nested path geps through both hops")
    assert_eq(loads, 1 as usize, "only the final scalar is loaded")
}

test "lowers a struct field read to a slot store and an offset load" {
    let unit = analyze(from_view("type Pt = struct { x: i32, y: i32 }\nfn main() i32 { let p = Pt { x = 7, y = 4 } return p.y }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_eq(m.functions.len, 1 as usize, "one function lowered")
    let f = &m.functions[0]

    let has_slot = false
    let has_load = false
    let instrs = &f.blocks[0].instrs
    for i in 0..instrs.len {
        instrs[i] match {
            StackSlot(_) => has_slot = true,
            Load(_) => has_load = true,
            _ => {},
        }
    }
    assert_true(has_slot, "struct literal allocated a stack slot")
    assert_true(has_load, "field read emitted an offset load")
}
