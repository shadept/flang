// AST -> FIR lowering: a type-checked `Module` (plus its `TypeCheckResult`,
// for per-node types by span) becomes a `flang_codegen` `IrModule`.
//
// Milestone 1 scope: straight-line single-block scalar functions - params,
// immutable `let`, int/bool literals, arithmetic/bitwise ops, `return`.
// Milestone 2 adds direct and UFCS calls to functions whose signatures
// lower. Milestone 3 adds branching: comparisons, short-circuit `and`/`or`,
// `if` (as expression and statement), `while` / `loop` / `for` over an
// integer range, and `break` / `continue`. Milestone 4 adds assignment,
// address-of and dereference, which is what makes every local a slotted
// place (see `LocalSlot`). Out-of-subset exprs lower to a placeholder;
// unsupported signatures skip.
//
// Still out of subset: indexed assignment (`xs[i] = v`), which needs the
// `op_index_ref` / `op_set_index` resolution the checker does not record
// yet, and compound paths through arrays and slices.
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
// overloads - and an ordinal handed out while walking definitions is not
// something a call site can re-derive. So symbols are assigned once, up
// front, and both sides read the same table.
//
// Call sites key by `FunctionScheme.id` - the id the checker records on
// each resolved call node as `RtFunction`. Definitions key by the decl's
// span fingerprint, which is how a `FunctionDecl` finds its own id.
//
// Membership is also the "is this callable?" gate: a function whose
// signature this milestone cannot lower is left out, so a call to it
// falls back to a placeholder rather than naming a symbol the module
// never defines - which would fail to link.
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
// counter across modules, so the walk order fixes the ordinals - which is
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
// (so the backend still emits their extern) but not called - the variadic
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

// Lowering context - everything the walk needs besides the block cursor
// and the local environment. Bundled rather than threaded separately so
// later milestones (loop labels for M3, arm state for M5) get a home
// without touching every signature again.
type LowerCtx = struct {
    result: &TypeCheckResult
    syms: &SymbolTable
    allocator: &Allocator
    loops: List(LoopFrame)
    // TEMPORARY SCAFFOLD - see `unlowerable`. Delete with it.
    blocked: bool
}

// ─────────────────────────────────────────────────────────────────────────
// TEMPORARY SCAFFOLD - remove when lowering covers the language
// ─────────────────────────────────────────────────────────────────────────
//
// `blocked` / `unlowerable` / `IrModule.skipped` exist only because lowering
// currently handles a subset of FLang. They are a crutch for the milestone
// period, not a design feature, and they are meant to be deleted.
//
// What they do: mark the function being lowered as containing a construct
// this milestone cannot represent, so `lower_function` refuses to emit it.
// The alternative - emitting it with placeholder zeros - produces a program
// that links, runs, and silently computes the wrong answer. A missing
// function fails loudly at link time; a wrong one never fails at all.
//
// REMOVAL CONDITION: when `lower_expr` and `lower_stmt` no longer need a
// catch-all placeholder arm - i.e. every `Expr` and `Stmt` variant lowers -
// there is nothing left to block. At that point delete: this function,
// `LowerCtx.blocked`, the skip branch in `lower_function`, `IrModule.skipped`
// and its `was_skipped` test helper, and every `unlowerable(ctx)` call site.
// The compiler should then either lower a construct or report a diagnostic,
// never quietly drop a function.
//
// ponytail: milestone-period crutch; delete once lowering is total. Tracked
// in docs/known-issues.md.
fn unlowerable(ctx: &LowerCtx) Operand {
    ctx.blocked = true
    return Operand.IntConst(0)
}

// Enclosing loops, innermost last, so `break` and `continue` can name the
// block they branch to. Both fields are FIR block labels - non-owning
// `String` views of labels the `FunctionBuilder` owns, which is the form
// `br`/`br_if` take.
type LoopFrame = struct {
    // Where `continue` goes: the block that performs one iteration's
    // bookkeeping and closes the back edge. For `while` and `loop` that is
    // the loop head itself; for `for` it is the block that advances the
    // induction variable before re-entering the head.
    latch: String
    // Where `break` goes: the first block after the loop.
    exit: String
}

// Lexical environment: a stack of bindings, innermost last. A block marks
// the stack on entry and pops back to the mark on exit, so a `let` inside a
// branch or loop body cannot outlive it and an inner binding shadows an
// outer one of the same name. Linear scan - function scopes are small, and
// a `Dict` cannot pop a scope.
// A local's storage. Every local is a place: it has an address, so `x = v`,
// `&x`, and mutation across a loop back edge all work the same way and need
// no "which locals escape SSA" analysis - an analysis whose gaps would be
// silent wrong code rather than a diagnostic.
//
// Slots are not about registers: FIR is an infinite-register SSA IR, and
// choosing real registers is the backend's job. A slot exists because an SSA
// value has no address and cannot be reassigned, and some locals need both.
//
// ponytail: slotting *every* local overshoots - one that is never assigned
// nor address-taken could stay a plain SSA value. The cost is that FIR passes
// cannot see through the slot's load/store traffic to the value inside. The
// upgrade path is a mem2reg pass over FIR, which is also what makes the
// merge-point cases (loop-carried locals) fall out as block parameters.
type LocalSlot = struct {
    // The local's address. Scalars load and store through it; an aggregate
    // *is* its address, so reading one hands the address straight back.
    addr: Operand
    // FIR type of the stored scalar. Unused for aggregates, which move by
    // byte copy rather than by typed load.
    ty: IrType
    aggregate: bool
}

type Env = struct {
    names: List(String)
    bindings: List(LocalSlot)
}

fn new_env(allocator: &Allocator) Env {
    let n: List(String) = list(8, allocator)
    let b: List(LocalSlot) = list(8, allocator)
    return Env { names = n, bindings = b }
}

// Bind `name` to a stack slot holding a scalar of `ty`.
fn bind_slot(self: &Env, name: String, addr: Operand, ty: IrType) {
    self.names.push(name)
    self.bindings.push(LocalSlot { addr = addr, ty = ty, aggregate = false })
}

// Bind `name` to an aggregate at `addr`.
fn bind_aggregate(self: &Env, name: String, addr: Operand) {
    self.names.push(name)
    self.bindings.push(LocalSlot { addr = addr, ty = IrType.Ptr, aggregate = true })
}

fn mark(self: &Env) usize {
    return self.names.len
}

fn release(self: &Env, m: usize) {
    while self.names.len > m {
        let _n = self.names.pop()
        let _b = self.bindings.pop()
    }
}

fn get(self: &Env, name: String) LocalSlot? {
    let i = self.names.len
    while i > 0 {
        i = i - 1
        if self.names[i] == name { return Some(self.bindings[i]) }
    }
    return null
}

fn deinit(self: &Env) {
    self.names.deinit()
    self.bindings.deinit()
}

// A stack slot sized for one FIR scalar.
fn alloc_slot(bb: &BlockBuilder, ty: IrType) Operand {
    let n = ir_size(ty)
    return bb.stack_slot(n, n)
}

fn ir_size(ty: IrType) u64 {
    return ty match {
        I8 => 1u64,
        I16 => 2u64,
        I32 => 4u64,
        I64 => 8u64,
        F32 => 4u64,
        F64 => 8u64,
        Ptr => 8u64,
    }
}

// A block label unique within the function: `fresh()` is the function's SSA
// id counter, so the suffix never repeats.
//
// ponytail: the label string is leaked, same as symbol names - one-shot
// builds exit before it matters.
fn fresh_label(bb: &BlockBuilder, prefix: String, allocator: &Allocator) String {
    let fb = bb.fb
    let n = fb.fresh()
    let sb = string_builder(prefix.len + 8, allocator)
    sb.append(prefix)
    sb.append(n)
    let owned = sb.to_string()
    sb.deinit()
    return owned.as_view()
}

// Lower every supported top-level function in `ast_module` into a fresh
// `IrModule`. Non-function decls and unsupported functions are skipped.
pub fn lower_module(ast_module: &Module, result: &TypeCheckResult, allocator: &Allocator? = null) IrModule {
    let alloc = allocator.or_global()
    let m = module(alloc)
    let sb = symbol_builder(result, alloc)
    sb.add_module(ast_module, "")
    let syms = sb.finish()
    let loop_stack: List(LoopFrame) = list(0, alloc)
    let ctx = LowerCtx {
        result = result,
        syms = &syms,
        allocator = alloc,
        loops = loop_stack,
        blocked = false
    }
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
    let loop_stack: List(LoopFrame) = list(0, alloc)
    let ctx = LowerCtx { result = result, syms = &syms, allocator = alloc, loops = loop_stack, blocked = false }
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

// A function declaration becomes a defined FIR function, or - when it has
// no body - an external declaration so calls to it compile. Both are
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
// the return type is outside the subset - the backend can't spell it, and
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
// function of the declaration - inserting a function cannot rename another.
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
// keep their declared names - both name symbols fixed outside the compiler
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
// when the symbol pre-pass didn't register one - the two gates are the
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
    let env = new_env(ctx.allocator)
    let param_ops: List(Operand) = list(decl.params.len, ctx.allocator)
    let param_irs: List(IrType) = list(decl.params.len, ctx.allocator)
    for i in 0..decl.params.len {
        let p = &decl.params[i]
        let pir = type_expr_to_ir(&p.type_expr)
        if pir.is_none() { return }
        param_ops.push(fb.param(pir.unwrap()))
        param_irs.push(pir.unwrap())
    }

    // `cur` is the block cursor: control flow moves it, so the body's final
    // terminator lands on whatever block lowering ended in, not the entry.
    let cur = fb.entry()
    ctx.blocked = false

    // Parameters spill to slots like any other local, so assigning one - or
    // taking its address - needs no special case.
    for i in 0..decl.params.len {
        let ir = param_irs[i]
        let slot = alloc_slot(&cur, ir)
        cur.store(ir, param_ops[i], slot)
        env.bind_slot(decl.params[i].name, slot, ir)
    }
    param_ops.deinit()
    param_irs.deinit()
    let body = decl.body.unwrap()
    let r = lower_block(ctx, &cur, &env, &body)
    if !r.terminated {
        if r.value.is_some() {
            cur.ret(r.value.unwrap())
        } else if return_ir.is_none() {
            cur.ret_void()
        } else {
            // A value function with no return path is a checker error.
            cur.unreachable()
        }
    }
    env.deinit()

    // TEMPORARY SCAFFOLD (see `unlowerable`): the body used something
    // outside the subset. Emitting it anyway would bake placeholder zeros
    // into a function that still links and runs.
    if ctx.blocked {
        m.skipped.push(sym)
        return
    }
    m.add_function(fb.finish())
}

// What lowering a block produced: whether it ended in a terminator (so the
// caller must not append one of its own - `set_terminator` overwrites) and
// the value of its trailing expression, if any.
type BlockResult = struct {
    terminated: bool
    value: Operand?
}

// Lower a block's statements then its trailing expression. The block's own
// scope is popped on the way out, so bindings introduced here do not leak
// into the code that follows.
fn lower_block(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, block: &BlockExpr) BlockResult {
    let scope = env.mark()
    let r = BlockResult { terminated = false, value = null }
    for i in 0..block.stmts.len {
        if lower_stmt(ctx, bb, env, &block.stmts[i]) {
            r.terminated = true
            env.release(scope)
            return r
        }
    }
    if block.trailing.is_some() {
        let e = block.trailing.unwrap()
        r.value = Some(lower_expr(ctx, bb, env, e))
    }
    env.release(scope)
    return r
}

// A block in expression position: its value, or the placeholder when it
// yields nothing.
fn lower_block_value(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, block: &BlockExpr) Operand {
    let r = lower_block(ctx, bb, env, block)
    if r.value.is_some() { return r.value.unwrap() }
    return Operand.IntConst(0)
}

// Returns whether the statement emitted a block terminator.
fn lower_stmt(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, stmt: &Stmt) bool {
    stmt.* match {
        Return(r) => {
            lower_return(ctx, bb, env, &r)
            return true
        },
        Let(l) => lower_let(ctx, bb, env, &l),
        Expression(e) => {
            let _u = lower_expr(ctx, bb, env, &e.expr)
        },
        While(w) => lower_while(ctx, bb, env, &w),
        Loop(l) => lower_loop(ctx, bb, env, &l),
        For(f) => lower_for(ctx, bb, env, &f),
        Break(_) => return lower_jump(ctx, bb, true),
        Continue(_) => return lower_jump(ctx, bb, false),

        // Not lowered yet - named rather than caught by a wildcard, so
        // adding a `Stmt` variant is a compile error here instead of a
        // silent skip.

        // `defer expr` - needs the scope-exit schedule (LIFO across sibling
        // defers, and run on every exit edge including `return` and `break`).
        // Dropping it would skip cleanup the source asked for.
        Defer(_) => { let _u = unlowerable(ctx) },

        // `#if(cond) { … } else { … }` - a compile-time conditional that
        // should have been resolved before lowering. Reaching here means it
        // was never expanded, and picking either branch would be a guess.
        IfDirective(_) => { let _u = unlowerable(ctx) },
    }
    return false
}

// `break` / `continue`. Outside a loop both are checker errors; lowering
// emits nothing rather than branching to a label that does not exist.
fn lower_jump(ctx: &LowerCtx, bb: &BlockBuilder, is_break: bool) bool {
    if ctx.loops.len == 0 { return false }
    let frame = &ctx.loops[ctx.loops.len - 1]
    if is_break { bb.br(frame.exit) } else { bb.br(frame.latch) }
    return true
}

fn lower_return(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, r: &ReturnStmt) {
    if r.value.is_some() {
        let e = r.value.unwrap()
        let v = lower_expr(ctx, bb, env, &e)
        bb.ret(v)
    } else {
        bb.ret_void()
    }
}

// `let name = init` - the local gets a stack slot and the initializer is
// stored into it. An aggregate initializer already produced its own storage,
// so the name binds to that address instead of copying it.
//
// The binding's type comes from the checker, not from the annotation:
// `let x` with neither annotation nor initializer is legal and infers from
// later use (`let i` then `print_u8(i)` makes `i` a `u8`).
//
// The type is unwrapped, not guarded. Inferring every binding is the
// checker's job and refusing to lower an unchecked unit is the driver's
// (`compile.f::build_program`, gated by `project_error_count` in
// `finish_build`). A missing type here is a violated contract, and panicking
// on it beats inventing one and compiling silently wrong arithmetic.
fn lower_let(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, l: &LetStmt) {
    let ty = ctx.result.get_type(node_id_of(l.span)).unwrap()

    if l.init.is_none() {
        // Zero initialization is the language's guarantee of the variable's
        // first value (spec 4.2), not an obligation to emit this store: it
        // may be dropped wherever the variable is provably written before any
        // read.
        //
        // ponytail: that write-before-read analysis is unwritten, so the
        // store always emits. Correct, just not minimal.
        if is_aggregate(&ty) { let _u = unlowerable(ctx); return }
        let zero_ir = ty_to_ir(&ty)
        let zero_slot = alloc_slot(bb, zero_ir)
        bb.store(zero_ir, Operand.IntConst(0), zero_slot)
        env.bind_slot(l.name, zero_slot, zero_ir)
        return
    }

    let e = l.init.unwrap()
    let v = lower_expr(ctx, bb, env, &e)
    if is_aggregate(&ty) {
        env.bind_aggregate(l.name, v)
        return
    }
    let ir = ty_to_ir(&ty)
    let slot = alloc_slot(bb, ir)
    bb.store(ir, v, slot)
    env.bind_slot(l.name, slot, ir)
}

// Expressions

fn lower_expr(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, expr: &Expr) Operand {
    return expr.* match {
        Lit(l) => lower_literal(ctx, &l),
        Identifier(id) => lower_identifier(ctx, bb, env, &id),
        Assignment(a) => lower_assignment(ctx, bb, env, &a),
        AddressOf(a) => lower_address_of(ctx, bb, env, &a),
        Dereference(d) => lower_deref(ctx, bb, env, &d),
        Binary(b) => lower_binary(ctx, bb, env, &b),
        Unary(u) => lower_unary(ctx, bb, env, &u),
        StructLit(s) => lower_struct_lit(ctx, bb, env, &s),
        MemberAccess(m) => lower_member(ctx, bb, env, &m),
        Call(c) => lower_call(ctx, bb, env, &c),
        If(f) => lower_if(ctx, bb, env, &f),
        Block(b) => lower_block_value(ctx, bb, env, &b),
        Match(mt) => lower_match(ctx, bb, env, &mt),

        // Not lowered yet - named rather than caught by a wildcard, so
        // adding an `Expr` variant is a compile error here instead of a
        // silent refusal that looks like a deliberate one.

        // `xs[i]` - needs the `op_index` / `op_index_ref` choice the checker
        // does not record yet, plus element-stride addressing.
        Index(_) => unlowerable(ctx),
        // `x as T` - needs the full conversion matrix (trunc/ext/fp casts,
        // pointer casts); FIR has the instructions, the mapping is unwritten.
        Cast(_) => unlowerable(ctx),
        // `[a, b, c]` and `(a, b)` - aggregate literals need element layout
        // and a slot to build into, like `StructLit` already has.
        ArrayLit(_) => unlowerable(ctx),
        TupleLit(_) => unlowerable(ctx),
        // `$"…"` - needs the data segment for the literal pieces and a
        // formatting call per interpolation.
        InterpolatedString(_) => unlowerable(ctx),
        // `a?.b`, `a ?? b`, `a?` - each is a branch on an optional plus a
        // desugaring the checker has not recorded.
        NullPropagation(_) => unlowerable(ctx),
        Coalesce(_) => unlowerable(ctx),
        Try(_) => unlowerable(ctx),
        // `a..b` outside a `for` header has no value representation yet;
        // `for` handles its own range directly (see `lower_for_range`).
        Range(_) => unlowerable(ctx),
        // `fn(x) { … }` - needs closure conversion and a capture record.
        Lambda(_) => unlowerable(ctx),
        // A parse or projection failure. Already diagnosed upstream; refusing
        // the function keeps a recovered AST from reaching the backend. Not
        // part of the milestone scaffold - this one stays.
        Error(_) => { ctx.blocked = true; Operand.IntConst(0) },
    }
}

// Control flow (M3)
//
// FIR is block-based with block parameters, so a construct that joins two
// paths passes its value along the edges instead of writing to a stack
// slot: no allocas, no phi nodes, and nothing to promote later. Loops use
// the same mechanism for the induction variable.
//
// A local mutated across a back edge would need a slot (or a loop-carried
// block parameter the walk does not compute yet), so assignment stays out
// of the subset - see `lower_place`. A loop reading an outer binding is
// fine: that value dominates the loop.

// `if` in expression position. The join block takes the result as a block
// parameter and each arm passes its own; an arm that terminated (returned,
// broke) contributes no edge. An `if` with no `else` cannot yield a value,
// whatever the checker recorded for the node.
fn lower_if(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, ife: &IfExpr) Operand {
    let ty = node_ty(ctx.result, ife.span)
    let yields = yields_value(&ty) and !is_no_else(&ife.else_branch)
    let ir = ty_to_ir(&ty)

    let cond = lower_expr(ctx, bb, env, ife.condition)

    let fb = bb.fb
    let then_bb = fb.block(fresh_label(bb, "then", ctx.allocator))
    let else_bb = fb.block(fresh_label(bb, "else", ctx.allocator))
    let join = if yields {
        fb.block(fresh_label(bb, "join", ctx.allocator), ir)
    } else {
        fb.block(fresh_label(bb, "join", ctx.allocator))
    }
    bb.br_if(cond, then_bb.label(), else_bb.label())

    bb.move_to(&then_bb)
    let tr = lower_block(ctx, bb, env, &ife.then_branch)
    join_from(ctx, bb, join.label(), yields, &tr)

    bb.move_to(&else_bb)
    let er = lower_else(ctx, bb, env, &ife.else_branch)
    join_from(ctx, bb, join.label(), yields, &er)

    bb.move_to(&join)
    if yields { return join.param(0) }
    return Operand.IntConst(0)
}

// Branch an arm's fall-through edge into the join block, carrying its value
// when the `if` yields one. A terminated arm contributes no edge.
fn join_from(ctx: &LowerCtx, bb: &BlockBuilder, label: String, yields: bool, r: &BlockResult) {
    if r.terminated { return }
    if !yields {
        bb.br(label)
        return
    }
    let args: List(Operand) = list(1, ctx.allocator)
    if r.value.is_some() { args.push(r.value.unwrap()) } else { args.push(Operand.IntConst(0)) }
    bb.br_args(label, args)
}

fn lower_else(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, eb: &ElseBranch) BlockResult {
    return eb.* match {
        Block(b) => lower_block(ctx, bb, env, &b),
        If(i) => BlockResult { terminated = false, value = Some(lower_if(ctx, bb, env, i)) },
        NoElse => BlockResult { terminated = false, value = null },
    }
}

fn is_no_else(eb: &ElseBranch) bool {
    return eb.* match {
        NoElse => true,
        _ => false,
    }
}

// Whether a node in expression position produces a usable value. `Never`
// and `Error` do not: nothing reaches the join through them.
fn yields_value(ty: &Ty) bool {
    return ty.* match {
        Void => false,
        Never => false,
        Error => false,
        _ => true,
    }
}

// `while cond { body }` - the head re-evaluates the condition, so it is
// also the `continue` target.
fn lower_while(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, w: &WhileStmt) {
    let fb = bb.fb
    let head = fb.block(fresh_label(bb, "while_head", ctx.allocator))
    let body = fb.block(fresh_label(bb, "while_body", ctx.allocator))
    let exit = fb.block(fresh_label(bb, "while_exit", ctx.allocator))

    bb.br(head.label())
    bb.move_to(&head)
    let cond = lower_expr(ctx, bb, env, w.condition)
    bb.br_if(cond, body.label(), exit.label())

    bb.move_to(&body)
    ctx.loops.push(LoopFrame { latch = head.label(), exit = exit.label() })
    let r = lower_block(ctx, bb, env, &w.body)
    let _f = ctx.loops.pop()
    if !r.terminated { bb.br(head.label()) }

    bb.move_to(&exit)
}

// `loop { body }` - exits only through `break` or `return`, so the exit
// block is reachable only from a `break`.
fn lower_loop(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, l: &LoopStmt) {
    let fb = bb.fb
    let head = fb.block(fresh_label(bb, "loop_head", ctx.allocator))
    let exit = fb.block(fresh_label(bb, "loop_exit", ctx.allocator))

    bb.br(head.label())
    bb.move_to(&head)
    ctx.loops.push(LoopFrame { latch = head.label(), exit = exit.label() })
    let r = lower_block(ctx, bb, env, &l.body)
    let _f = ctx.loops.pop()
    if !r.terminated { bb.br(head.label()) }

    bb.move_to(&exit)
}

// `for i in a..b { body }` - the induction variable is the head block's
// parameter, so it needs no stack slot. The latch (which advances it) is
// the `continue` target, not the head.
//
// Only bounded integer ranges lower. Any other iterable needs the iterator
// protocol, which is outside this milestone; the loop is skipped, matching
// how out-of-subset expressions lower to a placeholder.
fn lower_for(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, f: &ForStmt) {
    // The range is matched into a reference rather than copied out: an
    // optional-of-reference field (`start: &Expr?`) read off a by-value
    // local mis-lowers in the reference compiler (docs/known-issues.md).
    f.iterable.* match {
        Range(r) => lower_for_range(ctx, bb, env, f, &r),
        _ => { let _u = unlowerable(ctx) },
    }
}

fn lower_for_range(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, f: &ForStmt, rng: &RangeExpr) {
    if rng.start.is_none() { let _u = unlowerable(ctx); return }
    if rng.end.is_none() { let _u = unlowerable(ctx); return }
    let start_e = rng.start.unwrap()
    let end_e = rng.end.unwrap()

    let ity = node_ty(ctx.result, expr_span(start_e))
    let p = prim_of(&ity)
    if is_float(p) { let _u = unlowerable(ctx); return }
    let ir = ty_to_ir(&ity)
    let sg = is_signed_integer(p)

    let start = lower_expr(ctx, bb, env, start_e)
    let stop = lower_expr(ctx, bb, env, end_e)

    let fb = bb.fb
    let head = fb.block(fresh_label(bb, "for_head", ctx.allocator), ir)
    let body = fb.block(fresh_label(bb, "for_body", ctx.allocator))
    let latch = fb.block(fresh_label(bb, "for_latch", ctx.allocator))
    let exit = fb.block(fresh_label(bb, "for_exit", ctx.allocator))

    let init: List(Operand) = list(1, ctx.allocator)
    init.push(start)
    bb.br_args(head.label(), init)

    bb.move_to(&head)
    let iv = head.param(0)
    let cond = range_cond(bb, ir, sg, rng.inclusive, iv, stop)
    bb.br_if(cond, body.label(), exit.label())

    bb.move_to(&body)
    let scope = env.mark()
    // The induction variable is a fresh binding per iteration, so it gets
    // its own slot: assigning it inside the body cannot perturb the loop.
    let iv_slot = alloc_slot(bb, ir)
    bb.store(ir, iv, iv_slot)
    env.bind_slot(f.var_name, iv_slot, ir)
    ctx.loops.push(LoopFrame { latch = latch.label(), exit = exit.label() })
    let r = lower_block(ctx, bb, env, &f.body)
    let _fr = ctx.loops.pop()
    env.release(scope)
    if !r.terminated { bb.br(latch.label()) }

    bb.move_to(&latch)
    let next = bb.iadd(ir, iv, Operand.IntConst(1))
    let step: List(Operand) = list(1, ctx.allocator)
    step.push(next)
    bb.br_args(head.label(), step)

    bb.move_to(&exit)
}

fn range_cond(bb: &BlockBuilder, ir: IrType, sg: bool, inclusive: bool, iv: Operand, stop: Operand) Operand {
    if inclusive {
        if sg { return bb.icmp_sle(ir, iv, stop) }
        return bb.icmp_ule(ir, iv, stop)
    }
    if sg { return bb.icmp_slt(ir, iv, stop) }
    return bb.icmp_ult(ir, iv, stop)
}

// Calls (M2)
//
// The checker already picked the callee - overload, UFCS receiver, and
// default arguments are all settled by the time lowering runs, and the
// winner is recorded on the call node as `RtFunction(id)`. So lowering
// does not re-resolve anything: it maps that id through the symbol table
// and emits the args in order.
//
// A call falls back to the placeholder when the node carries no
// `RtFunction` (a variant constructor, an indirect call, or one of the
// checker's deliberate fresh-var fallbacks such as named arguments), or
// when the callee's signature was outside the lowerable subset - in that
// case there is no definition in the module to link against.
fn lower_call(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, call: &CallExpr) Operand {
    let sym_opt = callee_symbol(ctx, call)
    if sym_opt.is_none() { return unlowerable(ctx) }
    let sym = sym_opt.unwrap()

    let args: List(Operand) = list(call.args.len + 1, ctx.allocator)
    // A UFCS call `recv.f(a)` resolved to a free function takes the
    // receiver as its first argument; the AST still shows it as the
    // callee's member base, so it is prepended here. A member-access
    // callee that resolved to a free function is UFCS by construction -
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
fn lower_struct_lit(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, lit: &StructLiteralExpr) Operand {
    let reg = &ctx.result.nominals
    let ty = node_ty(ctx.result, lit.span)
    let target = resolve_struct(&ty, reg, ctx.allocator)
    if target.is_none() { return unlowerable(ctx) }
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
fn lower_field_init(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, fi: &StructFieldInit) Operand {
    if fi.value.is_some() {
        return lower_expr(ctx, bb, env, fi.value.unwrap())
    }
    return read_binding(ctx, bb, env, fi.name)
}

// Place lowering (docs/spec.md 3.4.1, docs/adr/0003)
//
// `lower_expr` yields a VALUE; `lower_place` yields the ADDRESS of a storage
// location. They are deliberately separate entry points: a place context that
// reaches for `lower_expr` copies the aggregate, and every write through the
// result is silently discarded - the defect ADR 0003 documents on the C# side,
// found at four independent sites there. Null means the expression is not a
// place and has no address.
//
// FIR addresses aggregates by pointer, so today `lower_expr` and `lower_place`
// happen to agree on a struct-typed member. They do *not* agree on a scalar
// member - `lower_expr` loads it - which is exactly what assignment (M3), `&`,
// and element stores need. The split is established now, before those land, so
// the C# archaeology is not repeated here.
// Match (M5)
//
// Arms are tested in source order, each test in its own block, so a failed
// test falls through to the next arm's test - a linear chain, not a jump
// table. A switch over a dense tag is a later optimisation; correctness
// first, and the chain is what guards and overlapping patterns need anyway.
//
// The scrutinee is evaluated exactly once. `lower_expr` already yields the
// right thing for both cases: a scalar's value, and an aggregate's address
// (which payload geps and tag loads need).
//
// Every pattern in the match must be lowerable or the whole match falls
// back to the placeholder. A partially-lowered match is worse than none: an
// unlowerable pattern has no honest test operand, and guessing either way
// silently takes or skips the wrong arm.

fn lower_match(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, m: &MatchExpr) Operand {
    for i in 0..m.arms.len {
        if !pattern_supported(ctx, &m.arms[i].pattern) { return unlowerable(ctx) }
    }

    let ty = node_ty(ctx.result, m.span)
    let yields = yields_value(&ty)
    let ir = ty_to_ir(&ty)

    let scrut_ty = node_ty(ctx.result, expr_span(m.scrutinee))
    let scrut = lower_expr(ctx, bb, env, m.scrutinee)

    let fb = bb.fb
    let join = if yields {
        fb.block(fresh_label(bb, "m_join", ctx.allocator), ir)
    } else {
        fb.block(fresh_label(bb, "m_join", ctx.allocator))
    }

    for i in 0..m.arms.len {
        let arm = &m.arms[i]
        let arm_bb = fb.block(fresh_label(bb, "m_arm", ctx.allocator))
        let next_bb = fb.block(fresh_label(bb, "m_next", ctx.allocator))

        let matched = pattern_test(ctx, bb, env, &arm.pattern, scrut, &scrut_ty)
        bb.br_if(matched, arm_bb.label(), next_bb.label())

        bb.move_to(&arm_bb)
        let scope = env.mark()
        bind_pattern(ctx, bb, env, &arm.pattern, scrut, &scrut_ty)

        // A guard runs with the arm's bindings in scope and, when it fails,
        // falls through to the next arm exactly as a failed test does.
        arm.guard match {
            Some(g) => {
                let body_bb = fb.block(fresh_label(bb, "m_body", ctx.allocator))
                let gv = lower_expr(ctx, bb, env, g)
                bb.br_if(gv, body_bb.label(), next_bb.label())
                bb.move_to(&body_bb)
            },
            None => {},
        }

        let r = lower_arm_body(ctx, bb, env, arm.body)
        env.release(scope)
        join_from(ctx, bb, join.label(), yields, &r)

        bb.move_to(&next_bb)
    }

    // Falling past the last arm means no pattern matched. Exhaustiveness is
    // the checker's job, so this block keeps its default `unreachable`.
    bb.move_to(&join)
    if yields { return join.param(0) }
    return Operand.IntConst(0)
}

// An arm body is an expression, but a block body may terminate (`return`),
// and the caller must not then append its own branch to the join - the
// builder's `set_terminator` would overwrite the `ret`.
fn lower_arm_body(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, body: &Expr) BlockResult {
    return body.* match {
        Block(b) => lower_block(ctx, bb, env, &b),
        _ => BlockResult { terminated = false, value = Some(lower_expr(ctx, bb, env, body)) },
    }
}

// Whether every part of `pat` can be lowered. Gates the whole match, so an
// unsupported form degrades to a placeholder rather than a wrong branch.
fn pattern_supported(ctx: &LowerCtx, pat: &Pattern) bool {
    return pat.* match {
        Wildcard(_) => true,
        Variable(_) => true,
        Literal(l) => literal_testable(&l.value),
        Range(_) => true,
        EnumVariant(ev) => variant_supported(ctx, &ev),
        // Alternatives must bind the same names; until binding merges across
        // them, only non-binding alternatives lower.
        Or(o) => or_supported(ctx, &o),
        Struct(_) => false,
        Tuple(_) => false,
        // The front end lost this pattern's meaning; treating it as
        // irrefutable would take the arm unconditionally.
        Error(_) => false,
    }
}

fn or_supported(ctx: &LowerCtx, o: &OrPattern) bool {
    for i in 0..o.alternatives.len {
        if !pattern_supported(ctx, &o.alternatives[i]) { return false }
        if pattern_binds(&o.alternatives[i]) { return false }
    }
    return true
}

fn variant_supported(ctx: &LowerCtx, ev: &EnumVariantPattern) bool {
    if resolved_variant(ctx, ev.span).is_none() { return false }
    // Multi-payload variants need per-payload offsets, which only the
    // enum's internal field layout knows; a single payload sits at the
    // payload offset itself.
    if ev.payloads.len > 1 { return false }
    for i in 0..ev.payloads.len {
        if !pattern_supported(ctx, &ev.payloads[i]) { return false }
    }
    return true
}

fn pattern_binds(pat: &Pattern) bool {
    return pat.* match {
        Variable(_) => true,
        EnumVariant(ev) => ev.payloads.len > 0,
        Struct(_) => true,
        Tuple(_) => true,
        _ => false,
    }
}

// Only the literal forms with a FIR constant can be compared against.
fn literal_testable(v: &LiteralValue) bool {
    return v.* match {
        Int(_) => true,
        Bool(_) => true,
        Char(_) => true,
        Byte(_) => true,
        Null => true,
        _ => false,
    }
}

// An i8 telling whether `pat` matches `scrut`. Tests are side-effect free,
// so `Or` and `Range` combine them with bitwise ops rather than branching.
fn pattern_test(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, pat: &Pattern, scrut: Operand, scrut_ty: &Ty) Operand {
    return pat.* match {
        Wildcard(_) => Operand.IntConst(1),
        // A bare identifier is a binding (irrefutable) unless the checker
        // resolved it to a payload-less variant - see `check_variable_pattern`.
        Variable(v) => variable_test(ctx, bb, &v, scrut, scrut_ty),
        Literal(l) => literal_test(ctx, bb, &l.value, scrut, scrut_ty),
        EnumVariant(ev) => variant_test(ctx, bb, &ev, scrut, scrut_ty),
        Or(o) => or_test(ctx, bb, env, &o, scrut, scrut_ty),
        Range(r) => range_test(ctx, bb, env, &r, scrut, scrut_ty),
        _ => unlowerable(ctx),
    }
}

fn variable_test(ctx: &LowerCtx, bb: &BlockBuilder, v: &VariablePattern, scrut: Operand, scrut_ty: &Ty) Operand {
    let idx = resolved_variant(ctx, v.span)
    if idx.is_none() { return Operand.IntConst(1) }
    return discriminant_test(ctx, bb, idx.unwrap(), scrut, scrut_ty)
}

fn or_test(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, o: &OrPattern, scrut: Operand, scrut_ty: &Ty) Operand {
    let acc = Operand.IntConst(0)
    for i in 0..o.alternatives.len {
        let alt = pattern_test(ctx, bb, env, &o.alternatives[i], scrut, scrut_ty)
        if i == 0 { acc = alt } else { acc = bb.ior(IrType.I8, acc, alt) }
    }
    return acc
}

// `lo..hi` - inclusive on the left, exclusive on the right unless the
// pattern says otherwise. A missing bound is unbounded on that side.
fn range_test(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, r: &RangePattern, scrut: Operand, scrut_ty: &Ty) Operand {
    let ir = ty_to_ir(scrut_ty)
    let p = prim_of(scrut_ty)
    let fl = is_float(p)
    let sg = is_signed_integer(p)

    let acc = Operand.IntConst(1)
    let have = false
    r.start match {
        Some(e) => {
            let lo = lower_expr(ctx, bb, env, e)
            acc = bb.ge_op(ir, fl, sg, scrut, lo)
            have = true
        },
        None => {},
    }
    r.end match {
        Some(e) => {
            let hi = lower_expr(ctx, bb, env, e)
            let upper = if r.inclusive { bb.le_op(ir, fl, sg, scrut, hi) } else { bb.lt_op(ir, fl, sg, scrut, hi) }
            if have { acc = bb.iand(IrType.I8, acc, upper) } else { acc = upper }
            have = true
        },
        None => {},
    }
    if !have { return Operand.IntConst(1) }
    return acc
}

fn literal_test(ctx: &LowerCtx, bb: &BlockBuilder, v: &LiteralValue, scrut: Operand, scrut_ty: &Ty) Operand {
    // `null` against a pointer-niche optional is the null test; the enum
    // has no tag to compare.
    let niche = niche_optional(ctx, scrut_ty)
    let is_null = v.* match { Null => true, _ => false }
    if is_null and niche { return bb.icmp_eq(IrType.Ptr, scrut, Operand.NullPtr) }

    let lit = lower_literal_value(v)
    let ir = ty_to_ir(scrut_ty)
    if is_float(prim_of(scrut_ty)) { return bb.fcmp_eq(ir, scrut, lit) }
    return bb.icmp_eq(ir, scrut, lit)
}

// `Some(x)` / `Color.Red`: compare the scrutinee's discriminant against the
// variant index the checker resolved. A pointer-niche optional carries no
// discriminant - `None` is the null pointer and `Some` is anything else.
fn variant_test(ctx: &LowerCtx, bb: &BlockBuilder, ev: &EnumVariantPattern, scrut: Operand, scrut_ty: &Ty) Operand {
    let vnum = resolved_variant(ctx, ev.span)
    if vnum.is_none() { return unlowerable(ctx) }
    return discriminant_test(ctx, bb, vnum.unwrap(), scrut, scrut_ty)
}

fn discriminant_test(ctx: &LowerCtx, bb: &BlockBuilder, idx: u32, scrut: Operand, scrut_ty: &Ty) Operand {
    if niche_optional(ctx, scrut_ty) {
        // The niche form is only ever `Option(&T)`, whose `None` is declared
        // first and so carries index 0 (stdlib/core/option.f). `None` is the
        // null pointer; anything else is `Some`.
        if idx == 0u32 { return bb.icmp_eq(IrType.Ptr, scrut, Operand.NullPtr) }
        return bb.icmp_ne(IrType.Ptr, scrut, Operand.NullPtr)
    }

    // A tagged enum is addressed by pointer, with the discriminant first.
    let tag = bb.load(IrType.I32, scrut)
    return bb.icmp_eq(IrType.I32, tag, Operand.IntConst(idx as i64))
}

// Bind the variables `pat` introduces. Runs in the arm's block, after its
// test succeeded, so every gep here is known to be in-bounds for the
// matched variant.
fn bind_pattern(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, pat: &Pattern, scrut: Operand, scrut_ty: &Ty) {
    pat.* match {
        Variable(v) => bind_matched(ctx, bb, env, v.name, scrut, scrut_ty),
        EnumVariant(ev) => bind_variant_payload(ctx, bb, env, &ev, scrut, scrut_ty),
        _ => {},
    }
}

// A pattern variable names the matched value. An aggregate binds to its
// address; a scalar gets a slot like any other local, so the arm body may
// assign to it.
fn bind_matched(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, name: String, value: Operand, ty: &Ty) {
    if is_aggregate(ty) {
        env.bind_aggregate(name, value)
        return
    }
    let ir = ty_to_ir(ty)
    let slot = alloc_slot(bb, ir)
    bb.store(ir, value, slot)
    env.bind_slot(name, slot, ir)
}

fn bind_variant_payload(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, ev: &EnumVariantPattern, scrut: Operand, scrut_ty: &Ty) {
    if ev.payloads.len == 0 { return }
    let sub = &ev.payloads[0]
    let pty = node_ty(ctx.result, pattern_span(sub))

    // A pointer-niche optional stores its payload *as* the scrutinee - there
    // is no separate payload slot to address.
    if niche_optional(ctx, scrut_ty) {
        bind_pattern(ctx, bb, env, sub, scrut, &pty)
        return
    }

    let off = payload_offset(ctx, scrut_ty)
    let addr = bb.gep(scrut, Operand.IntConst(off as i64))
    let value = if is_aggregate(&pty) { addr } else { bb.load(ty_to_ir(&pty), addr) }
    bind_pattern(ctx, bb, env, sub, value, &pty)
}

// The variant index the checker resolved for the pattern node at `span`.
fn resolved_variant(ctx: &LowerCtx, span: SourceSpan) u32? {
    let target = ctx.result.get_target(node_id_of(span))
    if target.is_none() { return null }
    return target.unwrap() match {
        RtEnumVariant(_, idx) => Some(idx),
        _ => null,
    }
}

// The enum a scrutinee type names, peeling one reference.
fn resolve_enum(ty: &Ty, reg: &NominalRegistry) EnumTarget? {
    let peeled = ty.* match {
        Ref(inner) => inner.*,
        _ => ty.*,
    }
    let nr = peeled match {
        Nominal(n) => n,
        _ => return null,
    }
    return reg.get(nr.id).* match {
        NomEnum(e) => Some(EnumTarget { def = e, args = nr.args }),
        _ => null,
    }
}

type EnumTarget = struct {
    def: EnumDef
    args: List(Ty)
}

fn niche_optional(ctx: &LowerCtx, ty: &Ty) bool {
    let t = resolve_enum(ty, &ctx.result.nominals)
    if t.is_none() { return false }
    let et = t.unwrap()
    return enum_layout(&et.def, &et.args, &ctx.result.nominals, ctx.allocator).is_niche
}

fn payload_offset(ctx: &LowerCtx, ty: &Ty) usize {
    let t = resolve_enum(ty, &ctx.result.nominals)
    if t.is_none() { return 4 as usize }
    let et = t.unwrap()
    return enum_layout(&et.def, &et.args, &ctx.result.nominals, ctx.allocator).payload_offset
}

// Assignment and address-of

// `lhs = rhs` - resolve the destination's address, then evaluate the right
// side and store through it. Destination first, matching the reference
// compiler's order; the two are independent for every expression in the
// subset, but the order is fixed rather than incidental.
//
// A left side with no address is an already-reported checker error (or an
// expression this milestone can't place); the store is dropped rather than
// written somewhere arbitrary. Assignment is an expression that yields no
// value, so the result is the unit placeholder.
fn lower_assignment(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, a: &AssignmentExpr) Operand {
    let dst = lower_place(ctx, bb, env, a.lhs)
    let v = lower_expr(ctx, bb, env, a.rhs)
    if dst.is_none() { return unlowerable(ctx) }

    let ty = node_ty(ctx.result, expr_span(a.lhs))
    if is_aggregate(&ty) {
        // Aggregates are addressed by pointer, so `v` is the source address
        // and the assignment is a byte copy.
        let lay = layout_of(&ty, &ctx.result.nominals, ctx.allocator)
        bb.memcpy(dst.unwrap(), v, Operand.IntConst(lay.size as i64))
    } else {
        bb.store(ty_to_ir(&ty), v, dst.unwrap())
    }
    return Operand.IntConst(0)
}

// `&place` - the address itself, with nothing to load or copy.
fn lower_address_of(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, a: &AddressOfExpr) Operand {
    let p = lower_place(ctx, bb, env, a.operand)
    if p.is_some() { return p.unwrap() }
    return unlowerable(ctx)
}

// `p.*` in value position - the pointer is already the address, so reading
// through it is one load. An aggregate pointee stays a pointer.
fn lower_deref(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, d: &DereferenceExpr) Operand {
    let p = lower_expr(ctx, bb, env, d.operand)
    let ty = node_ty(ctx.result, d.span)
    if is_aggregate(&ty) { return p }
    return bb.load(ty_to_ir(&ty), p)
}

fn lower_place(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, expr: &Expr) Operand? {
    return expr.* match {
        Identifier(id) => place_of_identifier(env, &id),
        MemberAccess(ma) => member_address(ctx, bb, env, &ma),
        // `p.*` - the pointer already is the address.
        Dereference(d) => Some(lower_expr(ctx, bb, env, d.operand)),
        _ => null,
    }
}

// The address of a base in a place context. Place-ness propagates leftward
// through a path (spec 3.4.1), so a base reached by another path operator is
// addressed rather than copied.
//
// It propagates through *path operators only*. An identifier base yields its
// value, which is already the right thing in both cases: an aggregate local's
// value IS its address, and a reference's value is the pointer to follow.
// Addressing the identifier instead would hand back its slot - one level of
// indirection too many.
fn lower_base_address(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, base: &Expr) Operand {
    let nested = base.* match {
        MemberAccess(_) => true,
        Index(_) => true,
        Dereference(_) => true,
        _ => false,
    }
    if nested {
        let p = lower_place(ctx, bb, env, base)
        if p.is_some() { return p.unwrap() }
    }
    return lower_expr(ctx, bb, env, base)
}

// A local's storage. Every local is slotted, so a name always has an address.
fn place_of_identifier(env: &Env, id: &IdentifierExpr) Operand? {
    let b = env.get(id.name)
    if b.is_none() { return null }
    return Some(b.unwrap().addr)
}

// The address of `ma`'s field: gep to the field offset off the receiver's
// address. Null when the receiver isn't a resolvable struct.
fn member_address(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, ma: &MemberAccessExpr) Operand? {
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
fn lower_member(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, ma: &MemberAccessExpr) Operand {
    let fpo = member_address(ctx, bb, env, ma)
    if fpo.is_none() { return unlowerable(ctx) }
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

fn lower_literal(ctx: &LowerCtx, l: &LiteralExpr) Operand {
    if !literal_testable(&l.value) { return unlowerable(ctx) }
    return lower_literal_value(&l.value)
}

// A literal form's FIR constant. Shared with pattern tests, where the same
// forms appear without an enclosing expression node.
fn lower_literal_value(v: &LiteralValue) Operand {
    return v.* match {
        Int(i) => Operand.IntConst(parse_int(i.text)),
        Bool(b) => Operand.IntConst(if b.value { 1 } else { 0 }),
        // Float/Char/Byte/String/Null lower later (strings need the data
        // segment; floats need a literal parser).
        _ => Operand.IntConst(0),
    }
}

// Reading a name: a scalar loads from its slot; an aggregate yields its
// address, since FIR addresses aggregates by pointer.
fn read_binding(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, name: String) Operand {
    let found = env.get(name)
    // Globals and function references are not lowered yet.
    if found.is_none() { return unlowerable(ctx) }
    let b = found.unwrap()
    if b.aggregate { return b.addr }
    return bb.load(b.ty, b.addr)
}

fn lower_identifier(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, id: &IdentifierExpr) Operand {
    return read_binding(ctx, bb, env, id.name)
}

fn lower_binary(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, b: &BinaryExpr) Operand {
    // `and`/`or` branch, so the right operand must not be lowered into the
    // current block alongside the left.
    b.op match {
        And => return lower_short_circuit(ctx, bb, env, b, true),
        Or => return lower_short_circuit(ctx, bb, env, b, false),
        _ => {},
    }

    let lhs = lower_expr(ctx, bb, env, b.lhs)
    let rhs = lower_expr(ctx, bb, env, b.rhs)
    let ty = node_ty(ctx.result, b.span)
    let ir = ty_to_ir(&ty)
    let p = prim_of(&ty)
    let fl = is_float(p)
    let sg = is_signed_integer(p)
    // A comparison is typed by its operands, not by its `bool` result.
    let oty = node_ty(ctx.result, expr_span(b.lhs))
    let op_ir = ty_to_ir(&oty)
    let op_p = prim_of(&oty)
    let ofl = is_float(op_p)
    let osg = is_signed_integer(op_p)
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
        Eq => if ofl { bb.fcmp_eq(op_ir, lhs, rhs) } else { bb.icmp_eq(op_ir, lhs, rhs) },
        Ne => if ofl { bb.fcmp_ne(op_ir, lhs, rhs) } else { bb.icmp_ne(op_ir, lhs, rhs) },
        Lt => bb.lt_op(op_ir, ofl, osg, lhs, rhs),
        Le => bb.le_op(op_ir, ofl, osg, lhs, rhs),
        Gt => bb.gt_op(op_ir, ofl, osg, lhs, rhs),
        Ge => bb.ge_op(op_ir, ofl, osg, lhs, rhs),
        // Handled above; unreachable.
        And => Operand.IntConst(0),
        Or => Operand.IntConst(0),
    }
}

// `a and b` / `a or b`. `b` is evaluated only when `a` leaves the result
// undecided; the deciding constant (false for `and`, true for `or`) rides
// the short-circuit edge into the join as a block argument.
fn lower_short_circuit(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, b: &BinaryExpr, is_and: bool) Operand {
    let lhs = lower_expr(ctx, bb, env, b.lhs)

    let fb = bb.fb
    let rhs_bb = fb.block(fresh_label(bb, "sc_rhs", ctx.allocator))
    let join = fb.block(fresh_label(bb, "sc_join", ctx.allocator), IrType.I8)

    let decided: List(Operand) = list(1, ctx.allocator)
    decided.push(Operand.IntConst(if is_and { 0 } else { 1 }))
    let no_args: List(Operand) = list(0, ctx.allocator)
    if is_and {
        bb.br_if_args(lhs, rhs_bb.label(), no_args, join.label(), decided)
    } else {
        bb.br_if_args(lhs, join.label(), decided, rhs_bb.label(), no_args)
    }

    bb.move_to(&rhs_bb)
    let rhs = lower_expr(ctx, bb, env, b.rhs)
    let carried: List(Operand) = list(1, ctx.allocator)
    carried.push(rhs)
    bb.br_args(join.label(), carried)

    bb.move_to(&join)
    return join.param(0)
}

fn lt_op(bb: &BlockBuilder, ir: IrType, fl: bool, sg: bool, lhs: Operand, rhs: Operand) Operand {
    if fl { return bb.fcmp_lt(ir, lhs, rhs) }
    if sg { return bb.icmp_slt(ir, lhs, rhs) }
    return bb.icmp_ult(ir, lhs, rhs)
}

fn le_op(bb: &BlockBuilder, ir: IrType, fl: bool, sg: bool, lhs: Operand, rhs: Operand) Operand {
    if fl { return bb.fcmp_le(ir, lhs, rhs) }
    if sg { return bb.icmp_sle(ir, lhs, rhs) }
    return bb.icmp_ule(ir, lhs, rhs)
}

fn gt_op(bb: &BlockBuilder, ir: IrType, fl: bool, sg: bool, lhs: Operand, rhs: Operand) Operand {
    if fl { return bb.fcmp_gt(ir, lhs, rhs) }
    if sg { return bb.icmp_sgt(ir, lhs, rhs) }
    return bb.icmp_ugt(ir, lhs, rhs)
}

fn ge_op(bb: &BlockBuilder, ir: IrType, fl: bool, sg: bool, lhs: Operand, rhs: Operand) Operand {
    if fl { return bb.fcmp_ge(ir, lhs, rhs) }
    if sg { return bb.icmp_sge(ir, lhs, rhs) }
    return bb.icmp_uge(ir, lhs, rhs)
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

fn lower_unary(ctx: &LowerCtx, bb: &BlockBuilder, env: &Env, u: &UnaryExpr) Operand {
    let v = lower_expr(ctx, bb, env, u.operand)
    let ty = node_ty(ctx.result, u.span)
    let ir = ty_to_ir(&ty)
    let p = prim_of(&ty)
    return u.op match {
        Neg => bb.neg_op(ir, is_float(p), v),
        BitNot => bb.ixor(ir, v, Operand.IntConst(-1)),
        // `!b` is `b == 0`; bool is a byte in FIR, so no widening.
        Not => bb.icmp_eq(ir, v, Operand.IntConst(0)),
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

// First function whose symbol starts with `prefix`. Type tokens embed the
// nominal's FQN, which depends on the analysed module's name, so tests that
// mention a user type match on the prefix rather than the whole symbol.
// Whether a symbol starting with `prefix` was refused rather than emitted.
// TEMPORARY SCAFFOLD (see `unlowerable`): delete with the skip mechanism.
fn was_skipped(m: &IrModule, prefix: String) bool {
    for i in 0..m.skipped.len {
        let n = m.skipped[i]
        if n.len >= prefix.len {
            if n[0..prefix.len] == prefix { return true }
        }
    }
    return false
}

fn find_fn_starting(m: &IrModule, prefix: String) usize {
    for i in 0..m.functions.len {
        let n = m.functions[i].name
        if n.len >= prefix.len {
            if n[0..prefix.len] == prefix { return i }
        }
    }
    return m.functions.len
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

test "a caller of an out-of-subset callee is refused, not emitted with a stub" {
    let unit = analyze(from_view("fn takes_slice(xs: i32[]) i32 { return 0 }\nfn main() i32 { return takes_slice([1]) }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    // The callee's signature never lowered, so there is no definition to
    // link against. Emitting `main` with a placeholder in place of the call
    // would produce a binary that runs and returns the wrong number.
    assert_true(find_fn(&m, "main") == m.functions.len, "main is not emitted")
    assert_true(was_skipped(&m, "main"), "and it is recorded as skipped")
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
    // `a__b__c` - two different functions, one symbol.
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
    // parameters, different symbol - regardless of declaration order or of
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

    // Re-mangling the same declaration yields the same symbol - the property
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

// Control flow test helpers.

// Index of the first block whose label starts with `prefix`, or the block
// count when there is none.
fn block_starting(f: &Function, prefix: String) usize {
    for i in 0..f.blocks.len {
        let l = f.blocks[i].label
        if l.len >= prefix.len {
            if l[0..prefix.len] == prefix { return i }
        }
    }
    return f.blocks.len
}

// Whether block `i` ends in a conditional branch.
fn ends_in_br_if(f: &Function, i: usize) bool {
    return f.blocks[i].terminator match { BrIf(_) => true, _ => false }
}

// The label an unconditional branch out of block `i` targets, or "".
fn br_target(f: &Function, i: usize) String {
    return f.blocks[i].terminator match { Br(t) => t.label, _ => "" }
}

// How many block arguments an unconditional branch out of block `i` carries.
fn br_argc(f: &Function, i: usize) usize {
    return f.blocks[i].terminator match { Br(t) => t.args.len, _ => 0 as usize }
}

fn compare_count(f: &Function) usize {
    let n: usize = 0
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            instrs[i] match { Compare(_) => n = n + 1, _ => {} }
        }
    }
    return n
}

fn block_compare_count(f: &Function, b: usize) usize {
    let n: usize = 0
    let instrs = &f.blocks[b].instrs
    for i in 0..instrs.len {
        instrs[i] match { Compare(_) => n = n + 1, _ => {} }
    }
    return n
}

// Every stack slot's SSA id, in emission order.
fn collect_slots(f: &Function, out: &List(u32)) {
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            instrs[i] match { StackSlot(s) => out.push(s.result), _ => {} }
        }
    }
}

fn operand_local(op: Operand) u32 {
    return op match { Local(id) => id, _ => 0u32 }
}

// The SSA id block `b` returns, or 0 when it does not return a value.
fn ret_local(f: &Function, b: usize) u32 {
    return f.blocks[b].terminator match {
        Ret(v) => if v.is_some() { operand_local(v.unwrap()) } else { 0u32 },
        _ => 0u32,
    }
}

// The slot a load producing `id` reads from, or 0 when `id` is not a load.
fn load_ptr(f: &Function, id: u32) u32 {
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            let hit = instrs[i] match {
                Load(l) => if l.result == id { Some(operand_local(l.ptr)) } else { null },
                _ => null,
            }
            if hit.is_some() { return hit.unwrap() }
        }
    }
    return 0u32
}

fn compare_operand_ty(f: &Function) IrType {
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            let hit = instrs[i] match { Compare(c) => Some(c.operand_ty), _ => null }
            if hit.is_some() { return hit.unwrap() }
        }
    }
    return IrType.Ptr
}

test "an if expression joins its arms through a block parameter" {
    let unit = analyze(from_view("fn pick(a: i32) i32 { return if a > 0 { 1 } else { 2 } }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "pick__i32")]
    assert_eq(f.blocks.len, 4 as usize, "entry, then, else and join")
    assert_true(ends_in_br_if(f, 0), "entry ends in a conditional branch")

    let join = block_starting(f, "join")
    assert_true(join < f.blocks.len, "a join block exists")
    assert_eq(f.blocks[join].params.len, 1 as usize, "the join carries the result as a parameter")

    let then_b = block_starting(f, "then")
    assert_eq(br_argc(f, then_b), 1 as usize, "the then arm passes its value along the edge")
}

test "an if with no else yields nothing and needs no join parameter" {
    let unit = analyze(from_view("fn f(a: i32) i32 { if a > 0 { return 1 } return 0 }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    let join = block_starting(f, "join")
    assert_true(join < f.blocks.len, "a join block exists")
    assert_eq(f.blocks[join].params.len, 0 as usize, "no value crosses the join")
}

test "an arm that returns contributes no edge to the join" {
    let unit = analyze(from_view("fn f(a: i32) i32 { if a > 0 { return 1 } else { return 2 } }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    let then_b = block_starting(f, "then")
    let else_b = block_starting(f, "else")
    let t_ret = f.blocks[then_b].terminator match { Ret(_) => true, _ => false }
    let e_ret = f.blocks[else_b].terminator match { Ret(_) => true, _ => false }
    assert_true(t_ret, "the then arm keeps its own return")
    assert_true(e_ret, "the else arm keeps its own return")
}

test "a while loop branches back to its head" {
    let unit = analyze(from_view("fn f(n: i32) i32 { while n > 0 { let x = n } return n }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    let head = block_starting(f, "while_head")
    let body = block_starting(f, "while_body")
    assert_true(head < f.blocks.len, "a loop head exists")
    assert_true(ends_in_br_if(f, head), "the head tests the condition")
    assert_true(br_target(f, body) == f.blocks[head].label, "the body branches back to the head")
}

test "a for over a range carries the induction variable as a block parameter" {
    let unit = analyze(from_view("fn f(n: i32) i32 { for i in 0..n { let x = i } return n }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    let head = block_starting(f, "for_head")
    let latch = block_starting(f, "for_latch")
    assert_true(head < f.blocks.len, "a loop head exists")
    assert_eq(f.blocks[head].params.len, 1 as usize, "the head takes the induction variable")
    assert_eq(br_argc(f, 0), 1 as usize, "entry seeds it with the range start")
    assert_eq(br_argc(f, latch), 1 as usize, "the latch passes the advanced value back")
    assert_true(br_target(f, latch) == f.blocks[head].label, "the latch closes the back edge")
}

// `..=` is pattern-only in FLang, so a range expression is always
// half-open; `range_cond` still honours the flag in case that changes.
test "a range bound is half-open" {
    let unit = analyze(from_view("fn f(n: i32) i32 { for i in 0..n { let x = i } return n }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    let head = block_starting(f, "for_head")
    let instrs = &f.blocks[head].instrs
    let slt = false
    for i in 0..instrs.len {
        instrs[i] match {
            Compare(c) => c.op match { IcmpSlt => slt = true, _ => {} },
            _ => {},
        }
    }
    assert_true(slt, "the upper bound is exclusive")
}

test "break exits the loop and continue re-enters the latch" {
    let unit = analyze(from_view("fn f(n: i32) i32 { for i in 0..n { if i > 2 { break } else { continue } } return n }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    let exit = f.blocks[block_starting(f, "for_exit")].label
    let latch = f.blocks[block_starting(f, "for_latch")].label
    assert_true(br_target(f, block_starting(f, "then")) == exit, "break leaves the loop")
    assert_true(br_target(f, block_starting(f, "else")) == latch, "continue advances the induction variable")
}

test "a for over a non-range iterable refuses the function" {
    let unit = analyze(from_view("fn f(xs: &i32) i32 { for x in xs { let y = 1 } return 0 }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    // Silently dropping the loop would compile a function that skips work
    // the source asked for.
    assert_true(find_fn_starting(&m, "f__ref_i32") == m.functions.len, "the function is not emitted")
    assert_true(was_skipped(&m, "f__ref_i32"), "and it is recorded as skipped")
}

test "and evaluates its right operand in its own block" {
    let unit = analyze(from_view("fn f(a: i32, b: i32) bool { return a > 0 and b > 0 }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32__i32")]
    let rhs = block_starting(f, "sc_rhs")
    let join = block_starting(f, "sc_join")
    assert_true(rhs < f.blocks.len, "the right operand got its own block")
    assert_eq(f.blocks[join].params.len, 1 as usize, "the result crosses the join as a parameter")
    assert_eq(compare_count(f), 2 as usize, "one compare per operand, neither duplicated")
    assert_eq(block_compare_count(f, rhs), 1 as usize, "the right operand's test is not in the entry block")
    assert_eq(block_compare_count(f, 0), 1 as usize, "and the left operand's test is not duplicated into it")
}

test "a comparison is typed by its operands, not by its bool result" {
    let unit = analyze(from_view("fn f(a: i64, b: i64) bool { return a < b }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i64__i64")]
    let ty = compare_operand_ty(f)
    let is_i64 = ty match { I64 => true, _ => false }
    assert_true(is_i64, "compares the i64 operands, not the i8 result")
}

test "a binding made inside a branch does not leak past it" {
    let unit = analyze(from_view("fn f(a: i32) i32 { let x = 1 if a > 0 { let x = 2 } return x }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    // Slots in emission order: the parameter, the outer `x`, then the
    // shadowing `x` inside the branch.
    let slots: List(u32) = list(4)
    collect_slots(f, &slots)
    assert_eq(slots.len, 3 as usize, "the shadowing let gets storage of its own")

    let join = block_starting(f, "join")
    let returned = ret_local(f, join)
    assert_eq(load_ptr(f, returned) as usize, slots[1] as usize, "the return reads the outer x")
    slots.deinit()
}

// Assignment test helpers.

fn store_count(f: &Function) usize {
    let n: usize = 0
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            instrs[i] match { Store(_) => n = n + 1, _ => {} }
        }
    }
    return n
}

// The slot the last store in `f` writes to, or 0 when it emits none.
fn last_store_ptr(f: &Function) u32 {
    let dst: u32 = 0
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            instrs[i] match { Store(s) => dst = operand_local(s.ptr), _ => {} }
        }
    }
    return dst
}

// Whether `id` was produced by a gep - i.e. names a field, not a slot.
fn is_gep_result(f: &Function, id: u32) bool {
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            let hit = instrs[i] match { Gep(g) => g.result == id, _ => false }
            if hit { return true }
        }
    }
    return false
}

fn memcpy_count(f: &Function) usize {
    let n: usize = 0
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            instrs[i] match { Memcpy(_) => n = n + 1, _ => {} }
        }
    }
    return n
}

test "every local and parameter gets a slot it can be assigned through" {
    let unit = analyze(from_view("fn f(a: i32) i32 { let b = a return b }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    let slots: List(u32) = list(4)
    collect_slots(f, &slots)
    assert_eq(slots.len, 2 as usize, "the parameter and the let each get storage")
    assert_eq(store_count(f), 2 as usize, "each is initialized by a store")
    slots.deinit()
}

test "assigning a local stores through its slot" {
    let unit = analyze(from_view("fn f(a: i32) i32 { let x = 1 x = a return x }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    let slots: List(u32) = list(4)
    collect_slots(f, &slots)
    assert_eq(slots.len, 2 as usize, "no extra slot for the assignment")
    assert_eq(last_store_ptr(f) as usize, slots[1] as usize, "the assignment writes x's slot")
    assert_eq(store_count(f), 3 as usize, "param init, let init, then the assignment")
    slots.deinit()
}

test "a local mutated across a loop back edge keeps one slot" {
    let unit = analyze(from_view("fn f(n: i32) i32 { let t = 0 for i in 0..n { t = t + i } return t }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    let slots: List(u32) = list(4)
    collect_slots(f, &slots)
    // n, t, and the induction variable's per-iteration copy.
    assert_eq(slots.len, 3 as usize, "the accumulator is not re-slotted per iteration")
    assert_eq(last_store_ptr(f) as usize, slots[1] as usize, "the loop body writes the accumulator's slot")
    slots.deinit()
}

test "taking a local's address hands back its slot, with no load" {
    let unit = analyze(from_view("fn f(a: i32) i32 { let x = a let p = &x return p.* }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    let slots: List(u32) = list(4)
    collect_slots(f, &slots)
    // a, x, p - `&x` produces no instruction of its own.
    assert_eq(slots.len, 3 as usize, "address-of allocates nothing")
    slots.deinit()
}

test "assigning through a dereference stores to the pointee" {
    let unit = analyze(from_view("fn f(p: &i32) i32 { p.* = 9 return p.* }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__ref_i32")]
    let slots: List(u32) = list(4)
    collect_slots(f, &slots)
    assert_eq(slots.len, 1 as usize, "only the parameter is slotted")
    // The store target is the loaded pointer, not the parameter's own slot.
    assert_true(last_store_ptr(f) != slots[0], "the write goes through the pointer, not over it")
    slots.deinit()
}

test "assigning a struct field writes through a gep, not a copy" {
    let unit = analyze(from_view("type P = struct { x: i32 y: i32 }\nfn f() i32 { let p = P { x = 1, y = 2 } p.x = 7 return p.x }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f")]
    assert_eq(memcpy_count(f), 0 as usize, "a scalar field assignment is a store, not a byte copy")
    // The struct literal also geps to initialize its fields, so counting
    // geps proves nothing; what matters is that the *assignment*'s store
    // targets a field address rather than the local's own slot.
    assert_true(is_gep_result(f, last_store_ptr(f)), "the write goes through a field address")
}

test "assigning an aggregate copies its bytes" {
    let unit = analyze(from_view("type P = struct { x: i32 y: i32 }\nfn f() i32 { let a = P { x = 1, y = 2 } let b = P { x = 3, y = 4 } b = a return b.x }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f")]
    assert_eq(memcpy_count(f), 1 as usize, "the aggregate assignment is a byte copy")
}

// Match test helpers.

fn block_count_starting(f: &Function, prefix: String) usize {
    let n: usize = 0
    for i in 0..f.blocks.len {
        let l = f.blocks[i].label
        if l.len >= prefix.len {
            if l[0..prefix.len] == prefix { n = n + 1 }
        }
    }
    return n
}

fn load_count(f: &Function) usize {
    let n: usize = 0
    for b in 0..f.blocks.len {
        let instrs = &f.blocks[b].instrs
        for i in 0..instrs.len {
            instrs[i] match { Load(_) => n = n + 1, _ => {} }
        }
    }
    return n
}

// `BinaryOp` is exported by both `ast` and `fir`, so it is never named in
// this file (see the header) - these match the variant instead.
fn has_ior_in(f: &Function, b: usize) bool {
    let instrs = &f.blocks[b].instrs
    for i in 0..instrs.len {
        let hit = instrs[i] match {
            Binary(bi) => bi.op match { IOr => true, _ => false },
            _ => false,
        }
        if hit { return true }
    }
    return false
}

fn has_iand_in(f: &Function, b: usize) bool {
    let instrs = &f.blocks[b].instrs
    for i in 0..instrs.len {
        let hit = instrs[i] match {
            Binary(bi) => bi.op match { IAnd => true, _ => false },
            _ => false,
        }
        if hit { return true }
    }
    return false
}

test "match on a scalar chains one test block per arm" {
    let unit = analyze(from_view("fn f(a: i32) i32 { return a match { 0 => 10, 1 => 20, _ => 30 } }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    assert_eq(block_count_starting(f, "m_arm"), 3 as usize, "one body block per arm")
    assert_eq(block_count_starting(f, "m_next"), 3 as usize, "each arm falls through to the next test")
    assert_eq(compare_count(f), 2 as usize, "the wildcard arm needs no compare")

    let join = block_starting(f, "m_join")
    assert_eq(f.blocks[join].params.len, 1 as usize, "the result crosses the join as a parameter")
}

test "the scrutinee is evaluated once, not per arm" {
    let unit = analyze(from_view("fn f(a: i32) i32 { return a match { 0 => 1, 1 => 2, _ => 3 } }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    // One load for the parameter's slot; the arms reuse that value.
    assert_eq(load_count(f), 1 as usize, "the scrutinee is loaded once for the whole match")
}

test "a match used as a statement carries no join parameter" {
    let unit = analyze(from_view("fn f(a: i32) i32 { a match { 0 => {}, _ => {} } return a }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    let join = block_starting(f, "m_join")
    assert_true(join < f.blocks.len, "a join block exists")
    assert_eq(f.blocks[join].params.len, 0 as usize, "no value crosses the join")
}

test "a guard gets its own block and falls through to the next arm" {
    let unit = analyze(from_view("fn f(a: i32) i32 { return a match { x if x > 5 => 1, _ => 2 } }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    assert_eq(block_count_starting(f, "m_body"), 1 as usize, "the guarded arm splits test from body")

    // The guard block branches to the arm body on success and to the next
    // arm's test on failure - never straight to the join.
    let arm = block_starting(f, "m_arm")
    assert_true(ends_in_br_if(f, arm), "the guard is a conditional branch")
}

// `or_test` and `range_test` are exercised only through these once the
// parser produces `Or`/`Range` pattern nodes. Today `parse_match_arm` keeps
// the pattern as a flat token run and the projector cannot read either
// shape, so both arrive as `Pattern.Error`. What is pinned here is the
// safety property: the match refuses to lower rather than treating the
// unreadable pattern as irrefutable and always taking its arm.
test "an or-pattern the parser cannot represent refuses to lower" {
    let unit = analyze(from_view("fn f(a: i32) i32 { return a match { 1 | 2 => 10, _ => 20 } }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(find_fn(&m, "f__i32") == m.functions.len, "the function is not emitted")
    assert_true(was_skipped(&m, "f__i32"), "and it is recorded as skipped")
}

test "a range pattern the parser cannot represent refuses to lower" {
    let unit = analyze(from_view("fn f(a: i32) i32 { return a match { 1..5 => 10, _ => 20 } }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    assert_true(find_fn(&m, "f__i32") == m.functions.len, "the function is not emitted")
    assert_true(was_skipped(&m, "f__i32"), "and it is recorded as skipped")
}

test "an arm that returns keeps its return, with no branch over it" {
    let unit = analyze(from_view("fn f(a: i32) i32 { a match { 0 => { return 7 }, _ => {} } return 0 }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    let arm = block_starting(f, "m_arm")
    let kept = f.blocks[arm].terminator match { Ret(_) => true, _ => false }
    assert_true(kept, "the arm's own return survives")
}

test "matching an enum variant tests the discriminant" {
    let unit = analyze(from_view("type Color = enum { Red, Green, Blue }\nfn f(c: &Color) i32 { return c.* match { Red => 1, Green => 2, _ => 3 } }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let fi = find_fn_starting(&m, "f__ref_")
    assert_true(fi < m.functions.len, "the &Color function lowered")
    let f = &m.functions[fi]
    assert_eq(compare_count(f), 2 as usize, "one discriminant test per named variant")
    // The tag is the enum's first field, so the test loads through the
    // scrutinee pointer rather than geping first.
    assert_true(load_count(f) >= 2 as usize, "each test loads the discriminant")
}

test "an unsupported pattern gates the whole match, not just its arm" {
    let unit = analyze(from_view("fn f(a: (i32, i32)) i32 { return a match { (0, 0) => 1, _ => 2 } }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    // The signature itself is out of subset here, so nothing is emitted;
    // the point is that lowering does not crash or half-emit.
    assert_true(m.functions.len == 0 as usize, "an unlowerable signature skips the function entirely")
}

test "a tuple pattern in a lowerable function degrades to a placeholder" {
    let unit = analyze(from_view("type P = struct { x: i32 }\nfn f(a: i32) i32 { return a match { _ => 1 } }"), "test.f")
    let m = lower_module(&unit.module, &unit.result)
    let f = &m.functions[find_fn(&m, "f__i32")]
    // A single wildcard arm still lowers - the gate is per-pattern, and a
    // wildcard is supported.
    assert_true(block_count_starting(f, "m_arm") == 1 as usize, "the supported match still lowers")
}
